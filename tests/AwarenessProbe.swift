import AppKit

// A read-only look at this Mac: runs Finger's live awareness sources once and
// prints what the panel would show right now. It reads Spotlight, the last two
// hours of FSEvents history, the front app, your shells' and agents' folders,
// and git (with --no-optional-locks), and writes nothing. scripts/awareness-probe.sh
// builds and runs it. Not part of check.sh: its output depends on the Mac.
//
//   --signals    also list the recently used and saved files it holds
//   --watch N    keep the sources running N seconds and report their CPU use
//   --bench      time the model on what it holds (--loop runs it 400 times, for `sample`)

private func pump(_ seconds: TimeInterval) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

private func ago(_ date: Date?) -> String {
  guard let date else { return "–" }
  return AwarenessText.ago(date, now: Date())
}

@main
private enum AwarenessProbe {
  static func main() {
    let started = Date()
    let home = NSHomeDirectory()
    // Read-only settings: nothing is written to defaults.
    let settings = AwarenessSettings(defaults: UserDefaults(suiteName: "finger.awareness.probe.readonly")!)
    let spotlight = AwarenessSpotlightSource(search: SpotlightSearch(home: home))
    let saves = AwarenessSaveSource()
    let front = AwarenessFrontSource()
    let sessions = AwarenessSessionSource()
    sessions.gap = 2
    let git = AwarenessGitSource()
    let documents = AwarenessDocumentSource()
    let trusted = AXIsProcessTrusted()
    let center = AwarenessCenter(
      home: home, settings: settings, sources: [spotlight, saves, front, sessions, git],
      documents: trusted ? documents : nil, opens: AwarenessOpeners().opens)
    center.delay = 0.2
    center.quietDelay = 0.2
    center.start()
    if trusted { documents.start(center) }

    // Spotlight and the FSEvents replay arrive over a few seconds.
    pump(6)
    // A second process scan, so agents without a terminal show CPU use.
    sessions.refresh()
    pump(0.5)
    // How long one scan takes, timed on a scanner of its own.
    let scanner = AwarenessSessionSource()
    let scanStart = Date()
    _ = scanner.scan(home: home, now: Date())
    let scanTime = Date().timeIntervalSince(scanStart)
    pump(2)
    let found = scanner.scan(home: home, now: Date())
    center.recomputeNow()
    // git answers for the busiest projects, then once more.
    pump(4)
    let modelStart = Date()
    center.recomputeNow()
    let modelTime = Date().timeIntervalSince(modelStart)
    pump(0.2)
    let snap = center.snapshot

    print("Finger awareness probe — \(Date()) — read-only")
    print("Accessibility trusted: \(trusted) (App Documents is \(trusted ? "available" : "not used"))")
    print("")
    print("FOOTER")
    print("  " + (snap.footer.isEmpty ? "(nothing: the footer keeps its usual text)" : "• " + snap.footer))
    print("")
    print("WORKING ON")
    if snap.items.isEmpty { print("  (empty)") }
    let place = PanelPlace(home: home)
    for item in snap.items {
      let kind = item.isFolder ? "folder" : "file"
      print("  \(AwarenessText.name(item.path))  [\(kind) in \(place.whereText(item.path))]")
      print("      side: \(item.side)")
      print("      why:  \(item.why)")
      print(String(format: "      score: %.2f", item.score))
    }
    print("")
    print("PROJECTS")
    for p in snap.projects {
      print(String(format: "  %-28@ %5.2f  %@", p.name as NSString, p.score, (p.host.map { "in " + $0 } ?? "") as NSString))
      if !p.why.isEmpty { print("      \(p.why)") }
    }
    print("")
    print("TRAIL (blue dots on folders)")
    for (path, _) in snap.trail.sorted(by: { $0.key < $1.key }).prefix(30) { print("  " + place.abbreviated(path)) }
    if snap.trail.count > 30 { print("  … \(snap.trail.count - 30) more") }
    print("")
    print("ACTIVE (blue dots on items): \(snap.active.count)")
    for (path, score) in snap.active.sorted(by: { $0.value > $1.value }).prefix(12) {
      print(String(format: "  %5.2f  %@", score, place.abbreviated(path) as NSString))
    }
    print("")
    print("WHAT FINGER KNOWS")
    for row in snap.knowledge { print("  \(row.signal)  |  \(row.sent)") }
    print("")
    print("SESSIONS (one process scan finds \(found.count) in \(String(format: "%.1f", scanTime * 1000)) ms)")
    for s in found.sorted(by: { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }).prefix(20) {
      let kind: String
      switch s.kind {
      case .agent(let name): kind = name
      case .shell(let name): kind = name
      }
      print("  \(kind.padding(toLength: 12, withPad: " ", startingAt: 0)) \(place.abbreviated(s.folder))  in \(s.host ?? "?")  active \(ago(s.active))")
    }
    print("")
    print("Signals held: " + center.summary())
    if CommandLine.arguments.contains("--signals") {
      let held = center.held()
      for (path, date) in held.used.sorted(by: { $0.value > $1.value }) { print("  used  \(ago(date))  \(place.abbreviated(path))") }
      for (path, dates) in held.saves { print("  saved \(dates.count)× last \(ago(dates.last))  \(place.abbreviated(path))") }
    }
    print(String(format: "One model run: %.1f ms", modelTime * 1000))
    if CommandLine.arguments.contains("--bench") {
      let held = center.held()
      let roots = AwarenessRoots(home: home)
      let model = AwarenessModel(home: home, roots: roots, opens: AwarenessOpeners().opens)
      if CommandLine.arguments.contains("--loop") {
        for _ in 0..<400 { _ = model.compute(held, now: Date()) }
      }
      for label in ["cold", "warm", "warm"] {
        let t = Date()
        _ = model.compute(held, now: Date())
        print(String(format: "  compute (%@): %.1f ms", label, Date().timeIntervalSince(t) * 1000))
      }
    }
    print("Process scans \(sessions.scans), git status runs \(git.statusRuns), model runs \(center.computeCount)")
    print("Probe took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

    // --watch N: keep the sources running N seconds and report what they cost.
    if let i = CommandLine.arguments.firstIndex(of: "--watch"), i + 1 < CommandLine.arguments.count,
      let seconds = TimeInterval(CommandLine.arguments[i + 1])
    {
      func cpu() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
      }
      // As in the app with the panel closed.
      center.quietDelay = 5
      let (cpu0, runs0, scans0, git0) = (cpu(), center.computeCount, sessions.scans, git.statusRuns)
      // Sleep in the run loop like the app does, rather than spinning it.
      let keepAlive = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { _ in }
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
      keepAlive.invalidate()
      let used = cpu() - cpu0
      print("")
      print(String(format: "WATCH %.0f s: %.2f s CPU (%.2f%%), %d model runs, %d process scans, %d git status runs",
        seconds, used, used / seconds * 100, center.computeCount - runs0, sessions.scans - scans0, git.statusRuns - git0))
      print("  footer now: " + center.snapshot.footer)
    }

    for source in [spotlight, saves, front, sessions, git] as [AwarenessSource] { source.stop() }
    documents.stop()
    pump(0.1)
  }
}
