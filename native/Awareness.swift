import Foundation

// "Working On": what you are actively working on, worked out from signals that
// never leave this Mac. This file is the model. It takes the signals as plain
// values plus a clock and has no threads of its own, so checks can feed it fake
// signals at fake times. AwarenessCenter collects the live signals and runs it.

// MARK: - Scoring

/// Two decays: a 30-minute half-life for "now" and a 2-day half-life for "this week".
enum AwarenessDecay {
  static let nowHalfLife: TimeInterval = 30 * 60
  static let weekHalfLife: TimeInterval = 2 * 86_400
  /// How much "this week" counts next to "now".
  static let weekShare = 0.3

  static func factor(_ age: TimeInterval, halfLife: TimeInterval) -> Double {
    pow(0.5, max(0, age) / halfLife)
  }
}

struct AwarenessScore: Equatable {
  var now = 0.0
  var week = 0.0
  var total: Double { now + AwarenessDecay.weekShare * week }

  mutating func add(_ weight: Double, at time: Date, now clock: Date) {
    let age = clock.timeIntervalSince(time)
    now += weight * AwarenessDecay.factor(age, halfLife: AwarenessDecay.nowHalfLife)
    week += weight * AwarenessDecay.factor(age, halfLife: AwarenessDecay.weekHalfLife)
  }

  static func + (a: AwarenessScore, b: AwarenessScore) -> AwarenessScore {
    AwarenessScore(now: a.now + b.now, week: a.week + b.week)
  }
}

/// How much each kind of signal counts, and the bars an item has to clear.
enum AwarenessWeight {
  /// One open never makes Working On by itself (0.4 + 0.3 × 0.4 < 0.6).
  static let opened = 0.4
  /// The newest save counts 1, the one before ½, then ⅓: an agent saving
  /// a file eight times in a minute doesn't drown out an open document.
  static let saved = 1.0
  static let document = 1.5
  static let agent = 2.0
  /// An agent whose activity isn't known yet (no terminal, one scan so far).
  static let agentIdle = 0.05
  static let shell = 0.6
  static let commit = 1.0
  /// A file or project shown in Working On. One save half an hour ago clears it; one open does not.
  static let item = 0.6
  static let project = 0.6
  /// A second file from the same project shows when it has this share of the first's score.
  static let second = 0.25
  /// This many files written within one second in one project is a checkout,
  /// an unzip or a copy, not editing. Together they count as one save.
  static let bulk = 8
}

// MARK: - Signals

/// An app that was in front, from NSWorkspace activations.
struct AwarenessFront: Equatable {
  var app: String
  var bundle: String?
  var start: Date
  /// Nil while it is still in front.
  var end: Date?
}

/// The front window's document, read through Accessibility when you allow it.
struct AwarenessDocument: Equatable {
  var path: String
  var app: String
  var bundle: String?
  var start: Date
  var end: Date?
}

/// A shell or agent CLI and the folder it is in.
struct AwarenessSession: Equatable {
  enum Kind: Equatable {
    case shell(String)
    case agent(String)
  }
  var kind: Kind
  var folder: String
  /// The terminal app it runs in: "Terminal", "Ghostty", "Rex".
  var host: String?
  /// Its last input, output or CPU use, when known.
  var active: Date?
  var pid: Int32 = 0

  var agent: String? { if case .agent(let name) = kind { return name } else { return nil } }
}

struct AwarenessGit: Equatable {
  var branch: String?
  var lastCommit: Date?
  var dirty: Int?
}

/// Everything collected so far. AwarenessCenter owns one on its queue.
struct AwarenessSignals {
  /// Spotlight's kMDItemLastUsedDate, for files.
  var used: [String: Date] = [:]
  /// Saves seen by FSEvents, oldest first, at most `keepSaves` old.
  var saves: [String: [Date]] = [:]
  var fronts: [AwarenessFront] = []
  var documents: [AwarenessDocument] = []
  var sessions: [AwarenessSession] = []
  var git: [String: AwarenessGit] = [:]

  static let keepSaves: TimeInterval = 2 * 3600
  static let keepFronts: TimeInterval = 2 * 86_400
  /// An editor's save is often several events: a temp file, a rename, a touch.
  static let sameSave: TimeInterval = 4

  var isEmpty: Bool {
    used.isEmpty && saves.isEmpty && fronts.isEmpty && documents.isEmpty && sessions.isEmpty
      && git.isEmpty
  }

  mutating func save(_ path: String, at time: Date) {
    var list = saves[path] ?? []
    if let last = list.last, abs(time.timeIntervalSince(last)) < AwarenessSignals.sameSave {
      list[list.count - 1] = max(last, time)
    } else {
      list.append(time)
      list.sort()
    }
    if list.count > 24 { list.removeFirst(list.count - 24) }
    saves[path] = list
  }

  /// `app` came to the front at `time`.
  mutating func front(_ app: String, bundle: String?, at time: Date) {
    if let i = fronts.indices.last, fronts[i].end == nil {
      if fronts[i].bundle == bundle && fronts[i].app == app { return }
      fronts[i].end = time
    }
    fronts.append(AwarenessFront(app: app, bundle: bundle, start: time))
  }

