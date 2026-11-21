import AppKit
import Quartz

final class MenuAction: NSObject, NSMenuItemValidation {
  var validate: ((NSMenuItem) -> Bool)?
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate?(menuItem) ?? true }
  let run: () -> Void
  init(_ block: @escaping () -> Void) { run = block }
  @objc func invokeMenuItem(_ sender: NSMenuItem) { run() }
}
final class CommandItem: NSMenuItem {
  private var handler: MenuAction?
  init(
    _ title: String, key: String = "", mask: NSEvent.ModifierFlags = .command, enabled: Bool = true,
    _ perform: @escaping () -> Void
  ) {
    let action = MenuAction(perform)
    super.init(title: title, action: #selector(MenuAction.invokeMenuItem(_:)), keyEquivalent: key)
    handler = action
    target = action
    keyEquivalentModifierMask = mask
    isEnabled = enabled
  }
  func validate(using block: @escaping (NSMenuItem) -> Bool) { handler?.validate = block }
  required init(coder: NSCoder) { fatalError() }
}

extension Browser {
  func openSelected() {
    guard !loading, !fileSelection.indexes.isEmpty else { return }
    let items = selected
    if items.count == 1 {
      openURL(items[0].url)
    } else {
      openItemsInDefaultApps(items.map(\.url), directories: items.filter(\.isDirectory).map(\.url))
    }
    window.makeFirstResponder(ui.table)
  }
  func handle(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch event.keyCode {
    case 36, 76:
      if flags.contains(.command) { rename() } else { openSelected() }
      return true
    case 124:
      if flags.contains(.option) || flags.contains(.command) {
        step("forward")
      } else if ui.table.numberOfSelectedRows == 1, let item = fileSelection.first, item.isDirectory
      {
        visit(item.path, animate: true)
      } else {
        quickLook()
      }
      return true
    case 123:
      if flags.contains(.option) || flags.contains(.command) { step("back") } else { goUp() }
      return true
    case 49:
      quickLook()
      return true
    case 53:
      clearFilter()
      return true
    default: break
    }
    if event.charactersIgnoringModifiers == String(UnicodeScalar(NSF2FunctionKey)!) {
      rename()
      return true
    }
    if flags.isDisjoint(with: [.command, .control, .option]),
      let text = event.characters, !text.isEmpty,
      !text.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .privateUse || CharacterSet.controlCharacters.contains($0)
      })
    {
      focusSearch(select: false)
      ui.query.stringValue += text
      if let editor = ui.query.currentEditor() {
        editor.selectedRange = NSRange(
          location: (ui.query.stringValue as NSString).length, length: 0)
      }
      filter()
      return true
    }
    return false
  }
  func clearFilter() {
    if !ui.query.stringValue.isEmpty || !displayedQuery.isEmpty {
      ui.query.stringValue = ""
      if !loading { filter() }
    }
    window.makeFirstResponder(ui.table)
  }
  func focusSearch(select: Bool = true) {
    if isWorktable { homeView.focusSearch(select: select); return }
    window.makeFirstResponder(ui.query)
    if select { ui.query.currentEditor()?.selectAll(nil) }
  }
  func findInSubfolders() {
    guard window.attachedSheet == nil, let root = folderPath ?? project else { return }
    let panel = FindPanel(
      parent: window, engine: engine, root: URL(fileURLWithPath: root, isDirectory: true),
      showHidden: showHidden
    ) { [weak self] result in
      guard let self else { return }
      self.findPanel = nil
      if let result { self.reveal(result) }
      self.window.makeFirstResponder(self.ui.table)
    }
    findPanel = panel
    panel.present()
  }
  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = (isWorktable ? project : folderPath).map { URL(fileURLWithPath: $0) }
    panel.prompt = isWorktable ? "Choose project" : "Open folder"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      if isWorktable { showWorktable(project: url.path); return }
      project = url.path
      visit(url.path)
      window.makeFirstResponder(ui.table)
    }
  }
  func prompt(
    _ title: String, value: String, action: String, completion: @escaping (String) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    let input = NSTextField(string: value)
    input.frame = NSRect(x: 0, y: 0, width: 350, height: 26)
    input.setAccessibilityLabel(title)
    alert.accessoryView = input
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = input
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.window.makeFirstResponder(self?.ui.table)
      if response == .alertFirstButtonReturn { completion(input.stringValue) }
    }
    input.selectText(nil)
    if title == "Rename item", let editor = input.currentEditor() {
      let base = (value as NSString).deletingPathExtension
      if !base.isEmpty {
        editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
      }
    }
  }
  func goToFolder() {
    prompt("Go to folder", value: folderPath ?? NSHomeDirectory(), action: "Go") {
      [weak self] input in
      guard let self else { return }
      let expanded = (input as NSString).expandingTildeInPath
      let base = folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
      let dest = URL(fileURLWithPath: expanded, isDirectory: false, relativeTo: base)
        .standardizedFileURL
      let initial = location
      pathRequests.resolve([dest]) { [weak self] result in
        guard let self, self.location == initial else { return }
        self.openExternal(result, setProject: false)
      }
    }
  }
  func toggleHidden() {
    showHidden.toggle()
    UserDefaults.standard.set(showHidden, forKey: "showHidden")
    load(snapshot(), clear: false)
    message(showHidden ? "Hidden files visible" : "Hidden files hidden")
  }
  func setFileOrder(_ order: FileOrder) {
    guard folderPath != nil, order != fileOrder else { return }
    let state = snapshot()
    fileOrder = order
    UserDefaults.standard.set(order.rawValue, forKey: "fileOrder")
    updateSortControls()
    load(state, clear: false)
  }
  func updateSortControls() {
    ui.order = folderPath == nil ? nil : fileOrder
    sortMenuItem?.submenu = fileSortMenu()
  }
  func fileSortMenu() -> NSMenu {
    let menu = NSMenu(title: "Sort By")
    menu.autoenablesItems = false
    guard folderPath != nil else {
      let supplied = NSMenuItem(title: "Collection Order", action: nil, keyEquivalent: "")
      supplied.state = .on
      supplied.isEnabled = false
      menu.addItem(supplied)
      return menu
    }
    for order in FileOrder.allCases {
      if order == .modifiedDesc || order == .sizeDesc { menu.addItem(.separator()) }
      let item = CommandItem(order.menuTitle) { [weak self] in self?.setFileOrder(order) }
      item.state = fileOrder == order ? .on : .off
      menu.addItem(item)
    }
    return menu
  }
  @objc func showSortMenu() {
    fileSortMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: ui.columns)
  }
  func toggleSidebar() {
    if ui.root.bounds.width < 940 {
      ui.rail.popUp(from: ui.sidebar)
      return
    }
    ui.showRail.toggle()
    UserDefaults.standard.set(ui.showRail, forKey: "showRail")
    ui.root.needsLayout = true
  }
  func togglePin() {
    guard let path = folderPath else { return }
    if isPinned(path) {
      let key = FolderReferences.key(path)
      favorites.removeAll { FolderReferences.key($0) == key }
    } else {
      favorites.insert(path, at: 0)
    }
    UserDefaults.standard.set(favorites, forKey: "favorites")
    updateChrome()
  }
  private func isPinned(_ path: String) -> Bool {
    let key = FolderReferences.key(path)
    return favorites.contains { FolderReferences.key($0) == key }
  }
  private var quickLookSelection: FileSelection {
    guard let homeSelection else { return fileSelection }
    return FileSelection(
      entries: homeSelection, rows: Array(homeSelection.indices),
      indexes: IndexSet(integersIn: homeSelection.indices))
  }
  func quickLook() {
    let selection = quickLookSelection
    guard let item = selection.first else { return }
    if previewPanel?.isVisible != true { ResumeHistory().recordUse(selection.map(limit: 64) { $0 }) }
    if let panel = previewPanel {
      if panel.isVisible {
        dismissQuickLook()
      } else {
        displayQuickLook(at: selection.indexes.first)
        panel.makeKeyAndOrderFront(nil)
      }
      return
    }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
      styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = window.appearance
    panel.delegate = self
    guard let view = QLPreviewView(frame: panel.contentView?.bounds ?? .zero, style: .normal) else {
      message("Quick Look is unavailable for " + item.name, error: true)
      return
    }
    view.autoresizingMask = [.width, .height]
    view.autostarts = true
    panel.contentView?.addSubview(view)
    if !panel.setFrameUsingName("FingerQuickLook") { panel.center() }
    panel.setFrameAutosaveName("FingerQuickLook")
    previewPanel = panel
    panelView = view
    displayQuickLook(at: selection.indexes.first)
    panel.makeKeyAndOrderFront(nil)
    quickLookEvent = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self, weak panel] event in
      guard let self, let panel, panel.isVisible, event.window == panel else { return event }
      if event.keyCode == 49 || event.keyCode == 53 {
        self.dismissQuickLook()
        return nil
      }
      if event.keyCode == 125 || event.keyCode == 126 {
        self.stepQuickLook(event.keyCode == 125 ? 1 : -1)
        return nil
      }
      return event
    }
  }
  func displayQuickLook(at row: Int?) {
    quickLookRow = row
    let selection = quickLookSelection
    let item = row.flatMap { selection.entry(at: $0) }
    guard item != quickLookItem else { return }
    if let item, item.path == quickLookItem?.path {
      panelView?.refreshPreviewItem()
    } else {
      panelView?.previewItem = item?.url as NSURL?
    }
    quickLookItem = item
    previewPanel?.title = item?.name ?? "Preview"
  }
  func syncQuickLookSelection() {
    let selection = quickLookSelection
    let indexes = selection.indexes
    guard let item = quickLookItem, let row = quickLookRow else {
      displayQuickLook(at: indexes.first)
      return
    }
    if indexes.contains(row), selection.entry(at: row)?.path == item.path {
      displayQuickLook(at: row)
      return
    }
    // Refreshes and sorts move selected files to new row numbers. Stay on the
    // same file, or choose the next surviving selection near its former row.
    let sameFile = indexes.first { selection.entry(at: $0)?.path == item.path }
    displayQuickLook(at: sameFile ?? indexes.integerGreaterThanOrEqualTo(row) ?? indexes.last)
  }
  func stepQuickLook(_ delta: Int) {
    let indexes = quickLookSelection.indexes
    guard indexes.count > 1, let row = quickLookRow else {
      if homeSelection == nil { moveSelection(delta) }
      return
    }
    let next = delta > 0 ? indexes.integerGreaterThan(row) : indexes.integerLessThan(row)
    if let next { displayQuickLook(at: next) }
  }
  func dismissQuickLook() {
    displayQuickLook(at: nil)
    previewPanel?.orderOut(nil)
    window.makeKeyAndOrderFront(nil)
    if homeSelection != nil { window.makeFirstResponder(homeView) }
    else { window.makeFirstResponder(ui.table) }
  }
  func actionsMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let count = ui.table.numberOfSelectedRows
    let any = count > 0 && !loading
    menu.addItem(CommandItem("Open", enabled: any) { [weak self] in self?.openSelected() })
    menu.addItem(CommandItem("Quick Look", enabled: any) { [weak self] in self?.quickLook() })
    menu.addItem(.separator())
    menu.addItem(
      CommandItem("New Folder…", enabled: folderPath != nil && !busy) { [weak self] in
        self?.newFolder()
      })
    menu.addItem(
      CommandItem("Rename…", enabled: count == 1 && !busy) { [weak self] in self?.rename()
      })
    menu.addItem(
      CommandItem("Copy to…", enabled: any && !busy) { [weak self] in
        self?.chooseTransfer(move: false)
      })
    menu.addItem(
      CommandItem("Move to…", enabled: any && !busy) { [weak self] in
        self?.chooseTransfer(move: true)
      })
    menu.addItem(.separator())
    menu.addItem(
      CommandItem("Copy Files", enabled: any) { [weak self] in self?.copyFiles(cut: false) })
    menu.addItem(
      CommandItem(
        "Paste Here",
        enabled: folderPath != nil && !busy
          && clipboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      ) {
        [weak self] in self?.pasteFiles(forceMove: false)
      })
    menu.addItem(
      CommandItem("Reveal in Finder", enabled: any) { [weak self] in
        guard let self else { return }
        NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
      })
    if let path = folderPath {
      menu.addItem(.separator())
      menu.addItem(
        CommandItem(isPinned(path) ? "Unpin Folder" : "Pin Folder") { [weak self] in
          self?.togglePin()
        })
    }
    if let record = collection {
      menu.addItem(.separator())
      menu.addItem(
        CommandItem("Rename Collection…") { [weak self] in self?.renameCollection(record) })
      menu.addItem(
        CommandItem("Remove Collection…") { [weak self] in self?.removeCollection(record) })
    }
    return menu
  }
  func showActions() {
    actionsMenu().popUp(
      positioning: nil, at: NSPoint(x: 0, y: ui.actions.bounds.height + 2), in: ui.actions)
  }
  func installMenu() {
    let bar = NSMenu()
    NSApp.mainMenu = bar
    func section(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      bar.addItem(item)
      let menu = NSMenu(title: title)
      item.submenu = menu
      return menu
    }
    let app = section("Finger")
    app.addItem(
      withTitle: "About Finger", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(
      withTitle: "Hide Finger", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(
      withTitle: "Quit Finger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let file = section("File")
    file.addItem(CommandItem(isWorktable ? "Choose Project Folder…" : "Open Folder…", key: "o") { [weak self] in self?.chooseFolder() })
    file.addItem(CommandItem("Open Practice Project") { [weak self] in self?.openDemo() })
    if isWorktable {
      let look = CommandItem("Preview Selection") { [weak self] in self?.homeView.onPreview?() }
      let hand = CommandItem("Hand to Codex") { [weak self] in self?.homeView.onHandoff?() }
      for item in [look, hand] {
        item.validate { [weak self] _ in self?.homeSelection?.isEmpty == false }
        file.addItem(item)
      }
      file.addItem(.separator())
    } else {
      file.addItem(
        CommandItem("Open Selection", key: "\u{f701}") { [weak self] in self?.openSelected() })
      file.addItem(CommandItem("Quick Look Selection") { [weak self] in self?.quickLook() })
      file.addItem(.separator())
      file.addItem(
        CommandItem("New Folder…", key: "n", mask: [.command, .shift]) { [weak self] in
          self?.newFolder()
        })
      file.addItem(CommandItem("Rename…", key: "\r") { [weak self] in self?.rename() })
      file.addItem(
        CommandItem("Copy to…", key: "c", mask: [.command, .shift]) { [weak self] in
          self?.chooseTransfer(move: false)
        })
      file.addItem(
        CommandItem("Move to…", key: "m", mask: [.command, .shift]) { [weak self] in
          self?.chooseTransfer(move: true)
        })
      file.addItem(.separator())
    }
    file.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let edit = section("Edit")
    if !isWorktable {
      for redo in [false, true] {
        let item = CommandItem(
          redo ? "Redo" : "Undo", key: "z", mask: redo ? [.command, .shift] : [.command]
        ) { [weak self] in self?.restoreAction(redo) }
        item.validate { [weak self] menu in
          guard let self else { return false }
          menu.title = self.restoreTitle(redo)
          return self.canRestore(redo)
        }
        edit.addItem(item)
      }
      edit.addItem(.separator())
    }
    for (title, sel, key) in [
      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
      ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key)
    }
    if !isWorktable {
      edit.addItem(
        CommandItem("Move Copied Files Here", key: "v", mask: [.command, .option]) { [weak self] in
          self?.pasteFiles(forceMove: true)
        })
      edit.addItem(.separator())
    }
    edit.addItem(CommandItem("Filter Filenames", key: "f") { [weak self] in self?.focusSearch() })
    if !isWorktable {
      edit.addItem(
        CommandItem("Find in Subfolders…", key: "f", mask: [.command, .shift]) { [weak self] in
          self?.findInSubfolders()
        })
    }
    let view = section("View")
    if !isWorktable {
      let sorting = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
      sorting.submenu = fileSortMenu()
      sortMenuItem = sorting
      view.addItem(sorting)
      view.addItem(.separator())
      view.addItem(
        CommandItem("Show or Hide Sidebar", key: "s", mask: [.command, .option]) { [weak self] in
          self?.toggleSidebar()
        })
      view.addItem(
        CommandItem("Show or Hide Hidden Files", key: ".", mask: [.command, .shift]) { [weak self] in
          self?.toggleHidden()
        })
    }
    view.addItem(
      CommandItem("Refresh", key: "r") { [weak self] in
        guard let self else { return }
        if isWorktable { refreshWorktable() } else { load(snapshot(), clear: false) }
      })
    let go = section("Go")
    go.addItem(CommandItem("Worktable", key: "1") { [weak self] in self?.showWorktable() })
    go.addItem(CommandItem("Browse Folders", key: "2") { [weak self] in self?.browseFromWorktable() })
    if !isWorktable {
      go.addItem(CommandItem("Back", key: "[") { [weak self] in self?.step("back") })
      go.addItem(CommandItem("Forward", key: "]") { [weak self] in self?.step("forward") })
      go.addItem(CommandItem("Enclosing Folder", key: "\u{f700}") { [weak self] in self?.goUp() })
      go.addItem(
        CommandItem("Go to Folder…", key: "g", mask: [.command, .shift]) { [weak self] in
          self?.goToFolder()
        })
      let shelf = NSMenuItem(title: "Collections", action: nil, keyEquivalent: "")
      browseCollectionsMenu = NSMenu(title: "Collections")
      shelf.submenu = browseCollectionsMenu
      go.addItem(.separator())
      go.addItem(shelf)
      rebuildCollectionsMenu()
      go.addItem(
        CommandItem("Clear Recent Folders") { [weak self] in
          guard let self else { return }
          self.recent.removeAll()
          UserDefaults.standard.removeObject(forKey: "recentFolders")
          UserDefaults.standard.removeObject(forKey: "recentDestinations")
          self.updateChrome()
        })
    }
    let win = section("Window")
    NSApp.windowsMenu = win
    win.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    let help = section("Help")
    help.addItem(
      CommandItem("Keyboard Shortcuts…", key: "?", mask: [.command]) { [weak self] in
        self?.showShortcuts()
      })
    help.addItem(CommandItem("Agent Connection…") { [weak self] in self?.showAgentConnection() })
  }
}
