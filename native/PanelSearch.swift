import Darwin
import Foundation

/// Stops a search that is still gathering. Its callback never runs afterwards.
protocol PanelSearchHandle: AnyObject {
  func cancel()
}

/// Where the panel's searches come from. The app uses Spotlight; the panel
/// checks inject a fixture so they do not depend on what Spotlight has indexed.
/// Every callback runs on the main thread.
protocol PanelSearching: AnyObject {
  /// Items used recently anywhere below `home`, newest first, with `lastUsed` set.
  func recentlyUsed(in home: String, _ done: @escaping ([PanelFile]) -> Void) -> PanelSearchHandle
  /// Items below `scope` whose names match `query`. `update` may run several
  /// times with everything found so far; the last call has `finished` true.
  func names(
    _ query: String, in scope: String,
    _ update: @escaping (_ files: [PanelFile], _ finished: Bool) -> Void
  ) -> PanelSearchHandle
  /// Items below `scope` whose text contains `query`.
  func contents(
    _ query: String, in scope: String,
    _ update: @escaping (_ files: [PanelFile], _ finished: Bool) -> Void
  ) -> PanelSearchHandle
}

extension PanelFile {
  /// One stat, following links. Enough for a search row; never reads the file.
  static func quick(_ path: String) -> PanelFile? {
    var info = stat()
    guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
    let directory = info.st_mode & S_IFMT == S_IFDIR
    let name = (path as NSString).lastPathComponent
    let modified =
      Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return PanelFile(
      path: path, isFolder: directory && !isPackage(name),
      modified: Date(timeIntervalSince1970: modified), size: directory ? nil : Int64(info.st_size))
  }
}

/// Spotlight-backed searches. Name matching across Home is word-indexed for
/// short queries and capped in time and size, so a one-letter query never
/// stalls; results arrive progressively.
final class SpotlightSearch: PanelSearching {
  private let work = DispatchQueue(label: "finger.panel.spotlight", qos: .userInitiated)
  private let home: String

  init(home: String = NSHomeDirectory()) { self.home = home }

  // Places Spotlight indexes that are never what you are looking for.
  private static let noiseFolders: Set<String> = [
    "node_modules", "DerivedData", "__pycache__", "Caches", "site-packages", "ModuleCache",
    "CMakeFiles",
  ]
  private static let opaqueExtensions: Set<String> = [
    "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary",
    "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace", "xcassets", "lproj", "pkg",
    "logarchive", "sparsebundle", "rtfd", "numbers", "pages", "key", "playground", "mlmodelc",
  ]

  static func isNoise(_ path: String, below scope: String, home: String) -> Bool {
    let prefix = scope == "/" ? "/" : scope + "/"
    guard path.hasPrefix(prefix) else { return true }
    let parts = path.dropFirst(prefix.count).split(separator: "/")
    guard let last = parts.last, !last.hasPrefix(".") else { return true }
    if scope == home, parts.first == "Library" { return true }
    for part in parts.dropLast() {
      if part.hasPrefix(".") || noiseFolders.contains(String(part)) { return true }
      let ext = (String(part) as NSString).pathExtension.lowercased()
      if !ext.isEmpty, opaqueExtensions.contains(ext) { return true }
    }
    return false
  }

  /// Escapes text for a Spotlight query string literal.
  static func literal(_ text: String) -> String {
    var out = ""
    for c in text {
      if c == "\"" || c == "\\" || c == "*" || c == "?" || c == "'" { out.append("\\") }
      out.append(c)
    }
    return out
  }

