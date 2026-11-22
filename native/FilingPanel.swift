import AppKit

/// The footer actions filing adds.
enum FilingHint: Equatable {
  case file, move, confirm, cancel
}

/// The panel's side of filing: chips on new downloads, the Jev bar above an
/// arrival's preview, ⇥, the move list (⌥M), moves through the core with
/// receipts, ⌘Z and the toast's Undo.
final class FilingPanel {
  /// "Move <name> to": the panel lists folders instead of files.
  struct MoveMode {
    let file: PanelFile
    /// Where you were, for Esc.
    let query: String
    let selected: String?
    let verdict: FilingVerdict?
    /// Shown first, under "Suggested by Jev".
    let jev: [FilingRanked]
    var local: FilingGathered?
    var project: String?
    var universe: [String]
    var preselect: String?
    var loading: Bool
  }

  struct Undo: Equatable {
    let receipts: [String]
    let name: String
    let from: String
    let to: String
    let source: String
    let destination: String
  }

  weak var controller: PanelController?
  let coordinator: FilingCoordinator
  let engine: Engine
  let bar = FilingBar()
  let toast = FilingToast()
  private(set) var move: MoveMode?
  private(set) var undos: [Undo] = []
  private(set) var busy = false
  /// Files the panel moved, old path → new path, so stale search rows follow them.
  private(set) var relocated: [String: String] = [:]
  private let moves = DispatchQueue(label: "finger.panel.filing", qos: .userInitiated)
  private let listing = DispatchQueue(label: "finger.panel.filing.folders", qos: .userInitiated)
  /// Runs after each move, undo or folder list finishes, for checks.
  var settled: (() -> Void)?

  var isMoving: Bool { move != nil }
  var canUndo: Bool { !busy && !undos.isEmpty }

  init(controller: PanelController, coordinator: FilingCoordinator, engine: Engine) {
    self.controller = controller
    self.coordinator = coordinator
    self.engine = engine
    bar.onPress = { [weak self] in self?.pressed($0) }
  }

  private var home: String { coordinator.home }
  private func name(_ folder: String) -> String { FilingText.folderName(folder, home: home) }

  // MARK: - Rows

  /// "Downloads · harborprint.co" for a new download.
  func arrivalSubtitle(_ path: String) -> String? {
    coordinator.arrival(path)?.host.map { "Downloads · " + FilingText.shortHost($0) }
  }

  func chip(for file: PanelFile) -> FilingChip? {
    guard !file.isFolder else { return nil }
    return coordinator.verdict(for: file.path)?.chip(home: home)
  }

  func decorate(_ cell: PanelItemCell, _ item: PanelItem) {
    if move != nil {
      cell.filingChip = nil
      cell.probability = item.probability
      cell.folder = false
      // Home reads as Home, never the user's folder name.
      cell.name = name(item.file.path)
      // Counted only for rows on screen: the list can hold hundreds of folders.
      cell.side = item.probability == nil ? (controller?.count(item.file) ?? "") : ""
      return
    }
    cell.probability = nil
    cell.filingChip = chip(for: item.file)
  }

  /// Search and Recents rows for files the panel moved point at their new place.
  func adjust(_ sections: [PanelSection]) -> [PanelSection] {
    guard !relocated.isEmpty, let c = controller else { return sections }
    return sections.map { section in
      var section = section
      var seen = Set<String>()
      section.items = section.items.compactMap { item in
        var item = item
        if let moved = relocated[item.file.path] {
          // New downloads that were filed have left; the next read drops them.
          if section.title == "Just Arrived" { return nil }
          guard FileManager.default.fileExists(atPath: moved) else { return nil }
          item.file = PanelFile(
            path: moved, isFolder: item.file.isFolder, lastUsed: item.file.lastUsed,
            modified: item.file.modified, size: item.file.size, added: item.file.added)
          if item.origin != .here { item.subtitle = c.place.whereText(moved) }
        }
        return seen.insert(item.file.path).inserted ? item : nil
      }
      return section
    }.filter { !$0.items.isEmpty }
  }

  // MARK: - Footer

  func decorate(_ hints: [PanelHint], _ item: PanelItem?) -> [PanelHint] {
    guard move == nil, let item, !item.file.isFolder else { return hints }
    var out = hints
    if coordinator.verdict(for: item.file.path)?.tier == .confident {
      let at = (out.firstIndex { $0.action == .activate }).map { $0 + 1 } ?? 0
      out.insert(PanelHint(keys: "⇥", label: "File", action: .filing(.file)), at: at)
    }
    // ⌥M Move before Show in Finder, which files leave to the move list's room.
    out.removeAll { $0.action == .reveal }
    out.append(PanelHint(keys: "⌥M", label: "Move", action: .filing(.move)))
    return out
  }

