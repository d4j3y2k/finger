import AppKit
import Quartz

// The panel's keys, typed paths, mouse, results table and Quick Look.
extension PanelController {
  // MARK: - Keys

  func handleKey(_ event: NSEvent) -> Bool {
    guard panel.isVisible else { return false }
    finishMotion()
    if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
    // The panel's own shortcut hides it, should it reach the panel.
    if shortcut.matches(event) {
      hide()
      return true
    }
    if waitingForSlash {
      heldKeys.append(event)
      return true
    }
    if let handled = filing?.handleKey(event) { return handled }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // After a click into the preview to select text, typing goes back to the
    // search field. Arrows, ↩, esc and ⇥ work from anywhere; ⌘C still copies.
    let editing = field.currentEditor() != nil && panel.firstResponder === field.currentEditor()
    if !editing, !flags.contains(.command), !flags.contains(.control),
      ![123, 124, 125, 126, 36, 76, 53, 48].contains(event.keyCode)
    {
      focusField(selectAll: false)
    }
    let command = flags.contains(.command)
    let option = flags.contains(.option)
    let shift = flags.contains(.shift)
    let control = flags.contains(.control)
    let text = field.stringValue
    let editor = field.currentEditor()
    let caretAtEnd =
      editor.map {
        $0.selectedRange.length == 0 && $0.selectedRange.location == (text as NSString).length
      } ?? true
    switch event.keyCode {
    case 126:  // ↑
      if command { goUp() } else { move(-1) }
      return true
    case 125:  // ↓
      if command { activate() } else { move(1) }
      return true
    case 36, 76:  // ↩
      if command { reveal() } else { activate() }
      return true
    case 48:  // ⇥
      if !shift, !command, let item = selectedItem, item.file.isFolder { enter(item.file.path) }
      return !command
    case 53:  // esc
      escape()
      return true
    case 124:  // →
      guard !command, !option, !control, caretAtEnd else { return false }
      return goRight()
    case 123:  // ←
      guard !command, !option, text.isEmpty, folder != nil else { return false }
      goUp()
      return true
    case 51:  // ⌫
      guard !command, !option, text.isEmpty else { return false }
      if folder != nil { goUp() }
      return true
    case 49:  // space
      if command || control || option { return false }
      if shift || text.isEmpty {
        toggleQuickLook()
        return true
      }
      return false
    default:
      break
    }
    if command || control { return false }
    let chars = event.characters ?? ""
    if chars == "/" {
      slash()
      return true
    }
    if chars == "~", text.isEmpty, folder == nil {
      enter(home)
      return true
    }
    return false
  }

  func escape() {
    if closeQuickLook() { return }
    if escapeHides {
      hide()
      return
    }
    if !field.stringValue.isEmpty {
      clearQuery()
      return
    }
    if folder != nil {
      exitBrowsing()
      escapeHides = true
      return
    }
    hide()
  }

  func clearQuery() {
    let before = selectedItem?.file
    setQuery("")
    cancelSearches()
    userMoved = false
    pendingPick = nil
    if let folder {
      rebuild(.path(before?.parent == folder ? before?.path : landing(folder)))
    } else {
      rebuild(.path(homeSelected))
    }
    updateFooter()
  }

  func goRight() -> Bool {
    guard let file = selectedItem?.file else { return false }
    if file.isFolder {
      enter(file.path)
      return true
    }
    if file.parent != folder {
      enter(file.parent, focus: file.path)
      return true
    }
    return false
  }

  /// ↩: a folder goes in; a file opens in its app and the panel hides.
  func activate() {
    if let filing, filing.isMoving {
      filing.confirmMove()
      return
    }
    guard let file = selectedItem?.file else { return }
    if file.isFolder {
      enter(file.path)
    } else {
      hide()
      opener(file.url)
    }
  }

  func reveal() {
    let target = selectedItem?.file.url ?? folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
    guard let target else { return }
    hide()
    revealer(target)
  }

  func perform(_ action: PanelAction) {
    finishMotion()
    switch action {
    case .activate: activate()
    case .reveal: reveal()
    case .quickLook: toggleQuickLook()
    case .intoFolder: _ = goRight()
    case .up: goUp()
    case .filing(let hint): filing?.perform(hint)
    }
  }

  // MARK: - Typing a path

  /// Whether `/` can pick its folder now, or must wait for results.
  var slashReady: Bool {
    let text = trimmedQuery
    if let folder {
      guard listings[folder] != nil else { return false }
      if text.isEmpty { return true }
      if rows.contains(where: { $0.item?.origin == .here && $0.item?.file.isFolder == true }) {
        return true
      }
      return found[key("names", folder, text)]?.finished == true
    }
    if text.isEmpty || found[key("names", home, text)]?.finished == true { return true }
    // Spotlight can take seconds when cold. A folder that already leads with
    // a name starting with what you typed is the one `/` would pick anyway.
    guard found[key("names", home, text)] != nil, let top = rows.lazy.compactMap(\.item).first
    else { return false }
    return top.file.isFolder && PanelMatch.rank(text, in: top.file.name) == PanelMatch.prefix
  }

