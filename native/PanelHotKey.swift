import Carbon
import Foundation

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission. The default is ⌥Space.
final class PanelHotKey {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void
  private(set) var status: OSStatus = noErr

  init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
    _ action: @escaping () -> Void)
  {
    self.action = action
    var pressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<PanelHotKey>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { hotKey.action() }
        return noErr
      }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else { return }
    // 'FNGR'
    let id = EventHotKeyID(signature: OSType(0x464E_4752), id: 1)
    status = RegisterEventHotKey(
      keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
  }

  var registered: Bool { hotKey != nil && status == noErr }

  deinit {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
  }
}
