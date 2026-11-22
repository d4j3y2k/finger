import AppKit
import UniformTypeIdentifiers

/// One file or folder the summonable panel can list. Identity is the path.
struct PanelFile: Equatable {
  let path: String
  /// A folder you can step into. Packages such as apps count as files.
  let isFolder: Bool
  var lastUsed: Date?
  var modified: Date?
  var size: Int64?
  var added: Date?

  init(
    path: String, isFolder: Bool, lastUsed: Date? = nil, modified: Date? = nil, size: Int64? = nil,
    added: Date? = nil
  ) {
    self.path = path
    self.isFolder = isFolder
    self.lastUsed = lastUsed
    self.modified = modified
    self.size = size
    self.added = added
  }

  init(entry: Entry) {
    self.init(
      path: entry.path, isFolder: entry.isDirectory && !PanelFile.isPackage(entry.name),
      modified: entry.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      size: entry.isDirectory ? nil : entry.size)
  }

  var name: String { (path as NSString).lastPathComponent }
  var parent: String { (path as NSString).deletingLastPathComponent }
  var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }

  /// A directory the Finder shows as one document, such as an app or a Numbers file.
  static func isPackage(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else {
      return false
    }
    return type.conforms(to: .package)
  }

  /// Reads what the panel shows for a path. Call it off the main thread.
  static func inspect(_ path: String) -> PanelFile? {
    let url = URL(fileURLWithPath: path)
    guard
      let values = try? url.resourceValues(forKeys: [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
        .addedToDirectoryDateKey,
      ])
    else { return nil }
    let directory = values.isDirectory == true
    return PanelFile(
      path: path, isFolder: directory && values.isPackage != true,
      modified: values.contentModificationDate,
      size: directory ? nil : values.fileSize.map(Int64.init), added: values.addedToDirectoryDate)
  }
}

/// Matches what you typed against a name: the start of the name first, then
/// the start of a word, then anywhere.
enum PanelMatch {
  static let none = 0, contains = 1, wordStart = 2, prefix = 3

  private static let options: NSString.CompareOptions = [
    .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
  ]
  private static let separators = CharacterSet(charactersIn: " ._-()[]{}+,/&")
  private static let lower = CharacterSet.lowercaseLetters
  private static let upper = CharacterSet.uppercaseLetters

  /// The best place `query` appears in `name`, with its rank. Nil when it does not appear.
  static func find(_ query: String, in name: String) -> (rank: Int, range: NSRange)? {
    guard !query.isEmpty else { return nil }
    let text = name as NSString
    var from = 0
    var first: NSRange?
    while from < text.length {
      let found = text.range(
        of: query, options: options, range: NSRange(location: from, length: text.length - from))
      if found.location == NSNotFound { break }
      if found.location == 0 { return (prefix, found) }
      if startsWord(text, at: found.location) { return (wordStart, found) }
      if first == nil { first = found }
      from = found.location + 1
    }
    return first.map { (contains, $0) }
  }

  static func rank(_ query: String, in name: String) -> Int { find(query, in: name)?.rank ?? none }

  private static func scalar(_ text: NSString, _ i: Int) -> Unicode.Scalar? {
    Unicode.Scalar(text.character(at: i))
  }

  static func startsWord(_ text: NSString, at i: Int) -> Bool {
    guard i > 0 else { return true }
    guard let previous = scalar(text, i - 1) else { return false }
    if separators.contains(previous) || CharacterSet.whitespaces.contains(previous) { return true }
    // camelCase: PreviewPane matches "pane" at a word start.
    if let current = scalar(text, i), lower.contains(previous), upper.contains(current) {
      return true
    }
    return false
  }

  /// Orders global search hits. Match quality decides first: a prefix match
  /// always ranks above a word-start match, which ranks above a contains
  /// match. Within a tier, folders, recent use, an exact name and a shallow
  /// path rank higher, and build output lower.
  static func score(
    _ file: PanelFile, rank: Int, query: String, home: String, now: Date = Date()
  ) -> Double {
    var bonus: Double = 0
    if file.isFolder { bonus += 20 }
    if let used = file.lastUsed {
      let age = now.timeIntervalSince(used)
      bonus += age < 3600 ? 40 : age < 86_400 ? 30 : age < 7 * 86_400 ? 20 : age < 30 * 86_400 ? 10 : 4
    }
    let name = file.name.lowercased()
    let typed = query.lowercased()
    if typed.count >= 3, name == typed || (name as NSString).deletingPathExtension == typed {
      bonus += 25
    }
    let below =
      file.path.hasPrefix(home + "/")
      ? file.path.dropFirst(home.count + 1).split(separator: "/").count : 12
    bonus -= Double(min(36, max(0, below - 1) * 3))
    if buried(file.path) { bonus -= 40 }
    return Double(rank) * 1000 + bonus
  }

