import Foundation

/// Capture the previous visit before starting a scan. Refreshes of the same
/// screen can reuse this snapshot while the next visit sees the new baseline.
struct ResumeHistory {
  private let defaults: FingerPreferences
  fileprivate let visits: [String: Double]
  fileprivate let uses: [String: Double]
  private static let visitKey = "resumeProjectVisits"
  private static let useKey = "resumeFileUses"
  private static let lock = NSLock()

  init(defaults: FingerPreferences = UserDefaults.standard) {
    self.defaults = defaults
    visits = defaults.dictionary(forKey: Self.visitKey) as? [String: Double] ?? [:]
    uses = defaults.dictionary(forKey: Self.useKey) as? [String: Double] ?? [:]
  }

  func markVisit(project: String, at date: Date = Date()) {
    save([project], date: date, key: Self.visitKey, limit: 40)
  }

  func recordUse(_ entries: [Entry]) {
    save(
      entries.lazy.filter { !$0.isDirectory }.prefix(64).map(\.path), date: Date(),
      key: Self.useKey, limit: 128)
  }

  private func save(_ paths: [String], date: Date, key: String, limit: Int) {
    guard !paths.isEmpty else { return }
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var values = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    for path in paths {
      let canonical = FolderReferences.key(path)
      values[canonical] = max(values[canonical] ?? -.infinity, date.timeIntervalSince1970)
    }
    if values.count > limit {
      let sorted = values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      values = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.key, $0.value) })
    }
    defaults.set(values, forKey: key)
  }
}

struct ResumeGroup {
  let primary: Entry
  let related: [Entry]
  let reason: String
  let relativeFolder: String
  let changed: Bool

  var files: [Entry] { [primary] + related }
}

struct ResumeCatalog {
  let groups: [ResumeGroup]
  private let root: URL