  /// The footer while choosing a folder.
  var moveFooter: (status: String, hints: [PanelHint])? {
    guard let move else { return nil }
    let hints = [
      PanelHint(keys: "↩", label: "Move", action: .filing(.confirm)),
      PanelHint(keys: "esc", label: "Cancel", action: .filing(.cancel)),
    ]
    return ("Choose a folder for " + move.file.name, hints)
  }

  func perform(_ hint: FilingHint) {
    switch hint {
    case .file:
      if let item = controller?.selectedItem { tab(item.file) }
    case .move: openMoveList()
    case .confirm: confirmMove()
    case .cancel: cancelMove()
    }
  }

  func emptyText(rowsEmpty: Bool) -> String? {
    guard let move, let c = controller else { return nil }
    guard rowsEmpty else { return "" }
    let text = c.trimmedQuery
    if text.isEmpty { return move.loading ? "" : "No folders to move to" }
    return "No folder matches “\(text)”"
  }

  // MARK: - Keys

  /// Nil leaves the key to the panel; true handled it; false lets the search field have it.
  func handleKey(_ event: NSEvent) -> Bool? {
    guard let c = controller else { return nil }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let command = flags.contains(.command)
    let option = flags.contains(.option)
    let control = flags.contains(.control)
    let shift = flags.contains(.shift)
    if move != nil {
      switch event.keyCode {
      case 53:  // esc
        if !c.closeQuickLook() { cancelMove() }
        return true
      case 48: return true  // ⇥
      case 36, 76: return command ? true : nil  // ↩ moves; ⌘↩ does nothing here
      case 126: return command ? true : nil  // ↑; no going up
      case 125: return nil  // ↓, and ⌘↓ moves
      case 123, 124: return command ? true : false  // ← → move the caret in the filter
      case 51: return false  // ⌫ edits the filter
      case 49: return shift ? nil : false  // ⇧Space Quick Look; Space types
      case 46 where option: return true  // ⌥M again
      case 6 where command: return true  // no ⌘Z while choosing
      default: return command || control ? nil : false
      }
    }
    switch event.keyCode {
    case 48 where !command && !option && !control && !shift:  // ⇥
      guard let item = c.selectedItem, !item.file.isFolder else { return nil }
      tab(item.file)
      return true
    case 46 where option && !command && !control:  // ⌥M
      openMoveList()
      return true
    case 6 where command && !option && !control && !shift:  // ⌘Z
      guard canUndo else { return nil }
      undo()
      return true
    default:
      return nil
    }
  }

  /// ⇥ on a file: confident files go now, otherwise the move list opens.
  func tab(_ file: PanelFile) {
    guard !busy, move == nil else { return }
    switch FilingTabAction.of(coordinator.verdict(for: file.path)) {
    case .file(let folder): self.file(file, to: folder)
    case .choose(let preselect): beginMove(file, preselect: preselect)
    }
  }

  func openMoveList() {
    guard let c = controller, move == nil else { return }
    guard let item = c.selectedItem, !item.file.isFolder else {
      say("Select a file to move")
      return
    }
    beginMove(item.file, preselect: nil)
  }

  private func pressed(_ button: FilingBar.Button) {
    guard let c = controller, let item = c.selectedItem, !item.file.isFolder else { return }
    let verdict = coordinator.verdict(for: item.file.path)
    switch button {
    case .file:
      if let top = verdict?.top { file(item.file, to: top.folder) }
    case .other: beginMove(item.file, preselect: nil)
    case .choose: beginMove(item.file, preselect: verdict?.top?.folder)
    }
  }

  // MARK: - The move list

  func beginMove(_ file: PanelFile, preselect: String?) {
    guard let c = controller, move == nil, !busy else { return }
    c.closeQuickLook()
    let verdict = coordinator.verdict(for: file.path)
    var jev: [FilingRanked] = []
    if let verdict, verdict.tier != .unsure {
      jev = verdict.ranked.enumerated().filter { $0.offset == 0 || $0.element.probability >= 0.03 }
        .prefix(5).map(\.element).filter { $0.folder != file.parent }
    }
    let local = coordinator.local(for: file.path)
    move = MoveMode(
      file: file, query: c.query, selected: c.selectedPath, verdict: verdict, jev: jev, local: local,
      project: nil, universe: [home, home + "/Desktop", home + "/Documents"],
      preselect: jev.isEmpty ? nil : preselect, loading: true)
    c.cancelSearches()
    c.setQuery("")
    c.userMoved = false
    c.chips.pill = "Move " + file.name + " to"
    c.field.placeholder = "Folder"
    c.layoutViews()
    show(select: move?.preselect)
    loadFolders(for: file, local: local)
  }

