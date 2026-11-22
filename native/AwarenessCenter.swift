import AppKit
import ApplicationServices

/// The menu bar item's two switches. "Use Activity" (on by default) turns all
/// of Working On off and forgets what was collected. "Use App Documents…"
/// (off by default) adds the front window's document through Accessibility.
final class AwarenessSettings {
  static let changed = Notification.Name("FingerAwarenessSettingsChanged")
  static let shared = AwarenessSettings()
  static let activityKey = "useActivity"
  static let documentsKey = "useAppDocuments"

  let defaults: UserDefaults
  /// Asks macOS for Accessibility; macOS shows its own dialog. Only turning
  /// App Documents on calls it.
  var requestAccess: () -> Void = {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
  var trusted: () -> Bool = { AXIsProcessTrusted() }

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var useActivity: Bool {
    get { defaults.object(forKey: AwarenessSettings.activityKey) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: AwarenessSettings.activityKey)
      NotificationCenter.default.post(name: AwarenessSettings.changed, object: self)
    }
  }

  var useDocuments: Bool {
    get { defaults.object(forKey: AwarenessSettings.documentsKey) as? Bool ?? false }
    set {
      defaults.set(newValue, forKey: AwarenessSettings.documentsKey)
      if newValue && !trusted() { requestAccess() }
      NotificationCenter.default.post(name: AwarenessSettings.changed, object: self)
    }
  }
}

/// What the panel reads from awareness. Main thread only; nothing here waits.
protocol PanelAwareness: AnyObject {
  /// The latest result, ready at once.
  var snapshot: AwarenessSnapshot { get }
  /// Working On, as the panel's rows.
  var workingFiles: [PanelFile] { get }
  /// Runs on the main thread after the snapshot changes.
  var onChange: (() -> Void)? { get set }
  /// The panel is opening: worth refreshing, but show what is cached now.
  func panelWillShow()
  /// The panel closed: updates can gather longer.
  func panelDidHide()
  /// The panel's own Spotlight Recents arrived.
  func noteUsage(_ files: [PanelFile])
}

/// Collects the signals, scores them off the main thread and keeps the latest
/// snapshot for the panel. Changes are coalesced: a burst of saves is one
/// update half a second later.
final class AwarenessCenter: PanelAwareness, AwarenessSink {
  let home: String
  let settings: AwarenessSettings
  let clock: () -> Date
  let sources: [AwarenessSource]
  let documents: AwarenessSource?
  /// How long changes gather before the model runs again, while the panel is
  /// open and while it is closed.
  var delay: TimeInterval = 0.5
  var quietDelay: TimeInterval = 5
  /// A snapshot older than this is recomputed when the panel opens, so "12 min ago" stays true.
  var staleAfter: TimeInterval = 15

  private let queue = DispatchQueue(label: "finger.awareness", qos: .utility)
  // On the queue.
  private var signals = AwarenessSignals()
  private let roots: AwarenessRoots
  private var model: AwarenessModel
  private var pending = false
  private var collecting = false
  private var collectingDocuments = false
  private var panelOpen = false
  private var queueEpoch = 0
  private(set) var computeCount = 0
  // On the main thread.
  private(set) var snapshot = AwarenessSnapshot.empty
  private(set) var workingFiles: [PanelFile] = []
  var onChange: (() -> Void)?
  private(set) var activityOn = false
  private(set) var documentsOn = false
  private var epoch = 0
  private var knowledge: Int?
  private var observer: NSObjectProtocol?

  init(
    home: String, settings: AwarenessSettings, sources: [AwarenessSource], documents: AwarenessSource?,
    clock: @escaping () -> Date = Date.init, fileSystem: AwarenessRoots.FileSystem = .live,
    opens: ((AwarenessFront, String) -> Bool)? = nil
  ) {
    let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    self.home = home
    self.settings = settings
    self.sources = sources
    self.documents = documents
    self.clock = clock
    roots = AwarenessRoots(home: home, fs: fileSystem)
    model = AwarenessModel(home: home, roots: roots, opens: opens)
    knowledge = PanelKnowledge.register { [weak self] in self?.snapshot.knowledge ?? [] }
    observer = NotificationCenter.default.addObserver(
      forName: AwarenessSettings.changed, object: settings, queue: .main
    ) { [weak self] _ in self?.apply() }
  }

  /// Finger's own: Spotlight, FSEvents, NSWorkspace, the process table, git
  /// and, when allowed, Accessibility.
  static func live(home: String = NSHomeDirectory(), settings: AwarenessSettings = .shared, search: PanelSearching)
    -> AwarenessCenter
  {
    let openers = AwarenessOpeners()
    return AwarenessCenter(
      home: home, settings: settings,
      sources: [
        AwarenessSpotlightSource(search: search), AwarenessSaveSource(), AwarenessFrontSource(),
        AwarenessSessionSource(), AwarenessGitSource(),
      ],
      documents: AwarenessDocumentSource(), opens: openers.opens)
  }

