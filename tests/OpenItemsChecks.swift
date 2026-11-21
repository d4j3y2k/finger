import Darwin
import Foundation

// Run in a standalone process with native/OpenItems.swift. No WindowServer,
// defaults, agent socket or existing documents are needed by this fixture.
@main
struct OpenItemsChecks {
  struct Failure: LocalizedError { var errorDescription: String? }
  static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(errorDescription: message) }
  }
  static func wait(_ condition: () -> Bool) throws {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() {
      try check(Date() < deadline, "Timed out waiting for background open request")
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "finger-open-" + UUID().uuidString, isDirectory: true
    ).standardizedFileURL
    let left = root.appendingPathComponent("exports", isDirectory: true)
    let right = root.appendingPathComponent("delivery", isDirectory: true)
    try fm.createDirectory(at: left, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: right, withIntermediateDirectories: true)
    let a = left.appendingPathComponent("cover one.png")
    let b = left.appendingPathComponent("cover two.svg")
    let hidden = left.appendingPathComponent(".hidden note")
    let other = right.appendingPathComponent("third.png")
    let missing = right.appendingPathComponent("no longer here.png")
    for item in [a, b, hidden, other] { try Data([0x41]).write(to: item) }

    try check(
      OpenItems.resolve([left]).view == .folder(left.path), "single folder must enter directly")
    try check(
      OpenItems.resolve([a]).view
        == .siblings(parent: left.path, paths: [a.path], showHidden: false),
      "single file must be revealed")
    let siblingView = OpenItems.View.siblings(
      parent: left.path, paths: [a.path, b.path], showHidden: false)
    try check(
      OpenItems.resolve([a, b, a]).view == siblingView, "sibling selection lost members or order")
    try check(
      OpenItems.resolve([right, left]).view
        == .siblings(parent: root.path, paths: [right.path, left.path], showHidden: false),
      "sibling directories must both be selected")
    try check(
      OpenItems.resolve([b, hidden]).view
        == .siblings(parent: left.path, paths: [b.path, hidden.path], showHidden: true),
      "explicit hidden members must remain selectable")
    try check(
      OpenItems.resolve([b, other]).view == .collection([b, other]),
      "mixed parents must remain together")
    let partial = OpenItems.resolve([missing, a, b])
    try check(
      partial.view == siblingView && partial.notice?.contains(missing.path) == true,
      "partial failure must preserve valid choices")
    let bad = OpenItems.resolve([missing])
    try check(
      bad.view == nil && bad.notice?.contains("Check the path") == true,
      "missing file needs an actionable error")
    let folderAlias = root.appendingPathComponent("current")
    try fm.createSymbolicLink(at: folderAlias, withDestinationURL: left)
    try check(
      OpenItems.resolve([folderAlias]).view == .folder(folderAlias.path),
      "directory alias was not navigable")
    let broken = left.appendingPathComponent("old alias")
    try fm.createSymbolicLink(at: broken, withDestinationURL: missing)
    try check(
      OpenItems.resolve([broken]).view
        == .siblings(parent: left.path, paths: [broken.path], showHidden: false),
      "dangling symlink can still be revealed")
    let package = right.appendingPathComponent("Example.app", isDirectory: true)
    try fm.createDirectory(at: package, withIntermediateDirectories: true)
    try check(
      OpenItems.resolve([package]).view
        == .siblings(parent: right.path, paths: [package.path], showHidden: false),
      "a package should reveal as one item")
    if geteuid() != 0 {
      let locked = right.appendingPathComponent("Locked", isDirectory: true)
      try fm.createDirectory(at: locked, withIntermediateDirectories: true)
      try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
      let denied = OpenItems.resolve([locked])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
      try check(
        denied.view == nil && denied.notice?.contains("denied") == true,
        "unreadable directory must not navigate")
    }

    let requests = OpenItemRequests()
    try check(
      requests.receive([a]).isEmpty && requests.receive([b]).isEmpty, "cold Apple events must queue"
    )
    try check(
      requests.launch(arguments: ["--folder", right.path]) == [a, b],
      "cold Apple events outrank process arguments")
    try check(requests.receive([a, other]) == [a, other], "warm event lost a URL")
    try check(
      OpenItemRequests().launch(arguments: [
        "-psn_0_7", "-NSWindowFoo", "YES", "--folder", a.path, b.path,
      ]).map(\.path) == [a.path, b.path], "command-line launch arguments misclassified")
    try check(
      OpenItemRequests().launch(arguments: ["-psn_0_7"]).isEmpty,
      "ordinary launch should resume workspace")

    let entered = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let asyncRequests = OpenItemRequests { urls, cancelled in
      precondition(!Thread.isMainThread)
      if urls == [a] {
        entered.signal()
        unblock.wait()
        finished.signal()
      }
      return OpenItems.resolve(urls, cancelled: cancelled)
    }
    var results: [OpenItems.View?] = []
    asyncRequests.resolve([a]) { results.append($0.view) }
    try check(entered.wait(timeout: .now() + 2) == .success, "slow request did not start")
    asyncRequests.resolve([right]) { results.append($0.view) }
    try wait { results.count == 1 }
    unblock.signal()
    try check(finished.wait(timeout: .now() + 2) == .success, "slow worker did not finish")
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    try check(results == [.folder(right.path)], "late provider result superseded the newer request")
    print(
      "Explicit-open checks passed: cold/warm events, multi-selection, collections, visibility, failures, background resolution and stale requests."
    )
  }
}