  /// The Spotlight queries for a name search, with how many results to read
  /// from each. Contains-matching scans every name, and one or two letters
  /// match tens of thousands, which Spotlight delivers in one late batch. So
  /// short queries ask only for what you used this year and for folders whose
  /// names start that way, which come back in a fraction of a second.
  static func namePredicates(_ query: String, global: Bool) -> [(NSPredicate, Int)] {
    let q = literal(query)
    let folder = "kMDItemContentType == \"public.folder\""
    func make(_ string: String) -> NSPredicate {
      NSPredicate(fromMetadataQueryString: string)
        ?? NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(query)*")
    }
    if query.count <= 2 {
      let words = "(kMDItemFSName == \"\(q)*\"cd || kMDItemDisplayName == \"\(q)*\"cdw)"
      return [
        (make("kMDItemLastUsedDate >= $time.today(-365) && " + words), 1000),
        (make("\(folder) && kMDItemFSName == \"\(q)*\"cd"), 1500),
      ]
    }
    let contains = "kMDItemFSName == \"*\(q)*\"cd"
    var out = [(make(contains), 4000)]
    // Folders rank first, so they get a small query of their own and are not
    // lost among thousands of files read in index order.
    if global { out.insert((make("\(folder) && \(contains)"), 1500), at: 0) }
    return out
  }

  static func contentPredicate(_ query: String) -> NSPredicate {
    NSPredicate(fromMetadataQueryString: "kMDItemTextContent == \"\(literal(query))*\"cdw")
      ?? NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", query)
  }

  /// Home's visible folders except Library. Searching them instead of Home
  /// keeps caches and app data out of the results.
  private func homeScopes() -> [URL] {
    let url = URL(fileURLWithPath: home, isDirectory: true)
    let children =
      (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey],
        options: [.skipsHiddenFiles])) ?? []
    return children.filter {
      guard $0.lastPathComponent != "Library",
        let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey])
      else { return false }
      return v.isDirectory == true && v.isHidden != true && v.isPackage != true
    }
  }

  func recentlyUsed(in home: String, _ done: @escaping ([PanelFile]) -> Void)
    -> PanelSearchHandle
  {
    let since = Date().addingTimeInterval(-120 * 86_400) as NSDate
    let query = SpotlightQuery(
      NSPredicate(format: "%K >= %@", "kMDItemLastUsedDate", since),
      scopes: [URL(fileURLWithPath: home, isDirectory: true)], sortedByUse: true, limit: 800,
      timeout: 4)
    let work = self.work
    query.start { hits, finished in
      guard finished else { return }
      work.async {
        var files: [PanelFile] = []
        for hit in hits where !SpotlightSearch.isNoise(hit.path, below: home, home: home) {
          guard var file = PanelFile.quick(hit.path) else { continue }
          file.lastUsed = hit.used
          files.append(file)
        }
        DispatchQueue.main.async { if !query.cancelled { done(files) } }
      }
    }
    return query
  }

  func names(
    _ text: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void
  ) -> PanelSearchHandle {
    let global = scope == home
    let scopes = global ? homeScopes() : [URL(fileURLWithPath: scope, isDirectory: true)]
    let queries = SpotlightSearch.namePredicates(text, global: global).map {
      SpotlightQuery($0.0, scopes: scopes, limit: $0.1, timeout: 4)
    }
    return run(
      queries, scope: scope, extra: global ? { self.homeChildren(matching: text) } : nil, update)
  }

  func contents(
    _ text: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void
  ) -> PanelSearchHandle {
    let scopes =
      scope == home ? homeScopes() : [URL(fileURLWithPath: scope, isDirectory: true)]
    return run(
      [SpotlightQuery(SpotlightSearch.contentPredicate(text), scopes: scopes, limit: 300, timeout: 5)],
      scope: scope, extra: nil, update)
  }

  /// Turns progressive Spotlight batches into stat'ed, filtered files, merged
  /// across queries. It is finished when every query is.
  private func run(
    _ queries: [SpotlightQuery], scope: String, extra: (() -> [PanelFile])?,
    _ update: @escaping ([PanelFile], Bool) -> Void
  ) -> PanelSearchHandle {
    let home = self.home
    let work = self.work
    let group = SpotlightGroup(queries)
    var found: [PanelFile] = []
    var paths = Set<String>()
    var seen = Array(repeating: 0, count: queries.count)
    var open = queries.count
    var first = true
    for (i, query) in queries.enumerated() {
      query.start { hits, finished in
        work.async {
          if first {
            first = false
            for file in extra?() ?? [] where paths.insert(file.path).inserted { found.append(file) }
          }
          for hit in hits.dropFirst(seen[i])
          where !paths.contains(hit.path)
            && !SpotlightSearch.isNoise(hit.path, below: scope, home: home)
          {
            if let file = PanelFile.quick(hit.path) {
              paths.insert(hit.path)
              found.append(file)
            }
          }
          seen[i] = hits.count
          if finished { open -= 1 }
          let snapshot = found
          let done = open == 0
          DispatchQueue.main.async { if !group.cancelled { update(snapshot, done) } }
        }
      }
    }
    return group
  }

  /// Home's own items, which a search of its folders would not include.
  private func homeChildren(matching text: String) -> [PanelFile] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
    return names.compactMap { name in
      guard !name.hasPrefix("."), name != "Library", PanelMatch.rank(text, in: name) > 0 else {
        return nil
      }
      return PanelFile.quick(home + "/" + name)
    }
  }
}

