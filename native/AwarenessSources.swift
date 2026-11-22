import AppKit
import ApplicationServices
import CoreServices
import Darwin

// The live signals behind "Working On". Every one of them stays on this Mac.
// Each source works off the main thread and reports through its sink, which
// is AwarenessCenter. None polls tightly: FSEvents and NSWorkspace push, the
// process scan runs at most every 10 seconds, git only after activity.

/// Where a source reports. AwarenessCenter implements it.
protocol AwarenessSink: AnyObject {
  var home: String { get }
  /// The center's clock.
  var now: Date { get }
  /// Changes the signals on the center's queue. Return false when nothing changed.
  func record(_ change: @escaping (inout AwarenessSignals) -> Bool)
  /// Another app came to the front.
  func hint()
}

protocol AwarenessSource: AnyObject {
  func start(_ sink: AwarenessSink)
  func stop()
  /// Fresher data would help now: the panel is opening, or another app came
  /// to the front. Sources rate-limit it themselves.
  func refresh()
  /// The busiest projects after an update, with their latest activity.
  func projects(_ roots: [(root: String, active: Date?)])
}

extension AwarenessSource {
  func refresh() {}
  func projects(_ roots: [(root: String, active: Date?)]) {}
}

extension AwarenessApps {
  /// "Adobe Illustrator 2026" reads as "Illustrator".
  static func display(_ name: String) -> String {
    var n = name
    for prefix in ["Adobe ", "Microsoft "] where n.hasPrefix(prefix) && n.count > prefix.count + 2 {
      n = String(n.dropFirst(prefix.count))
    }
    if let r = n.range(of: #" (\(Beta\)|20\d\d)$"#, options: .regularExpression) { n.removeSubrange(r) }
    return n
  }
}

// MARK: - 1. Recently used files

/// Spotlight's kMDItemLastUsedDate, through the panel's own Recents query.
/// It runs once at start; after that the panel hands over each fresh result.
final class AwarenessSpotlightSource: AwarenessSource {
  let search: PanelSearching
  private var handle: PanelSearchHandle?

  init(search: PanelSearching) { self.search = search }

  func start(_ sink: AwarenessSink) {
    DispatchQueue.main.async { [weak self, weak sink] in
      guard let self, let sink, self.handle == nil else { return }
      self.handle = self.search.recentlyUsed(in: sink.home) { [weak sink] files in
        sink?.record { AwarenessSpotlightSource.merge(files, into: &$0) }
      }
    }
  }

  func stop() {
    DispatchQueue.main.async { [weak self] in
      self?.handle?.cancel()
      self?.handle = nil
    }
  }

  @discardableResult
  static func merge(_ files: [PanelFile], into signals: inout AwarenessSignals) -> Bool {
    var changed = false
    for file in files where !file.isFolder {
      guard let used = file.lastUsed, (file.name as NSString).pathExtension != "app" else { continue }
      if signals.used[file.path].map({ $0 < used }) ?? true {
        signals.used[AwarenessPath.native(file.path)] = used
        changed = true
      }
    }
    return changed
  }
}

// MARK: - 2. Recent saves

/// An FSEvents stream on Home. On start it replays the last two hours from
/// the system's event history, so saves made before Finger started count.
final class AwarenessSaveSource: AwarenessSource {
  private let queue = DispatchQueue(label: "finger.awareness.saves", qos: .utility)
  private var stream: FSEventStreamRef?
  private weak var sink: AwarenessSink?
  private var home = ""
  var latency: CFTimeInterval = 2

  func start(_ sink: AwarenessSink) {
    self.sink = sink
    home = sink.home
    queue.async { [weak self] in self?.open() }
  }

  func stop() {
    queue.sync { close() }
  }

  deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }

