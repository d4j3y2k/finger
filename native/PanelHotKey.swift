import Carbon
import Foundation

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission. It can be re-registered live: a new shortcut
/// replaces the old one only once it has registered.
final class PanelHotKey {
  /// Undoes one registration.
  struct Registration {
    let unregister: () -> Void
  }
  typealias Register = (_ keyCode: UInt32, _ modifiers: UInt32, _ id: EventHotKeyID) -> (
    OSStatus, Registration?
  )

  static let carbon: Register = { keyCode, modifiers, id in
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else { return (status == noErr ? OSStatus(eventInternalErr) : status, nil) }
    return (noErr, Registration { UnregisterEventHotKey(ref) })
  }

  // 'FNGR'
  private static let signature = OSType(0x464E_4752)
  private static var nextID: UInt32 = 1
  private let registrar: Register
  private let action: () -> Void
  private var handler: EventHandlerRef?
  private var registration: Registration?
  private var id = EventHotKeyID(signature: PanelHotKey.signature, id: 0)
  private(set) var registered: PanelShortcut?

  init(register: @escaping Register = PanelHotKey.carbon, _ action: @escaping () -> Void) {
    self.registrar = register
    self.action = action
    var pressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<PanelHotKey>.fromOpaque(context).takeUnretainedValue()
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        // Each instance answers only for its own registration.
        guard status == noErr, pressed.signature == hotKey.id.signature, pressed.id == hotKey.id.id,
          hotKey.registration != nil
        else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { hotKey.action() }
        return noErr
      }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  /// Registers `shortcut` in place of the current one. If that fails, the
  /// current one stays registered and the Carbon status comes back.
  @discardableResult
  func register(_ shortcut: PanelShortcut) -> OSStatus {
    if shortcut == registered, registration != nil { return noErr }
    let next = EventHotKeyID(signature: PanelHotKey.signature, id: PanelHotKey.nextID)
    PanelHotKey.nextID += 1
    let (status, made) = registrar(shortcut.keyCode, shortcut.carbonModifiers, next)
    guard status == noErr, let made else { return status == noErr ? OSStatus(eventInternalErr) : status }
    registration?.unregister()
    registration = made
    id = next
    registered = shortcut
    return noErr
  }

  func unregister() {
    registration?.unregister()
    registration = nil
    registered = nil
  }

  deinit {
    registration?.unregister()
    if let handler { RemoveEventHandler(handler) }
  }
}