  private func show(select path: String?) {
    guard let c = controller else { return }
    c.rebuild(path.map { .path($0) } ?? .first)
    c.updateFooter()
  }

  /// Every folder the list can offer, read off the main thread.
  private func loadFolders(for file: PanelFile, local: FilingGathered?) {
    let home = self.home
    let defaults = coordinator.defaults
    let recent =
      FolderReferences.unique(
        (defaults.stringArray(forKey: "recentDestinations") ?? [])
          + (defaults.stringArray(forKey: "recentFolders") ?? []), limit: 24)
    let finish: (FilingGathered?) -> Void = { [weak self] gathered in
      self?.listing.async {
        let ownProject = FilingGather.project(of: file.parent, home: home)
        let project = ownProject ?? gathered?.project
        var folders: [String] = gathered?.candidates.map(\.folder) ?? []
        if let project {
          folders.append(project)
          for child in FilingGather.subfolders(project) {
            folders.append(child)
            folders += FilingGather.subfolders(child, limit: 12)
          }
        }
        folders += [home, home + "/Desktop", home + "/Documents"]
        for top in FilingGather.subfolders(home, limit: 60)
        where !["Library", "Applications"].contains((top as NSString).lastPathComponent) {
          folders.append(top)
          folders += FilingGather.subfolders(top, limit: 40)
        }
        folders += recent.filter { FilingGather.isFolder($0) }
        let universe = FolderReferences.unique(folders, limit: 600)
        DispatchQueue.main.async {
          guard let self, var move = self.move, move.file == file else { return }
          move.local = gathered ?? move.local
          move.project = project
          move.universe = universe
          move.loading = false
          self.move = move
          if let c = self.controller {
            // Until you move, the selection stays on Jev's folder or the first one.
            let typed = !c.trimmedQuery.isEmpty
            c.rebuild(c.userMoved ? .keep : typed ? .first : (move.preselect.map { .path($0) } ?? .first))
            c.updateFooter()
          }
          self.settled?()
        }
      }
    }
    if let local {
      finish(local)
    } else {
      coordinator.gather(path: file.path) { finish($0) }
    }
  }

  /// The folders a file can go to, in order: Jev's, then the rest.
  func moveSections(_ text: String) -> [PanelSection]? {
    guard let move, let c = controller else { return nil }
    let query = text.trimmingCharacters(in: .whitespaces)
    let exclude = Set([move.file.parent, move.file.path])
    func item(_ folder: String, _ p: Double?) -> PanelItem? {
      var range: NSRange?
      if !query.isEmpty {
        guard let match = PanelMatch.find(query, in: name(folder)) else { return nil }
        range = match.range
      }
      let file = PanelFile(path: folder, isFolder: true)
      var item = PanelItem(
        file: file, origin: .search, subtitle: folder == home ? "Your home folder" : c.place.whereText(folder),
        side: "", highlight: range)
      item.probability = p
      return item
    }
    let jev = move.jev.filter { !exclude.contains($0.folder) }.compactMap { item($0.folder, $0.probability) }
    var shown = Set(move.jev.map(\.folder)).union(exclude)
    let others = orderedOthers(move).filter { shown.insert($0).inserted }.compactMap { item($0, nil) }
    var sections: [PanelSection] = []
    if !jev.isEmpty {
      sections.append(
        PanelSection(title: "Suggested by Jev", aside: move.verdict?.tier.name ?? "", items: jev))
    }
    if !others.isEmpty {
      let title = !jev.isEmpty ? "Other Folders" : query.isEmpty ? "Your Usual Folders" : "Folders"
      var aside = ""
      if jev.isEmpty, query.isEmpty, coordinator.arrival(move.file.path) != nil {
        aside = coordinator.jevOn ? (move.verdict == nil ? "" : "Jev unsure") : "Jev off"
      }
      sections.append(PanelSection(title: title, aside: aside, items: others))
    }
    return sections
  }

