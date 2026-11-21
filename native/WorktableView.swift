import AppKit

/// The home selection is independent of the folder browser's saved selection.
final class WorktableView: Flipped, NSSearchFieldDelegate {
  var onSelection: (([Entry]) -> Void)?
  var onBrowse: (() -> Void)?
  var onChooseProject: (() -> Void)?
  var onPractice: (() -> Void)?
  var onPreview: (() -> Void)?
  var onHandoff: (() -> Void)?

  let query = NSSearchField()
  private(set) var visibleGroups: [ResumeGroup] = []
  private(set) var selected: [Entry] = []
  private var catalog: ResumeCatalog?
  private var cards: [WorktableCard] = []
  private let top = TopArea(color: Ink.rail)
  private let mark = Mark()
  private let brand = label("Finger", font(20, .bold), Ink.text)
  private let mode = label("Worktable", font(13, .medium), Ink.lime)
  private let slash = label("/", mono(15), Ink.faint)
  private lazy var browse = ActionButton(
    "Browse folders", icon: "folder", help: "Browse folders (⌘2)"
  ) {
    [weak self] in self?.onBrowse?()
  }
  private lazy var projectMenu = ActionButton(
    "Change project", icon: "chevron.down", help: "Choose a project"
  ) {
    [weak self] in self?.chooseProject()
  }
  private lazy var preview = ActionButton("Preview", icon: "eye", help: "Preview selection (Space)")
  {
    [weak self] in self?.previewFiles()
  }
  private let handoff = WorktableButton("Hand to Codex", primary: true)
  private let selectionInfo = label("", font(15, .semibold), Ink.text)
  private let selectionDetail = label("", mono(10.5), Ink.quiet)
  private let footer = Flipped(color: Ink.rail)
  private let scroll = NSScrollView()
  private let page = Flipped(color: Paper.desk)
  private let context = label("CURRENT PROJECT", mono(10.5, .semibold), Paper.green)
  private let titleField = label("", Paper.serif(46), Paper.ink, "Worktable project")
  private let divider = Flipped(color: Paper.line)
  private let section = label("Suggested files", font(17, .semibold), Paper.ink)
  private let hint = label("⌘-click to select multiple", mono(10.5), Paper.muted)
  private let empty = label("", font(17, .medium), Paper.muted, "Worktable status")
  private var report: String?
  private var noticeTicket = 0
  private var lastQuery = ""
  private var userSelected = false
  private var scanned = false
  private var projectPath = ""

