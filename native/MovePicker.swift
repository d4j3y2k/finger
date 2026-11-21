import AppKit

final class MovePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let panel: NSPanel
  let table = NSTableView()
  private let action: NSButton
  private let hint = label("", font(12), Ink.quiet)
  private let jev = NSButton()
  private var choices: [URL]
  private let sources: [URL]
  private let parent: NSWindow
  private let project: URL?
  private let move: Bool
  private let select: (URL?) -> Void
  private var closed = false
  private var request: Task<Void, Never>?
  init(
    parent: NSWindow, sources: [URL], sourceCount: Int? = nil, candidates: [URL], move: Bool,
    project: URL? = nil,
    select: @escaping (URL?) -> Void
  ) {
    self.project = project
    self.parent = parent
    self.sources = sources
    choices = candidates
    self.move = move
    self.select = select
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 518, height: 390), styleMask: [.titled],
      backing: .buffered, defer: false)
    let verb = move ? "Move" : "Copy"
    action = NSButton(title: verb, target: nil, action: nil)
    super.init()
    panel.appearance = parent.appearance
    panel.title = verb + " to Folder"
    panel.isReleasedWhenClosed = false
    let root = Flipped(color: Ink.main)
    panel.contentView = root
    let total = sourceCount ?? sources.count
    let desc = label(
      total == 1
        ? verb + " " + sources[0].lastPathComponent : "\(verb) \(total.formatted()) items",
      font(23, .semibold), Ink.text)
    let sub = label("Choose a destination", font(13), Ink.quiet)
    let scroll = NSScrollView()
    table.addTableColumn(NSTableColumn(identifier: .init("folders")))
    table.headerView = nil
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.rowHeight = 40
    table.style = .plain
    table.backgroundColor = Ink.well
    table.focusRingType = .none
    table.allowsEmptySelection = false
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(confirm)
    table.setAccessibilityLabel("Destination folders")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = true
    scroll.backgroundColor = Ink.well
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 5
    let browse = NSButton(title: "Other folder…", target: self, action: #selector(browse))
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    action.target = self
    action.action = #selector(confirm)
    action.keyEquivalent = "\r"
    action.isEnabled = !candidates.isEmpty
    jev.title = "Rank with Jev"
    jev.target = self
    jev.action = #selector(rank)
    jev.toolTip = "Sends selected filenames and destination folder names to TypeSafe."
    jev.isHidden = !DestinationRanker.jevConfigured || choices.count < 2
    hint.lineBreakMode = .byTruncatingTail
    for view in [desc, sub, scroll, browse, jev, cancel, action, hint] { root.addSubview(view) }
    position(desc, 20, 15, 475, 31)
    position(sub, 21, 53, 465, 19)
    position(scroll, 20, 82, 478, 226)
    position(hint, 21, 315, 476, 17)
    position(browse, 16, 345, 116, 29)
    position(jev, 134, 345, 115, 29)
    position(cancel, 327, 345, 78, 29)
    position(action, 407, 345, 89, 29)
    if choices.isEmpty { hint.stringValue = "Choose another folder to continue." }
    table.reloadData()
    if !choices.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }
  func present() {
    parent.beginSheet(panel)
    panel.makeFirstResponder(table)
  }
  func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard choices.indices.contains(row) else { return nil }
    let url = choices[row]
    let cell = NSTableCellView()
    let name = label(
      url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent, font(13, .semibold), Ink.text)
    let folder = url.deletingLastPathComponent().path
    let parentLabel: String
    if let project, url.path == project.path {
      parentLabel = "Project folder"
    } else if let project, folder == project.path {
      parentLabel = "This project · " + project.lastPathComponent
    } else if let project, folder.hasPrefix(project.path + "/") {
      parentLabel = "This project · " + String(folder.dropFirst(project.path.count + 1))
    } else {
      parentLabel = (folder as NSString).abbreviatingWithTildeInPath
    }
    let path = label(parentLabel, mono(9.5), Ink.quiet)
    path.lineBreakMode = .byTruncatingMiddle
    cell.toolTip = url.path
    let icon = NSImageView(image: symbol("folder", 16) ?? NSImage())
    icon.contentTintColor = Ink.lime
    cell.addSubview(icon)
    cell.addSubview(name)
    cell.addSubview(path)
    position(icon, 8, 11, 23, 19)
    position(name, 40, 20, 418, 18)
    position(path, 40, 3, 418, 15)
    cell.textField = name
    cell.setAccessibilityLabel(url.path)
    return cell
  }
  @objc func confirm() {
    guard choices.indices.contains(table.selectedRow) else { return }
    finish(choices[table.selectedRow])
  }
  @objc func cancel() { finish(nil) }
  private func finish(_ url: URL?) {
    guard !closed else { return }
    closed = true
    request?.cancel()
    parent.endSheet(panel)
    panel.orderOut(nil)
    select(url)
  }
  @objc private func browse() {
    let chooser = NSOpenPanel()
    chooser.canChooseFiles = false
    chooser.canChooseDirectories = true
    chooser.prompt = move ? "Move here" : "Copy here"
    chooser.directoryURL = choices.first ?? sources.first?.deletingLastPathComponent()
    chooser.beginSheetModal(for: panel) { [weak self] response in
      if response == .OK, let dest = chooser.url { self?.finish(dest) }
    }
  }
  @objc private func rank() {
    jev.isEnabled = false
    hint.stringValue = "Asking Jev to rank these destinations…"
    let candidates = choices
    let initialChoice =
      choices.indices.contains(table.selectedRow) ? choices[table.selectedRow] : nil
    request = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let ranked = try await DestinationRanker.rankWithJev(
          sources: sources, candidates: candidates, project: project)
        guard !closed, !Task.isCancelled else { return }
        let latestChoice =
          choices.indices.contains(table.selectedRow) ? choices[table.selectedRow] : nil
        let index =
          latestChoice != initialChoice
          ? latestChoice.flatMap { ranked.firstIndex(of: $0) } ?? 0 : 0
        choices = ranked
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        hint.stringValue = "Destinations ranked by Jev."
      } catch {
        guard !closed else { return }
        hint.stringValue = error.localizedDescription
        hint.toolTip = error.localizedDescription
      }
      jev.isEnabled = true
    }
  }
}
