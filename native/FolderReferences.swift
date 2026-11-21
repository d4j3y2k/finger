import Foundation

/// Compare macOS's built-in root symlinks without resolving user-created paths.
/// Display, navigation and file operations retain the original spelling.
enum FolderReferences {
  private static let systemLinks = ["/tmp", "/var", "/etc"]

  static func key(_ path: String) -> String {
    guard path.hasPrefix("/") else { return path }
    var path = path
    while path.hasSuffix("/") && path != "/" { path.removeLast() }
    for link in systemLinks where path == link || path.hasPrefix(link + "/") {
      return "/private" + path
    }
    return path
  }

  static func components(_ url: URL) -> [String] { (key(url.path) as NSString).pathComponents }

  /// Input order is most-recent first, so the first spelling is kept.
  static func unique(_ paths: [String], limit: Int) -> [String] {
    guard limit > 0 else { return [] }
    var seen = Set<String>()
    var result: [String] = []
    for path in paths where seen.insert(key(path)).inserted {
      result.append(path)
      if result.count == limit { break }
    }
    return result
  }
}
