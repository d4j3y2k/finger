import AppKit
import Darwin

// scripts/check.sh builds this against the app's code. It checks "Working On"
// with injected fake signal sources and a fake clock: scoring and decay,
// grouping by project, the why lines, the trail and landing, the footer, the
// two menu switches and the "What Finger knows" registry. Then it drives the
// panel over a fixture home and writes light and dark PNGs of Home with
// Working On and of browsing with the blue dots. Nothing here reads the real
// Mac's activity.

private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> Any = "") {
  if !ok {
    FileHandle.standardError.write("FAILED: \(label) \(detail())\n".data(using: .utf8)!)
    exit(1)
  }
  print("ok -", label)
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

private func pump(_ seconds: TimeInterval) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

private func wait(_ label: String, _ condition: () -> Bool) {
  let end = Date().addingTimeInterval(5)
  while !condition() {
    precondition(Date() < end, "timed out: " + label)
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
  }
}

/// A clock the checks move by hand.
private final class FakeClock {
  private let lock = NSLock()
  private var value: Date
  init(_ start: Date) { value = start }
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }
}

/// A signal source the checks push into by hand.
private final class FakeSource: AwarenessSource {
  private let lock = NSLock()
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var refreshes = 0
  private var seen: [[String]] = []
  weak var sink: AwarenessSink?

  func start(_ sink: AwarenessSink) {
    starts += 1
    self.sink = sink
  }
  func stop() {
    stops += 1
    sink = nil
  }
  func refresh() { refreshes += 1 }
  func projects(_ roots: [(root: String, active: Date?)]) {
    lock.lock()
    seen.append(roots.map(\.root))
    lock.unlock()
  }
  var projectsSeen: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
  var running: Bool { sink != nil }
  func push(_ change: @escaping (inout AwarenessSignals) -> Void) {
    sink?.record {
      change(&$0)
      return true
    }
  }
}

/// A file system of paths that exist, for project roots without touching disk.
private func fakeFS(_ paths: Set<String>, files: [String: String] = [:]) -> AwarenessRoots.FileSystem {
  AwarenessRoots.FileSystem(exists: { paths.contains($0) || files[$0] != nil }, read: { files[$0] })
}

@main
private enum AwarenessChecks {
  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    scoring()
    grouping()
    model()
    registry()
    center()
    menu()
    untrustedGit()
    if CommandLine.arguments.count >= 2 {
      core = try TestCore(URL(fileURLWithPath: CommandLine.arguments[1]))
      defer { core.finish() }
      panel(shots: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
    } else {
      print("(no finger-core given: skipping the panel)")
    }
    print("awareness checks passed")
  }
}

// MARK: - Scoring and decay

private func scoring() {
  let t0 = Date(timeIntervalSince1970: 1_795_000_000)
  var score = AwarenessScore()
  score.add(1, at: t0.addingTimeInterval(-30 * 60), now: t0)
  check(near(score.now, 0.5), "a save 30 min ago counts half for now", score.now)
  check(near(score.week, pow(0.5, 1800 / 172_800)), "and nearly fully for this week", score.week)
  check(near(score.total, 0.5 + 0.3 * score.week), "the total weighs this week at 0.3", score.total)
  var later = AwarenessScore()
  later.add(1, at: t0, now: t0.addingTimeInterval(2 * 86_400))
  check(near(later.week, 0.5) && later.now < 1e-20, "two days later, this week counts half and now nothing", later)

  // One save: Working On now, gone six hours later.
  let home = "/h"
  let roots = AwarenessRoots(home: home, fs: fakeFS(["/h/Developer/rex/Cargo.toml"]))
  let m = AwarenessModel(home: home, roots: roots)
  var s = AwarenessSignals()
  s.save("/h/Developer/rex/src/main.rs", at: t0.addingTimeInterval(-5 * 60))
  check(m.compute(s, now: t0).items.map(\.path) == ["/h/Developer/rex/src/main.rs"], "a fresh save is Working On")
  check(m.compute(s, now: t0.addingTimeInterval(6 * 3600)).items.isEmpty, "and decays out of it in hours")
  // Opening a file once is Recents, not Working On.
  var opened = AwarenessSignals()
  opened.used["/h/Developer/rex/README.md"] = t0.addingTimeInterval(-10 * 60)
  check(m.compute(opened, now: t0).items.isEmpty, "opening a file once is not working on it")
  // Saves an editor makes in one go count once.
  var burst = AwarenessSignals()
  for offset in [0.0, 0.4, 1.1, 2.5] { burst.save("/h/a.txt", at: t0.addingTimeInterval(offset)) }
  burst.save("/h/a.txt", at: t0.addingTimeInterval(60))
  check(burst.saves["/h/a.txt"]?.count == 2, "one save's several events coalesce", burst.saves["/h/a.txt"] ?? [])
  // More activity ranks higher.
  var two = AwarenessSignals()
  for minutes in [2.0, 9, 17] { two.save("/h/Developer/rex/src/busy.rs", at: t0.addingTimeInterval(-minutes * 60)) }
  two.save("/h/Developer/rex/src/quiet.rs", at: t0.addingTimeInterval(-3 * 60))
  let ranked = m.compute(two, now: t0).items.map { AwarenessText.name($0.path) }
  check(ranked == ["busy.rs", "quiet.rs"], "three saves outrank one", ranked)
  // Old saves are dropped after two hours.
  var old = AwarenessSignals()
  old.save("/h/x.txt", at: t0.addingTimeInterval(-3 * 3600))
  old.save("/h/y.txt", at: t0.addingTimeInterval(-10 * 60))
  old.prune(now: t0)
  check(old.saves.keys.sorted() == ["/h/y.txt"], "saves older than two hours are dropped", old.saves.keys.sorted())
}

// MARK: - Grouping by project root

