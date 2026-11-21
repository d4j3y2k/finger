import Darwin
import Foundation

struct FingerAgentSelection {
  let folder: URL?
  let collection: String?
  /// Called on the request worker after the window has frozen its selection.
  let paths: () -> [String]

  init(folder: URL?, collection: String? = nil, paths: @escaping () -> [String]) {
    self.folder = folder
    self.collection = collection
    self.paths = paths
  }
  init(folder: URL?, files: [URL], collection: String? = nil) {
    self.init(folder: folder, collection: collection, paths: { files.map(\.path) })
  }
}

// A rename or normal contents edit preserves this identity. A replaced regular
// file or symlink gets a new identity on filesystems that expose it.
enum FileIdentity: Equatable {
  case file(dev_t, ino_t, birthSeconds: Int, nanoseconds: Int)
  case missing, unavailable

  init(path: String) {
    var info = stat()
    let result = path.withCString { lstat($0, &info) }
    if result == 0 {
      self = .file(
        info.st_dev, info.st_ino, birthSeconds: info.st_birthtimespec.tv_sec,
        nanoseconds: info.st_birthtimespec.tv_nsec)
    } else {
      self = errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
    }
  }

  func detectsReplacement(atPath path: String) -> Bool {
    let current = FileIdentity(path: path)
    guard case .file = current else { return false }
    return self != .unavailable && self != current
  }

  var transferToken: String? {
    switch self {
    case .file(let device, let inode, let seconds, let nanos):
      return "\(device):\(inode):\(seconds):\(nanos)"
    case .missing: return "missing"
    case .unavailable: return nil
    }
  }
}

final class FingerAgentEndpoint {
  private struct Member: Equatable {
    var path: String
    var identity: FileIdentity

    init(_ path: String) {
      self.path = path
      identity = FileIdentity(path: path)
    }

    func check() throws {
      // Missing references show as missing rows. A new occupant at the same
      // pathname must never silently become the agent's original selection.
      if identity.detectsReplacement(atPath: path) {
        throw FingerAgentError(
          "\((path as NSString).lastPathComponent) now refers to a different item. Read the selection again."
        )
      }
    }
    func checkedPath() throws -> String {
      try check()
      return path
    }
  }
  /// Repeated snapshots retain distinct IDs. Freshly checked identical paths
  /// and identities can share storage and follow the same committed move.
  private final class Members {
    var values: [Member]
    init(_ values: [Member]) { self.values = values }
  }

  private struct Snapshot {
    var folder: URL?
    let collection: String?
    let members: Members
    let created: Date
  }

  private let worker = DispatchQueue(label: "finger.agent.requests", qos: .userInitiated)
  private let listenerQueue = DispatchQueue(label: "finger.agent.listener")
  private let availableConnections = DispatchSemaphore(value: 32)
  private var source: DispatchSourceRead?
  private var snapshots: [String: Snapshot] = [:]
  private var newestID: String?
  private var readSelection: (() -> FingerAgentSelection)?
  private var openCollection: ((String, [String]) -> Void)?
  // The browser advances this on main. The worker advances its copy after
  // applying the same move. Main never waits on the request queue.
  private var browserGeneration = 0
  private var appliedGeneration = 0

  /// Main-thread notification of successful in-app renames/moves, including renamed ancestors.
  /// Existing selection IDs and member indices stay valid. A transfer across devices rebinds identity.
  func remap(_ changes: [String: String]) {
    precondition(Thread.isMainThread)
    guard !changes.isEmpty else { return }
    browserGeneration += 1
    let generation = browserGeneration
    worker.async { [weak self] in
      guard let self else { return }
      var identities: [String: FileIdentity] = [:]
      var updated = Set<ObjectIdentifier>()
      for id in Array(self.snapshots.keys) {
        guard var snapshot = self.snapshots[id] else { continue }
        if let folder = snapshot.folder, let mapped = Self.mapped(folder.path, through: changes) {
          snapshot.folder = URL(fileURLWithPath: mapped, isDirectory: true)
          self.snapshots[id] = snapshot
        }
        let members = snapshot.members
        guard updated.insert(ObjectIdentifier(members)).inserted else { continue }
        for index in members.values.indices {
          let member = members.values[index]
          guard let path = Self.mapped(member.path, through: changes) else { continue }
          members.values[index].path = path
          let now = identities[path] ?? FileIdentity(path: path)
          identities[path] = now
          if case .file(let oldDevice, _, _, _) = member.identity,
            case .file(let newDevice, _, _, _) = now, oldDevice != newDevice
          {
            members.values[index].identity = now
          }
        }
      }
      self.appliedGeneration = generation
    }
  }

