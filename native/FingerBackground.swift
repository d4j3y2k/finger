import AppKit

/// Open at Login, as a per-user LaunchAgent that runs Finger's binary with
/// `--background`. Enabling loads it with `launchctl bootstrap`, disabling
/// unloads it with `launchctl bootout`. The plist's presence is the state.
///
/// FINGER_LAUNCH_AGENTS and FINGER_LAUNCHCTL point it elsewhere for checks.
struct FingerLoginItem {
  static let label = "com.d4j3y2k.Finger"
  let agents: URL
  let executable: String
  let launchctl: String
  let uid: uid_t

  init(
    agents: URL? = nil, executable: String? = nil, launchctl: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.agents =
      agents ?? environment["FINGER_LAUNCH_AGENTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/LaunchAgents", isDirectory: true)
    self.executable =
      executable ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    self.launchctl = launchctl ?? environment["FINGER_LAUNCHCTL"] ?? "/bin/launchctl"
    uid = getuid()
  }

  var url: URL { agents.appendingPathComponent(FingerLoginItem.label + ".plist") }
  private var domain: String { "gui/\(uid)" }
  private var service: String { domain + "/" + FingerLoginItem.label }

  /// The LaunchAgent: run once at login, in the background, never restarted.
  var contents: [String: Any] {
    [
      "Label": FingerLoginItem.label,
      "ProgramArguments": [executable, "--background"],
      "RunAtLoad": true,
      "KeepAlive": false,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
      "AssociatedBundleIdentifiers": [FingerLoginItem.label],
    ]
  }

  var isEnabled: Bool {
    (NSDictionary(contentsOf: url)?["Label"] as? String) == FingerLoginItem.label
  }

  /// The program the installed LaunchAgent starts, if there is one.
  var installedProgram: String? {
    (NSDictionary(contentsOf: url)?["ProgramArguments"] as? [String])?.first
  }