private func grouping() {
  let fs = fakeFS(
    [
      "/h/Developer/finger/.git", "/h/Developer/finger/Cargo.toml", "/h/Developer/finger/web/package.json",
      "/h/Developer/spleen/Package.swift", "/h/Developer/py/pyproject.toml",
    ],
    files: ["/h/.b-rex/worktrees/f/awareness/.git": "gitdir: /h/Developer/finger/.git/worktrees/awareness\n"])
  let roots = AwarenessRoots(home: "/h", fs: fs)
  func root(_ path: String) -> String { roots.root(ofFile: path).path }
  check(root("/h/Developer/finger/rust/launcher.rs") == "/h/Developer/finger", "the nearest folder with .git or Cargo.toml")
  check(root("/h/Developer/finger/web/src/app.ts") == "/h/Developer/finger/web", "a nested package.json is nearer")
  check(root("/h/Developer/spleen/Sources/Panel.swift") == "/h/Developer/spleen", "Package.swift marks a project")
  check(root("/h/Developer/py/lib/x.py") == "/h/Developer/py", "pyproject.toml marks a project")
  check(root("/h/Developer/scratch/notes.txt") == "/h/Developer/scratch", "no marker: the folder itself")
  check(
    root("/h/Studio/Fold Studies/exports/Overlap 01.svg") == "/h/Studio/Fold Studies",
    "a folder named like exports belongs to the one above it")
  check(root("/h/Documents/Finances/2026/Q4 budget.csv") == "/h/Documents/Finances", "so does a year")
  check(root("/h/Desktop/Screenshot.png") == "/h/Desktop", "a top-level folder stays itself")
  check(root("/h/Developer/scratch/try.py") == "/h/Developer/scratch", "rolling up stops below a top-level folder")
  check(root("/h/Documents/Codex/2026-11-21/can-x20/work/check.py") == "/h/Documents/Codex/2026-11-21/can-x20", "a work folder belongs to its task")
  check(
    root("/h/.b-rex/worktrees/f/awareness/native/Awareness.swift") == "/h/Developer/finger",
    "a linked worktree belongs to its main checkout")
  check(roots.accepts("/h/.b-rex/worktrees/f/awareness/native/Awareness.swift"), "a hidden folder counts inside a checkout")
  check(!roots.accepts("/h/.config/zed/settings.json"), "but not elsewhere")
  let counted = [
    "/h/Developer/finger/rust/launcher.rs", "/h/Studio/Fold Studies/exports/Overlap 01.svg",
  ]
  let skipped = [
    "/h/Library/Application Support/x.db", "/h/Developer/finger/target/release/finger",
    "/h/Developer/web/node_modules/a/index.js", "/h/Developer/finger/build/Finger.app/x",
    "/h/Developer/finger/.git/index", "/h/Developer/finger/.DS_Store", "/h/Developer/finger/x.swp",
    "/h/Library/Developer/Xcode/DerivedData/a/b.o", "/h/Developer/app/.build/debug/x",
    "/h/Developer/finger/rust/__pycache__/a.pyc", "/elsewhere/file.txt", "/h/Developer/finger/build.log",
  ]
  check(counted.allSatisfy { AwarenessFilter.counts($0, home: "/h") }, "work files count")
  let leaked = skipped.filter { AwarenessFilter.counts($0, home: "/h") }
  check(leaked.isEmpty, "Library, caches, .git, build, target, node_modules and DerivedData don't", leaked)
}

// MARK: - The model: why lines, trail, landing, footer

/// The mockup's afternoon: Overlap 01.svg open in Illustrator and saved three
/// times, its PNG saved, and a Claude Code session in Terminal editing finger.
private func mockupSignals(_ home: String, _ now: Date) -> AwarenessSignals {
  let fs = home + "/Studio/Fold Studies/exports"
  let finger = home + "/Developer/finger"
  func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
  var s = AwarenessSignals()
  s.front("Terminal", bundle: "com.apple.Terminal", at: ago(60))
  s.front("Illustrator", bundle: "com.adobe.illustrator", at: ago(25))
  s.document(fs + "/Overlap 01.svg", app: "Illustrator", bundle: "com.adobe.illustrator", at: ago(25))
  for minutes in [18.0, 9, 6] { s.save(fs + "/Overlap 01.svg", at: ago(minutes)) }
  s.save(fs + "/Overlap 01.png", at: ago(4))
  s.save(finger + "/rust/launcher.rs", at: ago(12))
  s.used[fs + "/Print notes.txt"] = ago(60)
  s.used[finger + "/README.md"] = ago(120)
  s.used[home + "/Developer/spleen/docs/DECISIONS_TRIAL.md"] = ago(2 * 1440)
  s.sessions = [
    AwarenessSession(kind: .agent("Claude Code"), folder: finger, host: "Terminal", active: ago(11), pid: 501),
    AwarenessSession(kind: .shell("zsh"), folder: home + "/Developer/rex", host: "Terminal", active: ago(300), pid: 502),
  ]
  s.git[finger] = AwarenessGit(branch: "main", lastCommit: ago(180), dirty: 2)
  return s
}

private func mockupFS(_ home: String) -> AwarenessRoots.FileSystem {
  fakeFS([home + "/Developer/finger/.git", home + "/Developer/finger/Cargo.toml", home + "/Developer/rex/Cargo.toml"])
}