  private func close() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  private func open() {
    guard stream == nil else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let me = Unmanaged<AwarenessSaveSource>.fromOpaque(info).takeUnretainedValue()
      let list = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).map(AwarenessPath.native)
      me.received(list, Array(UnsafeBufferPointer(start: flags, count: count)))
    }
    let since = AwarenessSaveSource.replayStart(home)
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagIgnoreSelf)
    guard
      let made = FSEventStreamCreate(
        kCFAllocatorDefault, callback, &context, [home] as CFArray, since, latency, flags)
    else { return }
    // At most eight; everything else is filtered by name.
    let skipped = ["Library", ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".local", "Pictures/Photos Library.photoslibrary"]
    FSEventStreamSetExclusionPaths(made, skipped.map { home + "/" + $0 } as CFArray)
    FSEventStreamSetDispatchQueue(made, queue)
    if !FSEventStreamStart(made) {
      FSEventStreamInvalidate(made)
      FSEventStreamRelease(made)
      return
    }
    stream = made
  }

  /// Where the replay of recent history starts. The per-device lookup by time
  /// returns 0 on APFS, so it falls back to the last `replayEvents` event ids:
  /// about two hours on a busy Mac, a second or so of work once at start.
  /// The files' own times then decide what falls within two hours.
  static var replayEvents: UInt64 = 2_000_000

  static func replayStart(_ home: String) -> FSEventStreamEventId {
    var info = stat()
    if stat(home, &info) == 0 {
      let earlier = FSEventsGetLastEventIdForDeviceBeforeTime(
        info.st_dev, CFAbsoluteTimeGetCurrent() - AwarenessSignals.keepSaves)
      if earlier != 0 { return earlier }
    }
    let current = FSEventsGetCurrentEventId()
    guard current > replayEvents else { return 1 }
    return current - replayEvents
  }

  private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
    guard let sink else { return }
    let wanted = UInt32(
      kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemRenamed)
    let now = Date()
    let cutoff = now.addingTimeInterval(-AwarenessSignals.keepSaves)
    var saves: [(String, Date)] = []
    var gone: [String] = []
    var seen = Set<String>()
    for (path, flag) in zip(paths, flags) {
      guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, flag & wanted != 0,
        seen.insert(path).inserted, AwarenessFilter.counts(path, home: home)
      else { continue }
      var info = stat()
      guard lstat(path, &info) == 0 else {
        gone.append(path)
        continue
      }
      guard info.st_mode & S_IFMT == S_IFREG else { continue }
      // The file's own time: a replayed event has no time of its own, and
      // several events of one save share it.
      let modified = Date(
        timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
      guard modified >= cutoff, modified <= now.addingTimeInterval(60) else { continue }
      saves.append((path, modified))
    }
    guard !saves.isEmpty || !gone.isEmpty else { return }
    sink.record { signals in
      for path in gone { signals.forget(path) }
      for (path, date) in saves { signals.save(path, at: date) }
      return true
    }
  }
}

// MARK: - 3. The app in front

/// NSWorkspace activations: which app is in front, and for how long.
final class AwarenessFrontSource: AwarenessSource {
  private var observer: NSObjectProtocol?

  func start(_ sink: AwarenessSink) {
    DispatchQueue.main.async { [weak self, weak sink] in
      guard let self, let sink, self.observer == nil else { return }
      if let app = NSWorkspace.shared.frontmostApplication { AwarenessFrontSource.note(app, sink) }
      self.observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak sink] note in
        guard let sink,
          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        AwarenessFrontSource.note(app, sink)
        sink.hint()
      }
    }
  }

  static func note(_ app: NSRunningApplication, _ sink: AwarenessSink) {
    let name = AwarenessApps.display(app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App")
    let bundle = app.bundleIdentifier
    let time = sink.now
    sink.record {
      $0.front(name, bundle: bundle, at: time)
      return true
    }
  }

  func stop() {
    DispatchQueue.main.async { [weak self] in
      if let observer = self?.observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
      self?.observer = nil
    }
  }
}

// MARK: - 4. Terminal and agent folders

/// The folders your shells and agent CLIs are in, read with proc_pidinfo, and
/// the terminal app each runs in. Activity comes from the terminal's tty times
/// (as `w` reads them) and, for agents without one, from CPU use between scans.
final class AwarenessSessionSource: AwarenessSource {
  static let shells: Set<String> = ["zsh", "bash", "fish", "nu", "xonsh", "tcsh", "ksh"]
  private let queue = DispatchQueue(label: "finger.awareness.sessions", qos: .utility)
  private var timer: DispatchSourceTimer?
  private weak var sink: AwarenessSink?
  private var last: Date?
  private var cpu: [pid_t: (total: UInt64, at: Date)] = [:]
  private var cpuActive: [pid_t: Date] = [:]
  /// A background scan this often; refresh() asks for one at most every `gap`.
  var interval: TimeInterval = 60
  var gap: TimeInterval = 10
  private(set) var scans = 0

  func start(_ sink: AwarenessSink) {
    self.sink = sink
    queue.async { [weak self] in
      guard let self, self.timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(
        deadline: .now() + self.interval, repeating: self.interval, leeway: .seconds(Int(self.interval / 3)))
      timer.setEventHandler { [weak self] in self?.scanNow() }
      timer.resume()
      self.timer = timer
      self.scanNow()
    }
  }

