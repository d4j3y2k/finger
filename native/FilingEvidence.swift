import CoreServices
import Foundation

/// Where filing looks on this Mac. The app asks Spotlight; checks use a fixture.
/// Every call runs on a background queue and may take a moment.
protocol FilingEvidenceSource: AnyObject {
  /// Files below home, outside `excluding`, whose download came from `host`.
  func files(from host: String, excluding: String) -> [String]
  /// Files below home, outside `excluding`, whose names start with `stem` and end in `.ext`.
  func files(named stem: String, ext: String, excluding: String) -> [String]
  /// Files used recently below home, newest first.
  func recentlyUsed() -> [(path: String, used: Date)]
}

/// Synchronous Spotlight queries, each bounded in size.
final class SpotlightFilingEvidence: FilingEvidenceSource {
  let home: String
  init(home: String = NSHomeDirectory()) { self.home = home }

  private var scopes: [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
    return names.filter { !$0.hasPrefix(".") && $0 != "Library" }.map { home + "/" + $0 }
  }

  private func run(_ text: String, limit: Int, used: Bool = false) -> [(String, Date?)] {
    guard
      let query = MDQueryCreate(
        kCFAllocatorDefault, text as CFString, [kMDItemPath, kMDItemLastUsedDate] as CFArray, nil)
    else { return [] }
    MDQuerySetSearchScope(query, scopes as CFArray, 0)
    MDQuerySetMaxCount(query, limit)
    guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
    var out: [(String, Date?)] = []
    for index in 0..<MDQueryGetResultCount(query) {
      guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
      let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
      guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
      let date = used ? MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date : nil
      out.append((path, date))
    }
    return out
  }

  private func outside(_ path: String, _ excluding: String) -> Bool {
    !(path == excluding || path.hasPrefix(excluding + "/"))
      && !SpotlightSearch.isNoise(path, below: home, home: home)
  }

  func files(from host: String, excluding: String) -> [String] {
    let text = "kMDItemWhereFroms == \"*\(SpotlightSearch.literal(host))*\"cd"
    return run(text, limit: 200).map(\.0).filter { outside($0, excluding) }
  }

  func files(named stem: String, ext: String, excluding: String) -> [String] {
    var text = "kMDItemFSName == \"\(SpotlightSearch.literal(stem))*\"cd"
    if !ext.isEmpty { text += " && kMDItemFSName == \"*.\(SpotlightSearch.literal(ext))\"cd" }
    return run(text, limit: 200).map(\.0).filter { outside($0, excluding) }
  }

  func recentlyUsed() -> [(path: String, used: Date)] {
    run("kMDItemLastUsedDate >= $time.today(-14)", limit: 400, used: true)
      .compactMap { path, used in used.map { (path, $0) } }
      .filter { !SpotlightSearch.isNoise($0.path, below: home, home: home) }
      .sorted { $0.used > $1.used }
  }
}

/// Where filing keeps what it remembers between launches: the app's
/// UserDefaults, or an in-memory store in checks, which then create no
/// preference domains.
protocol FilingPreferences: AnyObject {
  func data(forKey key: String) -> Data?
  func stringArray(forKey key: String) -> [String]?
  func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: FilingPreferences {}

/// Where Finger has filed things, so the next suggestion can follow. It holds
/// names, websites and folders, stays on this Mac and is never sent.
final class FilingMemory {
  struct Entry: Codable, Equatable {
    let name: String
    let host: String?
    let folder: String
    let date: Date
  }

  static let shared = FilingMemory(preferences: UserDefaults.standard)
  private let preferences: FilingPreferences
  private let key: String
  private let lock = NSLock()
  private let limit = 300

  init(preferences: FilingPreferences, key: String = "filingMemory") {
    self.preferences = preferences
    self.key = key
  }

  var entries: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    guard let data = preferences.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  func remember(name: String, host: String?, folder: String, at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    var list = preferences.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    list.insert(Entry(name: name, host: host, folder: folder, date: date), at: 0)
    if list.count > limit { list.removeLast(list.count - limit) }
    if let data = try? JSONEncoder().encode(list) { preferences.set(data, forKey: key) }
  }

  /// The browser's moves, source → destination. Reads where each came from off the main thread.
  func remember(moves: [String: String]) {
    guard !moves.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
      for (_, destination) in moves {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isFolder), !isFolder.boolValue
        else { continue }
        self.remember(
          name: (destination as NSString).lastPathComponent,
          host: FilingArrivals.sourceHost(destination),
          folder: (destination as NSString).deletingLastPathComponent)
      }
    }
  }
}

/// Local candidates for one file, ranked by what Finger saw on this Mac.
struct FilingGathered: Equatable {
  let file: String
  let host: String?
  /// Most likely first. The first ten are what Jev hears about.
  let candidates: [FilingCandidate]
  /// The project you used most recently, for the move list.
  let project: String?

  func evidence(for folder: String) -> FilingEvidence? {
    candidates.first { $0.folder == folder }?.evidence
  }
}

/// Gathers and scores candidate folders. Pure apart from reading folders, so
/// checks can drive it with a fixture.
enum FilingGather {
  struct Input {
    var file: String
    var host: String?
    var home: String
    var hostFiles: [String] = []
    var similarFiles: [String] = []
    var memory: [FilingMemory.Entry] = []
    var recent: [(path: String, used: Date)] = []
    var recentDestinations: [String] = []
    var now = Date()
  }