  /// The front window's document is now `path` (nil: none).
  mutating func document(_ path: String?, app: String, bundle: String?, at time: Date) {
    if let i = documents.indices.last, documents[i].end == nil {
      if documents[i].path == path && documents[i].app == app { return }
      documents[i].end = time
    }
    if let path { documents.append(AwarenessDocument(path: path, app: app, bundle: bundle, start: time)) }
  }

  mutating func forget(_ path: String) {
    used[path] = nil
    saves[path] = nil
  }

  mutating func prune(now: Date) {
    let saveCutoff = now.addingTimeInterval(-AwarenessSignals.keepSaves)
    saves = saves.compactMapValues { list in
      let kept = list.filter { $0 >= saveCutoff }
      return kept.isEmpty ? nil : kept
    }
    let frontCutoff = now.addingTimeInterval(-AwarenessSignals.keepFronts)
    fronts.removeAll { ($0.end ?? now) < frontCutoff }
    if fronts.count > 600 { fronts.removeFirst(fronts.count - 600) }
    documents.removeAll { ($0.end ?? now) < frontCutoff }
    if documents.count > 200 { documents.removeFirst(documents.count - 200) }
    let usedCutoff = now.addingTimeInterval(-14 * 86_400)
    used = used.filter { $0.value >= usedCutoff }
  }

  /// The app in front at `time`.
  func frontApp(at time: Date) -> AwarenessFront? {
    fronts.last { $0.start <= time && ($0.end.map { time < $0 } ?? true) }
  }

  /// Seconds `app` spent in front between `from` and `to`.
  func frontTime(_ app: String, from: Date, to: Date) -> TimeInterval {
    fronts.filter { $0.app == app }.reduce(0) { sum, f in
      let start = max(f.start, from)
      let end = min(f.end ?? to, to)
      return sum + max(0, end.timeIntervalSince(start))
    }
  }
}

// MARK: - Paths

/// Path pieces without bridging to NSString: the model takes these apart
/// thousands of times a run.
enum AwarenessPath {
  static func parent(_ path: String) -> String {
    let utf8 = path.utf8
    guard let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
    if slash == utf8.startIndex { return "/" }
    return String(path[..<slash])
  }

  static func name(_ path: String) -> String {
    guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
    return String(path[path.index(after: slash)...])
  }

  /// A native copy: paths from FSEvents and Spotlight arrive as NSStrings,
  /// which are slow to take apart from Swift.
  static func native(_ path: String) -> String {
    var copy = path
    copy.makeContiguousUTF8()
    return copy
  }
}

// MARK: - Which paths count

enum AwarenessFilter {
  /// Folders whose contents are never what you are working on: build output,
  /// dependencies, caches and version-control internals.
  static let skippedFolders: Set<Substring> = [
    "node_modules", "DerivedData", "build", "target", ".build", "Caches", "caches", ".cache",
    "__pycache__", ".git", ".svn", ".hg", "Pods", ".next", ".nuxt", ".gradle", ".Trash",
    ".venv", "venv", ".tox", "ModuleCache", "xcuserdata", ".swiftpm",
  ]
  static let skippedExtensions: Set<String> = [
    "tmp", "temp", "swp", "swx", "swo", "log", "lock", "part", "partial", "crdownload", "download",
    "pyc", "o", "d", "DS_Store",
  ]

  /// Whether a change at `path` can be work: under Home, outside Library, not
  /// build output or a cache, not a temporary or hidden file. Hidden folders
  /// are allowed here; AwarenessRoots decides those.
  static func counts(_ path: String, home: String) -> Bool {
    guard path.hasPrefix(home + "/") else { return false }
    let parts = path.dropFirst(home.count + 1).split(separator: "/")
    guard let name = parts.last, parts.count >= 1 else { return false }
    if parts.count > 1, parts[0] == "Library" { return false }
    for part in parts.dropLast() where skippedFolders.contains(part) { return false }
    if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasSuffix("~") { return false }
    for suffix in ["-journal", "-wal", "-shm", ".sb-"] where name.hasSuffix(suffix) { return false }
    if name.contains(".sb-") { return false }
    let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? ""
    if skippedExtensions.contains(ext) || skippedExtensions.contains(ext.lowercased()) { return false }
    return true
  }

  /// Whether any part of the path below Home starts with a dot.
  static func hidden(_ path: String, home: String) -> Bool {
    guard path.hasPrefix(home + "/") else { return false }
    var afterSlash = false
    for byte in path.utf8.dropFirst(home.utf8.count) {
      if afterSlash && byte == UInt8(ascii: ".") { return true }
      afterSlash = byte == UInt8(ascii: "/")
    }
    return false
  }
}

// MARK: - Projects

/// Finds the project a path belongs to: the nearest folder with .git,
/// Package.swift, Cargo.toml, package.json or pyproject.toml, else the folder
/// itself. A linked git worktree belongs to its main checkout. Not thread-safe:
/// AwarenessCenter uses it on its queue.
final class AwarenessRoots {
  struct FileSystem {
    var exists: (String) -> Bool
    /// The contents of a small text file, or nil (also for a folder).
    var read: (String) -> String?