  func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
      cpu.removeAll()
      cpuActive.removeAll()
      last = nil
    }
  }

  func refresh() {
    queue.async { [weak self] in
      guard let self, self.timer != nil else { return }
      if let last = self.last, Date().timeIntervalSince(last) < self.gap { return }
      self.scanNow()
    }
  }

  private func scanNow() {
    guard let sink else { return }
    last = Date()
    scans += 1
    let found = scan(home: sink.home, now: sink.now)
    sink.record {
      if $0.sessions == found { return false }
      $0.sessions = found
      return true
    }
  }

  private struct Proc {
    var ppid: pid_t
    var comm: String
    var tty: UInt32
  }

  private static let timebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(max(1, info.denom)))
  }()

  /// One pass over your processes. Read-only.
  func scan(home: String, now: Date) -> [AwarenessSession] {
    var table: [pid_t: Proc] = [:]
    for pid in Self.pids() {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
      let comm = withUnsafePointer(to: &info.pbi_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
      }
      table[pid] = Proc(ppid: pid_t(info.pbi_ppid), comm: comm, tty: info.e_tdev)
    }
    var hosts: [pid_t: String?] = [:]
    // `login` runs as root, so a terminal's shells have a parent outside the table.
    func parent(_ pid: pid_t) -> (ppid: pid_t, comm: String)? {
      if let proc = table[pid] { return (proc.ppid, proc.comm) }
      var info = proc_bsdshortinfo()
      let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
      let comm = withUnsafePointer(to: &info.pbsi_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
      }
      return (pid_t(info.pbsi_ppid), comm)
    }
    func host(_ pid: pid_t) -> String? {
      var p = pid
      var walked: [pid_t] = []
      var found: String?
      while p > 1, let proc = parent(p), walked.count < 24 {
        if let known = hosts[p] { found = known; break }
        walked.append(p)
        if proc.comm == "tmux" { found = "tmux"; break }
        if let path = Self.path(p), let app = Self.appName(path) { found = app; break }
        p = proc.ppid
      }
      for w in walked { hosts[w] = found }
      return found
    }
    var sessions: [AwarenessSession] = []
    var agentTTYs = Set<UInt32>()
    var alive = Set<pid_t>()
    for (pid, proc) in table {
      var agent: String?
      if proc.comm == "claude" {
        agent = "Claude Code"
      } else if proc.comm.hasPrefix("codex") {
        agent = "Codex"
      } else if proc.comm.first?.isNumber == true, proc.comm.contains("."),
        Self.path(pid)?.contains("/claude/versions/") == true
      {
        agent = "Claude Code"
      } else if proc.comm == "node", proc.tty != UInt32.max {
        let args = Self.arguments(pid).dropFirst().prefix(2).joined(separator: " ")
        if args.contains("claude-code") || args.hasSuffix("/claude") { agent = "Claude Code" }
        else if args.contains("@openai/codex") || args.hasSuffix("/codex") { agent = "Codex" }
      }
      let shell = agent == nil && Self.shells.contains(proc.comm) && proc.tty != UInt32.max
      guard agent != nil || shell else { continue }
      // A supervisor waiting for remote sessions is not a session.
      if agent == "Claude Code", Self.arguments(pid).contains("remote-control") { continue }
      guard let cwd = Self.cwd(pid), cwd.hasPrefix(home + "/") else { continue }
      alive.insert(pid)
      var active = Self.ttyActivity(proc.tty)
      if agent != nil {
        var task = proc_taskinfo()
        let tsize = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, tsize) == tsize {
          let total = (task.pti_total_user + task.pti_total_system) * Self.timebase.numer / Self.timebase.denom
          // Working, not idling: at least 2.5% of a core since the last scan. An
          // idle session's timers use well under 1%.
          if let before = cpu[pid], total >= before.total {
            let elapsed = max(1, now.timeIntervalSince(before.at))
            if Double(total - before.total) / 1e9 >= max(0.25, 0.025 * elapsed) { cpuActive[pid] = now }
          }
          cpu[pid] = (total, now)
        }
        if let busy = cpuActive[pid] { active = max(active ?? busy, busy) }
        if proc.tty != UInt32.max { agentTTYs.insert(proc.tty) }
      }
      sessions.append(
        AwarenessSession(
          kind: agent.map { .agent($0) } ?? .shell(proc.comm), folder: AwarenessPath.native(cwd), host: host(pid),
          active: active, pid: pid))
    }
    for pid in cpu.keys where !alive.contains(pid) {
      cpu[pid] = nil
      cpuActive[pid] = nil
    }
    // A shell running an agent says nothing the agent doesn't.
    sessions.removeAll {
      if case .shell = $0.kind, let tty = table[$0.pid]?.tty { return agentTTYs.contains(tty) }
      return false
    }
    return sessions.sorted { $0.pid < $1.pid }
  }

  static func pids() -> [pid_t] {
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
    guard bytes > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
    let filled = proc_listpids(
      UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
  }

  static func cwd(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
  }

  static func path(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return n > 0 ? String(cString: buffer) : nil
  }

  /// argv, from KERN_PROCARGS2.
  static func arguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var i = 4
    while i < size, buffer[i] != 0 { i += 1 }
    while i < size, buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < Int(argc), i < size {
      let start = i
      while i < size, buffer[i] != 0 { i += 1 }
      args.append(String(decoding: buffer[start..<i], as: UTF8.self))
      i += 1
    }
    return args
  }

  /// The latest output on a terminal, which includes the echo of what you
  /// type. Not its read time: any process that opens the device moves that.
  static func ttyActivity(_ device: UInt32) -> Date? {
    guard device != UInt32.max, let name = devname(dev_t(bitPattern: device), mode_t(S_IFCHR)) else { return nil }
    var info = stat()
    guard stat("/dev/" + String(cString: name), &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
  }

  static let hostNames: [String: String] = [
    "Rex Server": "Rex", "iTerm": "iTerm2", "Visual Studio Code": "VS Code", "Code": "VS Code",
    "WarpPreview": "Warp", "Terminal": "Terminal",
  ]

  /// The outermost app bundle in an executable's path.
  static func appName(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    let bundle = String(path[..<range.lowerBound])
    let name = (bundle as NSString).lastPathComponent
    return hostNames[name] ?? AwarenessApps.display(name)
  }
}

