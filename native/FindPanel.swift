import AppKit

private struct FindHit: Decodable, Equatable {
  let name: String
  let path: String
  let relativePath: String
  let kind: String
  let isDirectory: Bool
}

private struct FindPage: Decodable {
  let ok: Bool
  let error, rootError: String?
  let entries: [FindHit]?
  let total, scanned, folders, errors, permissionErrors, omitted: Int?
  let limited, complete: Bool?
}

private final class FindSheet: NSPanel {
  var handleKey: ((NSEvent) -> Bool)?
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, handleKey?(event) == true { return }
    super.sendEvent(event)
  }
}

private final class FindCell: NSTableCellView {
  private let glyph = NSImageView()
  private let filename = label("", font(14, .semibold), Ink.text)
  private let parentPath = label("", mono(10.5), Ink.quiet)

  override init(frame: NSRect) {
    super.init(frame: frame)
    [glyph, filename, parentPath].forEach(addSubview)
    textField = filename
    filename.lineBreakMode = .byTruncatingMiddle
    parentPath.lineBreakMode = .byTruncatingHead
  }
  required init?(coder: NSCoder) { fatalError() }

  func display(_ hit: FindHit, selected: Bool) {
    let parent = (hit.relativePath as NSString).deletingLastPathComponent
    filename.stringValue = hit.name
    parentPath.stringValue = parent.isEmpty ? "This folder" : parent
    let entry = Entry(
      name: hit.name, path: hit.path, kind: hit.kind,
      isDirectory: hit.isDirectory, size: nil, modified: nil)
    glyph.image = symbol(RowArt.glyph(entry), 17)
    toolTip = hit.path
    setAccessibilityLabel(hit.name + ", " + parentPath.stringValue)
    highlight(selected)
  }

  func highlight(_ selected: Bool) {
    filename.textColor = selected ? Ink.onSelection : Ink.text
    parentPath.textColor = selected ? Ink.onSelection.withAlphaComponent(0.78) : Ink.quiet
    glyph.contentTintColor = selected ? Ink.onSelection : Ink.lime
  }

  override func layout() {
    super.layout()
    position(glyph, 9, (bounds.height - 22) / 2, 22, 22)
    position(filename, 41, 21, bounds.width - 52, 19)
    position(parentPath, 41, 5, bounds.width - 52, 14)
  }
}

private final class FindRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    Ink.selected.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
  }
  override var isSelected: Bool {
    didSet { for case let cell as FindCell in subviews { cell.highlight(isSelected) } }
  }
}

final class FindPanel: NSObject, NSSearchFieldDelegate, NSTableViewDelegate, NSTableViewDataSource {
  let panel: NSPanel
  private let parent: NSWindow
  private let engine: Engine
  private let root: URL
  private let showHidden: Bool
  private let completion: (URL?) -> Void
  private let worker = DispatchQueue(label: "finger.find-picker", qos: .userInitiated)
  private let search = NSSearchField()
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let status = label("", font(11), Ink.quiet, "find-status")
  private let empty = label("Type a filename to search.", font(14), Ink.quiet)
  private let reveal = NSButton(title: "Reveal", target: nil, action: nil)
  private var hits: [FindHit] = []
  private var session: String?
  private var revision = 0
  private var currentResults: Int?
  private var pending: DispatchWorkItem?
  private var inFlight = false
  private var closed = false
  private var adjustingSelection = false
  private var explicitlySelected = false