    static let live = FileSystem(
      exists: { FileManager.default.fileExists(atPath: $0) },
      read: { path in
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? nil
        return data.flatMap { String(data: $0, encoding: .utf8) }
      })
  }

  struct Root: Equatable {
    /// The project folder. For a linked worktree, its main checkout.
    var path: String
    /// Found by a marker, as opposed to the folder itself.
    var marked: Bool
    var repo: Bool
    /// Where the marker is: the worktree itself, for a linked worktree.
    var checkout: String

    init(path: String, marked: Bool, repo: Bool, checkout: String? = nil) {
      self.path = path
      self.marked = marked
      self.repo = repo
      self.checkout = checkout ?? path
    }
  }

  static let markers = [".git", "Package.swift", "Cargo.toml", "package.json", "pyproject.toml"]
  /// Subfolder names that say "part of a project", not "a project".
  static let genericNames: Set<String> = [
    "exports", "export", "output", "outputs", "out", "renders", "render", "assets", "images", "img",
    "art", "artwork", "drafts", "draft", "final", "finals", "versions", "previews", "src", "source",
    "sources", "docs", "notes", "refs", "references", "files", "data", "media", "scans", "photos",
    "audio", "video", "pdf", "pdfs", "old", "archive", "work", "working", "scratch", "tmp", "temp",
  ]

  let home: String
  let fs: FileSystem
  private var cache: [String: Root] = [:]
  private var accepted: [String: Bool] = [:]
  private var counted: [String: Bool] = [:]

  init(home: String, fs: FileSystem = .live) {
    self.home = home
    self.fs = fs
  }

  func clear() {
    cache.removeAll()
    accepted.removeAll()
    counted.removeAll()
  }

  func root(ofFile path: String) -> Root { root(ofFolder: AwarenessPath.parent(path)) }

  /// AwarenessFilter.counts, remembered.
  func counts(_ path: String) -> Bool {
    if let hit = counted[path] { return hit }
    if counted.count > 8000 { counted.removeAll() }
    let answer = AwarenessFilter.counts(path, home: home)
    counted[path] = answer
    return answer
  }

  func root(ofFolder folder: String) -> Root {
    if let hit = cache[folder] { return hit }
    if cache.count > 4000 { cache.removeAll() }
    let found = find(folder)
    cache[folder] = found
    return found
  }

  private func find(_ folder: String) -> Root {
    let prefix = home + "/"
    var dir = folder
    while dir.hasPrefix(prefix) {
      for marker in AwarenessRoots.markers where fs.exists(dir + "/" + marker) {
        if marker == ".git" {
          return Root(path: mainCheckout(dir) ?? dir, marked: true, repo: true, checkout: dir)
        }
        // A package inside a repo still belongs to that repo's checkout when it is a worktree.
        return Root(path: dir, marked: true, repo: false)
      }
      dir = AwarenessPath.parent(dir)
    }
    // No marker: the folder itself, rolled up past names like "exports" and "2026".
    var root = folder
    while root.hasPrefix(prefix) {
      let name = AwarenessPath.name(root)
      let parent = AwarenessPath.parent(root)
      // Never up into Home or a top-level folder such as ~/Developer.
      guard parent != home, AwarenessPath.parent(parent) != home, AwarenessRoots.generic(name) else { break }
      root = parent
    }
    return Root(path: root, marked: false, repo: false)
  }

  static func generic(_ name: String) -> Bool {
    let lower = name.lowercased()
    if genericNames.contains(lower) { return true }
    return !lower.isEmpty && lower.allSatisfy(\.isNumber)
  }

  /// `dir/.git` as a file says "gitdir: <main>/.git/worktrees/<name>".
  private func mainCheckout(_ dir: String) -> String? {
    guard let text = fs.read(dir + "/.git"), text.hasPrefix("gitdir:") else { return nil }
    let gitdir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
    let main = String(gitdir[..<range.lowerBound])
    guard main.hasPrefix(home + "/"), fs.exists(main + "/.git") else { return nil }
    return main
  }

  /// Whether a path can be shown and counted. A hidden folder counts only
  /// inside a git checkout, such as an agent's worktree.
  func accepts(_ path: String, isFolder: Bool = false) -> Bool {
    if !isFolder {
      return !AwarenessPath.name(path).hasPrefix(".") && accepts(AwarenessPath.parent(path), isFolder: true)
    }
    if let hit = accepted[path] { return hit }
    if accepted.count > 4000 { accepted.removeAll() }
    var answer = !AwarenessFilter.hidden(path, home: home)
    if !answer {
      let prefix = home + "/"
      var dir = path
      while dir.hasPrefix(prefix) {
        if fs.exists(dir + "/.git") {
          // Nothing hidden below the checkout itself.
          answer = !path.dropFirst(dir.count).split(separator: "/").contains { $0.hasPrefix(".") }
          break
        }
        dir = AwarenessPath.parent(dir)
      }
    }
    accepted[path] = answer
    return answer
  }
}

// MARK: - Words

