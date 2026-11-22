import AppKit
import Security

/// Where the TypeSafe key is kept. The app uses the login Keychain; checks use
/// a fake so they never touch a real key.
protocol FilingSecretStore: AnyObject {
  func read() throws -> String?
  func save(_ secret: String) throws
  func remove() throws
}

/// A generic password with service "com.d4j3y2k.Finger.jev" in the login Keychain.
final class FilingKeychain: FilingSecretStore {
  static let service = "com.d4j3y2k.Finger.jev"
  let service: String
  let account = "TypeSafe API key"

  init(service: String = FilingKeychain.service) { self.service = service }

  struct Failure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
      let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
      return "The Keychain couldn’t do that: \(text)"
    }
  }

  func read() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = found as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func save(_ secret: String) throws {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    let data = Data(secret.utf8)
    let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw Failure(status: update) }
    var add = match
    add[kSecAttrAccount as String] = account
    add[kSecAttrLabel as String] = "Finger · Jev API Key"
    add[kSecAttrDescription as String] = "TypeSafe API key"
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  func remove() throws {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    let status = SecItemDelete(match as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
  }
}

/// The TypeSafe key for Jev: the Keychain first, then FINGER_JEV_API_KEY or
/// TYPESAFE_API_KEY. It lives only in memory and the Keychain; it is never
/// logged or written to a file.
final class FilingCredentials {
  enum Source: Equatable {
    case keychain
    case environment(String)
    case none
  }

  /// Posted on the main thread when the key is saved, removed or first read.
  static let changed = Notification.Name("FilingCredentials.changed")
  static let environmentNames = ["FINGER_JEV_API_KEY", "TYPESAFE_API_KEY"]

  let store: FilingSecretStore
  private let environment: [String: String]
  private let lock = NSLock()
  private var loaded: (key: String?, source: Source)?
  private(set) var lastError: String?

  init(store: FilingSecretStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.store = store
    self.environment = environment
  }

  /// Reads the Keychain the first time. The Keychain may ask the person for
  /// access, so call it off the main thread; `cachedSource` never blocks.
  var key: String? { resolve().key }
  var source: Source { resolve().source }
  var isConfigured: Bool { key != nil }

  /// What is known without reading the Keychain, or nil before the first read.
  var cachedSource: Source? {
    lock.lock()
    defer { lock.unlock() }
    return loaded?.source
  }

  /// Reads the key in the background, then posts `changed`.
  func load(on queue: DispatchQueue = .global(qos: .utility), _ done: (() -> Void)? = nil) {
    queue.async {
      _ = self.resolve()
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: FilingCredentials.changed, object: self)
        done?()
      }
    }
  }

  private func resolve() -> (key: String?, source: Source) {
    lock.lock()
    if let loaded {
      lock.unlock()
      return loaded
    }
    lock.unlock()
    var result: (key: String?, source: Source) = (nil, .none)
    do {
      if let stored = try store.read().map(FilingCredentials.clean), !stored.isEmpty {
        result = (stored, .keychain)
      }
    } catch {
      lastError = error.localizedDescription
    }
    if result.key == nil { result = fromEnvironment() }
    lock.lock()
    loaded = result
    lock.unlock()
    return result
  }

  private func fromEnvironment() -> (key: String?, source: Source) {
    for name in FilingCredentials.environmentNames {
      if let value = environment[name].map(FilingCredentials.clean), !value.isEmpty {
        return (value, .environment(name))
      }
    }
    return (nil, .none)
  }

  static func clean(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A pasted key: one token, no spaces inside.
  static func validate(_ text: String) -> String? {
    let key = clean(text)
    guard key.count >= 8, key.count <= 512, !key.contains(where: { $0.isWhitespace || $0.isNewline })
    else { return nil }
    return key
  }

  func save(_ text: String) throws {
    guard let key = FilingCredentials.validate(text) else {
      throw CoreError(message: "That doesn’t look like a TypeSafe API key.")
    }
    try store.save(key)
    lock.lock()
    loaded = (key, .keychain)
    lock.unlock()
    lastError = nil
    NotificationCenter.default.post(name: FilingCredentials.changed, object: self)
  }

  func remove() throws {
    try store.remove()
    lock.lock()
    loaded = fromEnvironment()
    lock.unlock()
    NotificationCenter.default.post(name: FilingCredentials.changed, object: self)
  }

  /// For the menu: whether Jev is on, and where its key came from.
  var statusText: String {
    switch cachedSource {
    case .keychain?: return "Jev is on · key in Keychain"
    case .environment(let name)?: return "Jev is on · key from \(name)"
    case .none?: return "Jev is off · no TypeSafe key"
    case nil: return "Jev · checking for a key…"
    }
  }
}