private func model() {
  let home = "/h"
  let now = Date(timeIntervalSince1970: 1_795_000_000)
  let roots = AwarenessRoots(home: home, fs: mockupFS(home))
  let m = AwarenessModel(home: home, roots: roots)
  let snap = m.compute(mockupSignals(home, now), now: now)
  let exports = "/h/Studio/Fold Studies/exports"
  let names = snap.items.map { AwarenessText.name($0.path) }
  check(names == ["Overlap 01.svg", "Overlap 01.png", "launcher.rs"], "Working On: the busiest files, by project", names)
  check(snap.items.count <= 4, "at most four")
  check(
    snap.items.map(\.side) == ["Open in Illustrator", "Saved 4 min ago", "Edited 12 min ago"],
    "each with a short side line", snap.items.map(\.side))
  check(
    snap.items[0].why == "Open in Illustrator for 25 min, saved 3 times in the last 20 min",
    "why: open in an app, and saved several times", snap.items[0].why)
  check(
    snap.items[2].why == "Edited 12 min ago from a Claude Code session in finger",
    "why: edited by an agent session in the project", snap.items[2].why)
  check(snap.items[1].why == "Saved 4 min ago", "why: a plain save", snap.items[1].why)
  check(
    snap.footer == "Fold Studies in Illustrator · finger in Terminal",
    "the footer names the top two projects and where they happen", snap.footer)
  let finger = snap.projects.first { $0.name == "finger" }
  check(
    finger?.why == "Claude Code is running in Terminal here, and launcher.rs was edited 12 min ago.",
    "a project's why names its session and its latest edit", finger?.why ?? "nil")
  check(
    snap.why(folder: "/h/Studio/Fold Studies") == "Overlap 01.svg is open in Illustrator, and Overlap 01.svg was saved 6 min ago."
      || snap.why(folder: "/h/Studio/Fold Studies")?.hasPrefix("Overlap 01.svg is open in Illustrator") == true,
    "a design project's why names the open document", snap.why(folder: "/h/Studio/Fold Studies") ?? "nil")
  check(
    snap.why(folder: "/h/Developer/finger/rust") == "Has launcher.rs, which you are working on.",
    "a folder on the trail says what it leads to", snap.why(folder: "/h/Developer/finger/rust") ?? "nil")
  check(
    snap.why(folder: exports) == "Has Overlap 01.svg and Overlap 01.png, which you are working on.",
    "and lists two", snap.why(folder: exports) ?? "nil")
  check(snap.why(folder: "/h/Developer/spleen") == nil, "a folder off the trail has no why")

  // The trail.
  let trail = Set(snap.trail.keys)
  let expected: Set<String> = [
    "/h/Studio", "/h/Studio/Fold Studies", exports, "/h/Developer", "/h/Developer/finger", "/h/Developer/finger/rust",
  ]
  check(trail == expected, "the trail is every folder from Home down to the work", trail.sorted())
  check(!snap.marked("/h") && snap.marked(exports + "/Overlap 01.svg") && !snap.marked("/h/Developer/spleen"), "Home itself and other folders get no dot")
  let fingerKids = ["bridge", "docs", "native", "rust", "scripts", "Cargo.toml", "README.md"].map { "/h/Developer/finger/" + $0 }
  check(snap.landing(among: fingerKids) == "/h/Developer/finger/rust", "entering finger lands on rust")
  let devKids = ["dotfiles", "finger", "keypad", "rex", "spleen"].map { "/h/Developer/" + $0 }
  check(snap.landing(among: devKids) == "/h/Developer/finger", "entering Developer lands on finger")
  check(snap.landing(among: ["/h/Documents/a", "/h/Documents/b"]) == nil, "no trail, no opinion")

  // What Finger knows.
  let rows = snap.knowledge.map(\.signal)
  check(rows.contains("Illustrator in front with Overlap 01.svg, 25 min"), "knows the front document", rows)
  check(rows.contains("Terminal in front 35 min of the last hour"), "knows app time", rows)
  check(rows.contains("4 saves in Studio › Fold Studies › exports in 20 min"), "knows saves by folder", rows)
  check(rows.contains("Claude Code running in Terminal in finger"), "knows the agent session", rows)
  check(rows.contains("finger on main, 2 changed files, last commit 3 hr ago"), "knows git", rows)
  check(snap.knowledge.allSatisfy { $0.sent == "Stays on this Mac" }, "and none of it leaves this Mac")

  // Activity spread over many files makes the project the item.
  var spread = AwarenessSignals()
  for (i, name) in ["a", "b", "c", "d", "e", "f"].enumerated() {
    spread.save("/h/Developer/finger/native/\(name).swift", at: now.addingTimeInterval(Double(-2 - i) * 60))
  }
  spread.sessions = [
    AwarenessSession(kind: .agent("Claude Code"), folder: "/h/Developer/finger", host: "Ghostty", active: now, pid: 9),
    AwarenessSession(kind: .agent("Claude Code"), folder: "/h/Developer/finger", host: "Ghostty", active: now, pid: 10),
  ]
  let spreadSnap = m.compute(spread, now: now)
  check(
    spreadSnap.items.map(\.path) == ["/h/Developer/finger"] && spreadSnap.items[0].isFolder,
    "edits spread over six files show the project folder", spreadSnap.items.map(\.path))
  check(spreadSnap.items[0].side == "2 Claude Code sessions", "with its sessions on the side", spreadSnap.items[0].side)
  check(
    spreadSnap.items[0].why == "2 Claude Code sessions are running here, and 6 files were saved here in the last hour.",
    "and a project-level why", spreadSnap.items[0].why)
  check(spreadSnap.footer == "finger in Ghostty", "attributed to its terminal", spreadSnap.footer)

  // Work in an agent's hidden worktree shows its main checkout.
  let wtRoots = AwarenessRoots(
    home: home,
    fs: fakeFS(
      ["/h/Developer/finger/.git"],
      files: ["/h/.b-rex/worktrees/f/awareness/.git": "gitdir: /h/Developer/finger/.git/worktrees/awareness"]))
  var wt = AwarenessSignals()
  wt.save("/h/.b-rex/worktrees/f/awareness/native/Awareness.swift", at: now.addingTimeInterval(-60))
  wt.sessions = [
    AwarenessSession(kind: .agent("Claude Code"), folder: "/h/.b-rex/worktrees/f/awareness", host: "Rex", active: now, pid: 7)
  ]
  let wtSnap = AwarenessModel(home: home, roots: wtRoots).compute(wt, now: now)
  check(wtSnap.items.map(\.path) == ["/h/Developer/finger"], "an agent's worktree shows as its project", wtSnap.items.map(\.path))
  check(wtSnap.footer == "finger in Rex", "in the agent's terminal", wtSnap.footer)
  check(!wtSnap.trail.keys.contains { $0.contains("/.b-rex") }, "and no dot leads into a hidden folder")

  // A save made while an app that opens the file is in front is credited to it.
  var credited = AwarenessSignals()
  credited.front("Preview", bundle: "com.apple.Preview", at: now.addingTimeInterval(-600))
  credited.save("/h/Documents/Contracts/lease.pdf", at: now.addingTimeInterval(-120))
  credited.save("/h/Documents/Contracts/notes.md", at: now.addingTimeInterval(-90))
  let opener = AwarenessModel(home: home, roots: AwarenessRoots(home: home, fs: fakeFS([]))) { app, path in
    app.bundle == "com.apple.Preview" && path.hasSuffix(".pdf")
  }
  let creditedSnap = opener.compute(credited, now: now)
  check(creditedSnap.item("/h/Documents/Contracts/lease.pdf")?.why == "Saved 2 min ago in Preview", "a save credited to the app in front")
  check(creditedSnap.item("/h/Documents/Contracts/notes.md")?.why == "Saved 1 min ago", "only when that app opens such files")
  check(creditedSnap.footer == "Contracts in Preview", "and the footer says where", creditedSnap.footer)

  // A checkout or an unzip writes many files in one second: that is one event, not editing.
  var checkout = AwarenessSignals()
  let second = now.addingTimeInterval(-120)
  for i in 0..<40 { checkout.save("/h/Developer/finger/native/File\(i).swift", at: second.addingTimeInterval(Double(i % 3) * 0.2)) }
  checkout.save("/h/Developer/finger/native/Edited.swift", at: now.addingTimeInterval(-60))
  let checkoutSnap = m.compute(checkout, now: now)
  check(checkoutSnap.items.map { AwarenessText.name($0.path) } == ["Edited.swift"], "forty files written at once don't bury the one you edited", checkoutSnap.items.map(\.path))
  check(
    checkoutSnap.knowledge.first?.signal == "A save in Developer › finger › native 1 min ago",
    "and aren't counted as saves", checkoutSnap.knowledge.map(\.signal))

  // Agents nobody has seen do anything yet, and sessions in a bare top-level folder, don't make a project.
  var idle = AwarenessSignals()
  idle.sessions = (0..<5).map {
    AwarenessSession(kind: .agent("Claude Code"), folder: "/h/Developer/finger", host: nil, active: nil, pid: Int32(20 + $0))
  } + [AwarenessSession(kind: .agent("Claude Code"), folder: "/h/Developer", host: "Ghostty", active: now, pid: 30)]
  let idleSnap = m.compute(idle, now: now)
  check(idleSnap.items.isEmpty && idleSnap.footer.isEmpty, "idle agents and a session in ~/Developer itself are not Working On", idleSnap.items.map(\.path))

  // Words.
  check(AwarenessText.list(["a", "b", "c", "d"]) == "a, b and 2 more", "lists stay short")
  check(AwarenessText.duration(70 * 60) == "1 hr 10 min" && AwarenessText.duration(25 * 60) == "25 min", "durations")
  check(AwarenessApps.display("Adobe Illustrator 2026") == "Illustrator", "app names read short")
  check(AwarenessSessionSource.appName("/Applications/Ghostty.app/Contents/MacOS/ghostty") == "Ghostty", "a terminal from its bundle")
  check(
    AwarenessSessionSource.appName("/Users/x/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex") == "Rex",
    "Rex's server reads as Rex")
  check(AwarenessSessionSource.appName("/Applications/iTerm.app/Contents/MacOS/iTerm2") == "iTerm2", "iTerm reads as iTerm2")
}