enum AwarenessText {
  static func ago(_ date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) hr ago" }
    if seconds < 2 * 86_400 { return "yesterday" }
    return "\(Int(seconds / 86_400)) days ago"
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "under a minute" }
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest < 5 ? "\(hours) hr" : "\(hours) hr \(rest) min"
  }

  /// "in the last 20 min": since the first of several saves, rounded up to 5 minutes.
  static func span(since first: Date, now: Date) -> String {
    let minutes = max(5, Int((now.timeIntervalSince(first) / 60 / 5).rounded(.up)) * 5)
    return minutes < 60 ? "\(minutes) min" : duration(TimeInterval(minutes * 60))
  }

  static func times(_ n: Int) -> String { n == 1 ? "once" : n == 2 ? "twice" : "\(n) times" }

  static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

  /// "a", "a and b", "a, b and c", "a, b and 2 more".
  static func list(_ names: [String]) -> String {
    switch names.count {
    case 0: return ""
    case 1: return names[0]
    case 2: return names[0] + " and " + names[1]
    case 3: return names[0] + ", " + names[1] + " and " + names[2]
    default: return names[0] + ", " + names[1] + " and \(names.count - 2) more"
    }
  }

  static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

  static func name(_ path: String) -> String { AwarenessPath.name(path) }
}

/// Apps that never claim a save or a project: the shell around everything,
/// and terminals (a session there says more than the app does).
enum AwarenessApps {
  static let ignored: Set<String> = [
    "Finder", "Finger", "Dock", "loginwindow", "SystemUIServer", "Spotlight", "Control Center",
    "Notification Center", "System Settings", "Raycast", "Alfred",
  ]
  static let terminals: Set<String> = [
    "Terminal", "iTerm2", "Ghostty", "Warp", "Rex", "Alacritty", "kitty", "WezTerm", "Hyper",
    "Tabby", "tmux",
  ]
}

// MARK: - The snapshot the panel reads

struct AwarenessSnapshot {
  struct Item: Equatable {
    var path: String
    var isFolder: Bool
    var project: String
    /// The right-hand column: "Open in Illustrator", "Edited 12 min ago".
    var side: String
    /// One line: "Edited 12 min ago from a Claude Code session in finger".
    var why: String
    var score: Double
  }

  struct Project: Equatable {
    var root: String
    var name: String
    var score: Double
    /// The app or terminal it is happening in.
    var host: String?
    /// "Claude Code is running in Terminal here, and launcher.rs was edited 12 min ago."
    var why: String
  }

  /// Working On, most active first: at most four.
  var items: [Item] = []
  var projects: [Project] = []
  /// Files and folders you are working on, with their scores. They get a blue dot.
  var active: [String: Double] = [:]
  /// Folders that lead from Home to something active, with the best score below.
  var trail: [String: Double] = [:]
  /// "Fold Studies in Illustrator · finger in Terminal", or empty.
  var footer = ""
  var knowledge: [PanelKnowledgeRow] = []
  /// Why lines for files you are working on that are not in `items`.
  var fileWhys: [String: String] = [:]
  /// The latest activity at or under a path: a folder's mtime doesn't move
  /// when a file inside it is saved, so its row's time comes from here.
  var latest: [String: Date] = [:]
  var computed: Date?

  static let empty = AwarenessSnapshot()

  var isEmpty: Bool { items.isEmpty && trail.isEmpty && footer.isEmpty && knowledge.isEmpty }

  /// Whether a row for `path` gets a blue dot.
  func marked(_ path: String) -> Bool { active[path] != nil || trail[path] != nil }

  func item(_ path: String) -> Item? { items.first { $0.path == path } }

  /// The right-hand text of a Working On row.
  func side(_ path: String) -> String? { item(path)?.side }

  /// Why a file matters, if it does.
  func why(file path: String) -> String? { item(path)?.why ?? fileWhys[path] }

  /// The folder peek's line: a project's own reasons, or what it leads to.
  func why(folder path: String) -> String? {
    if let project = projects.first(where: { $0.root == path }), !project.why.isEmpty { return project.why }
    guard trail[path] != nil || active[path] != nil else { return nil }
    let prefix = path + "/"
    var names = items.filter { $0.path.hasPrefix(prefix) }.map { AwarenessText.name($0.path) }
    if names.isEmpty {
      names = active.filter { $0.key.hasPrefix(prefix) }.sorted { $0.value > $1.value }
        .map { AwarenessText.name($0.key) }
    }
    guard !names.isEmpty else { return nil }
    return "Has \(AwarenessText.list(names)), which you are working on."
  }

  /// Of the items in a folder, the one on the trail to the most active work.
  func landing(among paths: [String]) -> String? {
    var best: (path: String, score: Double)?
    for path in paths {
      guard let score = [active[path], trail[path]].compactMap({ $0 }).max() else { continue }
      if best == nil || score > best!.score { best = (path, score) }
    }
    return best?.path
  }
}

// MARK: - The model

struct AwarenessModel {
  let home: String
  let roots: AwarenessRoots
  /// Whether an app (by bundle id, else name) can open a file. Without it no save is credited to an app.
  var opens: (_ app: AwarenessFront, _ path: String) -> Bool = { _, _ in false }
  var place: PanelPlace { PanelPlace(home: home) }

