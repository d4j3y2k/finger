import AppKit
import Quartz

/// Finger's summonable search-and-browse panel. Search for a file or folder,
/// step into a folder, and type to narrow. ⌃Space toggles it (Finger › Panel Shortcut…).
final class PanelController: NSObject, PanelKeyHandler, NSTextFieldDelegate, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate
{
  /// The app's panel, for the menu item.
  static weak var shared: PanelController?

  let panel = FingerPanel()
  let engine: Engine
  let search: PanelSearching
  let home: String
  let place: PanelPlace
  var preview: PanelPreview { didSet { installPreview(oldValue) } }

  /// The shortcut that shows and hides the panel. Nil in checks, which use the default.
  var shortcuts: PanelShortcuts? {
    didSet {
      NotificationCenter.default.removeObserver(self, name: PanelShortcuts.changed, object: nil)
      if let shortcuts {
        NotificationCenter.default.addObserver(
          self, selector: #selector(shortcutChanged), name: PanelShortcuts.changed, object: shortcuts)
      }
      updateFooter()
    }
  }
  var shortcut: PanelShortcut { shortcuts?.current ?? .standard }
  @objc func shortcutChanged() { updateFooter() }

  /// Hook for the "Working On" section, listed first on Home. Nil in phase 1.
  var workingOn: (() -> [PanelFile])?
  /// What you are working on: fills Working On and adds blue dots, landing on
  /// the trail, why lines and the footer status. Nil turns all of that off.
  var awareness: PanelAwareness? { didSet { awarenessInstalled(oldValue) } }
  let knowledgeView = PanelKnowledgeView()
  /// Hides the panel when it stops being the key window.
  var hidesOnResignKey = true
  var allowsMotion = true
  var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var revealer: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

  // MARK: Views
  let root = PanelRootView()
  let field = PanelField()
  let ghost = PanelGhost()
  let chips = PanelChipsView()
  let table = PanelTable()
  let peek = PanelFolderPeek()
  let footer = PanelFooter()
  let magnifier = NSImageView()
  let scroll = NSScrollView()
  let listHost = NSView()
  let previewHost = NSView()
  let emptyTitle = NSTextField(labelWithString: "")
  let emptyDetail = NSTextField(labelWithString: "")
  var flyers: [PanelFlyer] = []

  // MARK: State
  /// The folder you are browsing, or nil for Home and global search.
  private(set) var folder: String?
  private(set) var query = ""
  private(set) var rows: [PanelRow] = []
  private(set) var selectedRow: Int?
  var origin: (query: String, selected: String?)?
  var remembered: [String: String] = [:]
  var homeSelected: String?
  var escapeHides = false
  var userMoved = false
  var pendingPick: String?
  var hoveredRow = -1
  var concealedPath: String?
  var motionTicket = 0

  // MARK: Data
  private(set) var usage: [PanelFile] = []
  var usedAt: [String: Date] = [:]
  var usedUnder: [String: Date] = [:]
  private(set) var arrivals: [PanelFile] = []
  var listings: [String: [PanelFile]] = [:]
  var listingErrors: [String: String] = [:]
  var loading: Set<String> = []
  var counts: [String: Int] = [:]
  var counting: Set<String> = []
  var found: [String: (files: [PanelFile], finished: Bool)] = [:]
  var foundOrder: [String] = []
  var nameSearch: PanelSearchHandle?
  var contentSearch: PanelSearchHandle?
  var usageSearch: PanelSearchHandle?
  var searchWork: DispatchWorkItem?
  var arrival: (direction: Direction, snapshot: PanelMotionSnapshot?, focus: String?)?
  let reads = DispatchQueue(
    label: "finger.panel.reads", qos: .userInitiated, attributes: .concurrent)
  let countQueue = DispatchQueue(label: "finger.panel.counts", qos: .utility)

  // Keys typed after `/` wait here until the folder they belong to is known.
  var waitingForSlash = false
  var heldKeys: [NSEvent] = []
  var slashTimeout: DispatchWorkItem?

  enum Direction { case into, up }
  enum Pick {
    case first
    case keep
    case path(String?)
  }

  init(
    engine: Engine, search: PanelSearching? = nil, home: String = NSHomeDirectory(),
    preview: PanelPreview? = nil
  ) {
    self.engine = engine
    // Not standardizingPath: it would turn /private/var into /var.
    let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    self.home = home
    self.search = search ?? SpotlightSearch(home: home)
    self.place = PanelPlace(home: home)
    self.preview = preview ?? ContentPreview()
    super.init()
    build()
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  // MARK: - Building

  func build() {
    panel.keys = self
    panel.delegate = self
    root.frame = NSRect(origin: .zero, size: FingerPanel.size)
    let material = PanelMaterial.wrap(root)
    material.frame = NSRect(origin: .zero, size: FingerPanel.size)
    material.autoresizingMask = [.width, .height]
    panel.contentView = material
    root.frame = material.bounds
    root.onLayout = { [weak self] in self?.layoutViews() }

    magnifier.image = NSImage(
      systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
    magnifier.contentTintColor = .secondaryLabelColor
    magnifier.imageScaling = .scaleNone
    root.addSubview(magnifier)
    root.addSubview(chips)
    root.addSubview(ghost)
    root.addSubview(field)
    field.delegate = self
    field.placeholder = "Search"
    chips.onClick = { [weak self] in self?.go(to: $0) }

    let column = NSTableColumn(identifier: .init("item"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.backgroundColor = .clear
    table.intercellSpacing = .zero
    table.selectionHighlightStyle = .none
    table.style = .plain
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.focusRingType = .none
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Results")
    table.onClick = { [weak self] row, clicks, point in self?.click(row, clicks, point) }
    table.onHover = { [weak self] in self?.hover($0) }
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 10, right: 0)
    listHost.wantsLayer = true
    listHost.addSubview(scroll)
    emptyTitle.font = .systemFont(ofSize: 13)
    emptyTitle.textColor = .secondaryLabelColor
    emptyTitle.alignment = .center
    emptyTitle.lineBreakMode = .byTruncatingMiddle
    emptyDetail.font = .systemFont(ofSize: 12)
    emptyDetail.textColor = .tertiaryLabelColor
    emptyDetail.alignment = .center
    listHost.addSubview(emptyTitle)
    listHost.addSubview(emptyDetail)
    root.addSubview(listHost)

    previewHost.wantsLayer = true
    previewHost.addSubview(peek)
    peek.side = { [weak self] in self?.peekSide($0) ?? "" }
    peek.onPick = { [weak self] in self?.pickFromPeek($0) }
    root.addSubview(previewHost)
    installPreview(nil)
    footer.onHint = { [weak self] in self?.perform($0) }
    root.addSubview(footer)

    NotificationCenter.default.addObserver(
      self, selector: #selector(caretMoved(_:)), name: NSTextView.didChangeSelectionNotification,
      object: nil)
    updateChips()
    layoutViews()
    rebuild(.first)
  }

  func installPreview(_ old: PanelPreview?) {
    old?.view.removeFromSuperview()
    let view = preview.view
    view.frame = previewHost.bounds
    view.autoresizingMask = [.width, .height]
    previewHost.addSubview(view, positioned: .below, relativeTo: peek)
    updatePreview(force: true)
  }

  func layoutViews() {
    let b = root.bounds
    let top = b.height - PanelRootView.searchHeight
    magnifier.frame = NSRect(x: 16, y: top + (PanelRootView.searchHeight - 24) / 2, width: 24, height: 24)
    chips.maxWidth = ((b.width - 66) * 0.58).rounded()
    let chipsWidth = chips.contentWidth
    var x: CGFloat = 50
    chips.frame = NSRect(
      x: x, y: top + (PanelRootView.searchHeight - PanelChipsView.height) / 2, width: chipsWidth,
      height: PanelChipsView.height)
    chips.isHidden = chipsWidth == 0
    if chipsWidth > 0 { x += chipsWidth + 8 }
    field.frame = NSRect(x: x, y: top + (PanelRootView.searchHeight - 26) / 2, width: b.width - 18 - x, height: 26)
    let listWidth = (b.width * 1.08 / 2.08).rounded()
    root.listWidth = listWidth
    let bodyHeight = top - PanelRootView.footerHeight
    listHost.frame = NSRect(x: 0, y: PanelRootView.footerHeight, width: listWidth, height: bodyHeight)
    scroll.frame = listHost.bounds
    if let column = table.tableColumns.first { column.width = scroll.contentSize.width }
    emptyTitle.frame = NSRect(x: 18, y: listHost.bounds.height - 96, width: listWidth - 36, height: 18)
    emptyDetail.frame = NSRect(x: 18, y: listHost.bounds.height - 116, width: listWidth - 36, height: 16)
    previewHost.frame = NSRect(
      x: listWidth, y: PanelRootView.footerHeight, width: b.width - listWidth, height: bodyHeight)
    preview.view.frame = previewHost.bounds
    peek.frame = previewHost.bounds
    footer.frame = NSRect(x: 0, y: 0, width: b.width, height: PanelRootView.footerHeight)
    updateGhost()
  }

  // MARK: - Showing

  var isShown: Bool { panel.isVisible }

  func toggle() {
    if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
  }

  /// Shows the panel centered on the screen with the pointer.
  func show() { show(onScreen: true) }

  /// Prepares the panel without putting it on screen, for checks.
  func showOffscreen() { show(onScreen: false) }

  func show(onScreen: Bool) {
    escapeHides = false
    if !panel.isVisible {
      awareness?.panelWillShow()
      found.removeAll()
      foundOrder.removeAll()
      refreshHome()
      if let folder { refreshListing(folder) }
      if !trimmedQuery.isEmpty { scheduleSearch(immediate: true) }
      if !onScreen {
        panel.setFrame(
          NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: FingerPanel.size), display: false)
        panel.alphaValue = 1
      } else {
        panel.placeOnPointerScreen()
        if motionOn {
          panel.alphaValue = 0
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
          }
        } else {
          panel.alphaValue = 1
        }
      }
    }
    if onScreen { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    focusField(selectAll: onScreen)
    rebuild(.keep)
    if onScreen { DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() } }
  }

  func hide() {
    finishMotion()
    closeQuickLook()
    hideKnowledge()
    cancelSearches()
    releaseHeldKeys()
    panel.orderOut(nil)
    awareness?.panelDidHide()
  }

  func focusField(selectAll: Bool) {
    panel.makeFirstResponder(field)
    guard let editor = field.currentEditor() else { return }
    let length = (field.stringValue as NSString).length
    editor.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard hidesOnResignKey, panel.isVisible else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
      if NSApp.keyWindow is QLPreviewPanel { return }
      self.hide()
    }
  }

  // MARK: - Home data

  func refreshHome() {
    usageSearch?.cancel()
    usageSearch = search.recentlyUsed(in: home) { [weak self] files in
      guard let self else { return }
      self.usage = files
      self.indexUsage()
      self.awareness?.noteUsage(files)
      if self.folder == nil && self.trimmedQuery.isEmpty {
        self.rebuild(self.userMoved ? .keep : .path(self.homeSelected))
      }
    }
    let downloads = home + "/Downloads"
    reads.async { [weak self] in
      let cutoff = Date().addingTimeInterval(-3600)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? []
      let skip: Set<String> = ["download", "crdownload", "part", "partial"]
      let files = names.filter {
        !$0.hasPrefix(".") && !skip.contains(($0 as NSString).pathExtension.lowercased())
      }
      .compactMap { PanelFile.inspect(downloads + "/" + $0) }
      .filter { ($0.added ?? .distantPast) >= cutoff }
      .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.arrivals = files
        if self.folder == nil && self.trimmedQuery.isEmpty {
          self.rebuild(self.userMoved ? .keep : .path(self.homeSelected))
        }
      }
    }
  }

