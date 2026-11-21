import AppKit
import Darwin

/// Watches a file or folder by name, including replacement at that name.
/// The caller owns UI debouncing. Call observe from the main thread.
final class FolderWatcher {
  private static let workers: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Finger filesystem observations"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 4
    return queue
  }()
  private var generation = 0
  private var source: DispatchSourceFileSystemObject?
  private var opening: Operation?
  private var path: String?
  private var physicalPath: String?
  private var ready: (() -> Void)?
  private var changed: (() -> Void)?
  private var mountObserver: NSObjectProtocol?

  init() {
    mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, let path = self.path,
        let mount = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
      else { return }
      let prefix = mount.hasSuffix("/") ? mount : mount + "/"
      func onVolume(_ path: String) -> Bool { path == mount || path.hasPrefix(prefix) }
      // A mount can cover the fallback directory without changing its vnode.
      if onVolume(path) || self.physicalPath.map(onVolume) == true { self.arm(returning: true) }
    }
  }

  func observe(path: String?, ready: (() -> Void)? = nil, changed: @escaping () -> Void) {
    self.path = path
    physicalPath = nil
    self.ready = ready
    self.changed = path == nil ? nil : changed
    arm(returning: false)
  }

  private func notifyReady() {
    let callback = ready
    ready = nil
    callback?()
  }

  private func arm(returning: Bool) {
    generation += 1
    let token = generation
    opening?.cancel()
    opening = nil
    source?.cancel()
    source = nil
    guard let path else {
      notifyReady()
      return
    }
    let task = BlockOperation()
    task.addExecutionBlock { [weak self, weak task] in
      guard task?.isCancelled == false else { return }
      var watching = path
      var fd = Darwin.open(watching, O_EVTONLY | O_CLOEXEC)
      // Editors and exporters often replace a file or folder in two steps.
      // Watch its closest existing parent while the requested name is absent.
      while fd < 0 && (errno == ENOENT || errno == ENOTDIR) {
        let parent = (watching as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != watching, task?.isCancelled == false else { break }
        watching = parent
        fd = Darwin.open(watching, O_EVTONLY | O_CLOEXEC)
      }
      let descriptor = fd
      let fallback = watching != path
      // NSWorkspace reports the physical mount path even when the browser reached
      // it through a symlink, such as /tmp. Resolve the open vnode on this worker.
      var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      var physical: String?
      if descriptor >= 0, fcntl(descriptor, F_GETPATH, &buffer) == 0 {
        let directory = String(cString: buffer)
        let suffix = path.dropFirst(watching.count).drop(while: { $0 == "/" })
        physical = suffix.isEmpty ? directory : (directory == "/" ? "/" : directory + "/") + suffix
      }
      let resolved = physical
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == token else {
          if descriptor >= 0 { Darwin.close(descriptor) }
          return
        }
        self.opening = nil
        // A detached volume may also remove the symlink target through which
        // it was reached. Keep the last confirmed physical path while offline.
        if let resolved, !fallback || self.physicalPath == nil { self.physicalPath = resolved }
        if descriptor >= 0 {
          let node = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .main
          )
          node.setCancelHandler { Darwin.close(descriptor) }
          node.setRegistrationHandler { [weak self] in
            guard let self, self.generation == token else { return }
            self.notifyReady()
            guard self.generation == token else { return }
            if returning && !fallback { self.changed?() }
            if fallback {
              // Close the interval between observing a missing name and the
              // kernel registering the parent directory.
              Self.workers.addOperation { [weak self] in
                guard Darwin.access(path, F_OK) == 0 else { return }
                DispatchQueue.main.async { [weak self] in
                  guard let self, self.generation == token else { return }
                  self.arm(returning: true)
                }
              }
            }
          }
          node.setEventHandler { [weak self] in
            guard let self, self.generation == token, let current = self.source else { return }
            if fallback || !current.data.intersection([.rename, .delete, .revoke]).isEmpty {
              self.arm(returning: true)
            }
            if !fallback { self.changed?() }
          }
          self.source = node
          node.resume()
        } else {
          self.notifyReady()
        }
      }
    }
    opening = task
    Self.workers.addOperation(task)
  }

  deinit {
    if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
    opening?.cancel()
    source?.cancel()
  }
}