  /// Without Jev, strong local matches first; then the project, Home, Desktop
  /// and Documents; then other local candidates; then everything else by path.
  func orderedOthers(_ move: MoveMode) -> [String] {
    let local = move.local?.candidates ?? []
    let rank = Dictionary(local.enumerated().map { ($0.element.folder, $0.offset) }, uniquingKeysWith: { a, _ in a })
    let strong =
      move.jev.isEmpty
      ? local.filter {
        !$0.evidence.sameHost.isEmpty || !$0.evidence.filedBefore.isEmpty || !$0.evidence.similarNames.isEmpty
      }.prefix(3).map(\.folder) : []
    let fixed = [home, home + "/Desktop", home + "/Documents"]
    func group(_ folder: String) -> Int {
      if let project = move.project, folder == project || folder.hasPrefix(project + "/") { return 0 }
      if fixed.contains(folder) { return 1 }
      if rank[folder] != nil { return 2 }
      return 3
    }
    let rest = (move.universe + local.map(\.folder)).filter { !strong.contains($0) }
    let sorted = FolderReferences.unique(rest, limit: 1000).sorted { a, b in
      let ga = group(a)
      let gb = group(b)
      if ga != gb { return ga < gb }
      if ga == 1 { return fixed.firstIndex(of: a)! < fixed.firstIndex(of: b)! }
      // The project reads top-down, as in the Finder.
      if ga == 0 { return a.localizedStandardCompare(b) == .orderedAscending }
      let ra = rank[a] ?? .max
      let rb = rank[b] ?? .max
      if ra != rb { return ra < rb }
      return a.localizedStandardCompare(b) == .orderedAscending
    }
    return strong + sorted
  }

  func filterChanged() {
    guard let c = controller, let move else { return }
    let text = c.trimmedQuery
    c.rebuild(text.isEmpty ? (move.preselect.map { .path($0) } ?? .first) : .first)
    c.updateFooter()
  }

  /// ↩ or a double click: move to the selected folder.
  func confirmMove() {
    guard let c = controller, let move, let item = c.selectedItem, item.file.isFolder else {
      NSSound.beep()
      return
    }
    file(move.file, to: item.file.path)
  }

  /// Esc: back to where you were.
  func cancelMove() { endMove() }

  private func endMove() {
    guard let c = controller, let move else { return }
    self.move = nil
    c.chips.pill = nil
    c.field.placeholder = c.folder.map { "Search in " + c.place.name($0) } ?? "Search"
    c.setQuery(move.query)
    c.layoutViews()
    c.rebuild(.path(move.selected))
    if !c.trimmedQuery.isEmpty { c.scheduleSearch(immediate: true) }
    c.updateFooter()
  }

  func panelHidden() {
    if move != nil { endMove() }
    toast.dismiss()
  }

  // MARK: - Moving

  /// Moves one file through the core, as the window's Move does: the core
  /// checks it is still the file you chose, never overwrites, and returns a
  /// receipt for undo.
  func file(_ file: PanelFile, to folder: String, collision: String = "error") {
    guard !busy else { return }
    busy = true
    let source = file.path
    let selection = OperationSelection(paths: [source])
    let command: [String: Any] = [
      "op": "move", "sources": [source], "destination": folder, "collision": collision,
    ]
    let host = coordinator.arrival(source)?.host
    let engine = self.engine
    moves.async { [weak self] in
      let reply = Result { try engine.call(selection.protecting(command, sources: [source])) }
      DispatchQueue.main.async { self?.moved(file, to: folder, host: host, reply) }
    }
  }

  private func moved(_ file: PanelFile, to folder: String, host: String?, _ reply: Result<[String: Any], Error>) {
    busy = false
    if move != nil { endMove() }
    defer { settled?() }
    let folderName = name(folder)
    switch reply {
    case .failure(let error):
      say("Couldn’t move \(file.name): \(error.localizedDescription)")
    case .success(let data):
      let result = (data["results"] as? [[String: Any]])?.first ?? [:]
      switch result["status"] as? String {
      case "done":
        let destination = result["destination"] as? String ?? folder + "/" + file.name
        let movedName = (destination as NSString).lastPathComponent
        if let receipt = result["receipt"] as? String {
          undos.append(
            Undo(
              receipts: [receipt], name: movedName, from: file.parent, to: folder, source: file.path,
              destination: destination))
          if undos.count > 20 { undos.removeFirst() }
        }
        relocated[file.path] = destination
        coordinator.memory.remember(name: movedName, host: host, folder: folder)
        let defaults = coordinator.defaults
        let last = defaults.stringArray(forKey: "recentDestinations") ?? []
        defaults.set(FolderReferences.unique([folder] + last, limit: 12), forKey: "recentDestinations")
        coordinator.log.add("You moved \(file.name) to \(folderName)", sent: FilingLog.staysHere)
        coordinator.forget(file.path)
        coordinator.scan()
        refresh(around: [file.parent, folder])
        say("Moved \(movedName) to \(folderName)", action: "Undo") { [weak self] in self?.undo() }
      case "collision":
        say("\(folderName) already has “\(file.name)”", action: "Keep Both") { [weak self] in
          self?.file(file, to: folder, collision: "keepBoth")
        }
      default:
        say(result["error"] as? String ?? "Couldn’t move \(file.name).")
      }
    }
  }