  func indexUsage() {
    usedAt.removeAll()
    usedUnder.removeAll()
    for file in usage {
      guard let used = file.lastUsed else { continue }
      usedAt[file.path] = max(used, usedAt[file.path] ?? .distantPast)
      var parent = file.parent
      while parent.count > 1 {
        usedUnder[parent] = max(used, usedUnder[parent] ?? .distantPast)
        if parent == home { break }
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
  }

  /// When you last used this item, or anything inside it.
  func usedDate(_ file: PanelFile) -> Date? {
    [file.lastUsed, usedAt[file.path], usedUnder[file.path]].compactMap { $0 }.max()
  }

  func touched(_ file: PanelFile) -> Date? {
    [usedDate(file), file.modified, file.added, awarenessSnapshot.latest[file.path]].compactMap { $0 }.max()
  }

  /// Newer use first, then newer changes.
  func newer(_ a: PanelFile, _ b: PanelFile) -> Bool? {
    let ua = usedDate(a) ?? .distantPast
    let ub = usedDate(b) ?? .distantPast
    if ua != ub { return ua > ub }
    let ma = a.modified ?? .distantPast
    let mb = b.modified ?? .distantPast
    if ma != mb { return ma > mb }
    return nil
  }

  /// The item last selected in `folder`, which entering it again selects.
  func lastSelection(in folder: String) -> String? { remembered[folder] }

  /// Entering a folder selects the item last selected there, else the most
  /// recently used item, else the most recently changed one.
  func landing(_ folder: String) -> String? {
    guard let list = listings[folder], !list.isEmpty else { return nil }
    if let last = remembered[folder], list.contains(where: { $0.path == last }) { return last }
    if let trail = awarenessLanding(list) { return trail }
    return list.min { newer($0, $1) ?? false }?.path
  }

  // MARK: - Folders

  func refreshListing(_ path: String) {
    load(path)
  }

  func load(_ path: String) {
    guard !loading.contains(path) else { return }
    loading.insert(path)
    let engine = self.engine
    reads.async { [weak self] in
      var files: [PanelFile] = []
      var failure: String?
      do {
        let listing = try engine.readFolder(path, showHidden: false, order: .nameAsc)
        files = listing.entries.map(PanelFile.init(entry:))
        // The core lists directories first; packages read as files here.
        let folders = files.filter(\.isFolder)
        let rest = files.filter { !$0.isFolder }.sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        files = folders + rest
      } catch {
        failure = error.localizedDescription
      }
      DispatchQueue.main.async { self?.loaded(path, files, failure) }
    }
  }

  func loaded(_ path: String, _ files: [PanelFile], _ failure: String?) {
    loading.remove(path)
    let changed = listings[path] != files || listingErrors[path] != failure
    if listings.count > 300, listings[path] == nil, let any = listings.keys.first(where: { $0 != folder }) {
      listings[any] = nil
    }
    listings[path] = files
    listingErrors[path] = failure
    if path == folder {
      if let pending = arrival {
        arrival = nil
        rebuild(.path(pending.focus ?? landing(path)))
        if let snapshot = pending.snapshot { runMotion(pending.direction, snapshot, listOnly: true) }
      } else if changed {
        rebuild(.keep)
      }
    }
    if selectedItem?.file.path == path { updatePreview(force: true) }
    resumeHeldKeysIfReady()
  }

  func count(_ folder: PanelFile) -> String {
    if let n = counts[folder.path] { return n < 0 ? "Folder" : PanelText.count(n) }
    if let list = listings[folder.path] {
      counts[folder.path] = list.count
      return PanelText.count(list.count)
    }
    requestCount(folder.path)
    return "Folder"
  }

  func requestCount(_ path: String) {
    guard counts[path] == nil, !counting.contains(path) else { return }
    counting.insert(path)
    countQueue.async { [weak self] in
      let names = try? FileManager.default.contentsOfDirectory(atPath: path)
      let n = names.map { $0.filter { !$0.hasPrefix(".") }.count } ?? -1
      DispatchQueue.main.async {
        guard let self else { return }
        self.counting.remove(path)
        self.counts[path] = n
        let affected = IndexSet(
          self.rows.indices.filter { self.rows[$0].item?.file.path == path })
        if !affected.isEmpty {
          self.table.reloadData(forRowIndexes: affected, columnIndexes: IndexSet(integer: 0))
        }
        if self.peek.content?.items?.contains(where: { $0.path == path }) == true
          || self.peek.content?.folder.path == path
        {
          self.updatePreview(force: true)
        }
      }
    }
  }

  // MARK: - What the list shows

  var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

  func key(_ kind: String, _ scope: String, _ text: String) -> String {
    kind + "\u{0}" + scope + "\u{0}" + text.lowercased()
  }

  func store(_ key: String, _ files: [PanelFile], _ finished: Bool) {
    if found[key] == nil {
      foundOrder.append(key)
      if foundOrder.count > 40 { found[foundOrder.removeFirst()] = nil }
    }
    found[key] = (files, finished)
  }

  /// Hits for `text`, or until they arrive, the hits for the longest shorter
  /// query, which keeps the list steady while typing. Name hits also include
  /// recently used items, which Spotlight may return late or not at all.
  func hits(_ kind: String, _ scope: String, _ text: String) -> [PanelFile] {
    let searched = searchedHits(kind, scope, text)
    guard kind == "names" else { return searched }
    let prefix = scope == "/" ? "/" : scope + "/"
    let used = usage.filter {
      $0.path.hasPrefix(prefix) && PanelMatch.rank(text, in: $0.name) > 0
        && !SpotlightSearch.isNoise($0.path, below: scope, home: home)
    }
    return used + searched
  }

  func searchedHits(_ kind: String, _ scope: String, _ text: String) -> [PanelFile] {
    if let exact = found[key(kind, scope, text)] { return exact.files }
    var shorter = text
    while !shorter.isEmpty {
      shorter.removeLast()
      if let earlier = found[key(kind, scope, shorter)], !shorter.isEmpty {
        return kind == "names" ? earlier.files.filter { PanelMatch.rank(text, in: $0.name) > 0 } : []
      }
    }
    return []
  }

  func searching(_ scope: String, _ text: String) -> Bool {
    if found[key("names", scope, text)]?.finished != true { return true }
    return text.count >= 3 && found[key("contents", scope, text)]?.finished != true
  }

  func computeSections() -> [PanelSection] {
    let text = trimmedQuery
    if let folder { return browseSections(folder, text) }
    if text.isEmpty { return homeSections() }
    return searchSections(text)
  }

  func homeSections() -> [PanelSection] {
    var sections: [PanelSection] = []
    // Phase 2 plugs "Working On" in here.
    if let working = workingOn?(), !working.isEmpty {
      sections.append(
        PanelSection(
          title: "Working On",
          items: working.map {
            PanelItem(
              file: $0, origin: .home, subtitle: place.whereText($0.path),
              side: awarenessSide($0) ?? PanelText.ago(touched($0)))
          }))
    }
    var shown = Set(sections.flatMap(\.items).map(\.file.path))
    let fresh = arrivals.filter { !shown.contains($0.path) }
    if !fresh.isEmpty {
      sections.append(
        PanelSection(
          title: "Just Arrived",
          items: fresh.map {
            PanelItem(file: $0, origin: .home, subtitle: "Downloads", side: PanelText.ago($0.added))
          }))
    }
    shown.formUnion(fresh.map(\.path))
    let recents = usage.filter {
      !$0.isFolder && !shown.contains($0.path) && ($0.name as NSString).pathExtension != "app"
    }.prefix(8)
    if !recents.isEmpty {
      sections.append(
        PanelSection(
          title: "Recents",
          items: recents.map {
            PanelItem(
              file: $0, origin: .home, subtitle: place.whereText($0.path),
              side: PanelText.ago($0.lastUsed))
          }))
    }
    return sections
  }

  func searchSections(_ text: String) -> [PanelSection] {
    var seen = Set<String>()
    var ranked: [(file: PanelFile, range: NSRange, score: Double)] = []
    for var file in hits("names", home, text) where seen.insert(file.path).inserted {
      guard let match = PanelMatch.find(text, in: file.name) else { continue }
      file.lastUsed = usedDate(file)
      ranked.append(
        (file, match.range, PanelMatch.score(file, rank: match.rank, query: text, home: home)))
    }
    ranked.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.file.name.count != $1.file.name.count { return $0.file.name.count < $1.file.name.count }
      return $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending
    }
    let named = ranked.prefix(20).map {
      PanelItem(
        file: $0.file, origin: .search, subtitle: place.whereText($0.file.path),
        side: PanelText.ago(touched($0.file)), highlight: $0.range)
    }
    var sections: [PanelSection] = []
    if !named.isEmpty { sections.append(PanelSection(title: "Files & Folders", items: named)) }
    if text.count >= 3 {
      let inside = insideItems(home, text, excluding: Set(named.map(\.file.path)), limit: 6) {
        self.place.whereText($0.path)
      }
      if !inside.isEmpty { sections.append(PanelSection(title: "Inside Files", items: inside)) }
    }
    return sections
  }

  func insideItems(
    _ scope: String, _ text: String, excluding: Set<String>, limit: Int,
    where whereText: (PanelFile) -> String
  ) -> [PanelItem] {
    var seen = excluding
    let files = hits("contents", scope, text).filter { seen.insert($0.path).inserted }
    return files.sorted { newer($0, $1) ?? ($0.name < $1.name) }.prefix(limit).map {
      PanelItem(
        file: $0, origin: .inside, subtitle: whereText($0), side: PanelText.ago(touched($0)),
        match: text)
    }
  }

  func browseSections(_ folder: String, _ text: String) -> [PanelSection] {
    guard let list = listings[folder] else { return [] }
    let name = place.name(folder)
    if text.isEmpty {
      return [
        PanelSection(
          title: "In " + name, aside: PanelText.count(list.count),
          items: list.map { browseItem($0) })
      ]
    }
    func order(_ a: (PanelFile, Int, NSRange), _ b: (PanelFile, Int, NSRange)) -> Bool {
      if a.1 != b.1 { return a.1 > b.1 }
      if let n = newer(a.0, b.0) { return n }
      return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
    }
    let here = list.compactMap { f in PanelMatch.find(text, in: f.name).map { (f, $0.rank, $0.range) } }
      .sorted(by: order)
    let direct = Set(list.map(\.path))
    var seen = direct
    let deeper = hits("names", folder, text)
      .filter { $0.path != folder && seen.insert($0.path).inserted }
      .compactMap { f in PanelMatch.find(text, in: f.name).map { (f, $0.rank, $0.range) } }
      .filter { $0.1 >= PanelMatch.wordStart || text.count >= 3 }
      .sorted(by: order)
      .prefix(6)
    var sections: [PanelSection] = []
    if !here.isEmpty {
      sections.append(
        PanelSection(
          title: "In " + name, aside: "\(here.count) of \(list.count)",
          items: here.map { browseItem($0.0, highlight: $0.2) }))
    }
    if !deeper.isEmpty {
      sections.append(
        PanelSection(
          title: "Deeper in " + name,
          items: deeper.map {
            PanelItem(
              file: $0.0, origin: .deeper, subtitle: place.relativeText($0.0.path, in: folder),
              side: PanelText.ago(touched($0.0)), highlight: $0.2)
          }))
    }
    if text.count >= 3 {
      let shown = Set(here.map(\.0.path) + deeper.map(\.0.path))
      let inside = insideItems(folder, text, excluding: shown, limit: 4) {
        self.place.relativeText($0.path, in: folder)
      }
      if !inside.isEmpty { sections.append(PanelSection(title: "Inside Files", items: inside)) }
    }
    return sections
  }

  func browseItem(_ file: PanelFile, highlight: NSRange? = nil) -> PanelItem {
    // Subtitle and time are worked out when the row is drawn: a folder can
    // hold thousands of items and only a screenful is ever shown.
    PanelItem(file: file, origin: .here, subtitle: nil, side: nil, highlight: highlight)
  }

  // MARK: - Rows and selection

  var selectedItem: PanelItem? { selectedRow.flatMap { $0 < rows.count ? rows[$0].item : nil } }
  var selectedPath: String? { selectedItem?.file.path }
  var firstItemRow: Int? { rows.firstIndex { $0.item != nil } }
  /// Titles of the sections shown, for checks.
  var sectionTitles: [String] {
    rows.compactMap { if case .header(let s) = $0 { return s.title } else { return nil } }
  }
  var itemNames: [String] { rows.compactMap { $0.item?.file.name } }
  func items(in title: String) -> [PanelItem] {
    for row in rows { if case .header(let s) = row, s.title == title { return s.items } }
    return []
  }

  func rowIndex(of path: String) -> Int? {
    rows.firstIndex { $0.item?.file.path == path }
  }

  func rebuild(_ pick: Pick) {
    let previous = selectedPath
    let previousRow = selectedRow
    var built: [PanelRow] = []
    for section in computeSections() {
      built.append(.header(section))
      built += section.items.map(PanelRow.item)
    }
    rows = built
    selectedRow = nil
    hoveredRow = -1
    table.reloadData()
    var target: Int?
    switch pick {
    case .first:
      target = firstItemRow
    case .keep:
      target = previous.flatMap(rowIndex(of:))
      if target == nil, let previousRow {
        target = rows.indices.filter { rows[$0].item != nil }.min {
          abs($0 - previousRow) < abs($1 - previousRow)
        }
      }
      if target == nil { target = firstItemRow }
    case .path(let path):
      target = path.flatMap(rowIndex(of:)) ?? firstItemRow
    }
    select(target, reveal: true)
    updateEmptyState()
    resumeHeldKeysIfReady()
  }

  func select(_ row: Int?, reveal: Bool) {
    let old = selectedRow
    selectedRow = row
    for r in [old, row].compactMap({ $0 }) where r < rows.count {
      (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? PanelItemCell)?.chosen = r == row
    }
    if let row, reveal {
      // Keep a section's header in view when its first item is selected.
      if row > 0, case .header = rows[row - 1] { table.scrollRowToVisible(row - 1) }
      table.scrollRowToVisible(row)
    }
    selectionChanged()
  }

  func selectionChanged() {
    if let item = selectedItem {
      if let folder, trimmedQuery.isEmpty, item.file.parent == folder {
        remembered[folder] = item.file.path
      }
      if folder == nil, trimmedQuery.isEmpty { homeSelected = item.file.path }
    }
    updatePreview()
    updateGhost()
    updateFooter()
    if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible,
      ql.dataSource === self
    {
      ql.reloadData()
    }
  }

  func move(_ delta: Int) {
    let items = rows.indices.filter { rows[$0].item != nil }
    guard !items.isEmpty else { return }
    userMoved = true
    pendingPick = nil
    guard let current = selectedRow, let at = items.firstIndex(of: current) else {
      select(items[0], reveal: true)
      return
    }
    let next = items[max(0, min(items.count - 1, at + delta))]
    if next != current { select(next, reveal: true) }
  }

  func updateEmptyState() {
    let text = trimmedQuery
    var title = ""
    var detail = ""
    if rows.isEmpty {
      if let folder {
        let name = place.name(folder)
        if let error = listingErrors[folder] {
          title = "Can’t open “\(name)”"
          detail = error
        } else if listings[folder] == nil {
          title = ""
        } else if text.isEmpty {
          title = "Empty folder"
          detail = "Press ⌫ to go up"
        } else if !searching(folder, text) {
          title = "Nothing in \(name) matches “\(text)”"
          detail = "Searched its subfolders and the text inside its files"
        }
      } else if text.isEmpty {
        title = "Type to search your files"
        detail = "Recently used files and new downloads appear here"
      } else if !searching(home, text) {
        title = "No results for “\(text)”"
        detail = "Searched names and the text inside files"
      }
    }
    emptyTitle.stringValue = title
    emptyDetail.stringValue = detail
    emptyTitle.isHidden = title.isEmpty
    emptyDetail.isHidden = detail.isEmpty
  }

  func updateFooter() {
    let text = trimmedQuery
    if let folder {
      let busy = !text.isEmpty && searching(folder, text)
      footer.status =
        (text.isEmpty ? awarenessStatus : nil) ?? place.abbreviated(folder) + (busy ? " · Searching…" : "")
    } else if text.isEmpty {
      footer.status =
        shortcuts.map { !$0.registered } == true
        ? "\(shortcut.display) isn’t available · Finger › Panel Shortcut…"
        : awarenessStatus ?? "\(shortcut.display) shows and hides this panel"
    } else if searching(home, text) {
      footer.status = "Searching…"
    } else {
      let n = rows.filter { $0.item != nil }.count
      footer.status = n == 1 ? "1 result" : "\(n) results"
    }
    footer.aware = awarenessStatus != nil && footer.status == awarenessStatus
    var hints: [PanelHint] = []
    if let item = selectedItem {
      hints.append(PanelHint(keys: "↩", label: "Open", action: .activate))
      if !item.file.isFolder {
        hints.append(
          PanelHint(keys: text.isEmpty ? "Space" : "⇧Space", label: "Quick Look", action: .quickLook))
        if item.file.parent != folder {
          hints.append(PanelHint(keys: "→", label: "Folder", action: .intoFolder))
        }
      }
      hints.append(PanelHint(keys: "⌘↩", label: "Show in Finder", action: .reveal))
    }
    if folder != nil && field.stringValue.isEmpty {
      hints.append(PanelHint(keys: "⌫", label: "Up", action: .up))
    }
    footer.hints = hints
  }

  // MARK: - Preview and peek

  var previewShown: (url: URL?, match: String?)?

  func updatePreview(force: Bool = false) {
    guard let item = selectedItem else {
      peek.isHidden = true
      peek.content = nil
      preview.view.isHidden = false
      showPreview(nil, nil, force: force)
      return
    }
    if item.file.isFolder {
      showPreview(nil, nil, force: force)
      preview.view.isHidden = true
      peek.isHidden = false
      let file = item.file
      let list = listings[file.path]
      if list == nil { load(file.path) }
      let total = list?.count
      let parent = file.parent
      peek.content = PanelFolderPeek.Content(
        folder: file, title: place.name(file.path),
        subtitle: [total.map(PanelText.count) ?? count(file), place.name(parent == home ? home : parent)]
          .joined(separator: " · "),
        items: list.map { Array($0.prefix(PanelFolderPeek.rows)) }, total: total ?? 0,
        landing: landing(file.path), why: awarenessSnapshot.why(folder: file.path))
    } else {
      peek.isHidden = true
      peek.content = nil
      preview.view.isHidden = false
      // The query is only a match to highlight when the file was found by its contents.
      showPreview(item.file.url, item.origin == .inside ? item.match : nil, force: force)
    }
  }

  func showPreview(_ url: URL?, _ match: String?, force: Bool) {
    if !force, let shown = previewShown, shown.url == url, shown.match == match { return }
    previewShown = (url, match)
    preview.show(url, match: match)
  }

  func peekSide(_ file: PanelFile) -> String {
    file.isFolder ? count(file) : PanelText.size(file.size)
  }

  func pickFromPeek(_ path: String) {
    guard let item = selectedItem, item.file.isFolder else { return }
    finishMotion()
    enter(item.file.path, focus: path)
  }

  // MARK: - Ghost completion

  @objc func caretMoved(_ note: Notification) {
    guard let editor = note.object as? NSTextView, editor === field.currentEditor() else { return }
    updateGhost()
  }

  /// The gray rest of the selected name after the caret, when the name starts
  /// with what you typed.
  var completion: String {
    let typed = field.stringValue
    guard !typed.isEmpty, let name = selectedItem?.file.name else { return "" }
    if let editor = field.currentEditor() {
      let range = editor.selectedRange
      guard range.length == 0, range.location == (typed as NSString).length else { return "" }
    }
    let ns = name as NSString
    let length = (typed as NSString).length
    guard ns.length > length,
      ns.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive]).location == 0
    else { return "" }
    return ns.substring(from: length)
  }

  func updateGhost() {
    let rest = completion
    guard !rest.isEmpty else {
      ghost.isHidden = true
      ghost.stringValue = ""
      return
    }
    var end = field.frame.minX + 2 + PanelDraw.width(
      NSAttributedString(string: field.stringValue, attributes: [.font: PanelField.textFont]))
    if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager,
      let container = editor.textContainer
    {
      layout.ensureLayout(for: container)
      let glyphs = layout.glyphRange(for: container)
      let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
      let point = NSPoint(x: box.maxX + editor.textContainerOrigin.x, y: 0)
      end = editor.convert(point, to: root).x
    }
    let width = field.frame.maxX - end
    guard width > 8 else {
      ghost.isHidden = true
      return
    }
    ghost.stringValue = rest
    // Same font and cell as the field, so the baselines match.
    ghost.frame = NSRect(x: end - 2, y: field.frame.minY, width: width + 2, height: field.frame.height)
    ghost.isHidden = false
  }

  // MARK: - Typing

  func controlTextDidChange(_ obj: Notification) {
    finishMotion()
    let before = selectedItem?.file
    query = field.stringValue
    escapeHides = false
    userMoved = false
    pendingPick = nil
    if trimmedQuery.isEmpty {
      cancelSearches()
      if let folder {
        rebuild(.path(before?.parent == folder ? before?.path : landing(folder)))
      } else {
        rebuild(.path(homeSelected))
      }
    } else {
      rebuild(.first)
      scheduleSearch()
    }
    updateFooter()
  }

  func setQuery(_ text: String) {
    query = text
    field.stringValue = text
    if let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }
  }

  func cancelSearches() {
    searchWork?.cancel()
    searchWork = nil
    nameSearch?.cancel()
    nameSearch = nil
    contentSearch?.cancel()
    contentSearch = nil
  }

  /// Debounced lightly. A newer query cancels the older one's searches.
  func scheduleSearch(immediate: Bool = false) {
    cancelSearches()
    let text = trimmedQuery
    guard !text.isEmpty else { return }
    let scope = folder ?? home
    let work = DispatchWorkItem { [weak self] in self?.startSearch(text, scope) }
    searchWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.06), execute: work)
  }

  func startSearch(_ text: String, _ scope: String) {
    let names = key("names", scope, text)
    if found[names]?.finished != true {
      nameSearch = search.names(text, in: scope) { [weak self] files, finished in
        self?.arrived(names, text, scope, files, finished)
      }
    }
    let contents = key("contents", scope, text)
    if text.count >= 3, found[contents]?.finished != true {
      contentSearch = search.contents(text, in: scope) { [weak self] files, finished in
        self?.arrived(contents, text, scope, files, finished)
      }
    }
  }

  func arrived(
    _ key: String, _ text: String, _ scope: String, _ files: [PanelFile], _ finished: Bool
  ) {
    store(key, files, finished)
    guard text == trimmedQuery, scope == (folder ?? home) else { return }
    if userMoved {
      rebuild(.keep)
    } else if let pendingPick {
      rebuild(.path(pendingPick))
      if rowIndex(of: pendingPick) != nil || !searching(scope, text) { self.pendingPick = nil }
    } else {
      rebuild(.first)
    }
    updateFooter()
  }

  // MARK: - Navigation

  func enter(_ path: String, focus: String? = nil) {
    if folder == nil { origin = (query, selectedPath) }
    navigate(to: path, focus: focus ?? remembered[path], direction: .into)
  }

  /// Jumps up to an enclosing folder and lands on the folder you came out of.
  func go(to ancestor: String) {
    guard let folder, ancestor != folder else { return }
    navigate(to: ancestor, focus: place.child(of: ancestor, toward: folder), direction: .up)
  }

  func goUp() {
    guard let folder else { return }
    if let parent = place.parent(folder) { go(to: parent) } else { exitBrowsing() }
  }

  /// Back out of browsing to the search you started from.
  func exitBrowsing() {
    guard folder != nil else { return }
    let start = origin ?? (query: "", selected: homeSelected)
    origin = nil
    navigate(to: nil, focus: start.selected, direction: .up, restoring: start.query)
  }

  func navigate(
    to target: String?, focus: String?, direction: Direction, restoring text: String = ""
  ) {
    finishMotion()
    let snapshot = motionOn ? captureMotion() : nil
    cancelSearches()
    folder = target
    setQuery(text)
    escapeHides = false
    userMoved = false
    pendingPick = nil
    arrival = nil
    updateChips()
    layoutViews()
    field.placeholder = target.map { "Search in " + place.name($0) } ?? "Search"
    guard let target else {
      rebuild(.path(focus))
      if !trimmedQuery.isEmpty, searching(home, trimmedQuery) {
        pendingPick = focus
        scheduleSearch(immediate: true)
      }
      if let snapshot { runMotion(direction, snapshot, listOnly: false) }
      return
    }
    if listings[target] == nil {
      arrival = (direction, snapshot, focus)
      rows = []
      selectedRow = nil
      table.reloadData()
      selectionChanged()
      updateEmptyState()
      load(target)
      if direction == .into, let snapshot { flyIn(snapshot) }
      return
    }
    rebuild(.path(focus ?? landing(target)))
    refreshListing(target)
    if let snapshot { runMotion(direction, snapshot, listOnly: false) }
  }

  func updateChips() {
    guard let folder else {
      chips.chips = []
      return
    }
    var levels = place.levels(folder).map {
      PanelChipsView.Chip(path: $0, title: place.name($0), icon: PanelIcons.shared.icon($0))
    }
    if levels.count > 3 {
      levels = [levels[0], PanelChipsView.Chip(path: nil, title: "…", icon: nil)] + levels.suffix(2)
    }
    chips.chips = levels
  }

  /// Titles of the path chips, for checks.
  var chipTitles: [String] { chips.chips.map(\.title) }
}
