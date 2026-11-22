import AppKit
import Carbon

// scripts/check.sh builds this with native/PanelShortcut.swift and
// native/PanelHotKey.swift. It checks how the panel's shortcut is parsed,
// printed, saved and re-registered, and drives the Panel Shortcut window.
// Real Carbon registrations use ⌃⌥⇧⌘ with F16–F19, so a run never takes a
// shortcut someone is using.

private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> Any = "") {
  if !ok {
    FileHandle.standardError.write("FAILED: \(label) \(detail())\n".data(using: .utf8)!)
    exit(1)
  }
  print("ok -", label)
}

private func shortcut(_ text: String) -> PanelShortcut {
  guard let s = PanelShortcut(text) else {
    FileHandle.standardError.write("FAILED: could not parse \(text)\n".data(using: .utf8)!)
    exit(1)
  }
  return s
}

/// Preferences that never reach ~/Library/Preferences. Pass the same store
/// again for a "new launch".
private func defaults() -> FingerMemoryPreferences { FingerMemoryPreferences() }

/// Stands in for Carbon: records what is live and refuses what is "taken".
private final class FakeCarbon {
  var live: [String] = []
  var taken: Set<String> = []
  func key(_ code: UInt32, _ modifiers: UInt32) -> String { "\(code)/\(modifiers)" }
  func key(_ s: PanelShortcut) -> String { key(s.keyCode, s.carbonModifiers) }
  lazy var register: PanelHotKey.Register = { [unowned self] code, modifiers, _ in
    let k = self.key(code, modifiers)
    if self.taken.contains(k) || self.live.contains(k) { return (OSStatus(eventHotKeyExistsErr), nil) }
    self.live.append(k)
    return (noErr, PanelHotKey.Registration { self.live.removeAll { $0 == k } })
  }
}

@main
private enum PanelShortcutChecks {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    parsing()
    events()
    persisting()
    carbon()
    recorder()
    print("panel shortcut checks passed")
  }
}

private func parsing() {
  let standard = PanelShortcut.standard
  check(standard == shortcut("control+space"), "the default is ⌃Space")
  check(standard.text == "control+space" && standard.display == "⌃Space", "it reads control+space and shows ⌃Space")
  check(standard.carbonModifiers == UInt32(controlKey) && standard.keyCode == UInt32(kVK_Space), "Carbon gets controlKey and Space")
  check(shortcut(" Ctrl + Space ") == standard, "parsing ignores case, spaces and short names")
  let k = shortcut("command+shift+k")
  check(k.keyCode == UInt32(kVK_ANSI_K) && k.modifiers == [.command, .shift], "command+shift+k")
  check(k.text == "shift+command+k" && k.display == "⇧⌘K", "written in Apple's ⌃⌥⇧⌘ order", k.display)
  check(shortcut("option+command+space").display == "⌥⌘Space", "⌥⌘Space")
  check(shortcut("control+option+f5").display == "⌃⌥F5", "function keys")
  check(shortcut("alt+cmd+left").display == "⌥⌘←", "arrows and alias names")
  for bad in ["", "control+", "+space", "hyper+k", "control+bogus", "control+escape", "control++k"] {
    check(PanelShortcut(bad) == nil, "rejects \"\(bad)\"")
  }
  var trips = 0
  let sets: [NSEvent.ModifierFlags] = [[.control], [.option, .shift], [.command, .control, .option, .shift], [.command]]
  for code in PanelShortcut.usableKeyCodes {
    for mods in sets {
      let s = PanelShortcut(keyCode: code, modifiers: mods)
      guard PanelShortcut(s.text) == s else { check(false, "round trip", s.text) ; return }
      trips += 1
    }
  }
  check(PanelShortcut.usableKeyCodes.count == 80 && trips == 80 * sets.count, "all 80 usable keys round-trip through their text (\(trips))")
  check(shortcut("space").problem != nil && shortcut("shift+k").problem != nil, "a shortcut needs ⌘, ⌃ or ⌥")
  check(shortcut("control+shift+k").problem == nil && shortcut("command+f1").problem == nil, "⇧ works with another modifier")
  check(shortcut("command+space").warning?.contains("Spotlight") == true, "⌘Space warns about Spotlight")
  check(shortcut("option+command+space").warning?.contains("Finder") == true, "⌥⌘Space warns about Finder")
  check(shortcut("option+space").warning?.contains("ChatGPT") == true, "⌥Space warns about ChatGPT and Codex")
  check(standard.warning == nil && shortcut("control+option+space").warning == nil, "others don't warn")
  let item = NSMenuItem()
  item.keyEquivalent = standard.menuKey
  item.keyEquivalentModifierMask = standard.modifiers
  check(item.keyEquivalent == " " && item.keyEquivalentModifierMask == [.control], "menu key equivalent")
  check(shortcut("command+f5").menuKey == String(UnicodeScalar(UInt16(NSF5FunctionKey))!), "function key menu equivalent")
}