// MARK: - What Finger knows: the registry

private func registry() {
  let before = PanelKnowledge.rows
  let jev = PanelKnowledge.register {
    [PanelKnowledgeRow(signal: "Invoice 1121.pdf from billing.harborprint.co", sent: "harborprint.co, file name")]
  }
  check(PanelKnowledge.rows == before + [PanelKnowledgeRow(signal: "Invoice 1121.pdf from billing.harborprint.co", sent: "harborprint.co, file name")], "another part of Finger adds its rows")
  PanelKnowledge.unregister(jev)
  check(PanelKnowledge.rows == before, "and removes them")
}

// MARK: - The center: fake sources, coalescing, the switches

private func makeHome() -> String {
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("Finger Awareness " + UUID().uuidString, isDirectory: true)
  return base.path
}

private func write(_ path: String, _ text: String = "x\n") {
  try! FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func center() {
  let home = makeHome()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let finger = home + "/Developer/finger"
  write(finger + "/Cargo.toml")
  write(finger + "/rust/launcher.rs")
  write(finger + "/rust/listing.rs")
  let clock = FakeClock(Date())
  let defaults = FingerMemoryPreferences()
  let settings = AwarenessSettings(defaults: defaults)
  var asked = 0
  var trusted = false
  settings.requestAccess = { asked += 1 }
  settings.trusted = { trusted }
  check(settings.useActivity && !settings.useDocuments, "Use Activity starts on and App Documents off")
  let saves = FakeSource()
  let processes = FakeSource()
  let documents = FakeSource()
  let c = AwarenessCenter(
    home: home, settings: settings, sources: [saves, processes], documents: documents, clock: { clock.now })
  c.delay = 0.15
  c.quietDelay = 0.15
  var changes = 0
  c.onChange = { changes += 1 }
  c.start()
  check(saves.running && processes.running && !documents.running, "starting runs the activity sources, not App Documents")

  // A burst of signals is one update.
  for i in 0..<8 { saves.push { $0.save(finger + "/rust/launcher.rs", at: clock.now.addingTimeInterval(Double(-i * 10))) } }
  processes.push {
    $0.sessions = [AwarenessSession(kind: .agent("Claude Code"), folder: finger, host: "Terminal", active: clock.now, pid: 1)]
  }
  wait("the snapshot") { !c.snapshot.items.isEmpty }
  pump(0.3)
  check(c.computeCount == 1 && changes == 1, "nine signals in a burst are one update", (c.computeCount, changes))
  check(c.workingFiles.map(\.name) == ["launcher.rs"] && !c.workingFiles[0].isFolder, "Working On reaches the panel as files", c.workingFiles.map(\.name))
  check(c.snapshot.footer == "finger in Terminal", "the footer", c.snapshot.footer)
  check(processes.projectsSeen.last == [finger], "git hears which projects are busy", processes.projectsSeen)
  check(PanelKnowledge.rows.contains { $0.signal == "Claude Code running in Terminal in finger" }, "its rows are in What Finger knows")

  // Opening the panel shows the cache at once and asks for fresher data.
  let computed = c.computeCount
  let start = Date()
  c.panelWillShow()
  check(Date().timeIntervalSince(start) < 0.05 && processes.refreshes == 1 && saves.refreshes == 1, "opening the panel never waits, and sources are asked to refresh")
  pump(0.3)
  check(c.computeCount == computed, "a fresh snapshot is not recomputed")
  clock.advance(60)
  c.panelWillShow()
  wait("a stale snapshot is recomputed") { c.snapshot.computed == clock.now }
  check(c.computeCount == computed + 1, "a stale one is", c.computeCount)
  check(c.snapshot.items.first?.side == "Saved 1 min ago" || c.snapshot.items.first?.side == "Edited 1 min ago", "with times moved on", c.snapshot.items.first?.side ?? "nil")

  // While the panel is closed, updates gather longer.
  c.quietDelay = 1
  c.panelDidHide()
  let quiet = c.computeCount
  saves.push { $0.save(finger + "/rust/launcher.rs", at: clock.now) }
  pump(0.5)
  check(c.computeCount == quiet, "with the panel closed, a save waits for others")
  wait("the quiet update") { c.computeCount == quiet + 1 }
  check(true, "and is scored a moment later")
  c.quietDelay = 0.15

  // A file that is gone is forgotten.
  write(finger + "/rust/gone.rs")
  for i in 0..<3 { saves.push { $0.save(finger + "/rust/gone.rs", at: clock.now.addingTimeInterval(Double(-i * 30))) } }
  wait("gone.rs shows") { c.workingFiles.contains { $0.name == "gone.rs" } }
  try! FileManager.default.removeItem(atPath: finger + "/rust/gone.rs")
  c.recomputeNow()
  pump(0.05)
  check(!c.workingFiles.contains { $0.name == "gone.rs" } && !c.snapshot.items.contains { $0.path.hasSuffix("gone.rs") }, "a deleted file leaves Working On")

  // App Documents asks for Accessibility once, and runs only while on.
  settings.useDocuments = true
  pump(0.05)
  check(asked == 1 && documents.running, "turning on App Documents asks macOS for Accessibility and starts it")
  documents.push { $0.document(finger + "/rust/listing.rs", app: "Zed", bundle: "dev.zed.Zed", at: clock.now) }
  wait("the document counts") { c.snapshot.item(finger + "/rust/listing.rs")?.side == "Open in Zed" }
  check(true, "the front document shows as open in its app")
  trusted = true
  settings.useDocuments = false
  pump(0.05)
  check(!documents.running && asked == 1, "turning it off stops it without asking again")
  wait("the document is forgotten") { c.snapshot.item(finger + "/rust/listing.rs") == nil }
  check(true, "and forgets the documents it read")
  settings.useDocuments = true
  pump(0.05)
  check(asked == 1 && documents.running, "once trusted, turning it on asks nothing")
  settings.useDocuments = false

  // Use Activity off stops everything and forgets it.
  settings.useActivity = false
  pump(0.05)
  check(!saves.running && !processes.running && !documents.running, "Use Activity off stops every source")
  check(c.snapshot.isEmpty && c.workingFiles.isEmpty, "and clears what the panel shows")
  check(!PanelKnowledge.rows.contains { $0.sent == PanelKnowledge.staysHere }, "and what Finger knows")
  saves.push { $0.save(finger + "/rust/launcher.rs", at: clock.now) }
  pump(0.3)
  check(c.snapshot.isEmpty, "signals that arrive late are ignored")
  c.panelWillShow()
  check(processes.refreshes == 2, "opening the panel asks nothing of stopped sources")
  settings.useActivity = true
  pump(0.05)
  check(saves.running && processes.running, "Use Activity on starts the sources again")
  c.recomputeNow()
  pump(0.05)
  check(c.snapshot.items.isEmpty, "with nothing remembered from before")
  settings.useActivity = false
  _ = c
}

private func menu() {
  let defaults = FingerMemoryPreferences()
  let settings = AwarenessSettings(defaults: defaults)
  var asked = 0
  settings.requestAccess = { asked += 1 }
  settings.trusted = { false }
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("finger-awareness-menu-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let menu = FingerStatusMenu(
    loginItem: FingerLoginItem(agents: root, executable: "/x", launchctl: "/usr/bin/false"), showPanel: {},
    openWindow: {}, editShortcut: {}, quit: {}, awareness: settings)
  menu.shortcuts = { nil }
  menu.refresh()
  let titles = menu.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
  check(titles.contains("Use Activity") && titles.contains("Use App Documents…"), "the menu bar menu has both switches", titles)
  check(menu.activity.state == .on && menu.documents.state == .off, "Use Activity is checked, App Documents is not")
  menu.menu.performActionForItem(at: menu.menu.index(of: menu.documents))
  check(settings.useDocuments && menu.documents.state == .on && asked == 1, "choosing App Documents turns it on and asks for Accessibility")
  menu.menu.performActionForItem(at: menu.menu.index(of: menu.activity))
  check(!settings.useActivity && menu.activity.state == .off, "choosing Use Activity turns it off")
  check(menu.documents.state == .off && !menu.documents.isEnabled, "and App Documents with it")
  menu.menu.performActionForItem(at: menu.menu.index(of: menu.activity))
  check(settings.useActivity && menu.activity.state == .on && menu.documents.isEnabled, "and back on")
}

// MARK: - Git in a repo that arrived from elsewhere

// A repo unpacked from a zip keeps its .git/config, and a clean filter named
// there runs during `git status`. Finger reads the config first and leaves such
// a repo's changed-file count unknown. This uses the real git, when there is one.
private func untrustedGit() {
  let base = NSTemporaryDirectory() + "finger-git-checks-\(getpid())"
  defer { try? FileManager.default.removeItem(atPath: base) }
  let repo = base + "/repo"
  let included = base + "/included"
  let marker = base + "/filter-ran"
  try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
  try! FileManager.default.createDirectory(atPath: included, withIntermediateDirectories: true)
  if let git = AwarenessGitSource.findGit() {
    func run(_ dir: String, _ args: [String]) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: git)
      process.arguments = ["-C", dir] + args
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try! process.run()
      process.waitUntilExit()
    }
    run(repo, ["init", "-q"])
    try! "hello\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try! "more\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
    run(repo, ["add", "a.txt"])
    let source = AwarenessGitSource(git: git)
    check(!AwarenessGitSource.configRunsCommands(repo), "a plain repo's config runs nothing")
    check(source.dirtyCount(repo, git: git) == 2, "and Finger counts its two changed files")

    run(repo, ["config", "filter.x.clean", "touch '\(marker)'; cat"])
    try! "* filter=x\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
    // Same text in a new file, as after unzipping: git must read it again, through the filter.
    try! "hello\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    check(AwarenessGitSource.configRunsCommands(repo), "a config that names a filter is caught")
    check(source.dirtyCount(repo, git: git) == nil, "so its changed-file count stays unknown")
    check(!FileManager.default.fileExists(atPath: marker), "and the filter never ran")
    run(repo, ["status", "--porcelain"])
    check(FileManager.default.fileExists(atPath: marker), "where a plain git status would have run it")

    run(included, ["init", "-q"])
    run(included, ["config", "include.path", base + "/elsewhere"])
    check(AwarenessGitSource.configRunsCommands(included), "an include is caught too")
  } else {
    print("   skipped: no git on this Mac")
  }
}