  deinit {
    if let knowledge { PanelKnowledge.unregister(knowledge) }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    for source in sources { source.stop() }
    documents?.stop()
  }

  var now: Date { clock() }

  /// Starts collecting if the settings allow it.
  func start() { apply() }

  /// Brings collection in line with the two switches.
  func apply() {
    let wantActivity = settings.useActivity
    let wantDocuments = wantActivity && settings.useDocuments
    if wantActivity && !activityOn {
      activityOn = true
      queue.sync { collecting = true }
      for source in sources { source.start(self) }
    } else if !wantActivity && activityOn {
      activityOn = false
      for source in sources { source.stop() }
      epoch += 1
      let next = epoch
      queue.sync {
        collecting = false
        signals = AwarenessSignals()
        roots.clear()
        queueEpoch = next
      }
      snapshot = .empty
      workingFiles = []
      onChange?()
    }
    if wantDocuments && !documentsOn {
      documentsOn = true
      queue.sync { collectingDocuments = true }
      documents?.start(self)
    } else if !wantDocuments && documentsOn {
      documentsOn = false
      documents?.stop()
      queue.sync {
        collectingDocuments = false
        signals.documents.removeAll()
      }
      if activityOn { queue.async { self.schedule() } }
    }
  }

  // MARK: Sink

  func record(_ change: @escaping (inout AwarenessSignals) -> Bool) {
    queue.async {
      guard self.collecting else { return }
      let changed = change(&self.signals)
      if !self.collectingDocuments && !self.signals.documents.isEmpty { self.signals.documents.removeAll() }
      if changed { self.schedule() }
    }
  }

  func hint() {
    guard activityOn else { return }
    for source in sources { source.refresh() }
  }

  // MARK: Panel

  func panelWillShow() {
    queue.async { self.panelOpen = true }
    guard activityOn else { return }
    for source in sources { source.refresh() }
    if documentsOn { documents?.refresh() }
    let age = snapshot.computed.map { clock().timeIntervalSince($0) } ?? .infinity
    if age > staleAfter { queue.async { self.schedule() } }
  }

  func panelDidHide() {
    queue.async { self.panelOpen = false }
  }

  func noteUsage(_ files: [PanelFile]) {
    guard activityOn else { return }
    record { AwarenessSpotlightSource.merge(files, into: &$0) }
  }

  /// Runs the model now and waits for it, for checks and the probe. The new
  /// snapshot reaches the main thread on its next turn.
  func recomputeNow() {
    queue.sync { recompute() }
  }

  /// Waits for signals already sent to be recorded.
  func drain() { queue.sync {} }

  /// A copy of what is held, for checks and the probe.
  func held() -> AwarenessSignals { queue.sync { signals } }

  /// How much of each signal is held, for the probe.
  func summary() -> String {
    queue.sync {
      let s = signals
      return "\(s.used.count) recently used, \(s.saves.count) saved files (\(s.saves.values.reduce(0) { $0 + $1.count }) saves), "
        + "\(s.fronts.count) app switches, \(s.documents.count) documents, \(s.sessions.count) sessions, \(s.git.count) repos"
    }
  }

  // MARK: Queue

  private func schedule() {
    guard collecting, !pending else { return }
    pending = true
    queue.asyncAfter(deadline: .now() + (panelOpen ? delay : max(delay, quietDelay))) { [weak self] in
      guard let self else { return }
      self.pending = false
      self.recompute()
    }
  }

  private func recompute() {
    guard collecting else { return }
    computeCount += 1
    let now = clock()
    signals.prune(now: now)
    var snap = model.compute(signals, now: now)
    // Files that are gone since they were seen are forgotten.
    var files: [PanelFile] = []
    var missing: [String] = []
    for item in snap.items {
      guard var file = PanelFile.quick(item.path) else {
        missing.append(item.path)
        continue
      }
      file.lastUsed = signals.used[item.path]
      files.append(file)
    }
    if !missing.isEmpty {
      for path in missing { signals.forget(path) }
      snap = model.compute(signals, now: now)
      files = files.filter { file in snap.items.contains { $0.path == file.path } }
    }
    let busy: [(root: String, active: Date?)] = snap.projects.map { project in
      let prefix = project.root + "/"
      let last = signals.saves.filter { $0.key.hasPrefix(prefix) }.compactMap { $0.value.last }.max()
      return (project.root, last)
    }
    let captured = queueEpoch
    let result = snap
    DispatchQueue.main.async { [weak self] in
      guard let self, self.activityOn, self.epoch == captured else { return }
      self.snapshot = result
      self.workingFiles = files
      self.onChange?()
    }
    for source in sources { source.projects(busy) }
  }
}
