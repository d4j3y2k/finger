import AppKit

private final class AppDelegate: NSObject, NSApplicationDelegate {
  let engine: Engine
  var browser: Browser?
  private let requests = OpenItemRequests()

  init(engine: Engine) { self.engine = engine }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let b = Browser(engine: engine)
    browser = b
    b.installMenu()
    let explicit = requests.launch(arguments: Array(CommandLine.arguments.dropFirst()))
    if explicit.isEmpty && CommandLine.arguments.contains("--practice") {
      b.start(at: nil)
      b.openDemo()
    } else if explicit.isEmpty {
      b.start(
        at: UserDefaults.standard.string(forKey: "lastFolder"), resume: true,
        worktableProject: UserDefaults.standard.string(forKey: "worktableProject"))
    } else {
      b.start(at: nil)
      resolve(explicit, in: b)
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    if let browser, browser.isWorktable, browser.homeTicket == nil { browser.refreshWorktable() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    browser?.collectionWrites.waitUntilAllOperationsAreFinished()
    browser?.saveWorkspace()
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let browser, browser.busy else { return .terminateNow }
    browser.pendingQuit = true
    browser.message("Finishing the file operation before quitting…", seconds: 3600)
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func application(_ application: NSApplication, open urls: [URL]) {
    let items = requests.receive(urls)
    guard !items.isEmpty, let browser else { return }
    browser.window.makeKeyAndOrderFront(nil)
    resolve(items, in: browser)
  }

  private func resolve(_ urls: [URL], in browser: Browser) {
    let initialLocation = browser.location
    requests.resolve(urls) { [weak browser] result in
      guard let browser, browser.location == initialLocation else { return }
      browser.openExternal(result)
    }
  }
}

@_cdecl("finger_run")
public func fingerRun(
  _ request: FingerRequest, _ release: FingerRelease, _ list: FingerList,
  _ query: FingerQuery, _ dropIndex: FingerDropIndex
) {
  autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate(engine: Engine(request, release, list, query, dropIndex))
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
