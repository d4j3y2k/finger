import AppKit
import Darwin
import Quartz

private final class EntryTransitionView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func discard() {
    image = nil
    removeFromSuperview()
  }
}

final class Browser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
  NSWindowDelegate
{
  let engine: Engine
  private let clipboardOverride: NSPasteboard?
  var clipboard: NSPasteboard { clipboardOverride ?? .general }
  let ui = BrowserShell()
  let homeView = WorktableView()
  var homeTicket: FileReadTicket?
  var homeHistory = ResumeHistory()
  var homeVisitDate = Date()
  var browseDestination: (key: String, state: [String: Any]?)?
  var isWorktable: Bool { homeSelection != nil }
  let window: BrowserWindow
  private weak var entryVeil: EntryTransitionView?
  let endpoint = FingerAgentEndpoint()
  let pathRequests = OpenItemRequests()
  var agentError: String?
  let listingQueue = DispatchQueue(
    label: "finger.directory", qos: .userInitiated, attributes: .concurrent)
  let mutations = DispatchQueue(label: "finger.operations", qos: .userInitiated)
  let collectionWrites: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Finger collection preferences"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  var entries: [Entry] = []
  private var folderSearch: FolderSearchIndex?
  private var folderLoadTicket: FileReadTicket?
  var rows: [Int] = []
  var location = ""
  var prior: String?
  var canBack = false, canForward = false
  var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
  var fileOrder =
    UserDefaults.standard.string(forKey: "fileOrder").flatMap(FileOrder.init(rawValue:)) ?? .nameAsc
  private var displayedOrder: FileOrder?
  var sortMenuItem: NSMenuItem?
  var recent = FolderReferences.unique(
    UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [], limit: 15)
  var favorites = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
  var collections: [CollectionRecord] = []
  var browseCollectionsMenu: NSMenu?
  var project: String?
  var loading = false
  var scanning = false
  var folderDirty = false
  var previewItems: [Entry]?
  var previewSelectionCount = 0
  var previewLocation = ""
  var previewHidden = false
  var previewOrder: FileOrder?
  var applying = false
  var pendingQuit = false
  var pendingClose = false
  var busy = false {
    didSet {
      guard !busy, oldValue, pendingQuit || pendingClose else { return }
      DispatchQueue.main.async { [weak self] in self?.finishDeferredClose() }
    }
  }
  var revision = 0
  var transientStatus = false
  var statusEpoch = 0
  var pendingState: [String: Any]?
  var beforeFilter: [String: Any]?
  var displayedQuery = ""
  let folderWatcher = FolderWatcher()
  private var placeNames = [
    ("Desktop", "desktopcomputer"), ("Downloads", "arrow.down.circle"), ("Documents", "doc.text"),
  ]
  private var openEpoch = 0
  var refreshWork: DispatchWorkItem?
  private var nextFolderRefresh = DispatchTime.now()
  var previewPanel: NSPanel?
  var panelView: QLPreviewView?
  var quickLookRow: Int?
  var quickLookItem: Entry?
  var homeSelection: [Entry]? {
    didSet {
      if previewPanel?.isVisible == true { syncQuickLookSelection() }
    }
  }
  var picker: MovePicker?
  var findPanel: FindPanel?
  var quickLookEvent: Any?
  var lastCutChange = -1
  var cutPaths: [String] = []
  var undoActions: [FileAction] = []
  var redoActions: [FileAction] = []
  var clipboardCapture: (generation: Int, selection: OperationSelection)?
  var lastError: String?
  var folderPath: String? { location.hasPrefix("/") ? location : nil }
  var collection: CollectionRecord? { collections.first { "collection:" + $0.id == location } }
  var fileSelection: FileSelection {
    FileSelection(entries: entries, rows: rows, indexes: ui.table.selectedRowIndexes)
  }
  var selected: [Entry] { fileSelection.map { $0 } }
  func agentSelection() -> FingerAgentSelection {
    if let homeSelection {
      return FingerAgentSelection(
        folder: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
        paths: { homeSelection.map(\.path) })
    }
    let frozen = fileSelection
    return FingerAgentSelection(
      folder: folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
      collection: collection?.name, paths: { frozen.map(\.path) })
  }

  init(engine: Engine, clipboard: NSPasteboard? = nil) {
    self.engine = engine
    clipboardOverride = clipboard
    window = BrowserWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1150, height: 710),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init()
    let places = placeNames
    let home = NSHomeDirectory()
    listingQueue.async { [weak self] in
      let available = places.filter { FileManager.default.fileExists(atPath: home + "/" + $0.0) }
      DispatchQueue.main.async { [weak self] in
        guard let self, available.count != self.placeNames.count else { return }
        self.placeNames = available
        if !self.location.isEmpty { self.updateChrome() }
      }
    }
    if let d = UserDefaults.standard.data(forKey: "collections") {
      collections = (try? JSONDecoder().decode([CollectionRecord].self, from: d)) ?? []
    }
    ui.preview.engine = engine
    window.appearance = NSAppearance(named: .darkAqua)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.backgroundColor = Ink.rail
    window.contentMinSize = NSSize(width: 700, height: 405)
    window.tabbingMode = .disallowed
    window.contentView = ui.root
    window.delegate = self
    if !window.setFrameUsingName("FingerBrowser") { window.center() }
    window.setFrameAutosaveName("FingerBrowser")
    ui.table.delegate = self
    ui.table.dataSource = self
    ui.table.target = self
    ui.table.doubleAction = #selector(doubleClick)
    ui.retryOpeningFolder = { [weak self] in
      guard let self else { return }
      self.load(self.snapshot(), clear: true)
    }
    ui.table.onCopy = { [weak self] in self?.copyFiles(cut: $0) }
    ui.table.onPaste = { [weak self] in self?.pasteFiles(forceMove: false) }
    ui.query.delegate = self
    ui.table.handleKey = { [weak self] in self?.handle($0) ?? false }
    window.canTrackHistory = { [weak self] point in
      guard let self, !self.isWorktable else { return false }
      let local = self.ui.root.convert(point, from: nil)
      return self.ui.body.frame.contains(local) || self.ui.preview.frame.contains(local)
    }
    window.canStepHistory = { [weak self] back in
      guard let self else { return false }
      return back ? self.canBack : self.canForward
    }
    window.stepHistory = { [weak self] back in
      guard let self, back ? self.canBack : self.canForward else { return false }
      self.step(back ? "back" : "forward")
      return true
    }
    ui.table.context = { [weak self] _ in self?.actionsMenu() }
    ui.columns.target = self
    ui.columns.action = #selector(showSortMenu)
    ui.crumb.navigate = { [weak self] path in self?.visit(path) }
    ui.rail.canDropFiles = { [weak self] in self?.busy == false && self?.window.attachedSheet == nil
    }
    ui.rail.dropFiles = { [weak self] payload, path, move in
      guard let self, !self.busy else { return false }
      self.transfer(payload.paths, to: path, move: move, captured: payload.selection)
      return true
    }
    ui.rail.context = { [weak self] in self?.collectionMenu($0) }
    ui.rail.pick = { [weak self] key in self?.visit(key) }
    ui.preview.onOpen = { [weak self] url in self?.openURL(url) }
    ui.preview.onReveal = { [weak self] url in self?.reveal(url) }
    configureWorktable()
    ui.installButtons([
      ActionButton("", icon: "sidebar.left", help: "Toggle sidebar") { [weak self] in
        self?.toggleSidebar()
      },
      ActionButton("", icon: "chevron.left", help: "Go back") { [weak self] in self?.step("back") },
      ActionButton("", icon: "chevron.right", help: "Go forward") { [weak self] in
        self?.step("forward")
      },
      ActionButton("", icon: "arrow.up", help: "Enclosing folder") { [weak self] in self?.goUp() },
      ActionButton("Open folder", icon: "folder", help: "Choose a folder (⌘O)") { [weak self] in
        self?.chooseFolder()
      },
      ActionButton("Actions", icon: "ellipsis.circle", help: "File actions") { [weak self] in
        self?.showActions()
      },
      ActionButton("Move…", icon: "arrow.right", help: "Move selected items (⇧⌘M)", accent: true) {
        [weak self] in self?.chooseTransfer(move: true)
      },
      ActionButton("", icon: "link", help: "Agent connection") { [weak self] in
        self?.showAgentConnection()
      },
    ])
  }
  func start(at path: String?, resume: Bool = false, worktableProject: String? = nil) {
    project = path
    var initialKey = path
    var initialState: [String: Any]?
    if resume, let path, let data = UserDefaults.standard.data(forKey: "lastWorkspace"),
      let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let key = saved["key"] as? String,
      key == path || collections.contains(where: { "collection:" + $0.id == key })
    {
      initialKey = key
      initialState = saved["state"] as? [String: Any]
      if let root = saved["project"] as? String {
        let pathKey = FolderReferences.key(path)
        let rootKey = FolderReferences.key(root)
        if key.hasPrefix("collection:") || pathKey == rootKey
          || pathKey.hasPrefix(rootKey == "/" ? "/" : rootKey + "/") { project = root }
      }
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(ui.table)
    NSApp.activate(ignoringOtherApps: true)
    if resume {
      if let root = worktableProject ?? project {
        let restoreBrowser = root == project
        showWorktable(project: root)
        if restoreBrowser, let initialKey { browseDestination = (initialKey, initialState) }
      } else {
        openDemo()
      }
    } else if let initialKey {
      navigate(
        ["op": "visit", "key": initialKey], selecting: nil, animate: false, restoring: initialState)
    } else {
      window.title = "Finger"
      ui.showEmpty("Opening items…")
    }
    do {
      try endpoint.start(
        selection: { [weak self] in
          self?.agentSelection() ?? FingerAgentSelection(folder: nil, files: [])
        },
        showCollection: { [weak self] name, paths in self?.receiveCollection(name, paths: paths) })
    } catch {
      agentError = error.localizedDescription
      message(
        "Agent connection unavailable · " + error.localizedDescription, error: true, seconds: 12)
    }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === previewPanel { return true }
    guard busy else { return true }
    pendingClose = true
    message("Finishing the file operation before closing…", seconds: 3600)
    return false
  }
  private func finishDeferredClose() {
    guard !busy else { return }
    let ready = window.attachedSheet == nil
    if pendingQuit {
      pendingQuit = false
      pendingClose = false
      NSApp.reply(toApplicationShouldTerminate: ready)
    } else if pendingClose {
      pendingClose = false
      if ready { window.performClose(nil) }
    }
  }
  func saveWorkspace() {
    guard !isWorktable, !location.isEmpty else { return }
    var state = snapshot()
    // Very large selections can be reconstructed during this session. Keep the
    // launch preference small enough for the macOS defaults database.
    func large(_ value: Any?) -> Bool {
      value is [String: String] || ((value as? [String])?.count ?? 0) > 512
    }
    if large(state["selected"]) {
      state.removeValue(forKey: "selected")
      state.removeValue(forKey: "beforeFilter")
    } else if let before = state["beforeFilter"] as? [String: Any], large(before["selected"]) {
      state.removeValue(forKey: "beforeFilter")
    }
    var saved: [String: Any] = ["key": location, "state": state]
    if let project { saved["project"] = project }
    if let data = try? JSONSerialization.data(withJSONObject: saved), data.count < 512_000 {
      UserDefaults.standard.set(data, forKey: "lastWorkspace")
    }
  }
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === previewPanel {
      displayQuickLook(at: nil)
      return
    }
    saveWorkspace()
    if let monitor = quickLookEvent {
      NSEvent.removeMonitor(monitor)
      quickLookEvent = nil
    }
    panelView?.previewItem = nil
    previewPanel?.close()
  }
  func snapshot() -> [String: Any] {
    if let pendingState {
      var saved = pendingState
      saved["query"] = ui.query.stringValue
      return saved
    }
    var saved: [String: Any] = [
      "scroll": ui.scroll.contentView.bounds.origin.y,
      "row": max(0, ui.table.selectedRow), "query": ui.query.stringValue,
    ]
    if let folderPath, entries.count > 512, rows.count == entries.count,
      ui.table.numberOfSelectedRows == entries.count
    {
      saved["selected"] = ["folder": folderPath, "names": FullFolderSelection.names(entries)]
    } else {
      saved["selected"] = fileSelection.map(\.path)
    }
    saved["order"] = displayedOrder?.rawValue ?? "collection"
    let visible = ui.table.rows(in: ui.scroll.documentVisibleRect)
    if visible.length > 0, rows.indices.contains(visible.location) {
      let end = min(rows.count, NSMaxRange(visible))
      let row = (visible.location..<end).first(where: ui.table.isRowSelected) ?? visible.location
      saved["anchorRow"] = row
      saved["anchorPath"] = entries[rows[row]].path
      saved["anchorDelta"] = ui.table.rect(ofRow: row).minY - ui.scroll.contentView.bounds.minY
    }
    if !displayedQuery.isEmpty, let beforeFilter { saved["beforeFilter"] = beforeFilter }
    return saved
  }
  func visit(_ key: String, selecting: String? = nil, animate: Bool = false) {
    guard !key.isEmpty else { return }
    let transaction: [String: Any] = ["op": "visit", "key": key, "state": snapshot()]
    navigate(transaction, selecting: selecting, animate: animate)
  }
  func step(_ action: String) {
    guard action == "back" ? canBack : canForward else { return }
    navigate(["op": action, "state": snapshot()], selecting: nil, animate: false)
  }
  func navigate(
    _ cmd: [String: Any], selecting: String?, animate: Bool, restoring: [String: Any]? = nil
  ) {
    do {
      let result = try engine.call(cmd, service: 1)
      guard let key = result["key"] as? String else { return }
      if isWorktable { leaveWorktable() }
      window.cancelHistorySwipe()
      if key != location && lastError != nil {
        lastError = nil
        transientStatus = false
        statusEpoch += 1
      }
      canBack = result["back"] as? Bool ?? false
      canForward = result["forward"] as? Bool ?? false
      prior = result["previous"] as? String
      var state = restoring ?? (result["state"] as? [String: Any]) ?? [:]
      if let selecting {
        state["selected"] = [selecting]
        state["query"] = ""
        state["reveal"] = true
      }
      if animate { animateEntry() }
      location = key
      if let path = folderPath {
        UserDefaults.standard.set(path, forKey: "lastFolder")
        recent = FolderReferences.unique([path] + recent, limit: 15)
        UserDefaults.standard.set(recent, forKey: "recentFolders")
      }
      if let root = contextualProject { UserDefaults.standard.set(root, forKey: "worktableProject") }
      openEpoch += 1
      updateChrome()
      load(state, clear: true)
    } catch { message(error.localizedDescription, error: true) }
  }
  func goUp() {
    guard let path = folderPath else {
      step("back")
      return
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard parent != path else { return }
    if prior == parent { step("back") } else { visit(parent, selecting: path) }
  }
  func load(_ state: [String: Any], clear: Bool, refreshInspector: Bool = true) {
    folderLoadTicket?.cancel()
    let ticket = FileReadTicket()
    folderLoadTicket = ticket
    revision += 1
    let token = revision
    let path = folderPath
    let hidden = showHidden
    let members = collection?.paths
    let order = fileOrder
    let start = DispatchTime.now().uptimeNanoseconds
    let recovering = path != nil && lastError != nil
    scanning = true
    folderDirty = false
    lastError = nil
    if clear {
      loading = true
      pendingState = state
      beforeFilter = state["beforeFilter"] as? [String: Any]
      displayedQuery = state["query"] as? String ?? ""
      applying = true
      folderSearch = nil
      entries = []
      rows = []
      ui.table.reloadData()
      applying = false
      ui.query.stringValue = state["query"] as? String ?? ""
      ui.showEmpty("Opening…")
      previewItems = nil
      ui.preview.show(
        urls: [], context: path.map { URL(fileURLWithPath: $0) }, showHidden: showHidden,
        order: order)
      updateSelection(refreshPreview: false)
    }
    let read = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let result = Result { () throws -> BrowserListing in
        if let path {
          return try self.engine.readFolder(path, showHidden: hidden, order: order, ticket: ticket)
        }
        if let members {
          let entries = try members.map { path in
            if ticket.cancelled { throw CancellationError() }
            return Entry.inspect(path)
          }
          return BrowserListing(entries: entries, warnings: [], index: nil)
        }
        throw CoreError(message: "This collection is unavailable.")
      }
      DispatchQueue.main.async {
        guard self.revision == token else { return }
        // A passive refresh can finish after a click, scroll, or new query.
        // Carry the latest view unless the operation explicitly revealed an item.
        let restored = !clear && state["reveal"] as? Bool != true ? self.snapshot() : state
        self.folderLoadTicket = nil
        self.loading = false
        self.scanning = false
        self.pendingState = nil
        switch result {
        case .success(let listing):
          self.displayedOrder = path == nil ? nil : order
          self.entries = listing.entries
          self.folderSearch = listing.index
          if listing.index == nil {
            _ = try? self.engine.call(["names": listing.entries.map(\.name)], service: 2)
          }
          // The single-item inspector watches its own file. A sibling export
          // should leave its text selection, scroll view and artwork in place.
          if refreshInspector || self.previewSelectionCount != 1 { self.previewItems = nil }
          self.filter(state: restored)
          if let warning = listing.warnings.first {
            self.message(warning, error: true, seconds: 12)
          } else if recovering {
            self.message("Folder reopened", seconds: 3, announce: true)
          }
        case .failure(let error):
          self.folderSearch = nil
          self.entries = []
          self.rows = []
          self.ui.table.reloadData()
          self.lastError = error.localizedDescription
          // If an exporter replaces a directory or a disk reconnects,
          // restore the last usable selection and scroll when it returns.
          self.pendingState = restored
          self.ui.showEmpty("Couldn’t open this folder", error: error.localizedDescription)
          self.message(error.localizedDescription, error: true, seconds: 12)
          self.updateSelection()
        }
        self.trace("open", start: start, rows: self.entries.count)
        self.scheduleFolderRefresh()
      }
    }
    if clear {
      refreshWork?.cancel()
      refreshWork = nil
      nextFolderRefresh = .now()
      folderWatcher.observe(
        path: path,
        ready: { [weak self] in
          guard let self, self.revision == token else { return }
          self.listingQueue.async(execute: read)
        },
        changed: { [weak self] in
          guard let self, self.folderPath == path else { return }
          self.folderDirty = true
          self.scheduleFolderRefresh()
        })
    } else {
      listingQueue.async(execute: read)
    }
  }
  func filter(state: [String: Any]? = nil) {
    let start = DispatchTime.now().uptimeNanoseconds
    let query = ui.query.stringValue
    var restore = state
    if state == nil {
      if displayedQuery.isEmpty && !query.isEmpty {
        beforeFilter = snapshot()
        beforeFilter?["query"] = ""
      } else if !displayedQuery.isEmpty && query.isEmpty {
        restore = beforeFilter
      }
    }
    if query.isEmpty { beforeFilter = nil }
    displayedQuery = query
    if query.isEmpty {
      rows = Array(entries.indices)
    } else if entries.isEmpty {
      rows = []
    } else if let folderSearch {
      rows = folderSearch.matching(query) ?? Array(entries.indices)
    } else if let response = try? engine.call(["query": query], service: 3) {
      rows =
        (response["all"] as? Bool == true)
        ? Array(entries.indices) : response["rows"] as? [Int] ?? []
    } else {
      rows = []
    }
    applying = true
    ui.table.reloadData()
    let paths = Set((restore?["selected"] as? [String]) ?? [])
    let externalSelection = restore?["externalSelection"] as? Bool == true
    let group = (restore?["selected"] as? [String: String]).flatMap {
      FullFolderSelection.restored($0, folder: folderPath, entries: entries, rows: rows)
    }
    var selectedIndexes = group ?? IndexSet()
    if !paths.isEmpty {
      for (i, id) in rows.enumerated() where paths.contains(entries[id].path) {
        selectedIndexes.insert(i)
      }
    }
    if group == nil && !externalSelection && selectedIndexes.isEmpty && !rows.isEmpty
      && (paths.isEmpty ? restore?["selected"] == nil : true)
    {
      selectedIndexes.insert(min(rows.count - 1, max(0, restore?["row"] as? Int ?? 0)))
    }
    ui.table.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
    ui.table.layoutSubtreeIfNeeded()
    var offset = restore?["scroll"] as? CGFloat ?? 0
    let orderChanged =
      (restore?["order"] as? String).map { $0 != (displayedOrder?.rawValue ?? "collection") }
      ?? false
    if offset > 0 || orderChanged, let anchor = restore?["anchorPath"] as? String {
      // A new export earlier in the list moves the row without changing its sort order.
      let unchanged = (restore?["anchorRow"] as? Int).flatMap { row in
        rows.indices.contains(row) && entries[rows[row]].path == anchor ? row : nil
      }
      if let row = unchanged ?? rows.firstIndex(where: { entries[$0].path == anchor }) {
        offset = ui.table.rect(ofRow: row).minY - (restore?["anchorDelta"] as? CGFloat ?? 0)
      }
    }
    let clip = ui.scroll.contentView
    clip.scroll(
      to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: offset), size: clip.bounds.size))
        .origin)
    ui.scroll.reflectScrolledClipView(clip)
    if restore?["reveal"] as? Bool == true, let row = selectedIndexes.first {
      ui.table.scrollRowToVisible(row)
    }
    applying = false
    if let lastError {
      ui.showEmpty("Couldn’t open this folder", error: lastError)
    } else {
      let hint =
        query.isEmpty
        ? (collection == nil ? "This folder is empty" : "This collection is empty")
        : "No filenames match"
      ui.showEmpty(rows.isEmpty ? hint : nil)
    }
    ui.showsSizes = rows.contains { !entries[$0].isDirectory }
    ui.root.needsLayout = true
    updateSelection()
    if externalSelection && selectedIndexes.count < paths.count {
      let found = Set(selectedIndexes.map { entries[rows[$0]].path })
      if let missing = paths.first(where: { !found.contains($0) }) {
        message(
          "Couldn’t find “" + missing + "” in this folder. It may have moved.", error: true,
          seconds: 25)
      }
    }
    trace("filter", start: start, rows: rows.count)
  }
  func updateSelection(refreshPreview: Bool = true) {
    let n = ui.table.numberOfSelectedRows
    let total = entries.count
    ui.count.stringValue =
      loading
      ? "Opening…"
      : !ui.query.stringValue.isEmpty
        ? "\(rows.count.formatted()) of \(total.formatted()) items"
        : "\(total.formatted()) \(total == 1 ? "item" : "items")"
    if n > 1 { ui.count.stringValue += " · \(n.formatted()) selected" }
    ui.move.isEnabled = n > 0 && !busy && !loading
    if !transientStatus { showSelectionHint() }
    guard refreshPreview else { return }
    let items = fileSelection.map(limit: n > 128 ? 32 : n) { $0 }
    if items != previewItems || n != previewSelectionCount || location != previewLocation
      || showHidden != previewHidden || fileOrder != previewOrder
    {
      previewItems = items
      previewSelectionCount = n
      previewLocation = location
      previewHidden = showHidden
      previewOrder = fileOrder
      ui.preview.show(
        urls: items.map(\.url), context: folderPath.map { URL(fileURLWithPath: $0) },
        showHidden: showHidden, order: fileOrder, totalSelectionCount: n)
    }
    if previewPanel?.isVisible == true { syncQuickLookSelection() }
  }
  func updateChrome() {
    updateSortControls()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if let path = folderPath {
      let url = URL(fileURLWithPath: path)
      ui.heading.stringValue = path == "/" ? "Macintosh HD" : url.lastPathComponent
      ui.crumb.set(folder: path)
      if !isWorktable { window.representedURL = url }
    } else {
      ui.heading.stringValue = collection?.name ?? "Collection"
      ui.crumb.set(folder: nil)
      if !isWorktable { window.representedURL = nil }
    }
    ui.heading.toolTip = folderPath ?? ui.heading.stringValue
    ui.crumb.toolTip = folderPath
    let filterLabel = folderPath == nil ? "Filter this collection" : "Filter this folder"
    if ui.query.placeholderString != filterLabel {
      ui.query.placeholderString = filterLabel
      ui.query.setAccessibilityLabel(filterLabel)
    }
    if !isWorktable { window.title = ui.heading.stringValue + " — Finger" }
    ui.back.isEnabled = canBack
    ui.forward.isEnabled = canForward
    ui.up.isEnabled = location != "/" && (folderPath != nil || canBack)
    var places = [("Home", "house", home, home)]
    for part in placeNames {
      let path = home + "/" + part.0
      places.append((part.0, part.1, path, path))
    }
    var seen = Set(places.map { FolderReferences.key($0.2) })
    let projects = [project].compactMap { $0 }.compactMap {
      path -> (String, String, String, String)? in
      guard seen.insert(FolderReferences.key(path)).inserted else { return nil }
      return (URL(fileURLWithPath: path).lastPathComponent, "folder", path, path)
    }
    let pins = favorites.compactMap { path -> (String, String, String, String)? in
      guard seen.insert(FolderReferences.key(path)).inserted else { return nil }
      return (URL(fileURLWithPath: path).lastPathComponent, "pin", path, path)
    }
    let visits = recent.prefix(12).compactMap { path -> (String, String, String, String)? in
      guard seen.insert(FolderReferences.key(path)).inserted else { return nil }
      return (URL(fileURLWithPath: path).lastPathComponent, "clock", path, path)
    }.prefix(5)
    rebuildCollectionsMenu()
    let sets = collections.map {
      ($0.name, "square.stack", "collection:" + $0.id, "\($0.paths.count) items")
    }
    ui.rail.set(
      [
        .init(title: "Places", links: places), .init(title: "Project", links: projects),
        .init(title: "Pinned", links: pins), .init(title: "Collections", links: sets),
        .init(title: "Recent", links: Array(visits)),
      ], selected: location)
  }
  func scheduleFolderRefresh() {
    guard folderDirty, !busy, !scanning, refreshWork == nil, let path = folderPath else { return }
    // Keep the first deadline when an exporter is still writing the following pages.
    let task = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.refreshWork = nil
      guard self.location == path, self.folderDirty, !self.busy, !self.scanning else { return }
      // Coalesce a continuous print job into at most two full listings per second.
      self.nextFolderRefresh = .now() + 0.5
      self.load(self.snapshot(), clear: false, refreshInspector: false)
    }
    refreshWork = task
    DispatchQueue.main.asyncAfter(deadline: max(.now() + 0.15, nextFolderRefresh), execute: task)
  }
  func openExternal(_ result: OpenItems.Resolution, setProject: Bool = true) {
    switch result.view {
    case .folder(let path):
      if setProject { project = path }
      visit(path)
    case .siblings(let parent, let paths, let needsHidden):
      if setProject { project = parent }
      if needsHidden { showHidden = true }
      navigate(
        ["op": "visit", "key": parent, "state": snapshot()], selecting: nil, animate: false,
        restoring: ["selected": paths, "query": "", "reveal": true, "externalSelection": true])
    case .collection(let urls):
      let first = urls.first?.lastPathComponent ?? "Items"
      let name = "Opened together · " + String(first.prefix(80)) + " + " + String(urls.count - 1)
      receiveCollection(name, urls, bringForward: false)
    case nil:
      if location.isEmpty {
        let home = NSHomeDirectory()
        project = home
        visit(home)
      }
    }
    if let notice = result.notice { message(notice, error: true, seconds: 25) }
  }
  func receiveCollection(_ name: String, _ urls: [URL], bringForward: Bool = true) {
    receiveCollection(name, paths: urls.map(\.path), bringForward: bringForward)
  }
  func receiveCollection(_ name: String, paths: [String], bringForward: Bool = true) {
    let existing = collections.first(where: { $0.name == name && $0.paths == paths })
    let record = existing ?? CollectionRecord(id: UUID().uuidString, name: name, paths: paths)
    collections.removeAll { $0.id == record.id }
    collections.insert(record, at: 0)
    persistCollections()
    visit("collection:" + record.id)
    message("Opened collection · " + name, announce: true)
    if bringForward { window.makeKeyAndOrderFront(nil) }
  }
  func persistCollections() {
    let snapshot = collections
    // Only the newest queued revision needs writing. A write already in
    // progress finishes before the replacement, preserving their order.
    collectionWrites.cancelAllOperations()
    collectionWrites.addOperation {
      if let data = try? JSONEncoder().encode(snapshot) {
        UserDefaults.standard.set(data, forKey: "collections")
      }
    }
  }
  func reveal(_ url: URL) {
    visit(url.deletingLastPathComponent().path, selecting: url.path, animate: true)
  }
  func openURL(_ url: URL) {
    openItemsInDefaultApps([url])
  }
  func openItemsInDefaultApps(_ urls: [URL], directories: [URL]? = nil) {
    guard !urls.isEmpty else { return }
    openEpoch += 1
    let epoch = openEpoch
    listingQueue.async { [weak self] in
      let workspace = NSWorkspace.shared
      let folders = directories ?? urls.filter { Entry.inspect($0.path).isDirectory }
      if let folder = folders.first(where: {
        (try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
      }) {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.openEpoch == epoch else { return }
          if urls.count == 1 {
            self.visit(folder.path, animate: true)
          } else {
            self.message("Select one folder to enter it.")
          }
        }
        return
      }
      // One Launch Services request per default application also lets
      // Preview open a group of selected images as a single selection.
      var groups: [URL: [URL]] = [:]
      var errors: [String] = []
      for url in urls {
        do {
          try OpenItems.requireReadable(url)
          if let application = workspace.urlForApplication(toOpen: url) {
            groups[application, default: []].append(url)
          } else {
            errors.append("No default app for " + url.lastPathComponent)
          }
        } catch { errors.append(error.localizedDescription) }
      }
      let notice = OpenItems.failureNotice(errors)
      DispatchQueue.main.async { [weak self, groups] in
        guard let self, self.openEpoch == epoch else { return }
        if let notice { self.message(notice, error: true, seconds: 12) }
        for (application, documents) in groups {
          workspace.open(documents, withApplicationAt: application, configuration: .init()) {
            [weak self] _, error in
            guard let error else {
              self?.listingQueue.async {
                ResumeHistory().recordUse(documents.prefix(64).map { Entry.inspect($0.path) })
              }
              return
            }
            DispatchQueue.main.async {
              self?.message(
                "Couldn’t open " + documents[0].lastPathComponent + " · "
                  + error.localizedDescription,
                error: true, seconds: 12)
            }
          }
        }
      }
    }
  }
  @objc func doubleClick() {
    let row = ui.table.clickedRow
    if rows.indices.contains(row) { openURL(entries[rows[row]].url) }
  }
  func controlTextDidChange(_ obj: Notification) { if !loading { filter() } }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)):
      clearFilter()
      return true
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
      window.makeFirstResponder(ui.table)
      if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1) }
      return true
    case #selector(NSResponder.insertNewline(_:)):
      openSelected()
      return true
    default: return false
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let id = NSUserInterfaceItemIdentifier("BrowserFileRow")
    let view = tableView.makeView(withIdentifier: id, owner: self) as? FileRow ?? FileRow()
    view.identifier = id
    return view
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard rows.indices.contains(row) else { return nil }
    let id = NSUserInterfaceItemIdentifier("file")
    let cell = tableView.makeView(withIdentifier: id, owner: self) as? FileCell ?? FileCell()
    cell.identifier = id
    cell.update(
      entries[rows[row]], selected: tableView.selectedRowIndexes.contains(row),
      order: displayedOrder, project: project)
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if !applying && !loading { updateSelection() }
  }
  func moveSelection(_ delta: Int) {
    guard !rows.isEmpty else { return }
    let index = min(rows.count - 1, max(0, ui.table.selectedRow + delta))
    ui.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    ui.table.scrollRowToVisible(index)
  }
  func showSelectionHint() {
    let hint: String
    if ui.table.numberOfSelectedRows > 1 {
      hint = "⇧⌘M  Move selection"
    } else if rows.indices.contains(ui.table.selectedRow) {
      hint =
        entries[rows[ui.table.selectedRow]].isDirectory
        ? "→  Enter folder" : "Space  Quick Look    ↵  Open"
    } else {
      hint = ""
    }
    ui.status.stringValue = hint
    ui.status.toolTip = nil
    ui.status.textColor = Ink.faint
    ui.status.setAccessibilityLabel(hint)
  }
  func message(_ value: String, error: Bool = false, seconds: Double = 5, announce: Bool = false) {
    if isWorktable { homeView.notice(value) }
    transientStatus = true
    statusEpoch += 1
    let epoch = statusEpoch
    ui.status.stringValue = value
    ui.status.toolTip = value
    ui.status.textColor = error ? Ink.issue : Ink.quiet
    ui.status.setAccessibilityLabel(value)
    if announce {
      NSAccessibility.post(
        element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, self.statusEpoch == epoch else { return }
      self.transientStatus = false
      self.showSelectionHint()
    }
  }
  func trace(_ event: String, start: UInt64, rows: Int) {
    if ProcessInfo.processInfo.environment["FINGER_TRACE"] == "1" {
      let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      FileHandle.standardError.write(
        Data(String(format: "Finger %@ %d rows %.3f ms\n", event, rows, ms).utf8))
    }
  }
  func animateEntry() {
    entryVeil?.discard()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let rep = ui.preview.bitmapImageRepForCachingDisplay(in: ui.preview.bounds)
    else { return }
    ui.preview.cacheDisplay(in: ui.preview.bounds, to: rep)
    let image = NSImage(size: ui.preview.bounds.size)
    image.addRepresentation(rep)
    let veil = EntryTransitionView(frame: ui.preview.frame)
    veil.image = image
    veil.imageScaling = .scaleAxesIndependently
    veil.setAccessibilityElement(false)
    ui.root.addSubview(veil, positioned: .above, relativeTo: ui.preview)
    entryVeil = veil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.20
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      veil.animator().frame = ui.body.frame
      veil.animator().alphaValue = 0
    } completionHandler: { [weak veil] in
      veil?.discard()
    }
    // AppKit can defer animation completions while a window is hidden.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak veil] in veil?.discard() }
  }
}