// MARK: - 5. git

/// Branch, last commit and changed files for the busiest projects. Branch and
/// commit come from files in the git folder; changed files from `git status`,
/// run off the main thread with a time limit, and only after activity there.
final class AwarenessGitSource: AwarenessSource {
  private let queue = DispatchQueue(label: "finger.awareness.git", qos: .utility)
  private weak var sink: AwarenessSink?
  private var known: [String: (info: AwarenessGit, checked: Date, stamp: Date?)] = [:]
  private var running = false
  let git: String?
  private(set) var statusRuns = 0

  init(git: String? = AwarenessGitSource.findGit()) { self.git = git }

  /// A real git, never the /usr/bin shim, which offers to install the developer tools.
  static func findGit() -> String? {
    var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
    let tools = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"]
    candidates += tools.map { $0 + "/usr/bin/git" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  func start(_ sink: AwarenessSink) {
    self.sink = sink
    queue.async { self.running = true }
  }

  func stop() {
    queue.sync {
      running = false
      known.removeAll()
    }
  }

  func projects(_ roots: [(root: String, active: Date?)]) {
    queue.async { [weak self] in
      guard let self, self.running, let sink = self.sink else { return }
      for (root, active) in roots.prefix(4) {
        guard let gitdir = Self.gitdir(root) else { continue }
        let stamp = [Self.modified(gitdir + "/index"), Self.modified(gitdir + "/HEAD"), active].compactMap { $0 }.max()
        if let entry = self.known[root], entry.stamp == stamp || Date().timeIntervalSince(entry.checked) < 60 {
          continue
        }
        var info = AwarenessGit(branch: Self.branch(gitdir), lastCommit: Self.lastCommit(gitdir))
        info.dirty = self.git.flatMap { self.dirtyCount(root, git: $0) }
        let changed = self.known[root]?.info != info
        self.known[root] = (info, Date(), stamp)
        if changed {
          sink.record {
            $0.git[root] = info
            return true
          }
        }
      }
    }
  }

  static func gitdir(_ root: String) -> String? {
    let dotgit = root + "/.git"
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotgit, isDirectory: &isDir) else { return nil }
    if isDir.boolValue { return dotgit }
    guard let text = try? String(contentsOfFile: dotgit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
    let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
  }

  static func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  static func branch(_ gitdir: String) -> String? {
    guard let head = try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8) else { return nil }
    let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
    return line.isEmpty ? nil : String(line.prefix(7))
  }

  /// The newest "commit" entry in HEAD's reflog.
  static func lastCommit(_ gitdir: String) -> Date? {
    guard let handle = FileHandle(forReadingAtPath: gitdir + "/logs/HEAD") else { return nil }
    defer { try? handle.close() }
    let end = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2, parts[1].hasPrefix("commit") else { continue }
      let fields = parts[0].split(separator: " ")
      if fields.count >= 2, let seconds = TimeInterval(fields[fields.count - 2]) {
        return Date(timeIntervalSince1970: seconds)
      }
    }
    return nil
  }

