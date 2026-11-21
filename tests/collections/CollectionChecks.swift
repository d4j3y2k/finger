import CryptoKit

private func checkMetadata(in parent: URL) throws {
  let fm = FileManager.default
  let root = parent.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  let folder = root.appendingPathComponent("Folder")
  let file = root.appendingPathComponent(".hidden proof")
  let locked = root.appendingPathComponent("Locked")
  for dir in [folder, locked, root.appendingPathComponent("Press.app")] {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  defer {
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    try? fm.removeItem(at: root)
  }
  try Data("art".utf8).write(to: file)
  try fm.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: -0.75)], ofItemAtPath: file.path)
  try Data().write(to: locked.appendingPathComponent("private"))
  try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
  for (name, target) in [
    ("folder link", folder), ("file link", file),
    ("dangling", root.appendingPathComponent("absent")),
  ] {
    try fm.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: target)
  }
  for name in [
    ".hidden proof", "Folder", "Press.app", "folder link", "file link", "dangling", "absent",
    "Locked/private",
  ] {
    let path = root.appendingPathComponent(name).path
    let url = URL(fileURLWithPath: path)
    let v = try? url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ])
    var target: ObjCBool = false
    let dir =
      v?.isDirectory == true
      || (v?.isSymbolicLink == true && fm.fileExists(atPath: path, isDirectory: &target)
        && target.boolValue)
    let previous = Entry(
      name: url.lastPathComponent, path: path,
      kind: v == nil ? "missing" : v?.isSymbolicLink == true ? "symlink" : dir ? "folder" : "file",
      isDirectory: dir, size: v?.fileSize.map(Int64.init),
      modified: v?.contentModificationDate.map { Int64($0.timeIntervalSince1970) })
    if Entry.inspect(path) != previous {
      throw FingerAgentError("Metadata parity failed for " + name)
    }
  }
}

// This driver is compiled beside the private production AppDelegate. The two
// modes use real AppKit processes, normal termination, and the same isolated
// preferences and bundle identifier across relaunches.
private final class CollectionChecks: NSObject, NSApplicationDelegate {
  private let product: AppDelegate
  private let browser: Browser
  private let mode: String
  private let folder: URL
  private let count: Int
  private let output: URL
  private let ready: URL
  private let expectedName: String
  private var announced = false
  private var received = false
  private var receiptMs = 0.0
  private var started = DispatchTime.now().uptimeNanoseconds
  private var lastTick = DispatchTime.now().uptimeNanoseconds
  private var largestGap = 0.0
  private var timer: Timer?
  private var writeGate: DispatchSemaphore?
  private var writing: Bool { mode.hasSuffix("write") }