/// Finger › Jev API Key…: paste, save or remove the TypeSafe key.
final class FilingKeyWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
  let credentials: FilingCredentials
  let field = NSSecureTextField(frame: NSRect(x: 20, y: 98, width: 380, height: 24))
  let status = NSTextField(wrappingLabelWithString: "")
  let saveButton = NSButton(title: "Save", target: nil, action: nil)
  let removeButton = NSButton(title: "Remove Key", target: nil, action: nil)
  let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

  init(credentials: FilingCredentials) {
    self.credentials = credentials
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 236), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Jev API Key"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.contentView = content
    let intro = NSTextField(
      wrappingLabelWithString:
        "Jev suggests where new downloads belong. Paste a TypeSafe API key to turn it on. Finger keeps it in your login Keychain.")
    intro.font = .systemFont(ofSize: 12.5)
    intro.frame = NSRect(x: 20, y: 172, width: 380, height: 48)
    let privacy = NSTextField(
      wrappingLabelWithString:
        "Jev sees a download’s file name, the website it came from and folder names. Never file contents or full paths.")
    privacy.font = .systemFont(ofSize: 11)
    privacy.textColor = .secondaryLabelColor
    privacy.frame = NSRect(x: 20, y: 130, width: 380, height: 32)
    field.placeholderString = "Paste your TypeSafe API key"
    field.delegate = self
    field.setAccessibilityLabel("TypeSafe API key")
    status.font = .systemFont(ofSize: 11.5)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 20, y: 56, width: 380, height: 32)
    status.setAccessibilityIdentifier("jev-key-status")
    removeButton.bezelStyle = .rounded
    removeButton.target = self
    removeButton.action = #selector(removePressed)
    removeButton.frame = NSRect(x: 14, y: 12, width: 112, height: 32)
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.target = self
    cancelButton.action = #selector(cancelPressed)
    cancelButton.frame = NSRect(x: 420 - 14 - 84 - 88, y: 12, width: 88, height: 32)
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"
    saveButton.target = self
    saveButton.action = #selector(savePressed)
    saveButton.frame = NSRect(x: 420 - 14 - 84, y: 12, width: 84, height: 32)
    for view in [intro, privacy, field, status, removeButton, cancelButton, saveButton] {
      content.addSubview(view)
    }
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }

  func present() {
    field.stringValue = ""
    refresh()
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(field)
    NSApp.activate()
  }

  func refresh(message: String? = nil, error: Bool = false) {
    let source = credentials.cachedSource
    removeButton.isEnabled = source == .keychain
    saveButton.isEnabled = FilingCredentials.validate(field.stringValue) != nil
    status.textColor = error ? .systemRed : .secondaryLabelColor
    if let message {
      status.stringValue = message
      return
    }
    switch source {
    case .keychain?: status.stringValue = "A key is saved in your Keychain. Jev is on."
    case .environment(let name)?:
      status.stringValue = "Using \(name) from the environment. A key saved here takes its place."
    case .none?: status.stringValue = "Jev is off. Without a key the move list still ranks folders on this Mac."
    case nil: status.stringValue = ""
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    saveButton.isEnabled = FilingCredentials.validate(field.stringValue) != nil
  }

  @objc func savePressed() {
    let pasted = field.stringValue
    // Clear the field at once, whatever happens next.
    field.stringValue = ""
    do {
      try credentials.save(pasted)
      refresh(message: "Saved in your Keychain. Jev is on.")
      window?.performClose(nil)
    } catch {
      refresh(message: error.localizedDescription, error: true)
    }
  }

  @objc func removePressed() {
    do {
      try credentials.remove()
      refresh(message: credentials.cachedSource == FilingCredentials.Source.none ? "Removed. Jev is off." : "Removed from your Keychain.")
    } catch {
      refresh(message: error.localizedDescription, error: true)
    }
  }

  @objc func cancelPressed() {
    field.stringValue = ""
    window?.performClose(nil)
  }

  func windowWillClose(_ notification: Notification) { field.stringValue = "" }
}

/// The menu bar item's Jev entries: whether Jev is on, and Jev API Key….
final class FilingKeyMenu: NSObject {
  let credentials: FilingCredentials
  let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private(set) var item: CommandItem!
  private(set) var window: FilingKeyWindow?

  init(credentials: FilingCredentials) {
    self.credentials = credentials
    super.init()
    status.isEnabled = false
    item = CommandItem("Jev API Key…") { [weak self] in self?.showWindow() }
    NotificationCenter.default.addObserver(
      self, selector: #selector(credentialsChanged), name: FilingCredentials.changed, object: credentials)
    refresh()
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func credentialsChanged() { refresh() }

  func refresh() {
    status.title = credentials.statusText
    window?.refresh()
  }

  func showWindow() {
    if window == nil { window = FilingKeyWindow(credentials: credentials) }
    window?.present()
  }
}