  /// True when the repository's own config could make `git status` run a
  /// program. A repo that arrives in a zip, by AirDrop or in a shared folder
  /// brings its .git/config along, and a clean or process filter named there
  /// runs during status. An include could bring one in from elsewhere. The
  /// match is deliberately broad: a false alarm only costs the changed-file
  /// count. Submodules are skipped with --ignore-submodules, and fsmonitor
  /// is turned off on the command line.
  static func configRunsCommands(_ root: String) -> Bool {
    guard let gitdir = gitdir(root) else { return true }
    var files = [gitdir + "/config", gitdir + "/config.worktree"]
    // A linked worktree's gitdir names the shared one in "commondir".
    if let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) {
      let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
      let dir = path.hasPrefix("/") ? path : (gitdir as NSString).appendingPathComponent(path)
      files += [dir + "/config", dir + "/config.worktree"]
    }
    for file in files where FileManager.default.fileExists(atPath: file) {
      guard let data = FileManager.default.contents(atPath: file), data.count <= 1 << 20 else { return true }
      let text = String(decoding: data, as: UTF8.self).lowercased()
      if text.contains("filter") || text.contains("include") { return true }
    }
    return false
  }

  /// `git status` entries, or nil when git doesn't answer within three seconds
  /// or the repository's config could make status run a program.
  func dirtyCount(_ root: String, git: String) -> Int? {
    guard !Self.configRunsCommands(root) else { return nil }
    statusRuns += 1
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git)
    process.arguments = [
      "-C", root, "--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain", "-z",
      "--untracked-files=normal", "--ignore-submodules=all",
    ]
    process.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0, process.terminationReason == .exit else { return nil }
    var count = 0
    var skipNext = false
    for entry in data.split(separator: 0) {
      if skipNext {
        skipNext = false
        continue
      }
      count += 1
      // A rename or copy is followed by its old path.
      if let first = entry.first, first == UInt8(ascii: "R") || first == UInt8(ascii: "C") { skipNext = true }
    }
    return count
  }
}

// MARK: - 6. App documents (off unless you turn it on)

/// The front window's document through Accessibility (kAXDocumentAttribute).
/// It only runs when "Use App Documents…" is on and Finger is trusted; it
/// never asks for the permission itself.
final class AwarenessDocumentSource: AwarenessSource {
  private let queue = DispatchQueue(label: "finger.awareness.documents", qos: .utility)
  private weak var sink: AwarenessSink?
  private var observer: NSObjectProtocol?
  var trusted: () -> Bool = { AXIsProcessTrusted() }

  func start(_ sink: AwarenessSink) {
    self.sink = sink
    DispatchQueue.main.async { [weak self] in
      guard let self, self.observer == nil else { return }
      self.observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Let the app bring its window forward first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
      }
      self.refresh()
    }
  }

  func stop() {
    DispatchQueue.main.async { [weak self] in
      if let observer = self?.observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
      self?.observer = nil
    }
    sink = nil
  }

  func refresh() {
    let read = { [weak self] in
      guard let self, let sink = self.sink, self.trusted(),
        let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid()
      else { return }
      let pid = app.processIdentifier
      let name = AwarenessApps.display(app.localizedName ?? "App")
      let bundle = app.bundleIdentifier
      self.queue.async {
        let path = AwarenessDocumentSource.document(pid)
        let time = sink.now
        sink.record {
          $0.document(path, app: name, bundle: bundle, at: time)
          return true
        }
      }
    }
    if Thread.isMainThread { read() } else { DispatchQueue.main.async(execute: read) }
  }

  static func document(_ pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
      let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &value) == .success,
      let text = value as? String, let url = URL(string: text), url.isFileURL
    else { return nil }
    return url.path
  }
}

// MARK: - Which app opens what

/// Whether an app can open a file, from LaunchServices, cached by app and extension.
final class AwarenessOpeners {
  private var cache: [String: Bool] = [:]
  private let lock = NSLock()

  func opens(_ app: AwarenessFront, _ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    let key = (app.bundle ?? app.app) + "|" + ext
    lock.lock()
    if let hit = cache[key] {
      lock.unlock()
      return hit
    }
    lock.unlock()
    var answer = false
    if let bundle = app.bundle {
      let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: path))
      answer = urls.contains { Bundle(url: $0)?.bundleIdentifier == bundle }
    }
    lock.lock()
    cache[key] = answer
    lock.unlock()
    return answer
  }
}
