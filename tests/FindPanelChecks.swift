import AppKit
import Darwin

// scripts/check.sh builds this standalone AppKit host against the same
// directory engine and UI code as the application.
private final class TestCore {
  private let process = Process()
  private let input: FileHandle
  private let output: UnsafeMutablePointer<FILE>
  private let lock = NSLock()

  init(_ executable: URL) throws {
    let incoming = Pipe()
    let outgoing = Pipe()
    input = incoming.fileHandleForWriting
    output = fdopen(dup(outgoing.fileHandleForReading.fileDescriptor), "r")!
    process.executableURL = executable
    process.standardInput = incoming
    process.standardOutput = outgoing
    try process.run()
  }

  func forward(_ command: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    lock.lock()
    defer { lock.unlock() }
    var bytes = Data(bytes: command, count: strlen(command))
    bytes.append(10)
    input.write(bytes)
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    if getline(&line, &capacity, output) > 0 { return line }
    free(line)
    return nil
  }

  func finish() {
    try? input.close()
    process.waitUntilExit()
    fclose(output)
  }
}

private var core: TestCore!
private let gateLock = NSLock()
private var heldOp = ""
private var heldQuery: String?
private var active = Set<String>()
private let gateReached = DispatchSemaphore(value: 0)
private let gateRelease = DispatchSemaphore(value: 0)
private func arm(_ op: String, query: String? = nil) {
  gateLock.lock()
  heldOp = op
  heldQuery = query
  gateLock.unlock()
}
private func send(_ service: Int32, _ data: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
  guard service == 0, let data else { return nil }
  let reply = core.forward(data)
  if let message = try? JSONSerialization.jsonObject(with: Data(String(cString: data).utf8))
    as? [String: Any]
  {
    let op = message["op"] as? String
    gateLock.lock()
    if op == "startFind", let reply,
      let body = try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8))
        as? [String: Any], let id = body["session"] as? String
    {
      active.insert(id)
    }
    if op == "endFind", let id = message["session"] as? String { active.remove(id) }
    let hold = op == heldOp && (heldQuery == nil || heldQuery == message["query"] as? String)
    if hold { heldOp = "" }
    gateLock.unlock()
    if hold {
      gateReached.signal()
      _ = gateRelease.wait(timeout: .now() + 4)
    }
  }
  return reply
}
private func wait(_ label: String, _ condition: () -> Bool) {
  let end = Date().addingTimeInterval(5)
  while !condition() {
    precondition(Date() < end, label)
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.006))
  }
}
private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
  (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
}
private func key(_ code: UInt16, _ chars: String, _ panel: NSWindow) {
  let ev = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: panel.windowNumber, context: nil, characters: chars,
    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
  panel.sendEvent(ev)
}
@main
private enum FindPanelChecks {
  static func main() throws {
    precondition(CommandLine.arguments.count == 2, "Pass the path to the finger-core executable.")
    core = try TestCore(URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { core.finish() }
    runChecks()
  }
}

private func runChecks() {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  let parent = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 700, height: 405), styleMask: [.titled],
    backing: .buffered,
    defer: false)
  parent.appearance = NSAppearance(named: .darkAqua)
  let engine = Engine(send, { free($0) })
  let files = FileManager.default
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "Finger Find " + UUID().uuidString, isDirectory: true)
  defer { try? files.removeItem(at: root) }
  for name in [
    "exports/plan.svg", "exports-old/old/plan.svg", "exports-old/alpha.png",
    "delivery/empty/.hidden",
  ] {
    let url = root.appendingPathComponent(name)
    try! files.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(name.utf8).write(to: url)
  }
  for i in 0..<125 {
    files.createFile(atPath: root.appendingPathComponent("sample-\(i).txt").path, contents: Data())
  }
  var choice: URL?
  var completions = 0
  func picker(_ at: URL) -> FindPanel {
    FindPanel(parent: parent, engine: engine, root: at, showHidden: false) {
      choice = $0
      completions += 1
    }
  }
  let find = picker(root)
  find.present()
  let surface = find.panel.contentView!
  let search = descendants(surface, NSSearchField.self)[0]
  let table = descendants(surface, NSTableView.self)[0]
  let status = descendants(surface, NSTextField.self).first {
    $0.accessibilityIdentifier() == "find-status"
  }!
  func query(_ s: String) {
    search.stringValue = s
    find.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: search))
  }
  wait("initial index") { status.stringValue.contains("items indexed") }
  arm("find", query: "alpha")
  query("alpha")
  wait("old search entered") { gateReached.wait(timeout: .now()) == .success }
  query("plan")
  gateRelease.signal()
  wait("two new matches") { table.numberOfRows == 2 && status.stringValue.contains("2 matches") }
  surface.layoutSubtreeIfNeeded()
  let parents = (0..<2).map { row -> String in
    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)!
    return descendants(cell, NSTextField.self).map(\.stringValue).joined(separator: " ")
  }
  precondition(
    parents.contains("plan.svg exports-old/old") && parents.contains("plan.svg exports"),
    parents.description)
  print("duplicate filenames:", parents)
  query("sample")
  wait("result truncation") {
    table.numberOfRows == 100 && status.stringValue.contains("100 of 125 matches")
  }
  query("pla")
  wait("restored") { table.numberOfRows == 2 }
  find.panel.makeFirstResponder(table)
  key(45, "n", find.panel)
  let reveal = descendants(surface, NSButton.self).first {
    $0.accessibilityIdentifier() == "find-reveal"
  }!
  wait("typing from results refines search") { search.stringValue == "plan" && reveal.isEnabled }
  find.panel.setContentSize(NSSize(width: 360, height: 225))
  surface.layoutSubtreeIfNeeded()
  precondition(surface.bounds.contains(search.frame) && surface.bounds.contains(status.frame))
  find.panel.setContentSize(NSSize(width: 580, height: 340))
  surface.layoutSubtreeIfNeeded()
  let editor = search.currentEditor() as? NSTextView ?? NSTextView()
  _ = find.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
  precondition(table.selectedRow == 1)
  find.panel.makeFirstResponder(table)
  key(36, "\r", find.panel)
  wait("Return callback") { completions == 1 }
  precondition(choice?.lastPathComponent == "plan.svg" && files.fileExists(atPath: choice!.path))
  print("Return revealed:", choice!.path.replacingOccurrences(of: root.path + "/", with: ""))
  arm("startFind")
  let old = picker(root)
  old.present()
  wait("delayed start") { gateReached.wait(timeout: .now()) == .success }
  key(53, "\u{1b}", old.panel)
  let fresh = picker(root)
  fresh.present()
  gateRelease.signal()
  let freshStatus = descendants(fresh.panel.contentView!, NSTextField.self).first {
    $0.accessibilityIdentifier() == "find-status"
  }!
  wait("reopened") { freshStatus.stringValue.contains("items indexed") }
  fresh.cancel()
  let bad = picker(root.appendingPathComponent("absent"))
  bad.present()
  let badStatus = descendants(bad.panel.contentView!, NSTextField.self).first {
    $0.accessibilityIdentifier() == "find-status"
  }!
  wait("root error visible") {
    badStatus.stringValue != "Starting index…" && badStatus.textColor == Ink.issue
  }
  print("root error:", badStatus.stringValue)
  bad.cancel()
  wait("all index sessions released") {
    gateLock.lock()
    defer { gateLock.unlock() }
    return active.isEmpty
  }
  print("checks passed; callbacks", completions)
}