  init(home: String, roots: AwarenessRoots, opens: ((AwarenessFront, String) -> Bool)? = nil) {
    self.home = home
    self.roots = roots
    if let opens { self.opens = opens }
  }

  /// What one file's signals add up to.
  struct FileFacts {
    var path: String
    var project: AwarenessRoots.Root
    var score = AwarenessScore()
    var used: Date?
    var saves: [Date] = []
    var document: AwarenessDocument?
    var documentTime: TimeInterval = 0
    /// Who made the last save: an agent session, or the app in front.
    var agent: AwarenessSession?
    var app: String?
    var last: Date { [used, saves.last, document?.end ?? document?.start].compactMap { $0 }.max() ?? .distantPast }
  }

  struct ProjectFacts {
    var root: AwarenessRoots.Root
    var files: [FileFacts] = []
    var sessions: [AwarenessSession] = []
    var score = AwarenessScore()
    var git: AwarenessGit?
  }

  func compute(_ signals: AwarenessSignals, now: Date) -> AwarenessSnapshot {
    var files: [String: FileFacts] = [:]
    func facts(_ path: String) -> FileFacts? {
      if let hit = files[path] { return hit }
      guard roots.counts(path), roots.accepts(path) else { return nil }
      return FileFacts(path: path, project: roots.root(ofFile: path))
    }
    for (path, date) in signals.used where date <= now.addingTimeInterval(60) {
      guard var f = facts(path) else { continue }
      f.used = date
      f.score.add(AwarenessWeight.opened, at: date, now: now)
      files[path] = f
    }
    // A session sitting in a bare top-level folder, such as ~/Developer, is not in a project.
    // Saves that came in a crowd: how many files a project saw in each second.
    struct Second: Hashable {
      var root: String
      var second: Int
    }
    var crowd: [Second: Int] = [:]
    for (path, dates) in signals.saves where roots.counts(path) {
      let root = roots.root(ofFile: path).path
      for second in Set(dates.map { Int($0.timeIntervalSince1970) }) {
        crowd[Second(root: root, second: second), default: 0] += 1
      }
    }
    func crowdSize(_ path: String, _ date: Date) -> Int {
      crowd[Second(root: roots.root(ofFile: path).path, second: Int(date.timeIntervalSince1970))] ?? 1
    }
    let sessions = signals.sessions.filter {
      guard $0.folder.hasPrefix(home + "/"), roots.accepts($0.folder, isFolder: true) else { return false }
      let root = roots.root(ofFolder: $0.folder)
      return root.marked || AwarenessPath.parent(root.path) != home
    }
    for (path, dates) in signals.saves {
      guard var f = facts(path) else { continue }
      var own: [Date] = []
      for date in dates.sorted() {
        let n = crowdSize(path, date)
        if n >= AwarenessWeight.bulk {
          f.score.add(AwarenessWeight.saved / Double(n), at: date, now: now)
        } else {
          own.append(date)
        }
      }
      f.saves = own
      for (k, date) in f.saves.reversed().enumerated() {
        f.score.add(AwarenessWeight.saved / Double(k + 1), at: date, now: now)
      }
      if let last = f.saves.last { attribute(&f, last, sessions, signals) }
      files[path] = f
    }
    let docWindow = now.addingTimeInterval(-AwarenessSignals.keepSaves)
    for doc in signals.documents {
      guard var f = facts(doc.path) else { continue }
      let end = doc.end ?? now
      guard end >= docWindow else { continue }
      if f.document == nil || doc.start >= f.document!.start { f.document = doc }
      f.documentTime += end.timeIntervalSince(max(doc.start, docWindow))
      f.score.add(AwarenessWeight.document, at: end, now: now)
      files[doc.path] = f
    }

    // Group by project.
    var projects: [String: ProjectFacts] = [:]
    for f in files.values {
      projects[f.project.path, default: ProjectFacts(root: f.project)].files.append(f)
      projects[f.project.path]!.score = projects[f.project.path]!.score + f.score
    }
    for s in sessions {
      let root = roots.root(ofFolder: s.folder)
      projects[root.path, default: ProjectFacts(root: root)].sessions.append(s)
    }
    for key in projects.keys where !projects[key]!.sessions.isEmpty {
      // Each further agent counts less; of several terminal windows only the latest counts.
      let all = projects[key]!.sessions.sorted { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }
      for (k, s) in all.filter({ $0.agent != nil }).enumerated() {
        if let active = s.active {
          projects[key]!.score.add(AwarenessWeight.agent / Double(k + 1), at: active, now: now)
        } else {
          projects[key]!.score.add(AwarenessWeight.agentIdle / Double(k + 1), at: now, now: now)
        }
      }
      if let shell = all.first(where: { $0.agent == nil }), let active = shell.active {
        projects[key]!.score.add(AwarenessWeight.shell, at: active, now: now)
      }
    }
    for (root, git) in signals.git {
      guard var p = projects[root] else { continue }
      p.git = git
      if let commit = git.lastCommit, commit <= now { p.score.add(AwarenessWeight.commit, at: commit, now: now) }
      projects[root] = p
    }
    for key in projects.keys { projects[key]!.files.sort { $0.score.total > $1.score.total } }
    let ranked = projects.values.filter { $0.root.path != home }
      .sorted { $0.score.total > $1.score.total }

    var snapshot = AwarenessSnapshot()
    snapshot.computed = now
    let strong = ranked.filter { $0.score.total >= AwarenessWeight.project }

    // Working On.
    for p in strong {
      guard snapshot.items.count < 4 else { break }
      var picks: [AwarenessSnapshot.Item] = []
      let fileTotal = p.files.reduce(0) { $0 + $1.score.total }
      let visible = p.files.filter { !AwarenessFilter.hidden($0.path, home: home) }
      let hiddenShare = fileTotal > 0 ? (fileTotal - visible.reduce(0) { $0 + $1.score.total }) / fileTotal : 0
      let top = visible.first
      let spread =
        p.files.count >= 4 && (p.files.first?.score.total ?? 0) < 0.35 * fileTotal
      if let top, top.score.total >= AwarenessWeight.item, !spread, hiddenShare < 0.5 {
        picks.append(item(top, p, now))
        if visible.count > 1,
          visible[1].score.total >= max(AwarenessWeight.item, AwarenessWeight.second * top.score.total)
        {
          picks.append(item(visible[1], p, now))
        }
      } else if !AwarenessFilter.hidden(p.root.path, home: home) {
        picks.append(
          AwarenessSnapshot.Item(
            path: p.root.path, isFolder: true, project: p.root.path, side: projectSide(p, now),
            why: projectWhy(p, now), score: p.score.total))
      }
      snapshot.items += picks.prefix(4 - snapshot.items.count)
    }

    // Projects, for the footer, the peek and what Finger knows.
    snapshot.projects = strong.prefix(6).map {
      AwarenessSnapshot.Project(
        root: $0.root.path, name: AwarenessText.name($0.root.path), score: $0.score.total,
        host: host($0, now), why: projectWhy($0, now))
    }

    // Dots: what you are working on, and every folder on the way there.
    for item in snapshot.items { snapshot.active[item.path] = item.score }
    var extra = 0
    for p in strong {
      for f in p.files where f.score.total >= AwarenessWeight.item && snapshot.active[f.path] == nil {
        guard extra < 12, !AwarenessFilter.hidden(f.path, home: home) else { continue }
        snapshot.active[f.path] = f.score.total
        snapshot.fileWhys[f.path] = fileWhy(f, p, now)
        extra += 1
      }
    }
    for (path, score) in snapshot.active {
      var dir = AwarenessPath.parent(path)
      while dir.hasPrefix(home + "/") {
        snapshot.trail[dir] = max(score, snapshot.trail[dir] ?? 0)
        dir = AwarenessPath.parent(dir)
      }
    }

    func touch(_ path: String, _ date: Date) {
      guard date <= now.addingTimeInterval(60), !AwarenessFilter.hidden(path, home: home) else { return }
      var p = path
      while p.hasPrefix(home + "/") {
        if let known = snapshot.latest[p], known >= date { break }
        snapshot.latest[p] = date
        p = AwarenessPath.parent(p)
      }
    }
    for f in files.values where f.last > .distantPast { touch(f.path, f.last) }
    for s in sessions { if let active = s.active { touch(s.folder, active) } }

    snapshot.footer = snapshot.projects.prefix(2).map { p in
      p.host.map { "\(p.name) in \($0)" } ?? p.name
    }.joined(separator: " · ")
    snapshot.knowledge = knowledge(signals, Array(files.values), sessions, ranked, now)
    return snapshot
  }