  init(engine: Engine, args: [String]) {
    mode = args[1]
    folder = URL(fileURLWithPath: args[2], isDirectory: true)
    count = Int(args[3])!
    expectedName = (args[1].hasPrefix("fast-") ? "Quick exit archive " : "Press archive ") + args[3]
    output = URL(fileURLWithPath: args[4])
    ready = URL(fileURLWithPath: args[5])
    product = AppDelegate(engine: engine)
    browser = Browser(engine: engine)
    product.browser = browser
  }
  func applicationWillTerminate(_ note: Notification) {
    let began = DispatchTime.now().uptimeNanoseconds
    let queued = browser.collectionWrites.operationCount
    if let writeGate {
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { writeGate.signal() }
    }
    product.applicationWillTerminate(note)
    if writeGate != nil {
      let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
      let facts: [String: Any] = ["queuedAtQuit": queued, "waitMs": ms]
      try? JSONSerialization.data(withJSONObject: facts).write(
        to: output.appendingPathExtension("quit"))
    }
    if ProcessInfo.processInfo.environment["FINGER_QA_CLEAR_DOMAIN"] == "1",
      let id = Bundle.main.bundleIdentifier
    {
      UserDefaults.standard.removePersistentDomain(forName: id)
    }
  }
  func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
    product.applicationShouldTerminate(app)
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    browser.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    browser.window.alphaValue = 0
    if writing {
      do {
        try checkMetadata(in: output.deletingLastPathComponent())
        guard let socket = ProcessInfo.processInfo.environment["FINGER_FIXTURE_SOCKET"],
          try AgentWire.socketPath() == socket
        else { throw FingerAgentError("Missing fixture socket") }
        try browser.endpoint.start(
          selection: { [browser] in browser.agentSelection() },
          showCollection: { [weak self] name, paths in
            guard let self, name == expectedName && paths.count == count else { return }
            if mode == "fast-write" {
              let started = DispatchSemaphore(value: 0)
              let release = DispatchSemaphore(value: 0)
              writeGate = release
              browser.collectionWrites.addOperation {
                started.signal()
                _ = release.wait(timeout: .now() + 8)
              }
              guard started.wait(timeout: .now() + 2) == .success else {
                finish(["error": "Could not hold a pending preference write"])
                return
              }
            }
            started = DispatchTime.now().uptimeNanoseconds
            browser.receiveCollection(name, paths: paths, bringForward: false)
            receiptMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            received = true
            if mode == "fast-write", let record = browser.collection {
              // Quit before either the new preference or the collection rows
              // can finish loading. The real delegate must drain that write.
              finish(["present": true, "id": record.id, "count": record.paths.count])
            }
          })
      } catch {
        finish(["error": error.localizedDescription])
        return
      }
      browser.visit(folder.path)
    } else if let record = browser.collections.first(where: { $0.name == expectedName }) {
      started = DispatchTime.now().uptimeNanoseconds
      browser.visit("collection:" + record.id)
    } else {
      finish(["present": false])
      return
    }
    let tick = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in self?.check() }
    timer = tick
    RunLoop.main.add(tick, forMode: .common)
  }
  private func check() {
    let now = DispatchTime.now().uptimeNanoseconds
    if announced { largestGap = max(largestGap, Double(now - lastTick) / 1_000_000) }
    lastTick = now
    guard !browser.loading && !browser.scanning else { return }
    if writing && !announced {
      guard browser.folderPath == folder.path && browser.ui.table.numberOfRows == count else {
        return
      }
      browser.ui.table.selectAll(nil)
      guard browser.ui.table.numberOfSelectedRows == count else {
        finish(["error": "Select All failed"])
        return
      }
      announced = true
      do { try Data().write(to: ready) } catch { finish(["error": error.localizedDescription]) }
      return
    }
    guard !writing || received, let record = browser.collection else { return }
    browser.ui.root.layoutSubtreeIfNeeded()
    browser.ui.table.layoutSubtreeIfNeeded()
    let browseMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    var digest = SHA256()
    for path in record.paths {
      digest.update(data: Data(path.utf8))
      digest.update(data: Data([0]))
    }
    let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
    finish([
      "present": true, "id": record.id, "count": record.paths.count, "sha256": checksum,
      "listedInOrder": browser.entries.map(\.path) == record.paths, "receiveMs": receiptMs,
      "browseMs": browseMs, "largestMainGapMs": largestGap,
    ])
  }
  private func finish(_ info: [String: Any]) {
    timer?.invalidate()
    var report = info
    if mode == "write", ProcessInfo.processInfo.environment["FINGER_QA_PROFILE_WRITES"] == "1",
      let id = Bundle.main.bundleIdentifier,
      let scratch = UserDefaults(suiteName: id + ".encode-check")
    {
      do {
        let begin = DispatchTime.now().uptimeNanoseconds
        let data = try JSONEncoder().encode(browser.collections)
        let encoded = DispatchTime.now().uptimeNanoseconds
        scratch.set(data, forKey: "collections")
        let stored = DispatchTime.now().uptimeNanoseconds
        report["encodeMs"] = Double(encoded - begin) / 1_000_000
        report["defaultsSetMs"] = Double(stored - encoded) / 1_000_000
        scratch.removePersistentDomain(forName: id + ".encode-check")
      } catch { report["costError"] = error.localizedDescription }
    }
    report["records"] = browser.collections.map(\.name)
    report["defaultsBytes"] = UserDefaults.standard.data(forKey: "collections")?.count ?? 0
    do { try JSONSerialization.data(withJSONObject: report).write(to: output) } catch {
      FileHandle.standardError.write(Data(error.localizedDescription.utf8))
      exit(1)
    }
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }
}

@_cdecl("finger_run")
public func runCollectionChecks(
  _ request: FingerRequest, _ release: FingerRelease, _ list: FingerList,
  _ query: FingerQuery, _ dropIndex: FingerDropIndex
) {
  autoreleasepool {
    let args = CommandLine.arguments
    guard Bundle.main.bundleIdentifier?.hasPrefix("local.finger.gui-bench.") == true,
      args.count == 6, ["write", "read", "fast-write", "fast-read"].contains(args[1]),
      Int(args[3]) != nil,
      ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
    else { exit(64) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = CollectionChecks(
      engine: Engine(request, release, list, query, dropIndex), args: args)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