private func keyEvent(_ code: Int, _ flags: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent {
  let chars = code == kVK_Escape ? "\u{1b}" : code == kVK_Space ? " " : "k"
  return NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
    windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
}

private func events() {
  let pressed = keyEvent(kVK_ANSI_K, [.command, .shift, .capsLock])
  check(PanelShortcut(event: pressed) == shortcut("command+shift+k"), "a key press becomes a shortcut, caps lock ignored")
  check(shortcut("command+shift+k").matches(pressed), "and matches that press")
  check(!shortcut("command+shift+k").matches(keyEvent(kVK_ANSI_K, [.command])), "other modifiers don't match")
  check(PanelShortcut(event: keyEvent(kVK_Escape, [.control])) == nil, "Escape can't be a shortcut")
}

private func persisting() {
  let store = defaults()
  let fake = FakeCarbon()
  var announced = 0
  let observer = NotificationCenter.default.addObserver(forName: PanelShortcuts.changed, object: nil, queue: nil) { _ in
    announced += 1
  }
  defer { NotificationCenter.default.removeObserver(observer) }
  store.set("hyper+k", forKey: PanelShortcuts.defaultsKey)
  check(PanelShortcuts.load(from: store) == nil, "an unreadable saved value is ignored")
  store.set("shift+k", forKey: PanelShortcuts.defaultsKey)
  check(PanelShortcuts(defaults: store, register: fake.register, action: {}).current == .standard, "an unusable saved value falls back to ⌃Space")
  store.removeObject(forKey: PanelShortcuts.defaultsKey)

  let s = PanelShortcuts(defaults: store, register: fake.register, action: {})
  check(s.current == .standard && s.start() == noErr && fake.live == [fake.key(.standard)], "starts with ⌃Space registered")
  let k = shortcut("control+option+k")
  check(s.change(to: k) == .set(warning: nil), "changes to ⌃⌥K")
  check(store.string(forKey: PanelShortcuts.defaultsKey) == "control+option+k", "and saves it as text", store.string(forKey: PanelShortcuts.defaultsKey) ?? "nil")
  check(fake.live == [fake.key(k)], "the old shortcut is unregistered, the new one registered", fake.live)
  check(PanelShortcuts(defaults: store, register: FakeCarbon().register, action: {}).current == k, "a new launch reads it back")

  guard case .set(let warning) = s.change(to: shortcut("option+space")), warning?.contains("ChatGPT") == true else {
    check(false, "⌥Space is allowed with a warning")
    return
  }
  check(true, "⌥Space is allowed with a warning")
  guard case .rejected = s.change(to: shortcut("shift+k")) else { check(false, "⇧K is refused"); return }
  check(s.current == shortcut("option+space") && store.string(forKey: PanelShortcuts.defaultsKey) == "option+space", "a refused shortcut changes nothing")

  let j = shortcut("control+option+j")
  fake.taken = [fake.key(j)]
  guard case .failed(let why) = s.change(to: j) else { check(false, "a taken shortcut fails"); return }
  check(why.contains("⌃⌥J") && why.contains("⌥Space stays"), "the failure says so and names what stays", why)
  check(s.current == shortcut("option+space") && fake.live == [fake.key(shortcut("option+space"))], "the previous shortcut stays registered", fake.live)
  check(store.string(forKey: PanelShortcuts.defaultsKey) == "option+space", "and saved")

  check(s.reset() == .set(warning: nil) && s.current == .standard, "reset goes back to ⌃Space")
  check(store.object(forKey: PanelShortcuts.defaultsKey) == nil, "and clears the saved value")
  check(announced == 3, "each change is announced once", announced)
  s.suspend()
  check(fake.live.isEmpty && !s.registered, "suspending frees the shortcut for the recorder")
  s.resume()
  check(fake.live == [fake.key(.standard)] && s.registered, "resuming registers it again")
}

private func carbon() {
  let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
  func f(_ code: Int) -> PanelShortcut { PanelShortcut(keyCode: UInt32(code), modifiers: hyper) }
  let storeA = defaults()
  let storeB = defaults()
  let a = PanelShortcuts(defaults: storeA, standard: f(kVK_F19), action: {})
  check(a.start() == noErr && a.registered, "Carbon registers ⌃⌥⇧⌘F19")
  check(a.change(to: f(kVK_F18)) == .set(warning: nil) && a.hotKey.registered == f(kVK_F18), "re-registers live as ⌃⌥⇧⌘F18")
  let b = PanelShortcuts(defaults: storeB, standard: f(kVK_F17), action: {})
  check(b.start() == noErr, "a second owner registers F17")
  check(b.change(to: f(kVK_F19)) == .set(warning: nil), "F19 is free again, so the first owner let it go")
  guard case .failed(let why) = b.change(to: f(kVK_F18)) else {
    check(false, "Carbon refuses F18 while the first owner holds it")
    return
  }
  check(why.contains("-9878"), "Carbon refuses F18 while the first owner holds it", why)
  check(b.current == f(kVK_F19) && b.hotKey.registered == f(kVK_F19), "the second owner keeps F19 registered")
  a.suspend()
  check(b.change(to: f(kVK_F18)) == .set(warning: nil), "suspending frees F18")
  a.resume()
  check(a.status == OSStatus(eventHotKeyExistsErr) && !a.registered, "resuming reports that F18 is now taken", a.status)
  a.suspend()
  b.suspend()
}

private func recorder() {
  let store = defaults()
  let fake = FakeCarbon()
  let s = PanelShortcuts(defaults: store, register: fake.register, action: {})
  s.start()
  let w = PanelShortcutWindow(shortcuts: s)
  let window = w.window!
  window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
  window.orderFrontRegardless()
  w.recorder.start()
  func press(_ code: Int, _ flags: NSEvent.ModifierFlags = []) { window.sendEvent(keyEvent(code, flags, window: window)) }
  check(w.recorder.recording && fake.live.isEmpty, "recording frees the current shortcut so it can be pressed")
  check(w.resetButton.title == "Use ⌃Space", "the reset button names the default", w.resetButton.title)
  press(kVK_ANSI_K)
  check(w.recorder.recording && w.message.stringValue.contains("at least one of"), "a plain key is refused and recording goes on", w.message.stringValue)
  press(kVK_Escape)
  check(!w.recorder.recording && s.current == .standard && fake.live == [fake.key(.standard)], "Esc cancels and restores ⌃Space")
  w.recorder.start()
  press(kVK_ANSI_K, [.control, .option])
  check(s.current == shortcut("control+option+k") && !w.recorder.recording, "a combination is set at once", s.current.display)
  check(w.recorder.label == "⌃⌥K" && w.message.stringValue.hasPrefix("Saved."), "and shown", w.message.stringValue)
  check(fake.live == [fake.key(s.current)], "with no relaunch", fake.live)
  w.recorder.start()
  press(kVK_Space, [.option])
  check(s.current == shortcut("option+space") && w.message.stringValue.contains("ChatGPT"), "⌥Space is set, with a warning", w.message.stringValue)
  check(w.message.textColor == .systemOrange, "the warning doesn't read as an error")
  let j = shortcut("control+option+j")
  fake.taken = [fake.key(j)]
  w.recorder.start()
  press(kVK_ANSI_J, [.control, .option])
  check(w.message.stringValue.contains("Couldn’t use ⌃⌥J") && w.message.textColor == .systemRed, "a refused registration says so", w.message.stringValue)
  check(w.recorder.recording && w.recorder.shortcut == shortcut("option+space") && s.current == shortcut("option+space"), "and keeps the previous shortcut")
  press(kVK_Escape)
  check(fake.live == [fake.key(shortcut("option+space"))], "which is registered again after Esc", fake.live)
  w.resetPressed()
  check(s.current == .standard && store.object(forKey: PanelShortcuts.defaultsKey) == nil, "the reset button goes back to ⌃Space")
  check(fake.live == [fake.key(.standard)], "and registers it", fake.live)
  w.close()
  check(fake.live == [fake.key(.standard)], "closing the window leaves ⌃Space registered")
}
