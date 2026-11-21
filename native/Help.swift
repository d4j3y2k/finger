import AppKit

extension Browser {
  func openDemo() {
    guard let template = Bundle.main.resourceURL?.appendingPathComponent("Demo/Fold Studies"),
      FileManager.default.fileExists(atPath: template.path)
    else {
      alertError(
        "Practice project unavailable", "Rebuild Finger to include the Fold Studies files.")
      return
    }
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Finger practice " + String(UUID().uuidString.prefix(8)), isDirectory: true)
    let demo = parent.appendingPathComponent("Fold Studies", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: template, to: demo)
      showWorktable(project: demo.path)
    } catch { alertError("Couldn’t open practice project", error.localizedDescription) }
  }

  func showShortcuts() {
    let alert = NSAlert()
    alert.messageText = "Keyboard shortcuts"
    let shortcuts = [
      ("↑  /  ↓", "Select a row"), ("⇧↑  /  ⇧↓", "Extend selection"),
      ("→  /  ←", "Enter / leave a folder"),
      ("⌘[  /  ⌘]", "Back / forward"), ("Space", "Quick Look"), ("Return", "Open selected item"),
      ("Type  /  ⌘F", "Filter filenames"), ("Escape", "Clear filter and restore selection"),
      ("⇧⌘F", "Find in subfolders"), ("⇧⌘G", "Go to a path"), ("⇧⌘N", "New folder"),
      ("F2  /  ⌘Return", "Rename"),
      ("⇧⌘M  /  ⇧⌘C", "Move / copy to a folder"), ("⌘X  /  ⌘C  /  ⌘V", "Cut / copy / paste files"),
      ("⌘Z  /  ⇧⌘Z", "Undo / redo a move or rename"), ("⇧⌘.", "Show or hide hidden files"),
    ]
    let view = Flipped()
    view.frame = NSRect(x: 0, y: 0, width: 378, height: CGFloat(shortcuts.count) * 22)
    for (i, pair) in shortcuts.enumerated() {
      let key = label(pair.0, mono(11, .medium), Ink.lime)
      let text = label(pair.1, font(12), Ink.text)
      view.addSubview(key)
      view.addSubview(text)
      position(key, 0, CGFloat(i) * 22, 135, 20)
      position(text, 142, CGFloat(i) * 22, 235, 20)
    }
    alert.accessoryView = view
    alert.addButton(withTitle: "Done")
    alert.beginSheetModal(for: window)
  }

  func showAgentConnection() {
    let alert = NSAlert()
    alert.messageText = "Agent connection"
    alert.informativeText =
      agentError
      ?? "Codex and Claude can read the selected filenames and paths, then open a named collection in this window."
    let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/finger-mcp").path
    let shellPath = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let commands = [
      ("Codex", "codex mcp add finger -- " + shellPath),
      ("Claude Code", "claude mcp add --scope user --transport stdio finger -- " + shellPath),
    ]
    let view = Flipped()
    view.frame = NSRect(x: 0, y: 0, width: 410, height: 140)
    let heading = label(
      agentError == nil ? "LOCAL MCP SERVER" : "CONNECTION UNAVAILABLE", mono(10, .semibold),
      agentError == nil ? Ink.lime : Ink.issue)
    view.addSubview(heading)
    position(heading, 0, 1, 405, 19)
    for (i, item) in commands.enumerated() {
      let y = CGFloat(i) * 48 + 27
      let name = label(item.0, font(13, .semibold), Ink.text)
      let cmd = label(item.1, mono(10), Ink.quiet)
      cmd.isSelectable = true
      cmd.toolTip = item.1
      let copy = ActionButton(
        "Copy command", icon: "doc.on.doc", help: "Copy " + item.0 + " registration command"
      ) { [weak cmd] in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.1, forType: .string)
        cmd?.stringValue = "Copied to clipboard"
      }
      view.addSubview(name)
      view.addSubview(cmd)
      view.addSubview(copy)
      position(name, 0, y, 200, 19)
      position(cmd, 0, y + 20, 280, 16)
      position(copy, 283, y + 3, 127, 27)
    }
    alert.accessoryView = view
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Connection Guide")
    alert.beginSheetModal(for: window) { result in
      if result == .alertSecondButtonReturn,
        let guide = Bundle.main.url(forResource: "AGENTS-CONNECTION", withExtension: "md")
      {
        NSWorkspace.shared.open(guide)
      }
    }
  }
}
