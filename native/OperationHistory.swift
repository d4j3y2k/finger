import AppKit

struct FileAction {
  let id: UUID
  let name: String
  var receipts: [String]
}

extension Browser {
  func rememberAction(_ name: String, receipts: [String], group: UUID = UUID()) {
    guard !receipts.isEmpty else { return }
    redoActions.removeAll()
    if undoActions.last?.id == group {
      undoActions[undoActions.count - 1].receipts.append(contentsOf: receipts)
    } else {
      undoActions.append(FileAction(id: group, name: name, receipts: receipts))
      if undoActions.count > 32 { undoActions.removeFirst() }
    }
  }

  func canRestore(_ redo: Bool) -> Bool {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
      return (redo ? editor.undoManager?.canRedo : editor.undoManager?.canUndo) ?? false
    }
    return !busy && window.attachedSheet == nil && !(redo ? redoActions : undoActions).isEmpty
  }

  func restoreTitle(_ redo: Bool) -> String {
    let verb = redo ? "Redo" : "Undo"
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
      return verb
    }
    guard let action = (redo ? redoActions : undoActions).last else { return verb }
    return verb + " " + action.name
  }

  func restoreAction(_ redo: Bool) {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
      if redo { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
      return
    }
    guard canRestore(redo), let group = redo ? redoActions.last : undoActions.last else { return }
    let receipts = Array(group.receipts.reversed())
    busy = true
    updateSelection(refreshPreview: false)
    mutations.async { [weak self] in
      guard let self else { return }
      let reply = Result { try self.engine.call(["op": "restore", "receipts": receipts]) }
      DispatchQueue.main.async {
        self.busy = false
        self.updateSelection(refreshPreview: false)
        self.scheduleFolderRefresh()
        switch reply {
        case .failure(let error):
          self.alertError(
            "Couldn’t " + (redo ? "redo " : "undo ") + group.name.lowercased(),
            error.localizedDescription)
        case .success(let body):
          self.completeRestore(
            group, redo: redo, receipts: receipts,
            results: body["results"] as? [[String: Any]] ?? [])
        }
      }
    }
  }

  private func completeRestore(
    _ group: FileAction, redo: Bool, receipts: [String], results: [[String: Any]]
  ) {
    var inverse: [String] = []
    var remaining: [String] = []
    var failures: [String] = []
    var moves: [String: String] = [:]
    for (index, token) in receipts.enumerated() {
      let result = results.indices.contains(index) ? results[index] : [:]
      if result["status"] as? String == "done", let source = result["source"] as? String,
        let target = result["destination"] as? String
      {
        moves[source] = target
        if let opposite = result["receipt"] as? String { inverse.append(opposite) }
      } else {
        remaining.append(token)
        failures.append(result["error"] as? String ?? "The item could not be restored.")
      }
    }
    if redo { redoActions.removeLast() } else { undoActions.removeLast() }
    if !inverse.isEmpty {
      let opposite = FileAction(id: group.id, name: group.name, receipts: inverse)
      if redo { undoActions.append(opposite) } else { redoActions.append(opposite) }
    }
    if !remaining.isEmpty {
      let unfinished = FileAction(
        id: group.id, name: group.name, receipts: Array(remaining.reversed()))
      if redo { redoActions.append(unfinished) } else { undoActions.append(unfinished) }
    }
    if !moves.isEmpty {
      remap(moves)
      var state = snapshot()
      let arrivals = moves.values.filter {
        URL(fileURLWithPath: $0).deletingLastPathComponent().path == folderPath
      }
      if !arrivals.isEmpty {
        state["selected"] = Array(arrivals)
        state["reveal"] = true
      }
      load(state, clear: false)
      message(
        (redo ? "Redid " : "Undid ") + group.name.lowercased() + " · \(moves.count) "
          + (moves.count == 1 ? "item" : "items"), announce: failures.isEmpty)
    }
    guard !failures.isEmpty else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      (redo ? "Redo" : "Undo") + " couldn’t restore "
      + (failures.count == 1 ? "one item" : "\(failures.count) items")
    let details = failures.prefix(5).joined(separator: "\n")
    alert.informativeText =
      details + (failures.count > 5 ? "\n… and \(failures.count-5) more." : "")
    alert.addButton(withTitle: "Keep for Retry")
    alert.addButton(withTitle: "Forget This Step")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertSecondButtonReturn else { return }
      if redo && self.redoActions.last?.id == group.id { self.redoActions.removeLast() }
      if !redo && self.undoActions.last?.id == group.id { self.undoActions.removeLast() }
    }
  }
}