  /// A bounded metadata scan. Prioritize recently visited project folders so
  /// navigation still supplies context in projects larger than the scan budget.
  static func scan(
    project: String, recentFolders: [String] = [],
    history: ResumeHistory = ResumeHistory(),
    cancelled: () -> Bool = { false }
  ) throws -> ResumeCatalog {
    let root = URL(fileURLWithPath: project, isDirectory: true)
    let rootKey = FolderReferences.key(root.path)
    let rootPrefix = rootKey == "/" ? "/" : rootKey + "/"
    let recent = FolderReferences.unique(recentFolders, limit: 15).map(FolderReferences.key)
      .filter { $0 == rootKey || $0.hasPrefix(rootPrefix) }
    let files = try scanFiles(under: root, recent: recent, cancelled: cancelled)
    let now = Date().timeIntervalSince1970
    let ranked = bundles(files).map {
      recommendation($0, root: root, recent: recent, history: history, now: now)
    }.sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.modified != $1.modified { return $0.modified > $1.modified }
      return $0.group.primary.path < $1.group.primary.path
    }
    return ResumeCatalog(groups: ranked.map(\.group), root: root)
  }

  func matching(_ query: String, limit: Int = 4) -> [ResumeGroup] {
    guard limit > 0 else { return [] }
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return Array(groups.prefix(limit)) }
    var matches: [ResumeGroup] = []
    for group in groups {
      let files = group.files
      guard
        let match = files.first(where: { file in
          let path = Self.relativePath(file.url, under: root)
          return terms.allSatisfy { path.localizedStandardContains($0) }
        })
      else { continue }
      matches.append(
        ResumeGroup(
          primary: match, related: files.filter { $0.path != match.path },
          reason: group.reason,
          relativeFolder: Self.folder(of: match, under: root),
          changed: group.changed))
      if matches.count == limit { break }
    }
    return matches
  }

  private struct File {
    let entry: Entry
    let modified: Double
    var folder: String { (entry.path as NSString).deletingLastPathComponent }
  }

  private static let ignoredFolders: Set<String> = [
    "node_modules", "target", "build", "DerivedData", "__pycache__", "Pods", "vendor",
  ]
  private static let sourceFolders: Set<String> = ["source", "sources", "originals", "editable"]
  private static let exportFolders: Set<String> = [
    "export", "exports", "output", "outputs", "delivery", "renders",
  ]
  private static let archives: Set<Substring> = [
    "old", "previous", "archive", "archives", "archived", "backup", "backups",
  ]
  private static let imageSources: Set<String> = [
    "svg", "ai", "psd", "afdesign", "afphoto", "sketch", "fig", "indd", "kra",
  ]
  private static let imageExports: Set<String> = [
    "png", "jpg", "jpeg", "tif", "tiff", "webp", "heic", "gif", "pdf",
  ]
  private static let documentSources: Set<String> = [
    "doc", "docx", "pages", "odt", "key", "pptx", "tex", "md",
  ]
  private static let outputPriority = [
    "png", "pdf", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "gif",
  ]

  private static func scanFiles(
    under root: URL, recent: [String],
    cancelled: () -> Bool
  ) throws -> [File] {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
      .contentModificationDateKey, .fileSizeKey,
    ]
    guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: root.path])
    }
    let manager = FileManager.default
    let broadRoot = ["/", NSHomeDirectory(), "/Users", "/Volumes"].contains(root.path)
    let rootKey = FolderReferences.key(root.path)
    let canonicalRoot = FolderReferences.key(root.resolvingSymlinksInPath().path)
    var pending: [(url: URL, depth: Int)] = []
    // Keep the root's spelling on all results (notably /var versus /private/var).
    for path in recent where path != rootKey {
      let suffix = String(path.dropFirst(rootKey.count)).trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
      let pieces = suffix.split(separator: "/")
      guard !pieces.contains(where: { $0.hasPrefix(".") || ignoredFolders.contains(String($0)) })
      else { continue }
      let folder = root.appendingPathComponent(suffix, isDirectory: true)
      let resolved = FolderReferences.key(folder.resolvingSymlinksInPath().path)
      guard resolved == (canonicalRoot as NSString).appendingPathComponent(suffix) else { continue }
      pending.append((folder, pieces.count))
    }
    pending.append((root, 0))
    var visited = Set<String>()
    var cursor = 0
    var inspected = 0
    var files: [File] = []
    while cursor < pending.count, visited.count < 120, inspected < 3_000 {
      if cancelled() { throw CancellationError() }
      let (folder, depth) = pending[cursor]
      cursor += 1
      guard visited.insert(folder.path).inserted else { continue }
      var error: Error?
      guard
        let iterator = manager.enumerator(
          at: folder, includingPropertiesForKeys: Array(keys),
          options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, failure in
            error = failure
            return false
          })
      else {
        if folder == root {
          throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: root.path])
        }
        continue
      }
      var children: [URL] = []
      for case let url as URL in iterator {
        if cancelled() { throw CancellationError() }
        inspected += 1
        guard inspected <= 3_000 else { break }
        guard let info = try? url.resourceValues(forKeys: keys), info.isSymbolicLink != true else {
          continue
        }
        if info.isDirectory == true {
          if depth < 4, !broadRoot, info.isPackage != true,
            !ignoredFolders.contains(url.lastPathComponent)
          {
            children.append(folder.appendingPathComponent(url.lastPathComponent, isDirectory: true))
          }
        } else if info.isRegularFile == true {
          let stamp = info.contentModificationDate?.timeIntervalSince1970
          let path = folder.appendingPathComponent(url.lastPathComponent, isDirectory: false).path
          let entry = Entry(
            name: url.lastPathComponent, path: path, kind: "file", isDirectory: false,
            size: info.fileSize.map(Int64.init), modified: stamp.map(Int64.init))
          files.append(File(entry: entry, modified: stamp ?? 0))
        }
      }
      if let error, folder == root { throw error }
      for child in children.sorted(by: { $0.path < $1.path }) {
        pending.append((child, depth + 1))
      }
    }
    return files
  }

  private struct BundleKey: Hashable {
    let stem: String
    let folder: String
  }

  private static func bundles(_ files: [File]) -> [[File]] {
    let buckets = Dictionary(grouping: files) { file -> BundleKey in
      let folder = file.folder as NSString
      let name = folder.lastPathComponent.lowercased()
      let scope =
        sourceFolders.contains(name) || exportFolders.contains(name)
        ? folder.deletingLastPathComponent : file.folder
      return BundleKey(
        stem: (file.entry.name as NSString).deletingPathExtension.lowercased(), folder: scope)
    }
    return buckets.values.flatMap { bucket -> [[File]] in
      // Duplicate extensions in different locations are ambiguous. Keep those
      // folders independent instead of pairing one source with the wrong proof.
      if Set(bucket.map { $0.entry.ext }).count != bucket.count {
        return Dictionary(grouping: bucket, by: \.folder).values.flatMap(pair)
      }
      return pair(bucket)
    }
  }

  private static func pair(_ files: [File]) -> [[File]] {
    guard files.count > 1 else { return [files] }
    let sources = files.filter {
      imageSources.contains($0.entry.ext) || documentSources.contains($0.entry.ext)
    }
    guard sources.count == 1, let source = sources.first else { return files.map { [$0] } }
    let supported = imageSources.contains(source.entry.ext) ? imageExports : ["pdf"]
    let exports = files.filter { supported.contains($0.entry.ext) }
      .sorted {
        if $0.modified != $1.modified { return $0.modified > $1.modified }
        return (outputPriority.firstIndex(of: $0.entry.ext) ?? Int.max)
          < (outputPriority.firstIndex(of: $1.entry.ext) ?? Int.max)
      }
    guard let first = exports.first else { return files.map { [$0] } }
    let members = [first, source] + Array(exports.dropFirst())
    let paths = Set(members.map { $0.entry.path })
    return [members] + files.filter { !paths.contains($0.entry.path) }.map { [$0] }
  }

  private static func relativePath(_ url: URL, under root: URL) -> String {
    let prefix = root.path == "/" ? "/" : root.path + "/"
    return url.path.hasPrefix(prefix)
      ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
  }

  private static func folder(of file: Entry, under root: URL) -> String {
    let relative = (relativePath(file.url, under: root) as NSString).deletingLastPathComponent
    return relative.isEmpty ? root.lastPathComponent : relative
  }

  private static func recommendation(
    _ files: [File], root: URL, recent: [String],
    history: ResumeHistory, now: Double
  )
    -> (group: ResumeGroup, score: Double, modified: Double)
  {
    let primary = files[0]
    let modified = files.map(\.modified).max() ?? 0
    let previous = history.visits[FolderReferences.key(root.path)]
    let changed = previous.map { modified > $0 } ?? false
    let lastUse = files.compactMap { history.uses[FolderReferences.key($0.entry.path)] }.max()
    let recentFolder = files.compactMap { recent.firstIndex(of: FolderReferences.key($0.folder)) }
      .min()
    let relativeFolder = folder(of: primary.entry, under: root)
    let components = relativeFolder.lowercased().split { !$0.isLetter && !$0.isNumber }
    let archived = !archives.isDisjoint(with: components)
    let paired = files.count > 1
    let newerExport = paired && primary.modified > files[1].modified
    let isExport =
      paired
      || (imageExports.contains(primary.entry.ext)
        && exportFolders.contains((primary.folder as NSString).lastPathComponent.lowercased()))

    // Half-lives keep last year's edits or interactions from dominating new work.
    func freshness(_ stamp: Double, days: Double) -> Double {
      pow(0.5, max(0, now - stamp) / (days * 86_400))
    }
    var score = 20 * freshness(modified, days: 5)
    score += paired ? 19 : 0
    score += imageExports.contains(primary.entry.ext) ? 3 : 0
    score += changed ? 31 : 0
    score += archived ? -25 : 0
    if let lastUse { score += 46 * freshness(lastUse, days: 7) }
    if let recentFolder { score += Double(10 - min(10, recentFolder)) }
    let reason: String
    if changed, isExport, let previous, primary.modified > previous {
      reason = "Export updated since your last visit"
    } else if changed {
      reason = "Changed since your last visit"
    } else if let lastUse, now - lastUse < 7 * 86_400 {
      reason = "Recently used in Finger"
    } else if archived {
      reason = "In an archived folder"
    } else if newerExport {
      reason = "Export is newer than its source"
    } else if paired {
      reason = "Matching source and export"
    } else if recentFolder != nil {
      reason = "In a recently visited folder"
    } else if modified > 0, now - modified < 7 * 86_400 {
      reason = "Modified recently"
    } else {
      reason = "From this project"
    }
    let group = ResumeGroup(
      primary: primary.entry, related: files.dropFirst().map(\.entry), reason: reason,
      relativeFolder: relativeFolder, changed: changed)
    return (group, score, modified)
  }
}