/// Cancels several queries as one search.
final class SpotlightGroup: PanelSearchHandle {
  private let queries: [SpotlightQuery]
  private(set) var cancelled = false
  init(_ queries: [SpotlightQuery]) { self.queries = queries }
  func cancel() {
    cancelled = true
    queries.forEach { $0.cancel() }
  }
}

/// One NSMetadataQuery on the main run loop. It reports every result path
/// gathered so far, stops at `limit` results or after `timeout` seconds, and
/// reports nothing once cancelled.
final class SpotlightQuery: PanelSearchHandle {
  struct Hit {
    let path: String
    let used: Date?
  }
  private let query = NSMetadataQuery()
  private let limit: Int
  private let timeout: TimeInterval
  private let sortedByUse: Bool
  private var observers: [NSObjectProtocol] = []
  private var timer: Timer?
  private var hits: [Hit] = []
  private var report: (([Hit], Bool) -> Void)?
  private(set) var cancelled = false

  init(
    _ predicate: NSPredicate, scopes: [URL], sortedByUse: Bool = false, limit: Int,
    timeout: TimeInterval
  ) {
    self.limit = limit
    self.timeout = timeout
    self.sortedByUse = sortedByUse
    query.predicate = predicate
    query.searchScopes = scopes.isEmpty ? [NSMetadataQueryUserHomeScope] : scopes
    query.notificationBatchingInterval = 0.08
    if sortedByUse {
      query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
    }
  }

  func start(_ report: @escaping ([Hit], Bool) -> Void) {
    self.report = report
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main
      ) { [weak self] _ in self?.progress() })
    observers.append(
      center.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { [weak self] _ in self?.finish() })
    timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      self?.finish()
    }
    if !query.start() { finish() }
  }

  private func collect() {
    query.disableUpdates()
    defer { query.enableUpdates() }
    let count = min(query.resultCount, limit)
    // A sorted query reorders as it gathers, so it is only read once, at the end.
    let from = sortedByUse ? 0 : hits.count
    if sortedByUse { hits.removeAll() }
    guard from < count else { return }
    for i in from..<count {
      guard let item = query.result(at: i) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
      else { continue }
      let used =
        sortedByUse ? query.value(ofAttribute: "kMDItemLastUsedDate", forResultAt: i) as? Date : nil
      hits.append(Hit(path: path, used: used))
    }
  }

  private func progress() {
    guard !cancelled, report != nil, !sortedByUse else { return }
    collect()
    if query.resultCount >= limit {
      finish()
    } else {
      report?(hits, false)
    }
  }

  private func finish() {
    guard !cancelled, let report else { return }
    collect()
    stop()
    self.report = nil
    report(hits, true)
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    query.stop()
  }

  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    report = nil
    stop()
  }

  deinit {
    if !cancelled { stop() }
  }
}