  // MARK: Who did it

  /// Credits the last save to an agent working in the same project at the
  /// time, else to the app in front if it can open the file.
  private func attribute(
    _ f: inout FileFacts, _ save: Date, _ sessions: [AwarenessSession], _ signals: AwarenessSignals
  ) {
    let agents = sessions.filter { s in
      guard s.agent != nil, let active = s.active else { return false }
      let root = roots.root(ofFolder: s.folder)
      let inside = f.path.hasPrefix(s.folder + "/") || root.path == f.project.path
      return inside && abs(active.timeIntervalSince(save)) <= 180
    }
    if let agent = agents.max(by: { ($0.active ?? .distantPast) < ($1.active ?? .distantPast) }) {
      f.agent = agent
      return
    }
    if let front = signals.frontApp(at: save), !AwarenessApps.ignored.contains(front.app),
      !AwarenessApps.terminals.contains(front.app), opens(front, f.path)
    {
      f.app = front.app
    }
  }

  private func projectName(_ path: String) -> String { AwarenessText.name(path) }

  private func agentPhrase(_ s: AwarenessSession) -> String {
    "a \(s.agent ?? "agent") session in \(projectName(roots.root(ofFolder: s.folder).path))"
  }

  // MARK: Why, for a file

  func fileWhy(_ f: FileFacts, _ p: ProjectFacts, _ now: Date) -> String {
    var clauses: [String] = []
    var credited = false
    if let doc = f.document {
      if doc.end == nil {
        clauses.append("open in \(doc.app) for \(AwarenessText.duration(f.documentTime))")
      } else {
        clauses.append("open in \(doc.app) for \(AwarenessText.duration(f.documentTime)) until \(AwarenessText.ago(doc.end!, now: now))")
      }
      credited = true
    }
    let recent = f.saves.filter { now.timeIntervalSince($0) <= 30 * 60 }
    let who: String? = {
      if credited { return nil }
      if let agent = f.agent { return "from " + agentPhrase(agent) }
      if let app = f.app { return "in " + app }
      return nil
    }()
    if recent.count >= 2 {
      var clause = "saved \(AwarenessText.times(recent.count)) in the last \(AwarenessText.span(since: recent[0], now: now))"
      if let who { clause += " " + who }
      clauses.append(clause)
    } else if let last = f.saves.last {
      let verb = f.agent != nil ? "edited" : "saved"
      var clause = "\(verb) \(AwarenessText.ago(last, now: now))"
      if let who { clause += " " + who }
      clauses.append(clause)
    } else if clauses.isEmpty, let used = f.used {
      clauses.append("opened \(AwarenessText.ago(used, now: now))")
    }
    return AwarenessText.capitalized(clauses.prefix(2).joined(separator: ", "))
  }

