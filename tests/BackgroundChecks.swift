import AppKit

// scripts/check.sh builds this against the app's code. It checks Finger as a
// background utility: the Open at Login LaunchAgent, switching between no Dock
// icon and a Dock icon as the window closes and opens, staying alive with no
// windows, the menu bar item's menu, and scripts/install.sh against a
// temporary folder. A fake launchctl stands in for launchd, nothing is
// launched or quit, and nothing touches ~/Library or /Applications.

private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> Any = "") {
  if !ok {
    FileHandle.standardError.write("FAILED: \(label) \(detail())\n".data(using: .utf8)!)
    exit(1)
  }
  print("ok -", label)
}

private func pump(_ seconds: TimeInterval = 0.05) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

/// A launchctl that only records what it was asked and remembers "loaded".
private struct FakeLaunchd {
  let folder: URL
  var tool: String { folder.appendingPathComponent("launchctl").path }
  var log: [String] {
    ((try? String(contentsOf: folder.appendingPathComponent("launchctl.log"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }
  init(_ folder: URL) {
    self.folder = folder
    let script = """
      #!/bin/bash
      dir="$(dirname "$0")"
      echo "$*" >> "$dir/launchctl.log"
      case "$1" in
        print) [[ -f "$dir/loaded" ]] || exit 113
               echo "$2 = {"; [[ -f "$dir/pid" ]] && printf '\\tpid = %s\\n' "$(cat "$dir/pid")"; echo "}" ;;
        bootstrap) touch "$dir/loaded" ;;
        bootout) rm -f "$dir/loaded" "$dir/pid" ;;
      esac
      """
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! Data(script.utf8).write(to: folder.appendingPathComponent("launchctl"))
    chmod(tool, 0o755)
  }
  func clear() { try? FileManager.default.removeItem(at: folder.appendingPathComponent("launchctl.log")) }
  func pretendRunning(_ pid: pid_t) { try! Data("\(pid)".utf8).write(to: folder.appendingPathComponent("pid")) }
}

@main
private enum BackgroundChecks {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("Finger Background " + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    loginItem(root.appendingPathComponent("login"))
    presence()
    statusMenu(root.appendingPathComponent("menu"))
    if CommandLine.arguments.count > 1 {
      install(repository: URL(fileURLWithPath: CommandLine.arguments[1]), root.appendingPathComponent("install"))
    }
    print("background checks passed")
  }
}

private func loginItem(_ root: URL) {
  let launchd = FakeLaunchd(root.appendingPathComponent("launchd"))
  let agents = root.appendingPathComponent("LaunchAgents")
  let program = "/Applications/Finger.app/Contents/MacOS/Finger"
  let item = FingerLoginItem(agents: agents, executable: program, launchctl: launchd.tool)
  check(!item.isEnabled && !item.isLoaded, "Open at Login starts off")
  check(item.url.lastPathComponent == "com.d4j3y2k.Finger.plist", "the LaunchAgent is named for the bundle id")

  try! item.enable(load: true)
  let data = try! Data(contentsOf: item.url)
  let plist = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  check(plist["Label"] as? String == "com.d4j3y2k.Finger", "Label")
  check(plist["ProgramArguments"] as? [String] == [program, "--background"], "it runs the app's binary with --background", plist["ProgramArguments"] ?? "nil")
  check(plist["RunAtLoad"] as? Bool == true && plist["KeepAlive"] as? Bool == false, "RunAtLoad true, KeepAlive false")
  check(plist["LimitLoadToSessionType"] as? String == "Aqua" && plist["ProcessType"] as? String == "Interactive", "it runs in the login session, as an interactive process")
  check(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.d4j3y2k.Finger"], "System Settings attributes it to Finger")
  let lint = Process()
  lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
  lint.arguments = ["-lint", "-s", item.url.path]
  try! lint.run()
  lint.waitUntilExit()
  check(lint.terminationStatus == 0, "plutil accepts it")
  let uid = getuid()
  check(launchd.log.contains("bootstrap gui/\(uid) \(item.url.path)"), "enabling bootstraps it into gui/$UID", launchd.log)
  check(item.isEnabled && item.isLoaded, "and the toggle reads on")

  launchd.clear()
  try! item.enable(load: true)
  check(launchd.log.contains("bootout gui/\(uid)/com.d4j3y2k.Finger") && launchd.log.last?.hasPrefix("bootstrap") == true, "enabling again reloads the definition", launchd.log)

  launchd.clear()
  try! item.disable()
  check(launchd.log.contains("bootout gui/\(uid)/com.d4j3y2k.Finger"), "disabling boots it out", launchd.log)
  check(!item.isEnabled && !FileManager.default.fileExists(atPath: item.url.path), "and removes the plist")

  // When launchd started this very Finger, booting the job out would quit it.
  try! item.enable(load: true)
  launchd.pretendRunning(getpid())
  launchd.clear()
  try! item.disable()
  check(!launchd.log.contains { $0.hasPrefix("bootout") }, "it never boots out the Finger that is asking", launchd.log)
  check(!item.isEnabled, "but still turns Open at Login off")
  launchd.clear()
  try! item.enable(load: true)
  check(!launchd.log.contains { $0.hasPrefix("bootout") } && item.isEnabled, "turning it back on keeps that Finger running", launchd.log)
  try? FileManager.default.removeItem(at: item.url)
  try? FileManager.default.removeItem(at: launchd.folder.appendingPathComponent("loaded"))

  launchd.clear()
  check(FingerCommandLine.run(["--login-item", "on", "--no-load"], item: item) == 0 && item.isEnabled, "--login-item on --no-load writes the agent")
  check(launchd.log.isEmpty, "without loading it", launchd.log)
  check(FingerCommandLine.run(["--login-item", "status"], item: item) == 0, "--login-item status")
  check(FingerCommandLine.run(["--login-item", "off"], item: item) == 0 && !item.isEnabled, "--login-item off")
  check(FingerCommandLine.run(["--login-item", "sideways"], item: item) == 64, "an unknown verb is a usage error")
  check(FingerCommandLine.run(["--background"], item: item) == nil, "other arguments start the app")
}

private func presence() {
  let window = NSWindow(
    contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 100), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  var policies: [NSApplication.ActivationPolicy] = []
  var shows = 0
  let p = FingerPresence(window: window, policy: .accessory) { policies.append($0) }
  p.show = { shows += 1 }
  check(FingerPresence.isBackground(["--background"]) && !FingerPresence.isBackground(["--panel"]), "--background")
  check(!FingerPresence.terminatesAfterLastWindowClosed, "closing the last window doesn't quit Finger")
  check(FingerPresence.otherInstance(bundleID: nil) == nil && FingerPresence.otherInstance(bundleID: "com.example.finger.none") == nil, "no other copy is found where there is none")

  check(!p.reopen() && shows == 1, "opening Finger again with no window shows the window")
  p.windowWillShow()
  window.orderFrontRegardless()
  check(policies == [.regular], "a Dock icon while the window is open", policies)
  check(p.reopen() && shows == 1, "with the window open, reopening leaves it to AppKit")
  window.close()
  pump()
  check(policies == [.regular, .accessory], "closing the window removes the Dock icon", policies)
  NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
  check(policies == [.regular, .accessory, .regular], "the window becoming key brings it back", policies)
  window.orderFrontRegardless()
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSWindow())
  pump()
  check(policies.last == .regular, "other windows closing change nothing", policies)
  window.close()
  pump()
  check(policies.last == .accessory, "and only the browser window counts", policies)
}

private func statusMenu(_ root: URL) {
  let launchd = FakeLaunchd(root.appendingPathComponent("launchd"))
  let item = FingerLoginItem(
    agents: root.appendingPathComponent("LaunchAgents"), executable: "/Applications/Finger.app/Contents/MacOS/Finger",
    launchctl: launchd.tool)
  var calls: [String] = []
  let shortcuts = PanelShortcuts(
    defaults: FingerMemoryPreferences(),
    register: { _, _, _ in (noErr, PanelHotKey.Registration {}) }, action: {})
  let menu = FingerStatusMenu(
    loginItem: item, showPanel: { calls.append("panel") }, openWindow: { calls.append("window") },
    editShortcut: { calls.append("shortcut") }, quit: { calls.append("quit") },
    awareness: AwarenessSettings(defaults: FingerMemoryPreferences()))
  menu.shortcuts = { shortcuts }
  menu.refresh()
  let titles = menu.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
  check(
    titles == [
      "Show Finger Panel", "Open Finger Window", "—", "Use Activity", "Use App Documents…", "—", "Panel Shortcut…",
      "Open at Login", "—", "Quit Finger",
    ],
    "the menu bar item's menu", titles)
  check(menu.showPanel.keyEquivalent == " " && menu.showPanel.keyEquivalentModifierMask == [.control], "Show Finger Panel shows ⌃Space")
  check(menu.login.state == .off, "Open at Login is unchecked while it is off")
  menu.menu.performActionForItem(at: menu.menu.index(of: menu.login))
  check(item.isEnabled && menu.login.state == .on, "choosing it turns it on and checks it")
  check(launchd.log.contains { $0.hasPrefix("bootstrap") }, "and loads it", launchd.log)
  try! FileManager.default.removeItem(at: item.url)
  menu.menuNeedsUpdate(menu.menu)
  check(menu.login.state == .off, "the checkmark follows the real state")
  try! item.enable(load: false)
  menu.menuNeedsUpdate(menu.menu)
  check(menu.login.state == .on, "both ways")
  menu.menu.performActionForItem(at: menu.menu.index(of: menu.login))
  check(!item.isEnabled && menu.login.state == .off, "choosing it again turns it off")
  for entry in [menu.showPanel, menu.openWindow, menu.shortcut, menu.quit] {
    menu.menu.performActionForItem(at: menu.menu.index(of: entry))
  }
  pump()
  check(calls == ["window", "shortcut", "quit", "panel"], "each item does its job; the panel waits for the menu to close", calls)
  _ = shortcuts.change(to: PanelShortcut("control+option+k")!)
  menu.menuNeedsUpdate(menu.menu)
  check(menu.showPanel.keyEquivalent == "k" && menu.showPanel.keyEquivalentModifierMask == [.control, .option], "and it shows a changed shortcut")
}

private func install(repository: URL, _ root: URL) {
  let launchd = FakeLaunchd(root.appendingPathComponent("launchd"))
  let dest = root.appendingPathComponent("Applications/Finger.app")
  let agents = root.appendingPathComponent("LaunchAgents")
  func run() -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repository.appendingPathComponent("scripts/install.sh").path]
    var environment = ProcessInfo.processInfo.environment
    environment["FINGER_SKIP_BUILD"] = "1"
    environment["FINGER_APP_DEST"] = dest.path
    environment["FINGER_LAUNCH_AGENTS"] = agents.path
    environment["FINGER_LAUNCHCTL"] = launchd.tool
    environment["FINGER_LAUNCH"] = "0"
    // The quit step runs, but for an app that isn't there.
    environment["FINGER_BUNDLE_ID"] = "com.example.finger.none-" + UUID().uuidString
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
  let (first, out1) = run()
  print(out1.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
  check(first == 0 && out1.contains("Installed \(dest.path)"), "install.sh installs into the given folder", out1)
  check(out1.contains("No running Finger to quit") && out1.contains("Not starting Finger"), "it tried to quit nothing and launched nothing")
  let verify = Process()
  verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
  verify.arguments = ["--verify", "--deep", "--strict", dest.path]
  try! verify.run()
  verify.waitUntilExit()
  check(verify.terminationStatus == 0, "the installed app's signature verifies")
  let plist = NSDictionary(contentsOf: agents.appendingPathComponent("com.d4j3y2k.Finger.plist")) as? [String: Any]
  check(
    plist?["ProgramArguments"] as? [String] == [dest.appendingPathComponent("Contents/MacOS/Finger").path, "--background"],
    "Open at Login points at the installed app", plist?["ProgramArguments"] ?? "nil")
  check(launchd.log.isEmpty, "and loads at the next login, not now", launchd.log)
  let marker = dest.appendingPathComponent("Contents/Resources/.install-check")
  try! Data().write(to: marker)
  let (second, out2) = run()
  check(second == 0 && out2.contains("Replaced \(dest.path)"), "running it again swaps in a fresh copy", out2)
  check(!FileManager.default.fileExists(atPath: marker.path), "the old copy is gone")
  let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
  check(leftovers == ["Finger.app"], "no staging folders are left behind", leftovers)
}
