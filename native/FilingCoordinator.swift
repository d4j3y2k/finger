import Foundation

/// Works out in the background where each new download probably belongs.
///
/// It watches Downloads, gathers candidate folders on this Mac, then asks Jev
/// once per file, one request at a time. Results are cached by path, size and
/// modification time. Failures back off. Nothing here blocks the main thread;
/// `changed` reports new verdicts there.
final class FilingCoordinator {
  let home: String
  let downloads: String
  let credentials: FilingCredentials
  let transport: FilingTransport
  let evidence: FilingEvidenceSource
  let memory: FilingMemory
  let log: FilingLog
  let defaults: UserDefaults
  var now: () -> Date = Date.init

  /// Paths whose verdicts or local candidates changed. Main thread.
  var changed: ((Set<String>) -> Void)?
  /// The set of arrivals changed. Main thread.
  var arrivalsChanged: (() -> Void)?

  private(set) var arrivals: [FilingArrival] = []
  private(set) var verdicts: [FilingKey: FilingVerdict] = [:]
  private(set) var gathered: [FilingKey: FilingGathered] = [:]
  private(set) var backoff = FilingBackoff()
  /// How many requests reached the transport, for checks.
  private(set) var requestsSent = 0

  private var gathering: Set<FilingKey> = []
  private var queue: [FilingKey] = []
  private var asking: (key: FilingKey, task: Task<Void, Never>)?
  private var retry: DispatchWorkItem?
  private var expiry: DispatchWorkItem?
  private var scanGeneration = 0
  private var watcher: FilingFolderWatcher?
  private let work = DispatchQueue(label: "finger.filing.gather", qos: .utility)