  func fileSide(_ f: FileFacts, _ now: Date) -> String {
    if let doc = f.document, doc.end == nil { return "Open in \(doc.app)" }
    if let last = f.saves.last {
      return (f.agent != nil ? "Edited " : "Saved ") + AwarenessText.ago(last, now: now)
    }
    if let used = f.used { return "Opened " + AwarenessText.ago(used, now: now) }
    return ""
  }

  private func item(_ f: FileFacts, _ p: ProjectFacts, _ now: Date) -> AwarenessSnapshot.Item {
    AwarenessSnapshot.Item(
      path: f.path, isFolder: false, project: p.root.path, side: fileSide(f, now),
      why: fileWhy(f, p, now), score: f.score.total)
  }

  // MARK: Why, for a project

  /// Agent sessions here, most recently active first. Sessions come from the
  /// latest process scan, so each is running now.
  private func agents(_ p: ProjectFacts) -> [AwarenessSession] {
    p.sessions.filter { $0.agent != nil }.sorted { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }
  }

  private func shells(_ p: ProjectFacts, _ now: Date) -> [AwarenessSession] {
    p.sessions.filter { s in
      s.agent == nil && (s.active.map { now.timeIntervalSince($0) <= 12 * 3600 } ?? false)
    }.sorted { $0.active! > $1.active! }
  }

  /// The app or terminal the project is happening in.
  func host(_ p: ProjectFacts, _ now: Date) -> String? {
    if let doc = p.files.compactMap(\.document).first(where: { $0.end == nil }) { return doc.app }
    if let host = agents(p).first?.host { return host }
    if let host = shells(p, now).first?.host { return host }
    if let app = p.files.first(where: { $0.app != nil })?.app { return app }
    return nil
  }

  func projectSide(_ p: ProjectFacts, _ now: Date) -> String {
    let running = agents(p)
    if let s = running.first {
      let same = running.filter { $0.agent == s.agent }.count
      return same > 1 ? "\(same) \(s.agent!) sessions" : (s.host.map { "\(s.agent!) in \($0)" } ?? "\(s.agent!) running")
    }
    let latest = [p.files.map(\.last).max(), shells(p, now).first?.active]
      .compactMap { $0 }.max()
    return latest.map { "Active " + AwarenessText.ago($0, now: now) } ?? ""
  }

  func projectWhy(_ p: ProjectFacts, _ now: Date) -> String {
    var clauses: [String] = []
    let running = agents(p)
    if let s = running.first {
      let kind = s.agent!
      let same = running.filter { $0.agent == kind }.count
      if same > 1 {
        clauses.append("\(same) \(kind) sessions are running here")
      } else {
        clauses.append("\(kind) is running" + (s.host.map { " in \($0)" } ?? "") + " here")
      }
    }
    if let f = p.files.first(where: { $0.document?.end == nil && $0.document != nil }), let doc = f.document {
      clauses.append("\(AwarenessText.name(f.path)) is open in \(doc.app)")
    }
    let recentSaves = p.files.filter { f in f.saves.contains { now.timeIntervalSince($0) <= 3600 } }
    if clauses.count < 2 {
      if recentSaves.count >= 4 {
        clauses.append("\(recentSaves.count) files were saved here in the last hour")
      } else if let f = p.files.first(where: { !$0.saves.isEmpty && $0.document == nil }), let last = f.saves.last {
        let verb = f.agent != nil ? "edited" : "saved"
        clauses.append("\(AwarenessText.name(f.path)) was \(verb) \(AwarenessText.ago(last, now: now))")
      } else if let f = p.files.first(where: { $0.used != nil && $0.document == nil }), let used = f.used,
        clauses.isEmpty
      {
        clauses.append("\(AwarenessText.name(f.path)) was opened \(AwarenessText.ago(used, now: now))")
      }
    }
    if clauses.count < 2, running.isEmpty, let shell = shells(p, now).first {
      clauses.append("\(shell.host.map { "a \($0) window" } ?? "a terminal") is open here")
    }
    if clauses.count < 2, let git = p.git {
      if let dirty = git.dirty, dirty > 0 {
        clauses.append("\(AwarenessText.plural(dirty, "changed file")) on \(git.branch ?? "this branch")")
      } else if let commit = git.lastCommit, now.timeIntervalSince(commit) < 2 * 86_400 {
        clauses.append("the last commit was \(AwarenessText.ago(commit, now: now))")
      }
    }
    guard !clauses.isEmpty else { return "" }
    let sentence = clauses.count == 1 ? clauses[0] : clauses[0] + ", and " + clauses[1]
    return AwarenessText.capitalized(sentence) + "."
  }

