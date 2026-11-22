import Foundation

/// What Finger remembers between launches. The app uses UserDefaults.standard;
/// checks pass a FingerMemoryPreferences, so they never create preference
/// domains in ~/Library/Preferences. (Filing has its own FilingPreferences.)
protocol FingerPreferences: AnyObject {
  func object(forKey key: String) -> Any?
  func set(_ value: Any?, forKey key: String)
  func removeObject(forKey key: String)
}

extension FingerPreferences {
  func string(forKey key: String) -> String? { object(forKey: key) as? String }
  func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
}

extension UserDefaults: FingerPreferences {}

/// Preferences that last as long as the object. Several "launches" in a check
/// share one to read back what an earlier one saved.
final class FingerMemoryPreferences: FingerPreferences {
  private var values: [String: Any]
  private let lock = NSLock()

  init(_ values: [String: Any] = [:]) { self.values = values }

  func object(forKey key: String) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func set(_ value: Any?, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
  }

  func removeObject(forKey key: String) { set(nil, forKey: key) }
}