  init(
    home: String = NSHomeDirectory(), credentials: FilingCredentials, transport: FilingTransport,
    evidence: FilingEvidenceSource, memory: FilingMemory = .shared, log: FilingLog = .shared,
    defaults: UserDefaults = .standard
  ) {
    let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    self.home = home
    downloads = home + "/Downloads"
    self.credentials = credentials
    self.transport = transport
    self.evidence = evidence
    self.memory = memory
    self.log = log
    self.defaults = defaults
    NotificationCenter.default.addObserver(
      self, selector: #selector(credentialsChanged), name: FilingCredentials.changed, object: credentials)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stop()
  }

  // MARK: - Watching Downloads

  func start() {
    if watcher == nil {
      watcher = FilingFolderWatcher(folder: downloads) { [weak self] in self?.scan() }
    }
    watcher?.start()
    credentials.load(on: work)
    scan()
  }

  func stop() {
    watcher?.stop()
    retry?.cancel()
    expiry?.cancel()
    asking?.task.cancel()
    asking = nil
    queue.removeAll()
  }

  var isWatching: Bool { watcher?.isRunning == true }

  /// Reads Downloads again off the main thread.
  func scan(_ done: (() -> Void)? = nil) {
    scanGeneration += 1
    let generation = scanGeneration
    let downloads = self.downloads
    let at = now()
    work.async { [weak self] in
      let found = FilingArrivals.scan(downloads, now: at)
      DispatchQueue.main.async {
        guard let self, generation == self.scanGeneration else { return }
        self.receive(found)
        done?()
      }
    }
  }

  func receive(_ found: [FilingArrival]) {
    let before = arrivals
    arrivals = found
    let live = Set(found.map(\.key))
    // A file that left, or changed, stops its request.
    if let current = asking, !live.contains(current.key) {
      current.task.cancel()
      asking = nil
    }
    queue.removeAll { !live.contains($0) }
    for arrival in found { prepare(arrival.key, host: arrival.host) }
    scheduleExpiry()
    if before != found { arrivalsChanged?() }
    pump()
  }

  private func scheduleExpiry() {
    expiry?.cancel()
    guard let oldest = arrivals.map(\.added).min() else { return }
    let wait = max(1, oldest.addingTimeInterval(FilingArrivals.window).timeIntervalSince(now()) + 1)
    let item = DispatchWorkItem { [weak self] in self?.scan() }
    expiry = item
    DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
  }

  func arrival(_ path: String) -> FilingArrival? { arrivals.first { $0.path == path } }

  /// The verdict for an arrival as it is now, when Jev is on.
  func verdict(for path: String) -> FilingVerdict? {
    guard credentials.cachedSource.map({ $0 != .none }) == true, let arrival = arrival(path) else { return nil }
    return verdicts[arrival.key]
  }

  func local(for path: String) -> FilingGathered? {
    guard let arrival = arrival(path) else { return nil }
    return gathered[arrival.key]
  }

  /// The file left Downloads through Finger: drop it now rather than at the next scan.
  func forget(_ path: String) {
    if let current = asking, current.key.path == path {
      current.task.cancel()
      asking = nil
    }
    queue.removeAll { $0.path == path }
    let before = arrivals.count
    arrivals.removeAll { $0.path == path }
    if arrivals.count != before { arrivalsChanged?() }
    pump()
  }

  // MARK: - Gathering candidates

  private var recentDestinations: [String] {
    FolderReferences.unique(defaults.stringArray(forKey: "recentDestinations") ?? [], limit: 12)
  }

  private func prepare(_ key: FilingKey, host: String?) {
    guard gathered[key] == nil, !gathering.contains(key) else {
      enqueue(key)
      return
    }
    gathering.insert(key)
    gather(path: key.path, host: host) { [weak self] result in
      guard let self else { return }
      self.gathering.remove(key)
      guard self.arrivals.contains(where: { $0.key == key }) else { return }
      self.gathered[key] = result
      self.changed?([key.path])
      self.enqueue(key)
      self.pump()
    }
  }

  /// Gathers local candidates for any file, such as one ⌥M was pressed on.
  func gather(path: String, host: String? = nil, _ done: @escaping (FilingGathered) -> Void) {
    let home = self.home
    let source = evidence
    let memory = self.memory
    let destinations = recentDestinations
    let at = now()
    let downloads = self.downloads
    work.async {
      let host = host ?? FilingArrivals.sourceHost(path)
      var input = FilingGather.Input(file: path, host: host, home: home)
      if let host { input.hostFiles = source.files(from: host, excluding: downloads) }
      let name = (path as NSString).lastPathComponent
      if let stem = FilingText.stem(name) {
        input.similarFiles = source.files(
          named: stem, ext: (name as NSString).pathExtension, excluding: downloads)
      }
      input.memory = memory.entries
      input.recent = source.recentlyUsed()
      input.recentDestinations = destinations
      input.now = at
      let result = FilingGather.gather(input)
      DispatchQueue.main.async { done(result) }
    }
  }

  // MARK: - Asking Jev

  private func enqueue(_ key: FilingKey) {
    guard verdicts[key] == nil, gathered[key] != nil, asking?.key != key, !queue.contains(key) else { return }
    queue.append(key)
  }

  /// Starts the next request when Jev is on, nothing is in flight and backoff allows.
  private func pump() {
    guard asking == nil, !queue.isEmpty else { return }
    guard let source = credentials.cachedSource else { return }  // still reading the Keychain
    guard source != .none else { return }
    let at = now()
    guard backoff.allows(at) else {
      scheduleRetry()
      return
    }
    let key = queue.removeFirst()
    guard let local = gathered[key], verdicts[key] == nil else {
      pump()
      return
    }
    let folders = FilingCoordinator.question(local, home: home)
    guard folders.count > 1 else {
      // One candidate is not a question; leave the file to the move list.
      pump()
      return
    }
    let credentials = self.credentials
    let transport = self.transport
    let home = self.home
    let name = (key.path as NSString).lastPathComponent
    let host = local.host
    requestsSent += 1
    let task = Task { @MainActor [weak self] in
      do {
        guard let apiKey = credentials.key else { throw FilingJevError.status(401, retryAfter: nil) }
        let request = try FilingJev.request(
          file: name, host: host, folders: folders.map { FilingJev.Folder($0.folder, home: home) }, key: apiKey)
        self?.logRequest(name: name, host: host, folders: folders.map(\.folder))
        try Task.checkCancellation()
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        try FilingJev.check(response)
        let probabilities = try FilingJev.probabilities(data, count: folders.count)
        self?.answered(key, local: local, folders: folders.map(\.folder), probabilities: probabilities)
      } catch is CancellationError {
        self?.finished(key)
      } catch let error as URLError where error.code == .cancelled {
        self?.finished(key)
      } catch {
        self?.failed(key, error)
      }
    }
    asking = (key, task)
  }

  /// The folders Jev hears about: the best local candidates, with Desktop and
  /// Documents always among them as the general places things go.
  static func question(_ local: FilingGathered, home: String) -> [FilingCandidate] {
    let general = [home + "/Desktop", home + "/Documents"]
    let fallbacks = local.candidates.filter { general.contains($0.folder) }
    let rest = local.candidates.filter { !general.contains($0.folder) }
    return Array(rest.prefix(FilingJev.candidateLimit - fallbacks.count)) + fallbacks
  }

  private func logRequest(name: String, host: String?, folders: [String]) {
    let names = folders.map { FilingText.folderName($0, home: home) }
    log.add(
      host.map { "\(name) arrived from \($0)" } ?? "\(name) arrived in Downloads",
      sent: host.map { "Its file name and \($0)" } ?? "Its file name")
    log.add(
      "\(folders.count) folders it might belong in",
      sent: "Folder names: " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : ""))
  }