  @discardableResult
  func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchctl)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// The process launchd is running for the agent, if any.
  var runningPID: pid_t? {
    let (status, output) = launchctl(["print", service])
    guard status == 0 else { return nil }
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count == 2, parts[0] == "pid", let pid = pid_t(parts[1]) { return pid }
    }
    return nil
  }

  var isLoaded: Bool { launchctl(["print", service]).status == 0 }

  /// Writes the agent and, with `load`, loads it now. A copy that launchd
  /// starts while Finger is already running quits at once.
  func enable(load: Bool) throws {
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
    guard load else { return }
    // Reload an older definition, unless launchd is running this very process:
    // unloading would quit it.
    if isLoaded, runningPID != getpid() { launchctl(["bootout", service]) }
    let (status, output) = launchctl(["bootstrap", domain, url.path])
    if status != 0, !isLoaded {
      throw CoreError(message: "launchctl couldn’t load the login item: " + output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Unloads and removes the agent. If launchd started this Finger, it stays
  /// loaded until Finger quits, and nothing starts it at the next login.
  func disable() throws {
    if isLoaded, runningPID != getpid() { launchctl(["bootout", service]) }
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
}

/// `Finger --login-item on|off|status [--no-load]` changes Open at Login and
/// exits without starting the app. scripts/install.sh uses it.
enum FingerCommandLine {
  static func run(_ arguments: [String], item: FingerLoginItem = FingerLoginItem()) -> Int32? {
    guard let flag = arguments.firstIndex(of: "--login-item") else { return nil }
    let verb = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "status"
    do {
      switch verb {
      case "on":
        try item.enable(load: !arguments.contains("--no-load"))
        print("Open at Login is on: \(item.url.path) runs \(item.executable) --background")
      case "off":
        try item.disable()
        print("Open at Login is off: removed \(item.url.path)")
      case "status":
        print(item.isEnabled ? "Open at Login is on: \(item.installedProgram ?? "?") --background" : "Open at Login is off")
      default:
        FileHandle.standardError.write(Data("Use --login-item on, off or status.\n".utf8))
        return 64
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      return 1
    }
    return 0
  }
}

/// Keeps Finger running without windows so its panel shortcut keeps working:
/// no Dock icon while the browser window is closed, a Dock icon while it is open.
final class FingerPresence: NSObject {
  let window: NSWindow
  private let setPolicy: (NSApplication.ActivationPolicy) -> Void
  private(set) var policy: NSApplication.ActivationPolicy
  /// Opens the browser window, starting it the first time.
  var show: () -> Void = {}

  /// Closing the last window leaves Finger running.
  static let terminatesAfterLastWindowClosed = false

  init(
    window: NSWindow, policy: NSApplication.ActivationPolicy,
    setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }
  ) {
    self.window = window
    self.policy = policy
    self.setPolicy = setPolicy
    super.init()
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
      center.addObserver(self, selector: #selector(appeared), name: name, object: window)
    }
    center.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  static func isBackground(_ arguments: [String]) -> Bool { arguments.contains("--background") }

  /// Another copy of this app that is already running.
  static func otherInstance(bundleID: String? = Bundle.main.bundleIdentifier) -> NSRunningApplication? {
    guard let bundleID else { return nil }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      $0.processIdentifier != getpid() && !$0.isTerminated
    }
  }

  /// The browser window is about to show.
  func windowWillShow() { apply(.regular) }

  @objc private func appeared() { apply(.regular) }

  @objc private func closing() {
    // After the window has gone, so AppKit doesn't keep a window list entry for it.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.window.isVisible else { return }
      self.apply(.accessory)
    }
  }

  func becomeBackground() { apply(.accessory) }

  private func apply(_ next: NSApplication.ActivationPolicy) {
    guard next != policy else { return }
    policy = next
    setPolicy(next)
  }

  /// Opening Finger again (Dock, Finder, `open -a`) shows the browser window.
  func reopen() -> Bool {
    guard window.isVisible, !window.isMiniaturized else {
      show()
      return false
    }
    return true
  }
}

/// The menu bar item's menu.
final class FingerStatusMenu: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Finger")
  let showPanel: CommandItem
  let openWindow: CommandItem
  let shortcut: CommandItem
  let login = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
  let quit: CommandItem
  var loginItem: FingerLoginItem
  var shortcuts: () -> PanelShortcuts? = { PanelShortcuts.shared }
  /// Shown when Open at Login can't be changed.
  var report: (String) -> Void = { NSLog("Finger: %@", $0) }
  private var item: NSStatusItem?

  init(
    loginItem: FingerLoginItem = FingerLoginItem(), showPanel: @escaping () -> Void,
    openWindow: @escaping () -> Void, editShortcut: @escaping () -> Void,
    quit: @escaping () -> Void
  ) {
    self.loginItem = loginItem
    // Let the menu close before the panel takes the keyboard.
    self.showPanel = CommandItem("Show Finger Panel") { DispatchQueue.main.async(execute: showPanel) }
    self.openWindow = CommandItem("Open Finger Window", openWindow)
    shortcut = CommandItem("Panel Shortcut…", editShortcut)
    self.quit = CommandItem("Quit Finger", quit)
    super.init()
    login.target = self
    login.action = #selector(loginChosen)
    for entry in [self.showPanel, self.openWindow, NSMenuItem.separator(), shortcut, login, NSMenuItem.separator(), self.quit] {
      menu.addItem(entry)
    }
    menu.delegate = self
    menu.autoenablesItems = false
    refresh()
  }

  func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

  /// The current shortcut and the real login item state.
  func refresh() {
    login.state = loginItem.isEnabled ? .on : .off
    if let shortcuts = shortcuts() { shortcuts.decorate(showPanel) }
  }

  @objc private func loginChosen() { toggleLogin() }

  func toggleLogin() {
    do {
      if loginItem.isEnabled { try loginItem.disable() } else { try loginItem.enable(load: true) }
    } catch {
      report(error.localizedDescription)
    }
    refresh()
  }

  /// Puts the item in the menu bar.
  func install() {
    guard item == nil else { return }
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "Finger")
    image?.isTemplate = true
    status.button?.image = image
    status.button?.toolTip = "Finger"
    status.menu = menu
    item = status
  }
}
