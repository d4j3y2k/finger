import AppKit

extension Browser {
  func newFolder() {
    guard let path = folderPath, !busy else { return }
    prompt("New folder", value: "Untitled Folder", action: "Create") { [weak self] value in
      self?.change(
        ["op": "newFolder", "path": path, "name": value], success: "Created folder", in: path)
    }
  }
  func rename() {
    guard !busy, !loading, window.attachedSheet == nil, selected.count == 1,
      let entry = selected.first
    else { return }
    let key = location
    let captured = OperationSelection(paths: [entry.path])
    prompt("Rename item", value: entry.name, action: "Rename") { [weak self] value in
      self?.change(
        ["op": "rename", "path": entry.path, "name": value], success: "Renamed item", in: key,
        captured: captured)
    }
  }
  func change(
    _ cmd: [String: Any], success: String, in key: String, captured: OperationSelection? = nil
  ) {
    guard !busy else { return }
    busy = true
    updateSelection(refreshPreview: false)
    mutations.async { [weak self] in
      guard let self else { return }
      let reply = Result { () throws -> [String: Any] in
        if let captured, let path = cmd["path"] as? String {
          return try self.engine.call(captured.protecting(cmd, sources: [path]))
        }
        return try self.engine.call(cmd)
      }
      DispatchQueue.main.async {
        self.busy = false
        self.updateSelection(refreshPreview: false)
        self.scheduleFolderRefresh()
        switch reply {
        case .success(let data):
          if let receipt = data["receipt"] as? String {
            self.rememberAction("Rename", receipts: [receipt])
          } else {
            self.redoActions.removeAll()
          }
          if let path = data["path"] as? String {
            if cmd["op"] as? String == "rename", let old = cmd["path"] as? String {
              self.remap([old: path])
            }
            if self.location == key {
              var state = self.snapshot()
              state["selected"] = [path]
              state["reveal"] = true
              self.ui.query.stringValue = ""
              self.load(state, clear: false)
            }
          }
          self.message(success, announce: true)
        case .failure(let error):
          self.alertError(
            success == "Created folder" ? "Couldn’t create folder" : "Couldn’t rename item",
            error.localizedDescription)
        }
      }
    }
  }
  func alertError(_ title: String, _ detail: String) {
    message(detail, error: true, seconds: 12)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }
  func remap(_ changes: [String: String]) {
    guard !changes.isEmpty else { return }
    endpoint.remap(changes)
    let ordered = changes.sorted { $0.key.count > $1.key.count }
    func map(_ path: String) -> String {
      if let hit = changes[path] { return hit }
      for (from, to) in ordered where path.hasPrefix(from + "/") {
        return to + String(path.dropFirst(from.count))
      }
      return path
    }
    if let reply = try? engine.call(
      ["op": "remap", "changes": changes, "state": snapshot()], service: 1)
    {
      prior = reply["previous"] as? String
      if let key = reply["key"] as? String, key != location {
        location = key
        if key.hasPrefix("/") { UserDefaults.standard.set(key, forKey: "lastFolder") }
        load(reply["state"] as? [String: Any] ?? [:], clear: true)
      }
      beforeFilter = (reply["state"] as? [String: Any])?["beforeFilter"] as? [String: Any]
    }
    var lastDest = UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? []
    lastDest = FolderReferences.unique(lastDest.map(map), limit: 12)
    UserDefaults.standard.set(lastDest, forKey: "recentDestinations")
    for i in collections.indices { collections[i].paths = collections[i].paths.map(map) }
    persistCollections()
    favorites = favorites.map(map)
    recent = FolderReferences.unique(recent.map(map), limit: 15)
    project = project.map(map)
    UserDefaults.standard.set(favorites, forKey: "favorites")
    UserDefaults.standard.set(recent, forKey: "recentFolders")
    updateChrome()
  }
  func chooseTransfer(move: Bool) {
    let frozen = fileSelection
    guard !busy, !loading, !frozen.indexes.isEmpty, window.attachedSheet == nil else { return }
    let key = location
    let listedFolder = folderPath
    let useListing = !scanning && fileOrder == .nameAsc
    let folders = recent
    let pins = favorites
    let root = project
    let hidden = showHidden
    let last = FolderReferences.unique(
      UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? [], limit: 12)
    listingQueue.async { [weak self] in
      guard let self else { return }
      let sources = frozen.map(\.path)
      let sample = frozen.map(limit: 32, \.url)
      guard let first = sample.first else { return }
      let from = first.deletingLastPathComponent()
      let captured = OperationSelection(paths: sources, directory: listedFolder)
      var candidates = (last + pins).map { URL(fileURLWithPath: $0, isDirectory: true) }
      var inspected = Set<String>()
      for dir in [
        from, from.deletingLastPathComponent(),
        root.map { URL(fileURLWithPath: $0, isDirectory: true) },
      ]
      .compactMap({ $0 }) where inspected.insert(FolderReferences.key(dir.path)).inserted {
        if useListing && FolderReferences.key(dir.path) == listedFolder.map(FolderReferences.key) {
          // A name-ordered listing already has the exact first 40 inspected below.
          candidates.append(contentsOf: frozen.entries.prefix(40).filter(\.isDirectory).map(\.url))
        } else if let data = try? engine.data([
          "op": "list", "path": dir.path, "limit": 40, "showHidden": hidden,
        ]), let list = try? JSONDecoder().decode(ListResponse.self, from: data) {
          candidates.append(contentsOf: (list.entries ?? []).filter(\.isDirectory).map(\.url))
        }
        candidates.append(dir)
      }
      let fromPath = FolderReferences.key(from.path)
      // A directory's raw entries all have this parent. Collections can span projects.
      let collected =
        listedFolder == nil
        ? sources.map {
          FolderReferences.key($0)
        } : []
      let shareParent =
        listedFolder != nil
        || collected.allSatisfy {
          ($0 as NSString).deletingLastPathComponent == fromPath
        }
      func containsSelection(_ root: String) -> Bool {
        if shareParent && under(fromPath, root) { return true }
        if listedFolder != nil {
          return sources.count == 1 && FolderReferences.key(first.path) == root
        }
        return collected.allSatisfy { under($0, root) }
      }
      let rootURL = root.map { URL(fileURLWithPath: $0, isDirectory: true) }
      let scope =
        rootURL.flatMap { containsSelection(FolderReferences.key($0.path)) ? $0 : nil }
        ?? from.deletingLastPathComponent()
      let scopePath = FolderReferences.key(scope.path)
      let scopeContainsAll = containsSelection(scopePath)
      candidates += folders.filter { under(FolderReferences.key($0), scopePath) }.map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      let members = Set(listedFolder == nil ? collected : frozen.map(\.name))
      var checked = Set<String>()
      let viable = candidates.filter { url in
        let path = FolderReferences.key(url.path)
        guard checked.insert(path).inserted, !(move && shareParent && fromPath == path) else {
          return false
        }
        // Walk the few ancestors of each destination, even for a mixed selection of thousands.
        var ancestor = path
        while !ancestor.isEmpty {
          let parent = (ancestor as NSString).deletingLastPathComponent
          if listedFolder == nil {
            if members.contains(ancestor) { return false }
          } else if parent == fromPath && members.contains((ancestor as NSString).lastPathComponent)
          {
            return false
          }
          if ancestor == "/" { break }
          ancestor = parent
        }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
          && isDir.boolValue
      }
      let ranked = DestinationRanker.ranked(
        sources: sample, candidates: viable,
        recent: last.map { URL(fileURLWithPath: $0, isDirectory: true) }, project: scope,
        selectionScope: .init(insideProject: scopeContainsAll, shareParent: shareParent))
      DispatchQueue.main.async {
        self.whenSelectionMatches(frozen, sources: sources, location: key) {
          let picker = MovePicker(
            parent: self.window, sources: sample, sourceCount: sources.count,
            candidates: Array(ranked.prefix(8)), move: move,
            project: scope
          ) { [weak self] dest in
            guard let self else { return }
            self.picker = nil
            if let dest { self.transfer(sources, to: dest.path, move: move, captured: captured) }
          }
          self.picker = picker
          picker.present()
        }
      }
    }
  }
  private func whenSelectionMatches(
    _ frozen: FileSelection, sources: [String], location key: String, show: @escaping () -> Void
  ) {
    guard location == key, !busy, window.attachedSheet == nil else { return }
    let current = fileSelection
    guard current.indexes.count == sources.count else { return }
    if frozen.sameRows(as: current) {
      show()
      return
    }
    // After a passive reload the selected paths may still match. Check them on a
    // worker, then verify that its snapshot is still current before showing the sheet.
    listingQueue.async { [weak self] in
      guard current.map(\.path) == sources else { return }
      DispatchQueue.main.async {
        guard let self, self.location == key, !self.busy, self.window.attachedSheet == nil,
          current.sameRows(as: self.fileSelection)
        else { return }
        show()
      }
    }
  }
  func transfer(
    _ paths: [String], to destination: String, move: Bool, collision: String = "error",
    completed: Int = 0,
    pasteChange: Int? = nil, captured: OperationSelection? = nil, historyGroup: UUID = UUID()
  ) {
    guard !busy, !paths.isEmpty else { return }
    busy = true
    updateSelection(refreshPreview: false)
    let selection = captured ?? OperationSelection(paths: paths)
    let command: [String: Any] = [
      "op": move ? "move" : "copy", "sources": paths, "destination": destination,
      "collision": collision,
    ]
    let subject =
      paths.count == 1
      ? (paths[0] as NSString).lastPathComponent : "\(paths.count.formatted()) items"
    let destinationName = (destination as NSString).lastPathComponent
    message("\(move ? "Moving" : "Copying") \(subject) to \(destinationName)…", seconds: 3600)
    mutations.async { [weak self] in
      guard let self else { return }
      let reply = Result { try self.engine.call(selection.protecting(command, sources: paths)) }
      DispatchQueue.main.async {
        self.busy = false
        self.updateSelection(refreshPreview: false)
        self.scheduleFolderRefresh()
        switch reply {
        case .failure(let error):
          self.alertError("Transfer could not finish", error.localizedDescription)
        case .success(let data):
          let results = data["results"] as? [[String: Any]] ?? []
          let done = results.filter { $0["status"] as? String == "done" }
          if move {
            self.rememberAction(
              "Move", receipts: done.compactMap { $0["receipt"] as? String }, group: historyGroup)
          } else if !done.isEmpty {
            self.redoActions.removeAll()
          }
          let skipped = results.filter { $0["status"] as? String == "skipped" }
          let collisions = results.filter { $0["status"] as? String == "collision" }.compactMap {
            $0["source"] as? String
          }
          let errors = results.filter { $0["status"] as? String == "error" }
          var nextPasteChange = pasteChange
          if move, let generation = pasteChange, self.clipboard.changeCount == generation,
            !done.isEmpty
          {
            let consumed = Set(done.compactMap { $0["source"] as? String })
            let remaining = self.pasteSources().filter { !consumed.contains($0) }
            let paste = self.clipboard
            paste.clearContents()
            if !remaining.isEmpty {
              paste.writeObjects(remaining.map { URL(fileURLWithPath: $0) as NSURL })
            }
            self.cutPaths = remaining
            self.lastCutChange = remaining.isEmpty ? -1 : paste.changeCount
            self.clipboardCapture = remaining.isEmpty ? nil : (paste.changeCount, selection)
            nextPasteChange = remaining.isEmpty ? nil : paste.changeCount
          }
          if move {
            var changes = [String: String]()
            for item in done {
              if let s = item["source"] as? String, let d = item["destination"] as? String {
                changes[s] = d
              }
            }
            self.remap(changes)
            FilingMemory.shared.remember(moves: changes)
          }
          if !done.isEmpty {
            let last = UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? []
            UserDefaults.standard.set(
              FolderReferences.unique([destination] + last, limit: 12), forKey: "recentDestinations"
            )
          }
          let n = completed + done.count
          let summary =
            "\(move ? "Moved" : "Copied") \(n) \(n == 1 ? "item" : "items") to \(URL(fileURLWithPath:destination).lastPathComponent)"
          let notice: String
          if n == 0 && !skipped.isEmpty {
            notice = skipped.first?["error"] as? String ?? "The items are already in this folder."
          } else {
            notice = summary + (skipped.isEmpty ? "" : " · skipped " + String(skipped.count))
          }
          self.message(notice, announce: collisions.isEmpty && errors.isEmpty)
          if self.folderPath == destination || self.collection != nil
            || paths.contains(where: {
              URL(fileURLWithPath: $0).deletingLastPathComponent().path == self.folderPath
            })
          {
            self.load(self.snapshot(), clear: false)
          }
          let failures = errors.map { r in
            let file =
              (r["source"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Item"
            return file + " — " + (r["error"] as? String ?? "Could not finish.")
          }.joined(separator: "\n")
          if !collisions.isEmpty {
            let alert = NSAlert()
            alert.messageText =
              collisions.count == 1
              ? "An item with this name already exists" : "\(collisions.count) names already exist"
            let names = collisions.prefix(5).map { URL(fileURLWithPath: $0).lastPathComponent }
              .joined(separator: "\n")
            alert.informativeText =
              names + "\n\nKeep both to give the incoming items new names."
              + (n > 0 ? "\n\n" + summary + "." : "") + (failures.isEmpty ? "" : "\n\n" + failures)
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Skip")
            alert.beginSheetModal(for: self.window) { [weak self] response in
              if response == .alertFirstButtonReturn {
                self?.transfer(
                  collisions, to: destination, move: move, collision: "keepBoth", completed: n,
                  pasteChange: nextPasteChange, captured: selection, historyGroup: historyGroup)
              } else {
                self?.message(summary + " · skipped \(collisions.count)")
              }
            }
          } else if !failures.isEmpty {
            self.alertError(
              "Some items could not be transferred", failures + (n > 0 ? "\n\n" + summary : ""))
          }
        }
      }
    }
  }
  func copyFiles(cut: Bool) {
    let urls = selected.map(\.url)
    guard !urls.isEmpty else { return }
    let paste = clipboard
    paste.clearContents()
    guard paste.writeObjects(urls as [NSURL]) else {
      lastCutChange = -1
      cutPaths = []
      clipboardCapture = nil
      message("Couldn’t put these files on the clipboard.", error: true)
      return
    }
    lastCutChange = cut ? paste.changeCount : -1
    cutPaths = cut ? urls.map(\.path) : []
    clipboardCapture = (paste.changeCount, OperationSelection(paths: urls.map(\.path)))
    message("\(urls.count) \(urls.count == 1 ? "item" : "items") ready to \(cut ? "move":"copy")")
  }
  func pasteSources() -> [String] {
    (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []).map(\.path)
  }
  func pasteFiles(forceMove: Bool) {
    guard let dest = folderPath else { return }
    let paths = pasteSources()
    guard !paths.isEmpty else { return }
    let generation = clipboard.changeCount
    let isCut = generation == lastCutChange && paths == cutPaths
    let capture = clipboardCapture?.generation == generation ? clipboardCapture?.selection : nil
    transfer(
      paths, to: dest, move: forceMove || isCut,
      pasteChange: (forceMove || isCut) ? generation : nil, captured: capture)
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    return rows.indices.contains(row) ? entries[rows[row]].url as NSURL : nil
  }
  private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> (
    row: Int, path: String
  )? {
    guard !busy, !loading, window.attachedSheet == nil else { return nil }
    if operation == .on, rows.indices.contains(row), entries[rows[row]].isDirectory {
      return (row, entries[rows[row]].path)
    }
    return folderPath.map { (-1, $0) }
  }
  func tableView(
    _ tableView: NSTableView, draggingSession session: NSDraggingSession,
    willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
  ) {
    let paths = rowIndexes.compactMap { row in
      rows.indices.contains(row) ? entries[rows[row]].path : nil
    }
    ui.table.fileDrag.begin(sequence: session.draggingSequenceNumber, paths: paths)
  }
  func tableView(
    _ tableView: NSTableView, draggingSession session: NSDraggingSession,
    endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    ui.table.fileDrag.end(sequence: session.draggingSequenceNumber)
  }
  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
    proposedDropOperation op: NSTableView.DropOperation
  ) -> NSDragOperation {
    guard let dest = dropTarget(row: row, operation: op) else { return [] }
    let operation = FileDrop.operation(info)
    if !operation.isEmpty { tableView.setDropRow(dest.row, dropOperation: .on) }
    return operation
  }
  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    guard let dest = dropTarget(row: row, operation: dropOperation) else { return false }
    guard let payload = FileDrop.payload(info) else { return false }
    let operation = FileDrop.operation(info)
    guard !operation.isEmpty else { return false }
    transfer(payload.paths, to: dest.path, move: operation == .move, captured: payload.selection)
    return true
  }
}

private func under(_ path: String, _ directory: String) -> Bool {
  path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
}

extension FileSelection {
  fileprivate func sameRows(as current: FileSelection) -> Bool {
    // Immutable native arrays share their backing stores until a filter or listing replaces them.
    func sameBuffer<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
      lhs.withUnsafeBufferPointer { a in
        rhs.withUnsafeBufferPointer { b in
          a.baseAddress == b.baseAddress && a.count == b.count
        }
      }
    }
    return indexes == current.indexes && sameBuffer(entries, current.entries)
      && sameBuffer(rows, current.rows)
  }
}