  // MARK: What Finger knows

  /// "Studio › Fold Studies › exports", or for a hidden worktree "finger › native (worktree filing)".
  func placeText(_ folder: String) -> String {
    guard AwarenessFilter.hidden(folder, home: home) else { return place.folderText(folder) }
    let root = roots.root(ofFolder: folder)
    let inside = folder.dropFirst(root.checkout.count).split(separator: "/").map(String.init)
    let name = AwarenessText.name(root.path)
    let base = inside.isEmpty ? name : ([name] + inside.suffix(2)).joined(separator: " › ")
    return root.checkout == root.path ? base : base + " (worktree \(AwarenessText.name(root.checkout)))"
  }

  func knowledge(
    _ signals: AwarenessSignals, _ files: [FileFacts], _ sessions: [AwarenessSession], _ ranked: [ProjectFacts],
    _ now: Date
  ) -> [PanelKnowledgeRow] {
    var rows: [PanelKnowledgeRow] = []
    func add(_ text: String) { rows.append(PanelKnowledgeRow(signal: text, sent: PanelKnowledge.staysHere)) }
    let hour = now.addingTimeInterval(-3600)
    var described = Set<String>()
    // The front window's document, when App Documents is on.
    if let doc = signals.documents.last, doc.end == nil {
      let time = signals.frontTime(doc.app, from: max(doc.start, now.addingTimeInterval(-AwarenessSignals.keepSaves)), to: now)
      add("\(doc.app) in front with \(AwarenessText.name(doc.path)), \(AwarenessText.duration(max(time, now.timeIntervalSince(doc.start))))")
      described.insert(doc.app)
    }
    // Apps in front this hour.
    var apps: [String: TimeInterval] = [:]
    for f in signals.fronts where (f.end ?? now) > hour && !AwarenessApps.ignored.contains(f.app) {
      apps[f.app] = signals.frontTime(f.app, from: hour, to: now)
    }
    for (app, time) in apps.sorted(by: { $0.value > $1.value }).prefix(2)
    where time >= 60 && !described.contains(app) {
      add("\(app) in front \(AwarenessText.duration(time)) of the last hour")
    }
    // Saves, by folder.
    var folders: [String: [Date]] = [:]
    for f in files where !f.saves.isEmpty {
      folders[AwarenessPath.parent(f.path), default: []] += f.saves
    }
    for (folder, dates) in folders.sorted(by: { $0.value.count > $1.value.count }).prefix(2) {
      let sorted = dates.sorted()
      let place = placeText(folder)
      if sorted.count == 1 {
        add("A save in \(place) \(AwarenessText.ago(sorted[0], now: now))")
      } else {
        add("\(sorted.count) saves in \(place) in \(AwarenessText.span(since: sorted[0], now: now))")
      }
    }
    // Agents and terminals, by project.
    struct Group: Hashable {
      var agent: String?
      var project: String
      var host: String?
    }
    func group(_ s: AwarenessSession) -> Group {
      Group(agent: s.agent, project: projectName(roots.root(ofFolder: s.folder).path), host: s.host)
    }
    var sizes: [Group: Int] = [:]
    for s in sessions { sizes[group(s), default: 0] += 1 }
    var seen = Set<Group>()
    for s in sessions.sorted(by: { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }) {
      let key = group(s)
      let project = key.project
      guard !seen.contains(key) else { continue }
      if s.agent == nil, s.active.map({ now.timeIntervalSince($0) > 12 * 3600 }) ?? true { continue }
      seen.insert(key)
      let count = sizes[key] ?? 1
      let host = s.host.map { " in \($0)" } ?? ""
      if let agent = s.agent {
        add((count > 1 ? "\(count) \(agent) sessions" : agent) + " running\(host) in \(project)")
      } else {
        add("\(s.host ?? "A terminal") open in \(project)")
      }
      if seen.count >= 3 { break }
    }
    // git, for the busiest projects.
    for p in ranked.prefix(3) {
      guard let git = p.git, let branch = git.branch else { continue }
      var text = "\(projectName(p.root.path)) on \(branch)"
      if let dirty = git.dirty { text += ", " + (dirty == 0 ? "clean" : AwarenessText.plural(dirty, "changed file")) }
      if let commit = git.lastCommit { text += ", last commit \(AwarenessText.ago(commit, now: now))" }
      add(text)
    }
    // What Spotlight says you opened last.
    if let (path, date) = signals.used.filter({ now.timeIntervalSince($0.value) < 86_400 && $0.value <= now })
      .max(by: { $0.value < $1.value })
    {
      add("Opened \(AwarenessText.name(path)) \(AwarenessText.ago(date, now: now))")
    }
    return Array(rows.prefix(9))
  }
}