  /// `/` goes into the top folder match, so `dev/fi/ru` can be typed without stopping.
  func slash() {
    guard slashReady else {
      waitingForSlash = true
      let timeout = DispatchWorkItem { [weak self] in
        guard let self, self.waitingForSlash else { return }
        self.waitingForSlash = false
        self.performSlash()
        self.replayHeldKeys()
      }
      slashTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
      return
    }
    performSlash()
  }

  func performSlash() {
    if trimmedQuery.isEmpty {
      if folder == nil { enter(home) }
      return
    }
    let target =
      selectedItem?.file.isFolder == true
      ? selectedRow : rows.firstIndex { $0.item?.file.isFolder == true }
    guard let target, let file = rows[target].item?.file else {
      NSSound.beep()
      return
    }
    if target != selectedRow { select(target, reveal: false) }
    enter(file.path)
  }

  func resumeHeldKeysIfReady() {
    guard waitingForSlash, slashReady else { return }
    waitingForSlash = false
    slashTimeout?.cancel()
    slashTimeout = nil
    performSlash()
    replayHeldKeys()
  }

  func replayHeldKeys() {
    while !waitingForSlash, !heldKeys.isEmpty, panel.isVisible {
      panel.sendEvent(heldKeys.removeFirst())
    }
  }

  func releaseHeldKeys() {
    waitingForSlash = false
    slashTimeout?.cancel()
    slashTimeout = nil
    heldKeys.removeAll()
  }

  // MARK: - Mouse

  func click(_ row: Int, _ clicks: Int, _ point: NSPoint) {
    guard row >= 0, row < rows.count, let item = rows[row].item else { return }
    finishMotion()
    userMoved = true
    pendingPick = nil
    select(row, reveal: false)
    if clicks >= 2 {
      activate()
    } else if item.file.isFolder, point.x > table.bounds.width - 34 {
      enter(item.file.path)
    }
  }

  func hover(_ row: Int) {
    guard row != hoveredRow else { return }
    let old = hoveredRow
    hoveredRow = row
    for r in [old, row] where r >= 0 && r < rows.count {
      (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? PanelItemCell)?.hovered = r == row
    }
  }

  // MARK: - Table

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    if case .header = rows[row] { return PanelHeaderCell.height }
    return PanelItemCell.height
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    PanelRowView()
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .header(let section):
      let cell =
        tableView.makeView(withIdentifier: PanelHeaderCell.identifier, owner: nil) as? PanelHeaderCell
        ?? PanelHeaderCell()
      cell.title = section.title
      cell.aside = section.aside
      cell.needsDisplay = true
      return cell
    case .item(let item):
      let cell =
        tableView.makeView(withIdentifier: PanelItemCell.identifier, owner: nil) as? PanelItemCell
        ?? PanelItemCell()
      cell.icon = PanelIcons.shared.icon(item.file.path)
      cell.name = item.file.name
      cell.highlight = item.highlight
      cell.subtitle = item.subtitle ?? (item.file.isFolder ? count(item.file) : PanelText.details(item.file))
      cell.side = item.side ?? PanelText.ago(touched(item.file))
      cell.folder = item.file.isFolder
      cell.chosen = row == selectedRow
      cell.hovered = row == hoveredRow
      cell.concealed = item.file.path == concealedPath
      filing?.decorate(cell, item)
      cell.setAccessibilityLabel(item.file.name)
      cell.needsDisplay = true
      return cell
    }
  }

  // MARK: - Quick Look

  func toggleQuickLook() {
    if closeQuickLook() { return }
    guard selectedItem != nil, let ql = QLPreviewPanel.shared() else { return }
    ql.updateController()
    // Ordered front, not made key, so the panel keeps the keyboard.
    ql.orderFront(nil)
    ql.reloadData()
  }

  @discardableResult
  func closeQuickLook() -> Bool {
    guard QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(),
      ql.isVisible, ql.dataSource === self
    else { return false }
    ql.orderOut(nil)
    return true
  }

  func beginQuickLook(_ panel: QLPreviewPanel) {
    panel.dataSource = self
    panel.delegate = self
  }

  func endQuickLook(_ panel: QLPreviewPanel) {
    if panel.dataSource === self { panel.dataSource = nil }
    if panel.delegate === self { panel.delegate = nil }
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItem == nil ? 0 : 1 }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    selectedItem?.file.url as NSURL?
  }

  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    return handleKey(event)
  }

  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    guard let row = selectedRow, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
      as? PanelItemCell
    else { return .zero }
    let rect = cell.convert(cell.iconFrame, to: nil)
    return self.panel.convertToScreen(rect)
  }
}