  init(
    parent: NSWindow, engine: Engine, root: URL, showHidden: Bool,
    completion: @escaping (URL?) -> Void
  ) {
    self.parent = parent
    self.engine = engine
    self.root = root
    self.showHidden = showHidden
    self.completion = completion
    let bounds = parent.contentView?.bounds.size ?? NSSize(width: 700, height: 500)
    panel = FindSheet(
      contentRect: NSRect(
        x: 0, y: 0, width: max(360, min(610, bounds.width - 40)),
        height: max(225, min(425, bounds.height - 68))),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = "Find in Subfolders"
    panel.appearance = parent.appearance
    panel.isReleasedWhenClosed = false
    panel.contentMinSize = NSSize(width: 360, height: 225)
    let surface = LayoutRoot(color: Ink.main)
    panel.contentView = surface
    let heading = label("Find in " + rootName, font(17, .semibold), Ink.text)
    heading.toolTip = root.path
    search.placeholderString = "Search filenames"
    search.setAccessibilityLabel("Find files and folders by name")
    search.setAccessibilityIdentifier("find-name")
    search.delegate = self
    search.sendsSearchStringImmediately = true
    let column = NSTableColumn(identifier: .init("result"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.headerView = nil
    table.style = .plain
    table.rowHeight = 43
    table.intercellSpacing = .zero
    table.backgroundColor = Ink.well
    table.focusRingType = .none
    table.allowsEmptySelection = false
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.doubleAction = #selector(openClicked)
    table.setAccessibilityLabel("Matching files and folders")
    table.setAccessibilityIdentifier("find-results")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = true
    scroll.backgroundColor = Ink.well
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 5
    empty.alignment = .center
    reveal.target = self
    reveal.action = #selector(openSelected)
    reveal.keyEquivalent = "\r"
    reveal.isEnabled = false
    reveal.setAccessibilityIdentifier("find-reveal")
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    (panel as? FindSheet)?.handleKey = { [weak self] event in self?.key(event) ?? false }
    for view in [heading, search, scroll, empty, status, cancel, reveal] {
      surface.addSubview(view)
    }
    surface.arrange = { [weak surface, weak self] in
      guard let surface, let self else { return }
      let w = surface.bounds.width
      let h = surface.bounds.height
      position(heading, 17, 11, w - 34, 23)
      position(search, 16, 43, w - 32, 26)
      position(scroll, 16, 79, w - 32, h - 130)
      position(empty, 25, 79 + (h - 150) / 2, w - 50, 20)
      position(status, 18, h - 36, w - 190, 20)
      position(cancel, w - 170, h - 40, 73, 29)
      position(reveal, w - 91, h - 40, 76, 29)
    }
  }

  private var rootName: String { root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent }

  func present() {
    parent.beginSheet(panel) { [weak self] _ in self?.finish(nil) }
    panel.makeFirstResponder(search)
    status.stringValue = "Starting index…"
    let options: [String: Any] = ["op": "startFind", "path": root.path, "showHidden": showHidden]
    worker.async { [weak self, engine, worker] in
      let result = Result { () throws -> String in
        guard let id = try engine.call(options)["session"] as? String else {
          throw CoreError(message: "The search index did not start.")
        }
        return id
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed else {
          if case .success(let id) = result {
            worker.async { _ = try? engine.call(["op": "endFind", "session": id]) }
          }
          return
        }
        switch result {
        case .success(let id):
          self.session = id
          self.schedule(after: 0)
        case .failure(let error): self.showError(error)
        }
      }
    }
  }

  @objc func cancel() { finish(nil) }

  private func finish(_ choice: URL?) {
    guard !closed else { return }
    closed = true
    pending?.cancel()
    if let id = session {
      worker.async { [engine] in _ = try? engine.call(["op": "endFind", "session": id]) }
    }
    if panel.sheetParent != nil { parent.endSheet(panel) }
    panel.orderOut(nil)
    completion(choice)
  }

  func controlTextDidChange(_ obj: Notification) {
    revision += 1
    explicitlySelected = false
    reveal.isEnabled = false
    schedule(after: 0.035)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
    switch command {
    case #selector(NSResponder.moveDown(_:)): step(1)
    case #selector(NSResponder.moveUp(_:)): step(-1)
    case #selector(NSResponder.insertNewline(_:)): openSelected()
    case #selector(NSResponder.cancelOperation(_:)): cancel()
    default: return false
    }
    return true
  }

  private func key(_ event: NSEvent) -> Bool {
    guard (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
    switch event.keyCode {
    case 53:
      cancel()
      return true
    case 36, 76:
      guard panel.firstResponder === table || panel.firstResponder === search.currentEditor() else {
        return false
      }
      openSelected()
      return true
    default: break
    }
    guard panel.firstResponder === table,
      event.modifierFlags.isDisjoint(with: [.command, .control]),
      let value = event.characters, !value.isEmpty,
      value.unicodeScalars.allSatisfy({
        $0.properties.generalCategory != .privateUse && !CharacterSet.controlCharacters.contains($0)
      })
    else { return false }
    panel.makeFirstResponder(search)
    if let editor = search.currentEditor() as? NSTextView {
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
      editor.keyDown(with: event)
    }
    return true
  }

  private func step(_ distance: Int) {
    guard currentResults == revision, !hits.isEmpty else { return }
    let row = min(hits.count - 1, max(0, table.selectedRow + distance))
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  @objc private func openSelected() {
    guard currentResults == revision, hits.indices.contains(table.selectedRow) else { return }
    let hit = hits[table.selectedRow]
    finish(URL(fileURLWithPath: hit.path, isDirectory: hit.isDirectory))
  }

  @objc private func openClicked() {
    guard table.clickedRow >= 0 else { return }
    openSelected()
  }

  private func schedule(after delay: TimeInterval) {
    pending?.cancel()
    guard !closed, session != nil else { return }
    let task = DispatchWorkItem { [weak self] in self?.fetch() }
    pending = task
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
  }

  private func fetch() {
    guard !closed, !inFlight, let id = session else { return }
    inFlight = true
    let token = revision
    let query = search.stringValue
    worker.async { [weak self, engine] in
      let result = Result { () throws -> FindPage in
        let bytes = try engine.data(["op": "find", "session": id, "query": query, "limit": 100])
        let page = try JSONDecoder().decode(FindPage.self, from: bytes)
        guard page.ok, page.entries != nil, page.complete != nil else {
          throw CoreError(message: page.error ?? "Couldn’t read the search index.")
        }
        return page
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed else { return }
        self.inFlight = false
        guard self.revision == token else {
          self.schedule(after: 0)
          return
        }
        switch result {
        case .success(let page):
          self.apply(page, query: query)
          if page.complete == false { self.schedule(after: query.isEmpty ? 0.55 : 0.28) }
        case .failure(let error): self.showError(error)
        }
      }
    }
  }

  private func apply(_ page: FindPage, query: String) {
    if let error = page.rootError {
      showError(CoreError(message: error))
      return
    }
    let next = page.entries ?? []
    let sameQuery = currentResults == revision
    if next != hits || !sameQuery {
      let previousRow = table.selectedRow
      let selectionWasVisible =
        previousRow >= 0 && NSLocationInRange(previousRow, table.rows(in: table.visibleRect))
      let old =
        sameQuery && explicitlySelected && hits.indices.contains(table.selectedRow)
        ? hits[table.selectedRow].path : nil
      adjustingSelection = true
      hits = next
      table.reloadData()
      if !hits.isEmpty {
        let index = old.flatMap { path in hits.firstIndex { $0.path == path } } ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if !sameQuery || (old != nil && selectionWasVisible && previousRow != index) {
          table.scrollRowToVisible(index)
        }
      }
      adjustingSelection = false
    }
    currentResults = revision
    reveal.isEnabled = !hits.isEmpty && table.selectedRow >= 0
    empty.isHidden = !hits.isEmpty
    let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    empty.stringValue =
      blank
      ? "Type a filename to search."
      : page.complete == true ? "No matching filenames." : "Searching…"
    let total = page.total ?? hits.count
    let scanned = page.scanned ?? 0
    var detail: [String] = []
    if !blank {
      detail.append(
        total > hits.count
          ? "\(hits.count) of \(total.formatted()) matches"
          : "\(total.formatted()) " + (total == 1 ? "match" : "matches"))
    }
    if page.complete == false {
      detail.append("Indexing · \(scanned.formatted()) items")
    } else if blank {
      detail.append("\(scanned.formatted()) items indexed")
    }
    if page.limited == true { detail.append("Index limit reached") }
    if let errors = page.errors, errors > 0 { detail.append("\(errors.formatted()) unreadable") }
    if let omitted = page.omitted, omitted > 0 { detail.append("\(omitted.formatted()) omitted") }
    status.stringValue = detail.joined(separator: " · ")
    var fullStatus = detail
    if let folders = page.folders { fullStatus.append("\(folders.formatted()) folders visited") }
    if let denied = page.permissionErrors, denied > 0 {
      fullStatus.append("\(denied.formatted()) denied by permissions")
    }
    status.toolTip = fullStatus.joined(separator: " · ")
    status.setAccessibilityLabel(status.toolTip)
    status.textColor = page.limited == true || (page.errors ?? 0) > 0 ? Ink.issue : Ink.quiet
  }

  private func showError(_ error: Error) {
    hits.removeAll()
    currentResults = nil
    table.reloadData()
    reveal.isEnabled = false
    empty.isHidden = false
    empty.stringValue = "Search unavailable"
    status.textColor = Ink.issue
    status.stringValue = error.localizedDescription
    status.toolTip = error.localizedDescription
    status.setAccessibilityLabel(error.localizedDescription)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let id = NSUserInterfaceItemIdentifier("FindResultRow")
    let view = tableView.makeView(withIdentifier: id, owner: self) as? FindRow ?? FindRow()
    view.identifier = id
    return view
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard hits.indices.contains(row) else { return nil }
    let id = NSUserInterfaceItemIdentifier("find-result")
    let cell = table.makeView(withIdentifier: id, owner: self) as? FindCell ?? FindCell()
    cell.identifier = id
    cell.display(hits[row], selected: table.isRowSelected(row))
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if !adjustingSelection { explicitlySelected = true }
    reveal.isEnabled = currentResults == revision && hits.indices.contains(table.selectedRow)
  }
}
