import AppKit

/// Talk MCP over the real stdio bridge. This binary and its GUI endpoint only
/// connect to the owner-only socket created for this isolated test process.
func readMCP(_ executable: String, snapshot: String? = nil, offset: Int = 0, limit: Int = 1) throws
  -> [String: Any]
{
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.standardInput = input
  process.standardOutput = output
  var arguments: [String: Any] = ["limit": limit, "offset": offset]
  if let snapshot { arguments["selection_id"] = snapshot }
  let calls: [[String: Any]] = [
    [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": ["protocolVersion": "2025-11-25"],
    ],
    ["jsonrpc": "2.0", "method": "notifications/initialized"],
    [
      "jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": ["name": "get_selection", "arguments": arguments],
    ],
  ]
  try process.run()
  for call in calls {
    var line = try JSONSerialization.data(withJSONObject: call)
    line.append(10)
    try input.fileHandleForWriting.write(contentsOf: line)
  }
  try input.fileHandleForWriting.close()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0, let line = data.split(separator: 10).last,
    let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
    let result = reply["result"] as? [String: Any],
    let content = result["content"] as? [[String: Any]],
    let text = content.first?["text"] as? String
  else {
    throw CheckFailure("Bulk selection MCP request failed")
  }
  if result["isError"] as? Bool == true { throw CheckFailure(text) }
  guard let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
  else {
    throw CheckFailure("Bulk MCP response is malformed")
  }
  return payload
}

func profileBulkSelection(_ b: Browser, folder: URL, count: Int, samples: Int, bridge: String)
  throws
{
  guard let fixtureSocket = ProcessInfo.processInfo.environment["FINGER_FIXTURE_SOCKET"],
    try AgentWire.socketPath() == fixtureSocket
  else { throw CheckFailure("Expected a private QA socket") }
  b.window.setContentSize(NSSize(width: 1150, height: 710))
  b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
  b.window.makeFirstResponder(b.ui.table)
  try b.endpoint.start(
    selection: { [weak b] in
      b?.agentSelection() ?? FingerAgentSelection(folder: nil, files: [])
    }, showCollection: { _, _ in })
  func settle() throws {
    try spin(until: { !b.loading && !b.scanning }, "bulk selection table")
    try paint(b)
  }
  func measure(_ name: String, _ action: () throws -> Void) throws {
    let begin = DispatchTime.now().uptimeNanoseconds
    var last = begin
    var largest: UInt64 = 0
    var ticks = 0
    func tick() {
      let now = DispatchTime.now().uptimeNanoseconds
      largest = max(largest, now - last)
      last = now
      ticks += 1
    }
    let timer = Timer(timeInterval: 0.005, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    try autoreleasepool { try action() }
    tick()
    let time = ms(begin)
    let usage = try ProcessSample()
    print(
      String(
        format:
          "bulk %d %@ wall=%.1fms longestMainGap=%.1fms ticks=%d footprint=%.1fMiB heap=%.1fMiB",
        count, name, time, Double(largest) / 1_000_000, ticks, usage.footprint, usage.heapInUse))
    fflush(stdout)
  }
  func mcp(_ snapshot: String? = nil, offset: Int = 0) throws -> [String: Any] {
    var outcome: Result<[String: Any], Error>?
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try readMCP(bridge, snapshot: snapshot, offset: offset) }
      DispatchQueue.main.async { outcome = result }
    }
    try spin(until: { outcome != nil }, "large MCP read")
    return try outcome!.get()
  }
  try measure("open") {
    b.visit(folder.path)
    try settle()
  }
  try require(b.ui.table.numberOfRows == count, "Wrong fixture directory size")
  for trial in 1...samples {
    try select(b, named: "zzzz-proof-final.png")
    try measure("select-all-\(trial)") {
      b.ui.table.selectAll(nil)
      try paint(b)
    }
    try require(b.ui.table.numberOfSelectedRows == count, "Select All omitted visible files")
    try measure("preview-\(trial)") {
      try spin(
        until: {
          tree(b.ui.preview).contains { ($0 as? NSTextField)?.stringValue == "SELECTED ITEMS" }
        }, "multi-file preview")
    }
    var token: String?
    try measure("mcp-fresh-\(trial)") {
      let payload = try mcp()
      token = payload["selection_id"] as? String
      try require(token != nil && payload["total"] as? Int == count, "MCP selection was truncated")
    }
    try measure("mcp-last-page-\(trial)") {
      let payload = try mcp(token, offset: count - 1)
      let items = payload["items"] as? [[String: Any]]
      try require(items?.first?["id"] as? Int == count - 1, "MCP selection page missing")
    }
    try measure("filter-\(trial)") {
      try replaceSearch("zzzz-proof", in: b)
      try paint(b)
    }
    try require(b.ui.table.numberOfRows == 2, "Narrow bulk filter did not find both files")
    try measure("clear-\(trial)") {
      b.clearFilter()
      try paint(b)
    }
    try require(
      b.ui.table.numberOfSelectedRows == count, "Clear Filter lost the original selection")
    let child = folder.appendingPathComponent("000-open-me")
    try measure("enter-\(trial)") {
      b.visit(child.path)
      try settle()
    }
    try measure("back-\(trial)") {
      b.step("back")
      try settle()
    }
    try require(
      b.folderPath == folder.path && b.ui.table.numberOfSelectedRows == count,
      "Back lost selected paths")
  }
  // A selection captured before filtering must follow an in-app rename,
  // even while browsing elsewhere. Later arrivals do not belong to it.
  try replaceSearch("zzzz-proof", in: b)
  b.visit(folder.appendingPathComponent("000-open-me").path)
  try settle()
  let fm = FileManager.default
  let marker = UUID().uuidString
  let old = folder.appendingPathComponent("zzzz-proof-final.svg")
  let moved = folder.appendingPathComponent("Proof \(marker).svg")
  let added = folder.appendingPathComponent("Arrival \(marker).txt")
  try fm.moveItem(at: old, to: moved)
  defer {
    try? fm.removeItem(at: added)
    try? fm.removeItem(at: old)
    try? fm.moveItem(at: moved, to: old)
  }
  try Data("replacement".utf8).write(to: old)
  try Data("new".utf8).write(to: added)
  b.remap([old.path: moved.path])
  b.step("back")
  try settle()
  b.clearFilter()
  try paint(b)
  func selected(_ url: URL) -> Bool {
    guard let row = b.rows.firstIndex(where: { b.entries[$0].path == url.path }) else {
      return false
    }
    return b.ui.table.isRowSelected(row)
  }
  try require(
    b.ui.table.numberOfSelectedRows == count && selected(moved) && !selected(added)
      && !selected(old), "Restored bulk selection included a new arrival or lost an in-app move")
  b.filter(state: ["selected": ["folder": folder.path, "names": "A missing item " + marker]])
  try require(
    b.ui.table.numberOfSelectedRows == 0,
    "An entirely missing bulk selection picked an unrelated file")
  print(
    "Bulk selection restored only original members through a nested filter, a move, a replacement, and a new arrival."
  )
}
