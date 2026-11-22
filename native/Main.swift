import AppKit

private final class AppDelegate: NSObject, NSApplicationDelegate {
  let engine: Engine
  var browser: Browser?
  private var panel: PanelController?
  private var awareness: AwarenessCenter?
  private var shortcuts: PanelShortcuts?
  private var presence: FingerPresence?
  private var statusMenu: FingerStatusMenu?
  private var browserStarted = false
  private let requests = OpenItemRequests()

  init(engine: Engine) { self.engine = engine }

  /// The app itself, as opposed to a test host built from the same code: only
  /// it takes the global shortcut and a menu bar item.
  private var isFinger: Bool { Bundle.main.bundleIdentifier == FingerLoginItem.label }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let b = Browser(engine: engine)
    browser = b
    b.installMenu()
    let presence = FingerPresence(window: b.window, policy: NSApp.activationPolicy())
    presence.show = { [weak self] in self?.showBrowser() }
    self.presence = presence
    let explicit = requests.launch(arguments: arguments)
    if explicit.isEmpty && FingerPresence.isBackground(arguments) {
      // The menu bar item and the panel only. The window opens when asked for.
      presence.becomeBackground()
      startAgentEndpoint(b)
    } else if explicit.isEmpty && arguments.contains("--practice") {
      launchBrowser {
        b.start(at: nil)
        b.openDemo()
      }
    } else if explicit.isEmpty {
      launchBrowser { self.resumeBrowser(b) }
    } else {
      launchBrowser { b.start(at: nil) }
      resolve(explicit, in: b)
    }
    startPanel(show: arguments.contains("--panel"))
    if isFinger {
      let menu = FingerStatusMenu(
        showPanel: { [weak self] in self?.panel?.show() },
        openWindow: { [weak self] in self?.showBrowser() },
        editShortcut: { PanelShortcuts.shared?.showWindow() },
        quit: { NSApp.terminate(nil) })
      menu.install()
      statusMenu = menu
    }
  }

  private func resumeBrowser(_ b: Browser) {
    b.start(
      at: UserDefaults.standard.string(forKey: "lastFolder"), resume: true,
      worktableProject: UserDefaults.standard.string(forKey: "worktableProject"))
  }

  private func launchBrowser(_ start: () -> Void) {
    browserStarted = true
    presence?.windowWillShow()
    start()
  }

  /// Open Finger Window, the Dock icon, Finder or `open -a` while Finger runs
  /// in the background.
  private func showBrowser() {
    guard let browser else { return }
    guard browserStarted else {
      launchBrowser { resumeBrowser(browser) }
      return
    }
    presence?.windowWillShow()
    if !browser.window.isVisible {
      if browser.isWorktable { browser.refreshWorktable() } else { browser.load(browser.snapshot(), clear: false) }
    }
    browser.window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  /// Agents reach Finger while it runs in the background too. A collection
  /// they show opens the window.
  private func startAgentEndpoint(_ b: Browser) {
    do {
      try b.endpoint.start(
        selection: { [weak b] in b?.agentSelection() ?? FingerAgentSelection(folder: nil, paths: { [] }) },
        showCollection: { [weak self] name, paths in self?.showCollection(name, paths) })
    } catch {
      b.agentError = error.localizedDescription
      NSLog("Finger: agent connection unavailable: %@", error.localizedDescription)
    }
  }

  private func showCollection(_ name: String, _ paths: [String]) {
    guard let browser else { return }
    if browserStarted {
      presence?.windowWillShow()
      browser.window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      launchBrowser { browser.start(at: nil) }
    }
    browser.receiveCollection(name, paths: paths)
  }

  /// The summonable search panel. ⌃Space toggles it from any app; Finger ›
  /// Panel Shortcut… changes that.
  private func startPanel(show: Bool) {
    let controller = PanelController(engine: engine)
    panel = controller
    PanelController.shared = controller
    // Working On, from signals on this Mac. Use Activity in the menu bar item turns it off.
    let awareness = AwarenessCenter.live(search: controller.search)
    self.awareness = awareness
    controller.awareness = awareness
    awareness.start()
    let shortcuts = PanelShortcuts { [weak controller] in controller?.toggle() }
    self.shortcuts = shortcuts
    PanelShortcuts.shared = shortcuts
    controller.shortcuts = shortcuts
    if !isFinger {
      // A test host leaves the global shortcut alone.
    } else if let other = FingerPresence.otherInstance() {
      // Carbon can't tell two copies apart, and both would answer.
      NSLog(
        "Finger: another copy (pid %d) already has the panel shortcut; this one leaves it alone",
        other.processIdentifier)
    } else {
      let status = shortcuts.start()
      if status != noErr {
        NSLog("Finger: couldn’t register %@ for the panel (status %d)", shortcuts.current.display, Int(status))
      }
    }
    if show { DispatchQueue.main.async { controller.show() } }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    presence?.reopen() ?? true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    if let browser, browserStarted, browser.window.isVisible, browser.isWorktable,
      browser.homeTicket == nil
    {
      browser.refreshWorktable()
    }
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
  /// Finger keeps running with no windows, so the panel shortcut keeps working.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    FingerPresence.terminatesAfterLastWindowClosed
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    let items = requests.receive(urls)
    guard !items.isEmpty, let browser else { return }
    if browserStarted {
      presence?.windowWillShow()
      browser.window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      launchBrowser { browser.start(at: nil) }
    }
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
  let arguments = Array(CommandLine.arguments.dropFirst())
  // `--login-item on|off|status` changes Open at Login without starting the app.
  if let code = FingerCommandLine.run(arguments) { exit(code) }
  // At login, or when Open at Login is switched on, launchd may start a
  // second copy. The one already running keeps the shortcut and menu bar item.
  if FingerPresence.isBackground(arguments), let other = FingerPresence.otherInstance() {
    print("Finger is already running (pid \(other.processIdentifier)).")
    exit(0)
  }
  autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate(engine: Engine(request, release, list, query, dropIndex))
    // No Dock icon while there is no browser window.
    app.setActivationPolicy(FingerPresence.isBackground(arguments) ? .accessory : .regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
