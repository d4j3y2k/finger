import AppKit

/// Only the explicitly supplied image and mount below the disposable fixture
/// are touched. The parent test process owns final detachment and cleanup.
func checkVolumeRecovery(_ b: Browser, folder: URL, mount: URL, image: URL) throws {
  let fixture = image.deletingLastPathComponent()
  guard fixture.path.hasPrefix("/private/tmp/finger-remount-test-"),
    mount.deletingLastPathComponent().deletingLastPathComponent() == fixture,
    folder.deletingLastPathComponent() == mount
  else { throw CheckFailure("Expected test-owned image and mountpoint") }
  func disk(_ arguments: [String]) throws {
    var outcome: Result<Void, Error>?
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result<Void, Error> {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          throw CheckFailure(
            "hdiutil \(arguments[0]) failed: \(String(decoding:diagnostic,as:UTF8.self))")
        }
      }
      DispatchQueue.main.async { outcome = result }
    }
    try spin(until: { outcome != nil }, "normal disk image \(arguments[0])")
    try outcome!.get()
  }
  b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
  // A mount may arrive before the first vnode registration. The initial list
  // must still start once even though the first open was superseded.
  let starting = FolderWatcher()
  var readyCount = 0
  starting.observe(path: folder.path, ready: { readyCount += 1 }, changed: {})
  NSWorkspace.shared.notificationCenter.post(
    name: NSWorkspace.didMountNotification, object: nil,
    userInfo: [NSWorkspace.volumeURLUserInfoKey: mount])
  try spin(until: { readyCount > 0 }, "readiness after a mount during initial open")
  pump(0.1)
  try require(readyCount == 1, "Mount interruptions started the initial folder read twice")
  starting.observe(path: nil) {}
  let shortcut = fixture.appendingPathComponent("Shortcut", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: mount)
  for display in [folder, shortcut.appendingPathComponent("Exports", isDirectory: true)] {
    b.visit(display.path)
    try spin(
      until: { !b.loading && !b.scanning && b.entries.count == 70 }, "reading mounted exports")
    b.ui.table.selectRowIndexes(IndexSet(integersIn: 58..<60), byExtendingSelection: false)
    b.ui.table.scrollRowToVisible(59)
    try paint(b)
    let selected = b.selected.map(\.path)
    let offset = b.ui.scroll.contentView.bounds.minY
    try require(selected.count == 2 && offset > 0, "Expected a deep two-file selection")
    let revision = b.revision
    let different = mount.deletingLastPathComponent().appendingPathComponent(
      "Mounted disk backup", isDirectory: true)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.didMountNotification, object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: different])
    pump(0.25)
    try require(b.revision == revision, "An unrelated mount restarted the current folder")
    try disk(["detach", "-quiet", mount.path])
    try spin(
      until: { !b.scanning && b.lastError != nil && !b.ui.retry.isHidden },
      "offline volume Retry view")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    pump(0.4)
    try disk([
      "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path,
    ])
    let deadline = Date(timeIntervalSinceNow: 7)
    while Date() < deadline && (b.entries.count != 70 || b.scanning) { pump(0.02) }
    try require(
      b.folderPath == display.path && b.entries.count == 70 && b.lastError == nil
        && b.ui.retry.isHidden,
      "Remount at the original mountpoint left Finger on Retry")
    try paint(b)
    try require(
      b.selected.map(\.path) == selected && b.ui.scroll.contentView.bounds.minY == offset,
      "Remount lost one of the selected files or its exact scroll position")
    let marker = folder.appendingPathComponent("ZZZ watcher proof.txt")
    try Data("reconnected".utf8).write(to: marker)
    try spin(
      until: { !b.scanning && b.entries.contains { $0.name == marker.lastPathComponent } },
      "watching new volume vnode")
    print(
      "Normal APFS detach showed Retry. Remount restored \(selected.count) files and scroll \(offset) without input. A later external write appeared through the new vnode watch."
    )
    try FileManager.default.removeItem(at: marker)
    try spin(until: { !b.scanning && b.entries.count == 70 }, "watching marker removal")
  }
  b.folderWatcher.observe(path: nil) {}
  b.ui.preview.show(urls: [])
  b.window.orderOut(nil)
}
