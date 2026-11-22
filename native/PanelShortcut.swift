import AppKit
import Carbon

/// A key combination that shows and hides the panel: a Carbon virtual key
/// code and modifiers. UserDefaults holds it in a readable form such as
/// "control+space", which `init?(_:)` parses and `text` writes.
struct PanelShortcut: Equatable {
  let keyCode: UInt32
  let modifiers: NSEvent.ModifierFlags

  static let standard = PanelShortcut(keyCode: UInt32(kVK_Space), modifiers: [.control])
  private static let kept: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

  init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
    self.keyCode = keyCode
    self.modifiers = modifiers.intersection(PanelShortcut.kept)
  }

  static func == (a: PanelShortcut, b: PanelShortcut) -> Bool {
    a.keyCode == b.keyCode && a.modifiers.rawValue == b.modifiers.rawValue
  }

  /// The combination pressed, or nil for a key that can't be a shortcut.
  init?(event: NSEvent) {
    guard event.type == .keyDown, PanelShortcut.keys[Int(event.keyCode)] != nil else { return nil }
    self.init(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
  }

  /// Parses "control+option+k" or "command+shift+f5". Nil for anything unknown.
  init?(_ text: String) {
    let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = parts.last, !last.isEmpty,
      let code = PanelShortcut.keys.first(where: { $0.value.name == last })?.key
    else { return nil }
    var flags: NSEvent.ModifierFlags = []
    for part in parts.dropLast() {
      guard let flag = PanelShortcut.modifierNames[part] else { return nil }
      flags.insert(flag)
    }
    self.init(keyCode: UInt32(code), modifiers: flags)
  }

  private static let modifierNames: [String: NSEvent.ModifierFlags] = [
    "control": .control, "ctrl": .control, "option": .option, "opt": .option, "alt": .option,
    "shift": .shift, "command": .command, "cmd": .command,
  ]
  // Apple's order: ⌃ ⌥ ⇧ ⌘.
  private static let order: [(NSEvent.ModifierFlags, String, String)] = [
    (.control, "control", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.command, "command", "⌘"),
  ]

  /// The stored form: "control+space".
  var text: String {
    let names = PanelShortcut.order.filter { modifiers.contains($0.0) }.map(\.1)
    return (names + [PanelShortcut.keys[Int(keyCode)]?.name ?? "key\(keyCode)"]).joined(separator: "+")
  }

  /// How menus write it: "⌃Space".
  var display: String {
    PanelShortcut.order.filter { modifiers.contains($0.0) }.map(\.2).joined()
      + (PanelShortcut.keys[Int(keyCode)]?.symbol ?? "Key \(keyCode)")
  }

  var carbonModifiers: UInt32 {
    var out = 0
    if modifiers.contains(.command) { out |= cmdKey }
    if modifiers.contains(.control) { out |= controlKey }
    if modifiers.contains(.option) { out |= optionKey }
    if modifiers.contains(.shift) { out |= shiftKey }
    return UInt32(out)
  }

  /// Why this can't be the panel's shortcut, or nil when it can.
  var problem: String? {
    modifiers.isDisjoint(with: [.command, .control, .option])
      ? "Use at least one of ⌘, ⌃ or ⌥. ⇧ counts only together with one of them." : nil
  }

  /// A known clash. The shortcut still works, but another app may answer too.
  var warning: String? {
    guard keyCode == UInt32(kVK_Space) else { return nil }
    if modifiers == [.command] { return "⌘Space usually opens Spotlight." }
    if modifiers == [.option, .command] { return "⌥⌘Space usually opens a Finder search window." }
    if modifiers == [.option] { return "⌥Space is often taken by ChatGPT or Codex, and both may answer." }
    return nil
  }

  /// For an NSMenuItem: the key equivalent and its modifier mask.
  var menuKey: String { PanelShortcut.keys[Int(keyCode)]?.menu ?? "" }

  func matches(_ event: NSEvent) -> Bool {
    event.type == .keyDown && UInt32(event.keyCode) == keyCode
      && event.modifierFlags.intersection(PanelShortcut.kept) == modifiers
  }

  private struct Key {
    let name: String
    let symbol: String
    let menu: String
  }
  private static func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt16(scalar))!) }
  /// The keys a shortcut can use, by Carbon key code (US positions). Escape
  /// is left out: it cancels the recorder.
  private static let keys: [Int: Key] = {
    var keys: [Int: Key] = [:]
    let letters: [(Int, String)] = [
      (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
      (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
      (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
      (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
      (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
      (kVK_ANSI_Z, "z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
      (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
      (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
      (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
      (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
      (kVK_ANSI_Grave, "`"),
    ]
    for (code, name) in letters { keys[code] = Key(name: name, symbol: name.uppercased(), menu: name) }
    let named: [(Int, String, String, String)] = [
      (kVK_Space, "space", "Space", " "), (kVK_Return, "return", "↩", "\r"),
      (kVK_Tab, "tab", "⇥", "\t"), (kVK_Delete, "delete", "⌫", "\u{8}"),
      (kVK_ForwardDelete, "forwarddelete", "⌦", function(NSDeleteFunctionKey)),
      (kVK_LeftArrow, "left", "←", function(NSLeftArrowFunctionKey)),
      (kVK_RightArrow, "right", "→", function(NSRightArrowFunctionKey)),
      (kVK_DownArrow, "down", "↓", function(NSDownArrowFunctionKey)),
      (kVK_UpArrow, "up", "↑", function(NSUpArrowFunctionKey)),
      (kVK_Home, "home", "↖", function(NSHomeFunctionKey)),
      (kVK_End, "end", "↘", function(NSEndFunctionKey)),
      (kVK_PageUp, "pageup", "⇞", function(NSPageUpFunctionKey)),
      (kVK_PageDown, "pagedown", "⇟", function(NSPageDownFunctionKey)),
    ]
    for (code, name, symbol, menu) in named { keys[code] = Key(name: name, symbol: symbol, menu: menu) }
    let functions = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
      kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    for (i, code) in functions.enumerated() {
      keys[code] = Key(name: "f\(i + 1)", symbol: "F\(i + 1)", menu: function(NSF1FunctionKey + i))
    }
    return keys
  }()

  /// Every key a shortcut can use, for checks.
  static var usableKeyCodes: [UInt32] { keys.keys.sorted().map(UInt32.init) }
}

/// The shortcut that shows and hides the panel: kept in UserDefaults,
/// registered with Carbon, and changed live with no relaunch.
final class PanelShortcuts {
  static let defaultsKey = "panelShortcut"
  static let changed = Notification.Name("FingerPanelShortcutChanged")
  /// Window › Show Finger Panel, which shows the shortcut.
  static let menuItem = NSUserInterfaceItemIdentifier("finger.panel.show")
  /// The app's shortcuts, for menus and Help.
  static weak var shared: PanelShortcuts?

  enum Outcome: Equatable {
    /// Registered and saved, with a clash to mention if there is one.
    case set(warning: String?)
    /// Not allowed; nothing changed.
    case rejected(String)
    /// Carbon refused it; the previous shortcut stays.
    case failed(String)
  }

  let defaults: FingerPreferences
  let standard: PanelShortcut
  let hotKey: PanelHotKey
  private(set) var current: PanelShortcut
  /// The Carbon status of the last attempt to register `current`.
  private(set) var status: OSStatus = noErr
  private var window: PanelShortcutWindow?

  init(
    defaults: FingerPreferences = UserDefaults.standard, standard: PanelShortcut = .standard,
    register: @escaping PanelHotKey.Register = PanelHotKey.carbon, action: @escaping () -> Void
  ) {
    self.defaults = defaults
    self.standard = standard
    current = PanelShortcuts.load(from: defaults) ?? standard
    hotKey = PanelHotKey(register: register, action)
  }

  /// The saved shortcut, if there is a usable one.
  static func load(from defaults: FingerPreferences) -> PanelShortcut? {
    guard let text = defaults.string(forKey: defaultsKey), let shortcut = PanelShortcut(text),
      shortcut.problem == nil
    else { return nil }
    return shortcut
  }

  var registered: Bool { status == noErr && hotKey.registered == current }

  @discardableResult
  func start() -> OSStatus {
    status = hotKey.register(current)
    return status
  }

  /// Uses `shortcut` from now on, if it is allowed and registers.
  @discardableResult
  func change(to shortcut: PanelShortcut) -> Outcome {
    if let problem = shortcut.problem { return .rejected(problem) }
    let result = hotKey.register(shortcut)
    guard result == noErr else {
      return .failed(
        "Couldn’t use \(shortcut.display): macOS refused it (error \(result)), usually because it is already taken. \(current.display) stays.")
    }
    current = shortcut
    status = noErr
    if shortcut == standard {
      defaults.removeObject(forKey: PanelShortcuts.defaultsKey)
    } else {
      defaults.set(shortcut.text, forKey: PanelShortcuts.defaultsKey)
    }
    announce()
    return .set(warning: shortcut.warning)
  }

  @discardableResult
  func reset() -> Outcome { change(to: standard) }

  /// Lets the recorder hear the current shortcut instead of the panel.
  func suspend() { hotKey.unregister() }

  func resume() {
    guard hotKey.registered != current else { return }
    status = hotKey.register(current)
    announce()
  }

  /// Tells the panel's footer and the menu bar.
  private func announce() {
    if let menu = NSApp?.mainMenu, let item = PanelShortcuts.find(PanelShortcuts.menuItem, in: menu) {
      decorate(item)
    }
    NotificationCenter.default.post(name: PanelShortcuts.changed, object: self)
  }

  private static func find(_ id: NSUserInterfaceItemIdentifier, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if item.identifier == id { return item }
      if let sub = item.submenu, let hit = find(id, in: sub) { return hit }
    }
    return nil
  }

  /// Shows the current shortcut on a menu item.
  func decorate(_ item: NSMenuItem) {
    item.keyEquivalent = current.menuKey
    item.keyEquivalentModifierMask = current.modifiers
  }

  /// Panel Shortcut…
  func showWindow() {
    let window = self.window ?? PanelShortcutWindow(shortcuts: self)
    self.window = window
    NSApp.activate()
    window.present()
  }
}

/// Click, then press a combination. Esc stops recording.
final class PanelShortcutRecorder: NSView {
  var shortcut: PanelShortcut = .standard { didSet { needsDisplay = true } }
  private(set) var recording = false { didSet { needsDisplay = true } }
  private var held: NSEvent.ModifierFlags = [] { didSet { needsDisplay = true } }
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?
  /// A combination was pressed. It may still be refused.
  var onRecord: ((PanelShortcut) -> Void)?
  var onUnusable: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Panel shortcut")
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  func start() {
    guard !recording else { return }
    recording = true
    held = []
    window?.makeFirstResponder(self)
    onStart?()
  }

  func stop() {
    guard recording else { return }
    recording = false
    held = []
    onStop?()
  }

  override func resignFirstResponder() -> Bool {
    stop()
    return super.resignFirstResponder()
  }

  override func mouseDown(with event: NSEvent) { start() }

  override func flagsChanged(with event: NSEvent) {
    if recording { held = event.modifierFlags.intersection([.control, .option, .shift, .command]) }
  }

  // Command and Control combinations arrive as key equivalents, before the
  // menu bar can act on them.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard recording, window?.firstResponder === self, event.type == .keyDown,
      !event.modifierFlags.isDisjoint(with: [.control, .option, .command])
    else { return false }
    take(event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    let plain = event.modifierFlags.isDisjoint(with: [.control, .option, .shift, .command])
    if Int(event.keyCode) == kVK_Escape, plain {
      if recording { stop() } else { window?.performClose(nil) }
      return
    }
    guard recording else {
      if plain, Int(event.keyCode) == kVK_Space || Int(event.keyCode) == kVK_Return { start() }
      return
    }
    take(event)
  }

  private func take(_ event: NSEvent) {
    guard let shortcut = PanelShortcut(event: event) else {
      onUnusable?()
      return
    }
    onRecord?(shortcut)
  }

  /// What the field shows.
  var label: String {
    guard recording else { return shortcut.display }
    let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    let partial = order.filter { held.contains($0.0) }.map(\.1).joined()
    return partial.isEmpty ? "Type Shortcut" : partial + "…"
  }

  override func draw(_ dirtyRect: NSRect) {
    let box = bounds.insetBy(dx: 1, dy: 1)
    let shape = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
    NSColor.controlBackgroundColor.setFill()
    shape.fill()
    (recording ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
    shape.lineWidth = recording ? 2 : 1
    shape.stroke()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let quiet = recording && held.isEmpty
    let text = NSAttributedString(
      string: label,
      attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: quiet ? .regular : .medium),
        .foregroundColor: quiet ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        .paragraphStyle: style,
      ])
    let height = ceil(text.size().height)
    text.draw(in: NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height))
  }
}

/// Finger › Panel Shortcut…: a small window with the recorder, what happened,
/// and a button back to the default.
final class PanelShortcutWindow: NSWindowController, NSWindowDelegate {
  let shortcuts: PanelShortcuts
  let recorder = PanelShortcutRecorder(frame: NSRect(x: 95, y: 104, width: 190, height: 32))
  let message = NSTextField(wrappingLabelWithString: "")
  let resetButton: NSButton
  let doneButton: NSButton

  init(shortcuts: PanelShortcuts) {
    self.shortcuts = shortcuts
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 214), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Panel Shortcut"
    window.isReleasedWhenClosed = false
    resetButton = NSButton(title: "Use \(shortcuts.standard.display)", target: nil, action: nil)
    doneButton = NSButton(title: "Done", target: nil, action: nil)
    super.init(window: window)
    window.delegate = self
    let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.contentView = content
    let intro = NSTextField(
      wrappingLabelWithString: "This shortcut shows and hides the search panel from any app. Click the field and press a new combination.")
    intro.font = .systemFont(ofSize: 12)
    intro.textColor = .secondaryLabelColor
    intro.frame = NSRect(x: 20, y: 150, width: 340, height: 44)
    message.font = .systemFont(ofSize: 11.5)
    message.alignment = .center
    message.frame = NSRect(x: 20, y: 56, width: 340, height: 36)
    message.setAccessibilityIdentifier("shortcut-message")
    resetButton.bezelStyle = .rounded
    resetButton.target = self
    resetButton.action = #selector(resetPressed)
    resetButton.sizeToFit()
    resetButton.frame = NSRect(x: 16, y: 12, width: resetButton.frame.width + 8, height: 32)
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.target = self
    doneButton.action = #selector(donePressed)
    doneButton.frame = NSRect(x: 380 - 16 - 84, y: 12, width: 84, height: 32)
    for view in [intro, recorder, message, resetButton, doneButton] { content.addSubview(view) }
    recorder.shortcut = shortcuts.current
    recorder.onStart = { [weak self] in
      self?.shortcuts.suspend()
      self?.say(nil)
    }
    recorder.onStop = { [weak self] in self?.shortcuts.resume() }
    recorder.onRecord = { [weak self] in self?.apply($0) }
    recorder.onUnusable = { [weak self] in self?.say("That key can’t be used in a shortcut.", .systemRed) }
    if !shortcuts.registered {
      say("\(shortcuts.current.display) isn’t registered right now. Choose another combination.", .systemRed)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  func present() {
    recorder.shortcut = shortcuts.current
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    recorder.start()
  }

  private func apply(_ shortcut: PanelShortcut) {
    switch shortcuts.change(to: shortcut) {
    case .set(let warning):
      recorder.shortcut = shortcut
      recorder.stop()
      if let warning {
        say("Saved. " + warning, .systemOrange)
      } else {
        say("Saved. \(shortcut.display) shows and hides the panel.", .secondaryLabelColor)
      }
    case .rejected(let why):
      say(why, .systemRed)
    case .failed(let why):
      recorder.shortcut = shortcuts.current
      say(why, .systemRed)
    }
  }

  /// The message under the field, or none.
  private func say(_ text: String?, _ color: NSColor = .secondaryLabelColor) {
    message.stringValue = text ?? ""
    message.textColor = color
  }

  @objc func resetPressed() {
    recorder.stop()
    apply(shortcuts.standard)
  }

  @objc func donePressed() { window?.performClose(nil) }

  func windowWillClose(_ notification: Notification) {
    recorder.stop()
    shortcuts.resume()
  }
}
