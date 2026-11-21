// The isolated test builder places this driver alongside Finger’s production
// AppDelegate. It substitutes launch only. AppKit calls the production quit
// decision and completion through the delegate below.
private final class TerminationChecks: NSObject, NSApplicationDelegate {
  private enum Phase { case opening, copying, requested, choseKeepBoth, finished }
  private var phase = Phase.opening
  private let product: AppDelegate
  private let browser: Browser
  private let root: URL
  private let destination: URL
  private let collision: Bool
  private var clock: Timer?
  private var decisions: [NSApplication.TerminateReply] = []
  private var sawReview = false
  private let started = ProcessInfo.processInfo.systemUptime

  init(engine: Engine, root: URL, collision: Bool) {
    self.root = root
    self.collision = collision
    destination = root.appendingPathComponent(
      collision ? "Collision" : "Success", isDirectory: true)
    product = AppDelegate(engine: engine)
    browser = Browser(engine: engine)
    product.browser = browser
  }

  private func mark(_ text: String) {
    print(String(format: "%.3fs %@", ProcessInfo.processInfo.systemUptime - started, text))
    fflush(stdout)
  }

  private func fail(_ text: String) -> Never {
    mark("FAILED " + text)
    exit(1)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A transparent offscreen parent can host a real AppKit sheet without
    // covering or activating another app.
    browser.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    browser.window.alphaValue = 0
    browser.window.orderFront(nil)
    browser.visit(root.appendingPathComponent("Source").path)
    let timer = Timer(timeInterval: 0.006, repeats: true) { [weak self] _ in self?.tick() }
    clock = timer
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
      FileHandle.standardError.write(Data("Timed out waiting for AppKit termination.\n".utf8))
      exit(2)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reply = product.applicationShouldTerminate(sender)
    decisions.append(reply)
    mark(
      "AppKit asked to terminate; busy=\(browser.busy) reply=\(reply == .terminateLater ? "later" : reply == .terminateNow ? "now" : "cancel")"
    )
    return reply
  }

  func applicationWillTerminate(_ notification: Notification) {
    let expected: [NSApplication.TerminateReply] =
      collision ? [.terminateLater, .terminateNow] : [.terminateLater]
    guard decisions == expected, !browser.busy, !browser.pendingQuit, !collision || sawReview else {
      fail("The app terminated before completing the expected copy/review path")
    }
    product.applicationWillTerminate(notification)
    mark("Application will terminate after the completed copy")
  }

  private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews { if let match = button(title, in: child) { return match } }
    return nil
  }

  private func tick() {
    let fm = FileManager.default
    switch phase {
    case .opening:
      guard !browser.loading && !browser.scanning else { return }
      var paths = [root.appendingPathComponent("Source/Artwork").path]
      if collision { paths.append(root.appendingPathComponent("Source/Edition.txt").path) }
      phase = .copying
      browser.transfer(paths, to: destination.path, move: false)
    case .copying:
      let files = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
      guard browser.busy, files.contains(where: { $0.hasPrefix(".finger-transfer-") }) else {
        if !browser.busy { fail("Copy finished before the quit request reached active staging") }
        return
      }
      guard !fm.fileExists(atPath: destination.appendingPathComponent("Artwork").path) else {
        fail("Directory had already been published before Quit")
      }
      mark("Observed active staging with final directory absent; requesting Quit")
      phase = .requested
      // This is the same NSApplication action targeted by Finger’s Quit menu.
      NSApp.sendAction(#selector(NSApplication.terminate(_:)), to: NSApp, from: nil)
    case .requested:
      guard collision, !browser.pendingQuit, !browser.busy,
        let sheet = browser.window.attachedSheet, let view = sheet.contentView,
        let keep = button("Keep Both", in: view), let skip = button("Skip", in: view)
      else { return }
      guard keep.isEnabled, skip.isEnabled, !keep.isHiddenOrHasHiddenAncestor,
        fm.fileExists(atPath: destination.appendingPathComponent("Artwork").path)
      else { fail("Deferred quit left the collision controls unavailable") }
      sawReview = true
      mark("Deferred quit cancelled; usable collision sheet retained; clicking Keep Both")
      phase = .choseKeepBoth
      keep.performClick(nil)
    case .choseKeepBoth:
      guard !browser.busy, browser.window.attachedSheet == nil,
        fm.fileExists(atPath: destination.appendingPathComponent("Edition 2.txt").path)
      else { return }
      phase = .finished
      mark("Collision resolved; requesting Quit again")
      NSApp.sendAction(#selector(NSApplication.terminate(_:)), to: NSApp, from: nil)
    case .finished:
      break
    }
  }
}

@_cdecl("finger_run")
public func runTerminationChecks(
  _ request: FingerRequest, _ release: FingerRelease, _ list: FingerList,
  _ query: FingerQuery, _ dropIndex: FingerDropIndex
) {
  autoreleasepool {
    let args = CommandLine.arguments
    guard let identifier = Bundle.main.bundleIdentifier,
      identifier.hasPrefix("local.finger.gui-bench."),
      args.count == 3, ["success", "collision"].contains(args[2]),
      ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
    else { exit(64) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = TerminationChecks(
      engine: Engine(request, release, list, query, dropIndex),
      root: URL(fileURLWithPath: args[1], isDirectory: true), collision: args[2] == "collision")
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