// MARK: - The panel

private final class TestCore {
  private let process = Process()
  private let input: FileHandle
  private let output: UnsafeMutablePointer<FILE>
  private let lock = NSLock()

  init(_ executable: URL) throws {
    let incoming = Pipe()
    let outgoing = Pipe()
    input = incoming.fileHandleForWriting
    output = fdopen(dup(outgoing.fileHandleForReading.fileDescriptor), "r")!
    process.executableURL = executable
    process.standardInput = incoming
    process.standardOutput = outgoing
    try process.run()
  }

  func forward(_ command: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    lock.lock()
    defer { lock.unlock() }
    var bytes = Data(bytes: command, count: strlen(command))
    bytes.append(10)
    input.write(bytes)
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    if getline(&line, &capacity, output) > 0 { return line }
    free(line)
    return nil
  }

  func finish() {
    try? input.close()
    process.waitUntilExit()
    fclose(output)
  }
}

private var core: TestCore!
private func send(_ service: Int32, _ data: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
  guard service == 0, let data else { return nil }
  return core.forward(data)
}

/// Recents from a fixed list, a moment later, like Spotlight.
private final class FixtureSearch: PanelSearching {
  final class Handle: PanelSearchHandle {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  let root: String
  var used: [String: Date] = [:]
  init(root: String) { self.root = root }