  override init(color: NSColor? = Paper.desk) {
    super.init(color: color)
    setAccessibilityIdentifier("Worktable")
    appearance = NSAppearance(named: .aqua)
    top.appearance = NSAppearance(named: .darkAqua)
    footer.appearance = NSAppearance(named: .darkAqua)
    query.placeholderString = "Narrow files"
    query.font = font(13)
    query.sendsSearchStringImmediately = true
    query.sendsWholeSearchString = false
    query.delegate = self
    query.setAccessibilityLabel("Narrow worktable files")
    query.toolTip = "Type a filename, folder, or extension (⌘F)"
    projectMenu.contentTintColor = Paper.ink
    projectMenu.imagePosition = .imageTrailing
    handoff.target = self
    handoff.action = #selector(handFiles)
    handoff.toolTip = "Open the selected file paths in a Codex draft"
    handoff.setAccessibilityLabel(handoff.title)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = page
    for view in [top, scroll, footer] { addSubview(view) }
    for view in [mark, brand, slash, mode, browse, query] { top.addSubview(view) }
    for view in [context, titleField, projectMenu, divider, section, hint, empty] {
      page.addSubview(view)
    }
    for view in [selectionInfo, selectionDetail, preview, handoff] { footer.addSubview(view) }
    hint.alignment = .right
    empty.alignment = .center
    empty.maximumNumberOfLines = 3
    empty.lineBreakMode = .byWordWrapping
    updateSelection()
  }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }

  @objc private func previewFiles() { if !selected.isEmpty { onPreview?() } }
  @objc private func handFiles() { if !selected.isEmpty { onHandoff?() } }
  @objc private func chooseProject() {
    let menu = NSMenu()
    menu.addItem(CommandItem("Choose Project Folder…") { [weak self] in self?.onChooseProject?() })
    menu.addItem(CommandItem("Open Practice Project") { [weak self] in self?.onPractice?() })
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: projectMenu.bounds.height), in: projectMenu)
  }

  func begin(project: String) {
    projectPath = project
    titleField.stringValue =
      project == "/" ? "Macintosh HD" : URL(fileURLWithPath: project).lastPathComponent
    titleField.toolTip = project
    catalog = nil
    report = nil
    scanned = false
    query.stringValue = ""
    selected = []
    userSelected = false
    scroll.contentView.scroll(to: .zero)
    refreshResults()
  }
  func show(_ catalog: ResumeCatalog) {
    // A replacement can keep its name, size, and rounded modification time.
    // A fresh scan must also refresh the artwork; filtering reuses these views.
    for card in cards { card.removeFromSuperview() }
    cards.removeAll()
    self.catalog = catalog
    scanned = true
    report = nil
    refreshResults()
  }
  func showError(_ message: String) {
    catalog = nil
    scanned = true
    report = message
    refreshResults()
  }
  func refreshResults() {
    visibleGroups = catalog?.matching(query.stringValue, limit: 3) ?? []
    // Rebuild only changed cards while typing. Thumbnail requests belong to the card's lifetime.
    let previous = cards
    cards = visibleGroups.map { group in
      if let card = previous.first(where: {
        $0.group.files == group.files && $0.group.reason == group.reason
          && $0.group.changed == group.changed
      }) {
        return card
      }
      let card = WorktableCard(
        group,
        choose: { [weak self] entries, extending in
          self?.select(entries, extending: extending)
          self?.window?.makeFirstResponder(self)
        }, preview: { [weak self] in self?.previewFiles() })
      page.addSubview(card)
      return card
    }
    for old in previous where !cards.contains(old) { old.removeFromSuperview() }
    let entries = visibleGroups.flatMap(\.files)
    if lastQuery != query.stringValue { userSelected = false }
    let retained = lastQuery == query.stringValue ? Set(selected.map(\.path)) : []
    lastQuery = query.stringValue
    selected = entries.filter { retained.contains($0.path) }
    if selected.isEmpty, !userSelected, let first = visibleGroups.first {
      selected = [first.primary]
    }
    empty.stringValue =
      report
      ?? (!scanned
        ? "Gathering project files…"
        : (query.stringValue.isEmpty
          ? "No files to suggest in this project." : "No matching files."))
    empty.toolTip = report
    empty.isHidden = !cards.isEmpty
    section.stringValue = query.stringValue.isEmpty ? "Suggested files" : "Matching files"
    hint.isHidden = cards.isEmpty
    updateSelection()
    needsLayout = true
  }
  func select(_ entries: [Entry], extending: Bool = false) {
    userSelected = true
    if extending {
      let paths = Set(entries.map(\.path))
      let alreadySelected = paths.isSubset(of: Set(selected.map(\.path)))
      selected.removeAll { paths.contains($0.path) }
      if !alreadySelected { selected.append(contentsOf: entries) }
    } else {
      selected = entries
    }
    updateSelection()
  }
  private func updateSelection() {
    let paths = Set(selected.map(\.path))
    for card in cards { card.updateSelection(paths) }
    preview.isEnabled = !selected.isEmpty
    handoff.isEnabled = !selected.isEmpty
    selectionInfo.stringValue =
      selected.count == 1
      ? (selected.first?.name ?? "")
      : selected.isEmpty ? "No selection" : "\(selected.count) files selected"
    let detail =
      selected.count == 1
      ? selected.first.map { entry in
        let parent = entry.url.deletingLastPathComponent().path
        let base = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        return parent.hasPrefix(base)
          ? String(parent.dropFirst(base.count)) : (parent as NSString).lastPathComponent
      } : nil
    selectionDetail.stringValue = detail ?? selected.map(\.name).joined(separator: "  +  ")
    selectionDetail.toolTip = selected.map(\.path).joined(separator: "\n")
    noticeTicket += 1
    onSelection?(selected)
  }
  func notice(_ message: String) {
    noticeTicket += 1
    let ticket = noticeTicket
    selectionDetail.stringValue = message
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      guard let self, self.noticeTicket == ticket else { return }
      updateSelection()
    }
  }
  override func layout() {
    super.layout()
    let w = bounds.width
    let h = bounds.height
    let pad: CGFloat = w < 850 ? 24 : 38
    let topHeight: CGFloat = 56
    let footerHeight: CGFloat = 62
    position(top, 0, 0, w, topHeight)
    position(mark, 85, 14, 27, 27)
    position(brand, 119, 13, 70, 30)
    position(slash, 192, 19, 16, 20)
    position(mode, 211, 18, 95, 20)
    let searchWidth = min(256, w * 0.24)
    position(browse, w - pad - 128 - searchWidth, 14, 119, 28)
    position(query, w - pad - searchWidth, 14, searchWidth, 28)
    position(scroll, 0, topHeight, w, h - topHeight - footerHeight)
    let pw = scroll.contentSize.width
    let width = pw - 2 * pad
    let wide = width >= 785
    let headerH: CGFloat = wide ? 153 : 138
    let gap: CGFloat = 16
    let deckH = max(320, min(470, scroll.contentSize.height - headerH - 26))
    let trailingRows = max(0, cards.count - 1)
    let narrowH = CGFloat(trailingRows) * (150 + gap)
    let cardArea = cards.isEmpty ? 150 : (wide ? deckH : 315 + narrowH)
    page.frame = NSRect(
      x: 0, y: 0, width: pw, height: max(scroll.contentSize.height, headerH + cardArea + 24))
    position(context, pad, wide ? 26 : 18, width - 160, 17)
    position(titleField, pad - 2, wide ? 45 : 37, width - 137, 61)
    position(projectMenu, pw - pad - 123, wide ? 60 : 51, 123, 28)
    position(divider, pad, headerH - 48, width, 1)
    position(section, pad, headerH - 35, width - 205, 24)
    position(hint, pw - pad - 210, headerH - 32, 210, 18)
    position(empty, pad, headerH + 25, width, 76)
    let left = cards.count == 1 ? width : floor((width - gap) * 0.55)
    for (index, card) in cards.enumerated() {
      card.compact = index > 0
      if wide && index > 0 {
        let height = (deckH - CGFloat(trailingRows - 1) * gap) / CGFloat(trailingRows)
        position(
          card, pad + left + gap, headerH + CGFloat(index - 1) * (height + gap), width - left - gap,
          height)
      } else if wide {
        position(card, pad, headerH, left, deckH)
      } else {
        let y = index == 0 ? headerH : headerH + 315 + gap + CGFloat(index - 1) * (150 + gap)
        position(card, pad, y, width, index == 0 ? 315 : 150)
      }
    }
    position(footer, 0, h - footerHeight, w, footerHeight)
    position(selectionInfo, pad, 9, width - 280, 22)
    position(selectionDetail, pad, 34, width - 280, 17)
    position(preview, w - pad - 237, 16, 91, 30)
    position(handoff, w - pad - 135, 13, 135, 36)
  }

  func focusSearch(select: Bool) {
    window?.makeFirstResponder(query)
    if select { query.currentEditor()?.selectAll(nil) }
  }
  func controlTextDidChange(_ obj: Notification) { refreshResults() }
  private func clearQuery() {
    query.stringValue = ""
    refreshResults()
    window?.makeFirstResponder(self)
  }
  private func step(_ delta: Int) {
    let files = visibleGroups.flatMap(\.files)
    guard !files.isEmpty else { return }
    let current = files.firstIndex { $0.path == selected.last?.path } ?? -1
    let next = files[min(files.count - 1, max(0, current + delta))]
    select([next])
    if let card = cards.first(where: { $0.group.files.contains(next) }) {
      card.scrollToVisible(card.bounds)
    }
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)): clearQuery()
    case #selector(NSResponder.moveDown(_:)): window?.makeFirstResponder(self)
    case #selector(NSResponder.moveUp(_:)): window?.makeFirstResponder(self)
    case #selector(NSResponder.insertNewline(_:)): previewFiles()
    default: return false
    }
    return true
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 49, 36, 76: previewFiles()
    case 53: clearQuery()
    case 123, 126: step(-1)
    case 124, 125: step(1)
    default:
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
        let chars = event.characters, !chars.isEmpty,
        !chars.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .privateUse
            || CharacterSet.controlCharacters.contains($0)
        })
      else {
        super.keyDown(with: event)
        return
      }
      focusSearch(select: false)
      if let editor = query.currentEditor() as? NSTextView {
        editor.insertText(chars, replacementRange: editor.selectedRange())
      }
    }
  }
}