  /// The project a path belongs to: two levels below home ("Studio/Fold Studies"),
  /// or one level for a folder directly in home.
  static func project(of path: String, home: String) -> String? {
    guard path.hasPrefix(home + "/") else { return nil }
    let parts = path.dropFirst(home.count + 1).split(separator: "/")
    guard let first = parts.first, first != "Library", first != "Downloads", !first.hasPrefix(".") else {
      return nil
    }
    let depth = min(2, parts.count)
    return home + "/" + parts.prefix(depth).joined(separator: "/")
  }

  /// Visible subfolders, not packages.
  /// Paths keep the spelling they were given: URL listings can turn /private/var into /var.
  static func subfolders(_ folder: String, limit: Int = 40) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    let prefix = folder == "/" ? "/" : folder + "/"
    return names.filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { prefix + $0 }
      .filter { path in
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey])
        return values?.isDirectory == true && values?.isPackage != true && values?.isHidden != true
      }
      .prefix(limit).map { $0 }
  }

  static func isFolder(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
      && !PanelFile.isPackage((path as NSString).lastPathComponent)
  }

  static func gather(_ input: Input) -> FilingGathered {
    let home = input.home
    let name = (input.file as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    let stem = FilingText.stem(name)
    let parent = (input.file as NSString).deletingLastPathComponent
    let downloads = home + "/Downloads"
    var evidence: [String: FilingEvidence] = [:]
    var order: [String] = []
    func touch(_ folder: String, _ change: (inout FilingEvidence) -> Void) {
      guard folder != parent, folder.hasPrefix(home), folder != downloads,
        !folder.hasPrefix(downloads + "/"), !(folder + "/").hasPrefix(input.file + "/"),
        !folder.hasPrefix(home + "/Library")
      else { return }
      if evidence[folder] == nil {
        evidence[folder] = FilingEvidence()
        order.append(folder)
      }
      change(&evidence[folder]!)
    }
    if input.host != nil {
      for path in input.hostFiles where path != input.file {
        touch((path as NSString).deletingLastPathComponent) {
          $0.sameHost.append((path as NSString).lastPathComponent)
        }
      }
    }
    for entry in input.memory {
      let sameHost = input.host != nil && entry.host == input.host
      let sameStem = stem != nil && FilingText.stem(entry.name) == stem
      guard sameHost || sameStem, entry.name != name || entry.folder != parent else { continue }
      touch(entry.folder) { $0.filedBefore.append(entry.name) }
    }
    for path in input.similarFiles where path != input.file {
      touch((path as NSString).deletingLastPathComponent) {
        $0.similarNames.append((path as NSString).lastPathComponent)
      }
    }
    // Recently used projects: the project and its folders.
    var projects: [(path: String, used: Date)] = []
    for hit in input.recent {
      guard let root = project(of: hit.path, home: home), !projects.contains(where: { $0.path == root })
      else { continue }
      projects.append((root, hit.used))
      if projects.count == 3 { break }
    }
    for (root, used) in projects where isFolder(root) {
      let title = (root as NSString).lastPathComponent
      for folder in [root] + subfolders(root) {
        touch(folder) {
          $0.project = title
          $0.projectUsed = max(used, $0.projectUsed ?? .distantPast)
        }
      }
    }
    for folder in input.recentDestinations.prefix(12) { touch(folder) { $0.recentDestination = true } }
    for folder in [home + "/Desktop", home + "/Documents"] { touch(folder) { _ in } }
    // Keep real folders only, then count files of the same kind in each.
    var candidates: [FilingCandidate] = []
    for folder in order where isFolder(folder) {
      var e = evidence[folder]!
      if !ext.isEmpty {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        e.sameKind = names.filter {
          !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == ext && $0 != name
        }.count
      }
      candidates.append(FilingCandidate(folder: folder, evidence: e, score: score(e, now: input.now)))
    }
    // DestinationRanker's local order breaks ties and nudges close calls.
    let local = DestinationRanker.ranked(
      sources: [URL(fileURLWithPath: input.file)], candidates: candidates.map { URL(fileURLWithPath: $0.folder) },
      recent: input.recentDestinations.map { URL(fileURLWithPath: $0, isDirectory: true) })
    let place = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($0.element.path, $0.offset) })
    for index in candidates.indices {
      let rank = place[candidates[index].folder] ?? local.count
      candidates[index].score += Double(max(0, 8 - rank))
    }
    candidates.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      return (place[$0.folder] ?? .max) < (place[$1.folder] ?? .max)
    }
    let project = projects.first?.path
    return FilingGathered(file: input.file, host: input.host, candidates: candidates, project: project)
  }

  static func score(_ e: FilingEvidence, now: Date) -> Double {
    var s = 0.0
    s += 30 * Double(min(3, e.sameHost.count))
    s += 25 * Double(min(3, e.filedBefore.count))
    s += 12 * Double(min(3, e.similarNames.count))
    if e.sameKind > 0 { s += 6 + Double(min(5, e.sameKind)) }
    if let used = e.projectUsed {
      let age = now.timeIntervalSince(used)
      s += age < 86_400 ? 15 : age < 7 * 86_400 ? 8 : 3
    }
    if e.recentDestination { s += 6 }
    return s
  }
}