  func recentlyUsed(in home: String, _ done: @escaping ([PanelFile]) -> Void) -> PanelSearchHandle {
    let handle = Handle()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      guard !handle.cancelled else { return }
      done(self.used.sorted { $0.value > $1.value }.compactMap { path, date in
        var file = PanelFile.quick(path)
        file?.lastUsed = date
        return file
      })
    }
    return handle
  }

  func names(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void) -> PanelSearchHandle {
    let handle = Handle()
    var out: [PanelFile] = []
    let walker = FileManager.default.enumerator(atPath: scope)
    while let relative = walker?.nextObject() as? String {
      guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
      let path = scope + "/" + relative
      if PanelMatch.rank(query, in: (path as NSString).lastPathComponent) > 0, let file = PanelFile.quick(path) {
        out.append(file)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { if !handle.cancelled { update(out, true) } }
    return handle
  }

  func contents(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void) -> PanelSearchHandle {
    let handle = Handle()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { if !handle.cancelled { update([], true) } }
    return handle
  }
}

private func panel(shots: String?) {
  let root = makeHome()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let dev = root + "/Developer"
  let finger = dev + "/finger"
  let fold = root + "/Studio/Fold Studies"
  for path in [
    "Developer/dotfiles/zshrc", "Developer/finger/bridge/FingerMCP.swift", "Developer/finger/docs/AGENTS-CONNECTION.md",
    "Developer/finger/native/PreviewPane.swift", "Developer/finger/native/Browser.swift",
    "Developer/finger/rust/listing.rs", "Developer/finger/scripts/build.sh", "Developer/finger/Cargo.toml",
    "Developer/finger/README.md", "Developer/keypad/README.md", "Developer/orphne/README.md",
    "Developer/rex/README.md", "Developer/rex/Cargo.toml", "Developer/spleen/README.md", "Developer/spleen/Package.swift",
    "Documents/Finances/2026/Q4 budget.csv", "Studio/Posters/Spring poster.txt",
  ] {
    write(root + "/" + path)
  }
  write(finger + "/rust/launcher.rs", "fn lock<T: Default>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {\n    mutex.lock().unwrap_or_else(|p| p.into_inner())\n}\n")
  try! FileManager.default.createDirectory(atPath: finger + "/.git", withIntermediateDirectories: true)
  let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/Demo/Fold Studies")
  try! FileManager.default.createDirectory(atPath: root + "/Studio", withIntermediateDirectories: true)
  try! FileManager.default.copyItem(at: demo, to: URL(fileURLWithPath: fold))
  for extra in ["delivery", "invoices", "refs"] {
    try! FileManager.default.createDirectory(atPath: fold + "/" + extra, withIntermediateDirectories: true)
  }
  let exports = fold + "/exports"
  let svg = (try! FileManager.default.contentsOfDirectory(atPath: exports)).first { $0.hasSuffix(".svg") && $0.contains("01") }
  let png = (try! FileManager.default.contentsOfDirectory(atPath: exports)).first { $0.hasSuffix(".png") && $0.contains("01") }
  check(svg != nil && png != nil, "the practice project has Overlap 01 as SVG and PNG")

  let now = Date()
  func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
  // Everything a month old, so only the signals say what is recent.
  let old = now.addingTimeInterval(-31 * 86_400)
  let everything = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [])
    .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
  for relative in everything {
    try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + relative)
  }