  private func finished(_ key: FilingKey) {
    if asking?.key == key { asking = nil }
    pump()
  }

  private func answered(_ key: FilingKey, local: FilingGathered, folders: [String], probabilities: [Double]) {
    guard asking?.key == key else { return }
    asking = nil
    backoff.succeeded()
    let ranked = zip(folders, probabilities).enumerated()
      .sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1 }
      .map { FilingRanked(folder: $0.element.0, probability: $0.element.1) }
    let name = (key.path as NSString).lastPathComponent
    let why = ranked.first.flatMap { top in
      local.evidence(for: top.folder).flatMap {
        FilingText.why(file: name, host: local.host, evidence: $0, now: now())
      }
    }
    verdicts[key] = FilingVerdict(ranked: ranked, why: why)
    if let top = ranked.first, let why {
      log.add(
        why.replacingOccurrences(of: " here", with: " in " + FilingText.folderName(top.folder, home: home)),
        sent: FilingLog.staysHere)
    }
    changed?([key.path])
    pump()
  }

  private func failed(_ key: FilingKey, _ error: Error) {
    if asking?.key == key { asking = nil }
    backoff.failed(error, at: now())
    // Ask again later, unless the key was refused.
    if arrivals.contains(where: { $0.key == key }), !queue.contains(key) { queue.insert(key, at: 0) }
    scheduleRetry()
  }

  private func scheduleRetry() {
    retry?.cancel()
    guard let at = backoff.notBefore, !backoff.waitingForKey else { return }
    let item = DispatchWorkItem { [weak self] in self?.pump() }
    retry = item
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, at.timeIntervalSince(now())), execute: item)
  }

  /// Tries again now, for checks that move the clock.
  func retryNow() { pump() }

  @objc private func credentialsChanged() {
    backoff.keyChanged()
    let paths = Set(arrivals.map(\.path))
    for key in gathered.keys where verdicts[key] == nil { enqueue(key) }
    if credentials.cachedSource == FilingCredentials.Source.none {
      asking?.task.cancel()
      asking = nil
    }
    changed?(paths)
    pump()
  }

  /// Whether Jev is on, as last read.
  var jevOn: Bool { credentials.cachedSource.map { $0 != .none } ?? false }
  var isAsking: Bool { asking != nil }
}