  // Build output and vendored code: shown, but after everything else in its tier.
  private static let buriedFolders: Set<Substring> = [
    "build", "target", "dist", "out", "vendor", "registry", "deps", "Pods", "obj", "tmp",
    "toolchain", "toolchains",
  ]

  static func buried(_ path: String) -> Bool {
    path.split(separator: "/").dropLast().contains { buriedFolders.contains($0) }
  }
}

/// How the panel words places, times and sizes.
enum PanelText {
  static func ago(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) hr ago" }
    if seconds < 2 * 86_400 { return "Yesterday" }
    if seconds < 30 * 86_400 { return "\(Int(seconds / 86_400)) days ago" }
    let calendar = Calendar.current
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    return (sameYear ? shortDate : longDate).string(from: date)
  }

  private static let shortDate: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMM d")
    return f
  }()
  private static let longDate: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return f
  }()

  static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

  static func size(_ bytes: Int64?) -> String {
    guard let bytes else { return "" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// The same kind names as the file preview's header, so a row and its preview agree.
  static func kind(_ file: PanelFile) -> String {
    file.isFolder ? "Folder" : ContentPreviewReader.kind(of: URL(fileURLWithPath: file.path))
  }

  /// "Kind · Size" for a file row inside a folder.
  static func details(_ file: PanelFile) -> String {
    let size = size(file.size)
    return size.isEmpty ? kind(file) : kind(file) + " · " + size
  }
}

/// The folders the panel can be in, and how their chips read. Levels start
/// below Home; Home itself is only a chip when you are in it.
struct PanelPlace {
  let home: String

  func name(_ folder: String) -> String {
    if folder == home { return "Home" }
    if folder == "/" { return FileManager.default.displayName(atPath: "/") }
    return (folder as NSString).lastPathComponent
  }

  /// Every level of `folder`, outermost first.
  func levels(_ folder: String) -> [String] {
    if folder == home || folder == "/" { return [folder] }
    let base = folder.hasPrefix(home + "/") ? home : ""
    var path = base
    return folder.dropFirst(base.count).split(separator: "/").map {
      path += "/" + $0
      return path
    }
  }

  /// The folder ⌫ goes up to, or nil when going up leaves browsing.
  func parent(_ folder: String) -> String? {
    if folder == home || folder == "/" { return nil }
    return (folder as NSString).deletingLastPathComponent
  }

  /// The level of `folder` directly inside `ancestor`.
  func child(of ancestor: String, toward folder: String) -> String? {
    let prefix = ancestor == "/" ? "/" : ancestor + "/"
    guard folder.hasPrefix(prefix) else { return nil }
    guard let first = folder.dropFirst(prefix.count).split(separator: "/").first else { return nil }
    return prefix + first
  }

  /// Where an item lives, as crumbs: "Developer › finger".
  func whereText(_ path: String) -> String {
    folderText((path as NSString).deletingLastPathComponent)
  }

  func folderText(_ folder: String) -> String {
    if folder == home { return "Home" }
    var parts: [String]
    if folder.hasPrefix(home + "/") {
      parts = folder.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    } else {
      parts = folder.split(separator: "/").map(String.init)
      if parts.isEmpty { return name("/") }
    }
    if parts.count > 3 { parts = [parts[0], "…"] + parts.suffix(2) }
    return parts.joined(separator: " › ")
  }

  /// Where a deeper result lives, relative to the folder you are in.
  func relativeText(_ path: String, in folder: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    guard parent.hasPrefix(folder + "/") else { return name(parent) }
    var parts = parent.dropFirst(folder.count + 1).split(separator: "/").map(String.init)
    if parts.count > 3 { parts = [parts[0], "…"] + parts.suffix(2) }
    return parts.joined(separator: " › ")
  }

  /// "~/Developer/finger" for the footer.
  func abbreviated(_ folder: String) -> String {
    if folder == home { return "~" }
    if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
    return folder
  }
}

/// A row in the results list.
struct PanelItem {
  enum Origin { case home, search, inside, here, deeper }
  var file: PanelFile
  var origin: Origin
  /// The second line. Nil means "kind · size" or the item count, worked out when drawn.
  var subtitle: String?
  /// The time or count on the right. Nil means when it was last touched, worked out when drawn.
  var side: String?
  /// The text that found this file by its contents.
  var match: String?
  var highlight: NSRange?
  /// Jev's probability for a folder in the move list.
  var probability: Double? = nil
}

struct PanelSection {
  var title: String
  var aside: String = ""
  var items: [PanelItem]
}

enum PanelRow {
  case header(PanelSection)
  case item(PanelItem)

  var item: PanelItem? {
    if case .item(let item) = self { return item }
    return nil
  }
}