  let search = FixtureSearch(root: root)
  // Spleen was opened more recently than anything in finger, so landing on
  // finger in Developer is the trail's doing, not recency's.
  search.used = [
    dev + "/spleen/README.md": ago(1),
    exports + "/Print notes.txt": ago(60),
    finger + "/README.md": ago(120),
    root + "/Documents/Finances/2026/Q4 budget.csv": ago(26 * 60),
  ]
  let defaults = FingerMemoryPreferences()
  let settings = AwarenessSettings(defaults: defaults)
  settings.trusted = { true }
  defaults.set(true, forKey: AwarenessSettings.documentsKey)
  let signals = FakeSource()
  let documents = FakeSource()
  let awareness = AwarenessCenter(
    home: root, settings: settings, sources: [signals], documents: documents, clock: { now })
  awareness.delay = 0.05
  awareness.quietDelay = 0.05
  awareness.start()
  let illustrator = AwarenessFront(app: "Illustrator", bundle: "com.adobe.illustrator", start: ago(25))
  signals.push { s in
    s.front("Terminal", bundle: "com.apple.Terminal", at: ago(60))
    s.front("Illustrator", bundle: "com.adobe.illustrator", at: ago(25))
    for minutes in [18.0, 9, 6] { s.save(exports + "/" + svg!, at: ago(minutes)) }
    s.save(exports + "/" + png!, at: ago(4))
    s.save(finger + "/rust/launcher.rs", at: ago(12))
    s.sessions = [
      AwarenessSession(kind: .agent("Claude Code"), folder: finger, host: "Terminal", active: ago(11), pid: 501)
    ]
    s.git[finger] = AwarenessGit(branch: "main", lastCommit: ago(180), dirty: 2)
  }
  documents.push { $0.document(exports + "/" + svg!, app: illustrator.app, bundle: illustrator.bundle, at: ago(25)) }
  wait("awareness") { awareness.snapshot.items.count == 3 }

  let engine = Engine(send, { free($0) })
  let c = PanelController(engine: engine, search: search, home: root, preview: ContentPreview())
  c.hidesOnResignKey = false
  c.allowsMotion = false
  c.awareness = awareness
  let panel = c.panel
  panel.appearance = NSAppearance(named: .aqua)
  c.showOffscreen()