  private static func mapped(_ path: String, through changes: [String: String]) -> String? {
    var ancestor = path[...]
    while !ancestor.isEmpty {
      if let target = changes[String(ancestor)] {
        return target + path[ancestor.endIndex...]
      }
      guard let slash = ancestor.lastIndex(of: "/") else { break }
      ancestor = ancestor[..<slash]
    }
    return nil
  }

  // Call once after the window is ready. Both UI callbacks execute on the main thread.
  func start(
    selection: @escaping () -> FingerAgentSelection,
    showCollection: @escaping (String, [String]) -> Void
  ) throws {
    guard source == nil else { return }
    let path = try AgentWire.socketPath()
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    if mkdir(directory, 0o700) != 0 && errno != EEXIST {
      throw AgentWire.systemError("Create Finger agent directory")
    }
    var info = stat()
    guard lstat(directory, &info) == 0, info.st_uid == geteuid(),
      (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0
    else {
      throw FingerAgentError("Finger needs an owner-only local agent directory.")
    }

    // An advisory lock survives a crashed window as an unlocked file. It lets a new
    // process reclaim a stale socket without disconnecting another running window.
    let lock = open(directory + "/window.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw AgentWire.systemError("Open Finger agent lock") }
    var listener: Int32 = -1
    do {
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw FingerAgentError("Another Finger process owns the agent connection.")
      }
      if unlink(path) != 0 && errno != ENOENT {
        throw AgentWire.systemError("Clear previous Finger socket")
      }
      listener = try AgentWire.descriptor()
      let bound = try AgentWire.withAddress(path) { Darwin.bind(listener, $0, $1) }
      guard bound == 0 else { throw AgentWire.systemError("Bind Finger agent socket") }
      guard chmod(path, 0o600) == 0, listen(listener, 16) == 0 else {
        throw AgentWire.systemError("Listen for Finger agents")
      }
      guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
        throw AgentWire.systemError("Configure Finger agent socket")
      }
    } catch {
      if listener >= 0 { close(listener) }
      close(lock)
      throw error
    }
    readSelection = selection
    openCollection = showCollection
    let fd = listener
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listenerQueue)
    source.setEventHandler { [weak self] in self?.acceptRequests(from: fd) }
    source.setCancelHandler {
      close(fd)
      unlink(path)
      close(lock)
    }
    self.source = source
    source.resume()
  }

  deinit { source?.cancel() }

  private func acceptRequests(from fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      var user: uid_t = 0
      var group: gid_t = 0
      guard getpeereid(client, &user, &group) == 0, user == geteuid() else {
        close(client)
        continue
      }
      guard availableConnections.wait(timeout: .now()) == .success else {
        close(client)
        continue
      }
      AgentWire.configure(client)
      _ = fcntl(client, F_SETFL, 0)
      DispatchQueue.global(qos: .userInitiated).async { [weak self, availableConnections] in
        defer {
          close(client)
          availableConnections.signal()
        }
        guard let self else { return }
        do {
          let request = try AgentWire.read(AgentRequest.self, from: client)
          let reply = try worker.sync { try self.handle(request) }
          try AgentWire.write(reply, to: client)
        } catch {
          try? AgentWire.write(AgentReply(error: error.localizedDescription), to: client)
        }
      }
    }
  }

  private func handle(_ request: AgentRequest) throws -> AgentReply {
    let now = Date()
    snapshots = snapshots.filter { now.timeIntervalSince($0.value.created) < 600 }
    switch request.action {
    case "selection":
      let limit = request.limit ?? 60
      let offset = request.offset ?? 0
      guard (1...150).contains(limit), offset >= 0 else {
        throw FingerAgentError("Use a limit from 1 to 150 and a nonnegative offset.")
      }
      let id: String
      let snapshot: Snapshot
      if let existingID = request.selectionID {
        id = existingID
        snapshot = try load(id)
      } else {
        guard let readSelection else {
          throw FingerAgentError("The browser window is unavailable.")
        }
        guard offset == 0 else {
          throw FingerAgentError("Pass the selection_id to read another page.")
        }
        id = UUID().uuidString
        let (selected, generation) = DispatchQueue.main.sync {
          (readSelection(), browserGeneration)
        }
        guard generation == appliedGeneration else {
          throw FingerAgentError("Files just moved. Read the selection again.")
        }
        let values = selected.paths().map(Member.init)
        guard DispatchQueue.main.sync(execute: { browserGeneration == generation }) else {
          throw FingerAgentError("Files just moved. Read the selection again.")
        }
        let members: Members
        if let newestID, let last = snapshots[newestID]?.members, last.values == values {
          members = last
        } else {
          members = Members(values)
        }
        snapshot = Snapshot(
          folder: selected.folder, collection: selected.collection, members: members, created: now)
        if snapshots.count >= 16,
          let oldest = snapshots.min(by: { $0.value.created < $1.value.created })
        {
          snapshots.removeValue(forKey: oldest.key)
        }
        snapshots[id] = snapshot
        newestID = id
      }
      let files = snapshot.members.values
      guard offset <= files.count else {
        throw FingerAgentError("The offset exceeds the selection size.")
      }
      let end = offset + min(limit, files.count - offset)
      let items = try (offset..<end).map { index in
        let member = files[index]
        if request.selectionID != nil { try member.check() }
        return AgentItem(
          id: index, name: (member.path as NSString).lastPathComponent, path: member.path)
      }
      return AgentReply(
        selectionID: id, folder: snapshot.folder?.path,
        total: files.count, items: items, nextOffset: end < files.count ? end : nil,
        collection: snapshot.collection)
    case "collection":
      guard let id = request.selectionID else {
        throw FingerAgentError("Read the selection first.")
      }
      let snapshot = try load(id)
      let name = (request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 100, name.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw FingerAgentError("Use a collection name between 1 and 100 visible characters.")
      }
      let paths: [String]
      if let ids = request.itemIDs {
        let available = snapshot.members.values
        guard ids.count <= available.count, Set(ids).count == ids.count,
          ids.allSatisfy(available.indices.contains)
        else {
          throw FingerAgentError("Use distinct item IDs from this selection.")
        }
        paths = try ids.map { try available[$0].checkedPath() }
      } else {
        paths = try snapshot.members.values.map { try $0.checkedPath() }
      }
      guard !paths.isEmpty else {
        throw FingerAgentError("Select at least one item in Finger first.")
      }
      guard let openCollection else { throw FingerAgentError("The browser window is unavailable.") }
      let generation = appliedGeneration
      try DispatchQueue.main.sync {
        guard browserGeneration == generation else {
          throw FingerAgentError(
            "Files just moved. Retry this collection using the same selection_id.")
        }
        openCollection(name, paths)
      }
      return AgentReply(total: paths.count, name: name)
    default:
      throw FingerAgentError("Unrecognized Finger agent request.")
    }
  }

  private func load(_ id: String) throws -> Snapshot {
    guard let snapshot = snapshots[id] else {
      throw FingerAgentError(
        "This selection has expired. Read the current selection in Finger again.")
    }
    return snapshot
  }
}