  /// ⌘Z or the toast's Undo: the core puts the file back from its receipt.
  func undo() {
    guard !busy, let last = undos.last else { return }
    busy = true
    let engine = self.engine
    moves.async { [weak self] in
      let reply = Result { try engine.call(["op": "restore", "receipts": Array(last.receipts.reversed())]) }
      DispatchQueue.main.async { self?.undone(last, reply) }
    }
  }

  private func undone(_ last: Undo, _ reply: Result<[String: Any], Error>) {
    busy = false
    defer { settled?() }
    var results: [[String: Any]] = []
    var reason = "It may have moved again."
    switch reply {
    case .success(let body):
      results = body["results"] as? [[String: Any]] ?? []
      if let error = results.first?["error"] as? String { reason = error }
    case .failure(let error):
      reason = error.localizedDescription
    }
    guard results.contains(where: { $0["status"] as? String == "done" }) else {
      say("Couldn’t put \(last.name) back. \(reason)")
      return
    }
    if undos.last == last { undos.removeLast() }
    relocated[last.source] = nil
    coordinator.log.add("You put \(last.name) back in \(name(last.from))", sent: FilingLog.staysHere)
    coordinator.scan()
    refresh(around: [last.from, last.to])
    say("Moved \(last.name) back to \(name(last.from))")
  }

  private func refresh(around folders: [String]) {
    guard let c = controller else { return }
    for folder in folders {
      c.counts[folder] = nil
      if c.listings[folder] != nil, folder != c.folder { c.listings[folder] = nil }
    }
    if let folder = c.folder {
      c.refreshListing(folder)
    } else if c.trimmedQuery.isEmpty {
      c.refreshHome()
    } else {
      c.rebuild(.keep)
    }
    updateBar()
    c.updateFooter()
  }

  // MARK: - Bar and toast

  /// The Jev bar above a new download's preview, or none.
  func updateBar() {
    guard let c = controller, let preview = c.preview.view as? ContentPreview else { return }
    if move != nil, let item = c.selectedItem, let p = item.probability, var peek = c.peek.content {
      // The move list's folder peek says how sure Jev is.
      let label = "Jev " + FilingDraw.percent(p)
      if !peek.subtitle.hasPrefix(label) {
        peek.subtitle = label + " · " + peek.subtitle
        c.peek.content = peek
      }
    }
    guard move == nil, let item = c.selectedItem, !item.file.isFolder,
      let verdict = coordinator.verdict(for: item.file.path), verdict.tier != .unsure, let top = verdict.top
    else {
      preview.accessory = nil
      return
    }
    bar.content = FilingBar.Content(
      folder: top.folder, name: name(top.folder), parent: FilingText.parentName(top.folder, home: home),
      probability: top.probability, why: verdict.why, tier: verdict.tier)
    let width = max(200, preview.bounds.width)
    bar.frame = NSRect(x: 0, y: 0, width: width, height: bar.height(for: width))
    bar.needsDisplay = true
    preview.accessory = bar
  }

  func say(_ text: String, action: String? = nil, _ handler: (() -> Void)? = nil) {
    guard let c = controller else { return }
    toast.show(text, action: action, in: c.root, bottom: PanelRootView.footerHeight + 12, handler)
  }

  // MARK: - The coordinator

  func verdictsChanged(_ paths: Set<String>) {
    guard let c = controller else { return }
    let affected = IndexSet(c.rows.indices.filter { c.rows[$0].item.map { paths.contains($0.file.path) } ?? false })
    if !affected.isEmpty { c.table.reloadData(forRowIndexes: affected, columnIndexes: IndexSet(integer: 0)) }
    if let path = c.selectedPath, paths.contains(path) {
      updateBar()
      c.updateFooter()
    }
  }

  func arrivalsChanged() {
    guard let c = controller, c.panel.isVisible, move == nil, c.folder == nil, c.trimmedQuery.isEmpty else {
      return
    }
    c.refreshHome()
  }
}

extension PanelController {
  /// Connects Jev filing to the panel.
  func attachFiling(_ coordinator: FilingCoordinator) {
    let filing = FilingPanel(controller: self, coordinator: coordinator, engine: engine)
    self.filing = filing
    coordinator.changed = { [weak filing] in filing?.verdictsChanged($0) }
    coordinator.arrivalsChanged = { [weak filing] in filing?.arrivalsChanged() }
    rebuild(.keep)
  }
}