  func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
    let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
    let characters = arrows[code].map { String(UnicodeScalar(UInt16($0))!) } ?? chars
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
    panel.sendEvent(event)
  }
  func type(_ text: String) { for ch in text { key(0, String(ch)) } }
  let ret: UInt16 = 36, esc: UInt16 = 53, del: UInt16 = 51, down: UInt16 = 125
  func name(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "nil" }
  func cell(_ path: String) -> PanelItemCell? {
    guard let row = c.rowIndex(of: path) else { return nil }
    return c.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PanelItemCell
  }

  // Home: Working On first.
  wait("home") { c.sectionTitles.first == "Working On" && c.sectionTitles.contains("Recents") }
  let working = c.items(in: "Working On")
  check(working.map(\.file.name) == [svg!, png!, "launcher.rs"], "Working On leads Home", working.map(\.file.name))
  check(
    working.map { $0.side ?? "" } == ["Open in Illustrator", "Saved 4 min ago", "Edited 12 min ago"],
    "its rows say why on the right", working.map { $0.side ?? "" })
  check(working[0].subtitle == "Studio › Fold Studies › exports" && working[2].subtitle == "Developer › finger › rust", "and where on the second line", working.map { $0.subtitle ?? "" })
  check(!c.items(in: "Recents").contains { $0.file.name == "launcher.rs" }, "Recents doesn't repeat them")
  check(cell(working[0].file.path)?.dot == false, "Home's own rows have no dots")
  check(c.footer.status == "Fold Studies in Illustrator · finger in Terminal" && c.footer.aware, "the footer says what you're working on", c.footer.status)
  snapshot(c, shots, "home-working-on")

  // The footer status opens What Finger knows; esc closes it first.
  c.root.layoutSubtreeIfNeeded()
  c.footer.display()
  let status = c.footer.convert(NSPoint(x: c.footer.statusRect.midX, y: c.footer.statusRect.midY), to: nil)
  c.footer.mouseDown(
    with: NSEvent.mouseEvent(
      with: .leftMouseDown, location: status, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
  check(c.knowledgeShown, "clicking the status opens What Finger knows")
  let jev = PanelKnowledge.register { [PanelKnowledgeRow(signal: "Invoice 1121.pdf from billing.harborprint.co", sent: "harborprint.co, file name")] }
  c.refreshKnowledge()
  let shown = c.knowledgeView.rows
  check(shown.first?.signal == "Illustrator in front with \(svg!), 25 min", "it lists the signals", shown.map(\.signal))
  check(shown.dropLast().allSatisfy { $0.sent == "Stays on this Mac" } && shown.last?.sent == "harborprint.co, file name", "with what is sent, and other parts of Finger add rows")
  check(c.knowledgeView.frame.maxY <= c.root.bounds.height - PanelRootView.searchHeight && c.knowledgeView.frame.minX == 10, "it sits above the footer, inside the panel", c.knowledgeView.frame)
  snapshot(c, shots, "what-finger-knows")
  PanelKnowledge.unregister(jev)
  key(esc, "\u{1b}")
  check(!c.knowledgeShown && panel.isVisible, "esc puts it away and leaves the panel up")

  // Into Developer: land on finger, the trail, not the more recently used spleen.
  type("dev")
  wait("found Developer") { c.items(in: "Files & Folders").first?.file.path == dev }
  check(c.awarenessDot(c.items(in: "Files & Folders")[0]), "a search result on the trail has a dot")
  key(ret, "\r")
  wait("inside Developer") { c.folder == dev && c.selectedPath != nil }
  check(name(c.selectedPath) == "finger", "entering Developer lands on finger, the trail", name(c.selectedPath))
  check(cell(finger)?.dot == true && cell(dev + "/spleen")?.dot == false, "finger has a dot; spleen doesn't")
  check(cell(finger)?.side == "11 min ago", "its time is the latest activity inside, not the folder's date", cell(finger)?.side ?? "nil")
  wait("the peek reads finger") { c.peek.content?.items != nil }
  check(
    c.peek.content?.why == "Claude Code is running in Terminal here, and launcher.rs was edited 12 min ago.",
    "the peek says why finger matters", c.peek.content?.why ?? "nil")
  check(c.peek.content?.landing == finger + "/rust", "and tints rust, where you would land", c.peek.content?.landing ?? "nil")
  check(c.footer.status == "Fold Studies in Illustrator · finger in Terminal", "the footer keeps the status while browsing", c.footer.status)
  snapshot(c, shots, "inside-developer-dots")

  key(ret, "\r")
  wait("inside finger") { c.folder == finger && c.selectedPath != nil }
  check(name(c.selectedPath) == "rust", "finger lands on rust", name(c.selectedPath))
  wait("the peek reads rust") { c.peek.content?.items != nil }
  check(cell(finger + "/rust")?.side == "12 min ago", "rust was last touched when launcher.rs was edited", cell(finger + "/rust")?.side ?? "nil")
  check(c.peek.content?.why == "Has launcher.rs, which you are working on.", "rust's peek says what it leads to", c.peek.content?.why ?? "nil")
  check(c.peek.marked(finger + "/rust/launcher.rs") && !c.peek.marked(finger + "/rust/listing.rs"), "and dots launcher.rs in the peek")
  snapshot(c, shots, "inside-finger-dots")
  key(ret, "\r")
  wait("inside rust") { c.folder == finger + "/rust" && c.selectedPath != nil }
  check(name(c.selectedPath) == "launcher.rs", "rust lands on launcher.rs", name(c.selectedPath))

  // Where you left off still comes first.
  key(del, "\u{7f}")
  wait("back in finger") { c.folder == finger && name(c.selectedPath) == "rust" }
  key(down, "")
  check(name(c.selectedPath) == "scripts", "↓ to scripts", name(c.selectedPath))
  key(del, "\u{7f}")
  wait("up to Developer") { c.folder == dev }
  key(ret, "\r")
  wait("finger again") { c.folder == finger && c.selectedPath != nil }
  check(name(c.selectedPath) == "scripts", "where you left off beats the trail", name(c.selectedPath))

  // Use Activity off: no Working On, dots, trail landing or status.
  settings.useActivity = false
  pump(0.1)
  check(c.awareness?.snapshot.isEmpty == true && cell(finger + "/rust")?.dot == false, "with Use Activity off the dots go")
  check(c.footer.status == "~/Developer/finger" && !c.footer.aware, "and the footer goes back to the folder", c.footer.status)
  key(esc, "\u{1b}")
  wait("out of the folders") { c.folder == nil }
  key(esc, "\u{1b}")
  check(!panel.isVisible, "esc twice hides the panel")
  c.showOffscreen()
  if !c.query.isEmpty { key(esc, "\u{1b}") }
  wait("home without Working On") { c.sectionTitles.first == "Recents" || c.sectionTitles.first == "Just Arrived" }
  check(!c.sectionTitles.contains("Working On"), "and Home has no Working On", c.sectionTitles)
  check(c.footer.status == "⌃Space shows and hides this panel", "and the footer is the shortcut again", c.footer.status)
  c.hide()
  _ = awareness
}

/// Light and dark PNGs of the panel on a quiet desktop, like PanelChecks.
private func snapshot(_ c: PanelController, _ shots: String?, _ title: String) {
  guard let shots else { return }
  pump(0.05)
  c.root.layoutSubtreeIfNeeded()
  let panel = c.panel
  if let file = c.selectedItem?.file, !file.isFolder, let preview = c.preview as? ContentPreview {
    wait("preview of \(file.name)") { preview.report.url?.path == file.path && preview.report.kind != .loading }
  }
  for (suffix, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    panel.appearance = NSAppearance(named: look)
    pump(0.08)
    let view = c.root
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let dark = look == .darkAqua
    let size = view.bounds.size
    let margin: CGFloat = 48
    let canvas = NSImage(size: NSSize(width: size.width + margin * 2, height: size.height + margin * 2), flipped: false) { rect in
      let wall = dark
        ? NSGradient(colors: [NSColor(srgbRed: 0.23, green: 0.33, blue: 0.41, alpha: 1), NSColor(srgbRed: 0.23, green: 0.19, blue: 0.16, alpha: 1)])!
        : NSGradient(colors: [NSColor(srgbRed: 0.73, green: 0.81, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.91, green: 0.80, blue: 0.66, alpha: 1)])!
      wall.draw(in: rect, angle: -35)
      let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
      let shape = NSBezierPath(roundedRect: frame, xRadius: FingerPanel.radius, yRadius: FingerPanel.radius)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 30
      shadow.shadowOffset = NSSize(width: 0, height: -12)
      shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.28)
      shadow.set()
      (dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 0.9) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 0.9)).setFill()
      shape.fill()
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    let out = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(canvas.size.width * 2), pixelsHigh: Int(canvas.size.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = canvas.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
      canvas.draw(in: NSRect(origin: .zero, size: canvas.size))
    }
    NSGraphicsContext.restoreGraphicsState()
    let file = (shots as NSString).appendingPathComponent("\(title)-\(suffix).png")
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
  }
  panel.appearance = NSAppearance(named: .aqua)
  print("   wrote \(title)-light.png and \(title)-dark.png")
}
