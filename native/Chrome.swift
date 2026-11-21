import AppKit

final class RailLink: NSButton {
  private(set) var key: String
  var dropFiles: ((FileDrop.Payload, String, Bool) -> Bool)?
  var canDropFiles: (() -> Bool)?
  private var targeted = false { didSet { if oldValue != targeted { needsDisplay = true } } }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let allowed = key.hasPrefix("/") && canDropFiles?() == true ? FileDrop.operation(sender) : []
    targeted = !allowed.isEmpty
    return allowed
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
  override func draggingEnded(_ sender: NSDraggingInfo) { targeted = false }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    targeted = false
    guard canDropFiles?() == true else { return false }
    let operation = FileDrop.operation(sender)
    guard !operation.isEmpty, key.hasPrefix("/"), let payload = FileDrop.payload(sender) else {
      return false
    }
    return dropFiles?(payload, key, operation == .move) ?? false
  }
  var menuForLink: ((String) -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? { menuForLink?(key) }
  var selected = false { didSet { if oldValue != selected { needsDisplay = true } } }
  private let invoke: (String) -> Void
  private var glyph: String
  private var display: String { title }
  init(
    _ title: String, glyph: String, key: String, tip: String, perform: @escaping (String) -> Void
  ) {
    self.key = key
    self.glyph = glyph
    invoke = perform
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    setButtonType(.momentaryChange)
    target = self
    action = #selector(pick)
    toolTip = tip
    setAccessibilityLabel(title)
    setAccessibilityHelp(tip)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError() }
  func update(title: String, glyph: String, key: String, tip: String) {
    if self.key != key {
      targeted = false
      self.key = key
    }
    if self.glyph != glyph {
      self.glyph = glyph
      needsDisplay = true
    }
    if self.title != title {
      self.title = title
      setAccessibilityLabel(title)
      needsDisplay = true
    }
    if toolTip != tip {
      toolTip = tip
      setAccessibilityHelp(tip)
    }
  }
  @objc private func pick() { invoke(key) }
  override func draw(_ dirtyRect: NSRect) {
    let active = selected || isHighlighted || targeted
    if active {
      Ink.raised.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    if targeted {
      Ink.lime.setStroke()
      let outline = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
      outline.lineWidth = 1.5
      outline.stroke()
    }
    let tone = selected || targeted ? Ink.lime : Ink.quiet
    if let im = symbol(glyph, 13, .medium) {
      let painted = im.copy() as! NSImage
      painted.lockFocus()
      tone.set()
      NSRect(origin: .zero, size: painted.size).fill(using: .sourceAtop)
      painted.unlockFocus()
      let f = NSSize(width: min(15, painted.size.width), height: min(15, painted.size.height))
      painted.draw(
        in: NSRect(x: 9, y: (bounds.height - f.height) / 2, width: f.width, height: f.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    (display as NSString).draw(
      in: NSRect(x: 32, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 38), height: 18),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .medium),
        .foregroundColor: selected ? Ink.text : Ink.quiet, .paragraphStyle: para,
      ])
  }
}
final class Rail: Flipped {
  struct Group {
    let title: String
    let links: [(String, String, String, String)]
  }
  private var sections: [(NSTextField, [RailLink])] = []
  private var headers: [String: NSTextField] = [:]
  private var linksByKey: [String: RailLink] = [:]
  private let scroller = NSScrollView()
  private let body = Flipped()
  private var groups: [Group] = []
  private var selectedKey = ""
  var pick: ((String) -> Void)?
  var context: ((String) -> NSMenu?)?
  var dropFiles: ((FileDrop.Payload, String, Bool) -> Bool)?
  var canDropFiles: (() -> Bool)?
  override init(color: NSColor? = Ink.rail) {
    super.init(color: color)
    scroller.drawsBackground = false
    scroller.hasVerticalScroller = true
    scroller.autohidesScrollers = true
    scroller.scrollerStyle = .overlay
    scroller.documentView = body
    addSubview(scroller)
  }
  required init?(coder: NSCoder) { fatalError() }
  func set(_ groups: [Group], selected: String) {
    self.groups = groups
    selectedKey = FolderReferences.key(selected)
    let keys = Set(groups.flatMap { $0.links.map { FolderReferences.key($0.2) } })
    var available = linksByKey.compactMap { keys.contains($0.key) ? nil : $0.value }
    var current: [String: RailLink] = [:]
    sections.removeAll(keepingCapacity: true)
    for header in headers.values { header.isHidden = true }
    for group in groups where !group.links.isEmpty {
      let title =
        headers[group.title] ?? label(group.title.uppercased(), mono(9.5, .semibold), Ink.faint)
      if title.superview == nil {
        body.addSubview(title)
        headers[group.title] = title
      }
      title.isHidden = false
      let links = group.links.map { item in
        let key = FolderReferences.key(item.2)
        let l =
          linksByKey[key] ?? available.popLast()
          ?? RailLink(item.0, glyph: item.1, key: item.2, tip: item.3) { [weak self] in
            self?.pick?($0)
          }
        l.update(title: item.0, glyph: item.1, key: item.2, tip: item.3)
        l.menuForLink = context
        l.dropFiles = dropFiles
        l.canDropFiles = canDropFiles
        l.selected = selectedKey == key
        if l.superview == nil { body.addSubview(l) }
        current[key] = l
        return l
      }
      sections.append((title, links))
    }
    for link in available { link.removeFromSuperview() }
    linksByKey = current
    needsLayout = true
  }
  func popUp(from button: NSButton) {
    navigationMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
  }
  func navigationMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for group in groups where !group.links.isEmpty {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      let heading = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for link in group.links {
        let item = CommandItem(link.0) { [weak self] in self?.pick?(link.2) }
        item.toolTip = link.3
        item.image = symbol(link.1, 12)
        item.state = FolderReferences.key(link.2) == selectedKey ? .on : .off
        menu.addItem(item)
      }
    }
    return menu
  }
  override func layout() {
    super.layout()
    scroller.frame = bounds
    var y: CGFloat = 26
    for (title, links) in sections {
      position(title, 18, y, bounds.width - 30, 15)
      y += 23
      for l in links {
        position(l, 8, y, bounds.width - 16, 30)
        y += 31
      }
      y += 24
    }
    body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
  }
}
final class DividerHandle: NSView {
  var dragTo: ((CGFloat) -> Void)?
  var reset: (() -> Void)?
  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { reset?() }
  }
  override func mouseDragged(with event: NSEvent) { dragTo?(event.locationInWindow.x) }
}
final class TopArea: Flipped {
  override var mouseDownCanMoveWindow: Bool { true }
}
final class BrowserShell {
  let root = LayoutRoot(color: Ink.main)
  let top = TopArea(color: Ink.rail)
  let topRule = Flipped(color: Ink.rule)
  let mark = Mark()
  let wordmark = label("Finger", font(18, .bold), Ink.text)
  let rail = Rail()
  let railRule = Flipped(color: Ink.rule)
  let body = Flipped(color: Ink.main)
  let divider = Flipped(color: Ink.rule)
  let handle = DividerHandle()
  let preview = PreviewPane()
  let bottom = Flipped(color: Ink.rail)
  let bottomRule = Flipped(color: Ink.rule)
  let heading = label("", font(32, .bold), Ink.text, "Folder name")
  let crumb = PathBar()
  let columns = NSButton(title: "", target: nil, action: nil)
  let sizes = label("SIZE", mono(9.5, .semibold), Ink.faint)
  let columnRule = Flipped(color: Ink.rule)
  let scroll = NSScrollView()
  let table = BrowserTable()
  let query = NSSearchField()
  let status = label("", mono(10.5), Ink.quiet, "Browser status")
  let count = label("", mono(10.5), Ink.quiet, "Item count")
  let empty = label("", font(15, .medium), Ink.quiet, "Empty or unavailable folder")
  let emptyDetail = label("", font(12), Ink.quiet, "Folder error detail")
  var retryOpeningFolder: (() -> Void)?
  lazy var retry = ActionButton(
    "Try Again", icon: "arrow.clockwise", help: "Retry opening this folder"
  ) { [weak self] in
    self?.retryOpeningFolder?()
  }
  var showsSizes = true
  var order: FileOrder? = .nameAsc { didSet { root.needsLayout = true } }
  var onWorktable: (() -> Void)?
  lazy var worktable = ActionButton("Worktable", icon: "square.grid.2x2", help: "Show worktable (⌘1)") {
    [weak self] in self?.onWorktable?()
  }
  var agents: ActionButton!
  var back: ActionButton!, forward: ActionButton!, up: ActionButton!, open: ActionButton!,
    sidebar: ActionButton!, actions: ActionButton!, move: ActionButton!
  var fraction: CGFloat = UserDefaults.standard.object(forKey: "previewFraction") as? Double ?? 0.45
  var showRail = UserDefaults.standard.object(forKey: "showRail") as? Bool ?? true
  var railWidth: CGFloat { showRail && root.bounds.width >= 940 ? 157 : 0 }
  init() {
    for v in [top, topRule, rail, railRule, body, divider, preview, bottom, bottomRule, handle] {
      root.addSubview(v)
    }
    for view in [mark, wordmark, query] { top.addSubview(view) }
    for view in [heading, crumb, columns, sizes, columnRule, scroll, empty, emptyDetail, retry] {
      body.addSubview(view)
    }
    for view in [count, status] { bottom.addSubview(view) }
    heading.lineBreakMode = .byTruncatingMiddle
    columns.isBordered = false
    columns.alignment = .left
    columns.setButtonType(.momentaryChange)
    columns.setAccessibilityIdentifier("File sort order")
    sizes.alignment = .right
    empty.alignment = .center
    status.alignment = .right
    emptyDetail.alignment = .center
    emptyDetail.maximumNumberOfLines = 2
    emptyDetail.lineBreakMode = .byWordWrapping
    emptyDetail.isHidden = true
    retry.isHidden = true
    query.placeholderString = "Filter this folder"
    query.font = font(13)
    query.sendsSearchStringImmediately = true
    query.sendsWholeSearchString = false
    query.setAccessibilityLabel("Filter this folder")
    query.toolTip = "Filter filenames as you type (⌘F)"
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = table
    let column = NSTableColumn(identifier: .init("files"))
    column.title = "Name"
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.allowsMultipleSelection = true
    table.allowsEmptySelection = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.usesAutomaticRowHeights = false
    table.rowHeight = 38
    table.intercellSpacing = NSSize(width: 0, height: 1)
    table.selectionHighlightStyle = .regular
    table.backgroundColor = Ink.main
    table.style = .plain
    table.usesAlternatingRowBackgroundColors = false
    table.focusRingType = .none
    table.setAccessibilityLabel("Files")
    table.setAccessibilityIdentifier("File list")
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    table.registerForDraggedTypes([.fileURL])
    root.arrange = { [weak self] in self?.layout() }
    handle.dragTo = { [weak self] x in
      guard let self else { return }
      fraction = min(
        0.65, max(0.25, (root.bounds.width - x) / max(1, root.bounds.width - railWidth)))
      UserDefaults.standard.set(Double(fraction), forKey: "previewFraction")
      root.needsLayout = true
    }
    handle.reset = { [weak self] in
      self?.fraction = 0.45
      self?.root.needsLayout = true
    }
  }
  func showEmpty(_ title: String?, error: String? = nil) {
    empty.stringValue = title ?? ""
    empty.isHidden = title == nil
    emptyDetail.stringValue = error ?? ""
    emptyDetail.toolTip = error
    emptyDetail.isHidden = error == nil
    retry.isHidden = error == nil
  }
  func installButtons(_ buttons: [ActionButton]) {
    sidebar = buttons[0]
    back = buttons[1]
    forward = buttons[2]
    up = buttons[3]
    open = buttons[4]
    actions = buttons[5]
    move = buttons[6]
    agents = buttons[7]
    top.addSubview(agents)
    top.addSubview(worktable)
    for button in buttons.prefix(5) { top.addSubview(button) }
    bottom.addSubview(actions)
    bottom.addSubview(move)
    root.needsLayout = true
  }
  func layout() {
    guard sidebar != nil else { return }
    let w = root.bounds.width
    let h = root.bounds.height
    let topH: CGFloat = 57
    let footH: CGFloat = 39
    let contentH = max(0, h - topH - footH)
    let rw = railWidth
    let sidebarName = w < 940 ? "Browse locations" : "Toggle sidebar"
    sidebar.toolTip = sidebarName
    sidebar.setAccessibilityLabel(sidebarName)
    let remaining = w - rw
    let right = min(max(270, (remaining * fraction).rounded()), max(270, remaining - 295))
    let lw = remaining - right - 1
    position(top, 0, 0, w, topH)
    position(topRule, 0, topH - 1, w, 1)
    position(mark, 84, 14, 27, 27)
    position(wordmark, 119, 16, 74, 25)
    position(sidebar, 192, 15, 30, 27)
    position(back, 233, 15, 28, 27)
    position(forward, 261, 15, 28, 27)
    position(up, 291, 15, 28, 27)
    worktable.imagePosition = w < 840 ? .imageOnly : .imageLeading
    position(worktable, 327, 15, w < 840 ? 32 : 91, 27)
    let searchW = max(150, min(290, w * 0.23))
    position(query, w - searchW - 20, 15, searchW, 27)
    position(open, w - searchW - 135, 15, 105, 27)
    position(agents, w - searchW - 174, 15, 30, 27)
    agents.isHidden = w < 740
    rail.isHidden = rw == 0
    railRule.isHidden = rw == 0
    position(rail, 0, topH, rw, contentH)
    position(railRule, rw - 1, topH, 1, contentH)
    position(body, rw, topH, lw, contentH)
    position(divider, rw + lw, topH, 1, contentH)
    position(handle, rw + lw - 3, topH, 7, contentH)
    position(preview, rw + lw + 1, topH, right, contentH)
    position(crumb, 23, 19, lw - 46, 22)
    position(heading, 21, 44, lw - 42, 43)
    let metadataWidth = FileCell.detailWidth(for: lw - 22, order: order)
    sizes.isHidden =
      metadataWidth == 0 || (!showsSizes && order?.isModified != true && order?.isSize != true)
    let field = order?.isModified == true ? "MODIFIED" : "SIZE"
    let headingText: String
    if let order {
      if order.isName {
        headingText = "NAME " + order.arrow + "  ▾"
      } else if sizes.isHidden {
        headingText = "NAME  ·  " + field + " " + order.arrow + "  ▾"
      } else {
        headingText = "NAME  ▾"
      }
      sizes.stringValue = field + (order.isName ? "" : " " + order.arrow)
      columns.toolTip = "Sort files · " + order.menuTitle
    } else {
      headingText = "COLLECTION ORDER"
      sizes.stringValue = "SIZE"
      columns.toolTip = "Items appear in the collection’s saved order."
    }
    if columns.attributedTitle.string != headingText {
      columns.attributedTitle = NSAttributedString(
        string: headingText, attributes: [.font: mono(9.5, .semibold), .foregroundColor: Ink.quiet])
    }
    columns.setAccessibilityLabel(columns.toolTip)
    position(columns, 26, 101, sizes.isHidden ? lw - 50 : lw - metadataWidth - 55, 24)
    position(sizes, lw - metadataWidth - 23, 106, metadataWidth, 15)
    position(columnRule, 19, 126, lw - 38, 1)
    position(scroll, 11, 131, lw - 22, contentH - 139)
    position(empty, 15, 160, lw - 30, 24)
    position(emptyDetail, 25, 189, lw - 50, 35)
    position(retry, (lw - 104) / 2, 232, 104, 26)
    let available = scroll.contentSize.width
    if let column = table.tableColumns.first, abs(column.width - available) >= 1 {
      column.width = max(1, available)
    }
    position(bottom, 0, h - footH, w, footH)
    position(bottomRule, 0, h - footH, w, 1)
    position(count, 18, 12, 170, 16)
    position(status, 187, 12, w - 410, 16)
    position(actions, w - 202, 7, 87, 25)
    position(move, w - 110, 7, 94, 25)
  }
}
