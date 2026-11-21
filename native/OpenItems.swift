import Darwin
import Foundation

/// Resolve an explicit Finder or command-line request before updating the window.
/// Folder and file-provider metadata can block. Run resolve on a background queue.
enum OpenItems {
  enum View: Equatable {
    case folder(String)
    case siblings(parent: String, paths: [String], showHidden: Bool)
    case collection([URL])
  }

  struct Resolution {
    var view: View?
    var errors: [String] = []

    var notice: String? { OpenItems.failureNotice(errors) }
  }

  static func failureNotice(_ errors: [String]) -> String? {
    guard let first = errors.first else { return nil }
    if errors.count == 1 { return first }
    let more = errors.count - 1
    return first + " (\(more) other \(more == 1 ? "item" : "items") could not be opened.)"
  }

  private struct Item {
    let url: URL
    let folder: Bool
    let hidden: Bool
  }

  static func arguments(_ values: [String]) -> [URL] {
    var urls: [URL] = []
    var positional = false
    var skipValue = false
    for value in values {
      if skipValue {
        skipValue = false
        continue
      }
      if !positional {
        if value == "--" || value == "--folder" {
          positional = true
          continue
        }
        if value.hasPrefix("-psn_") { continue }
        if value.hasPrefix("-NS") || value.hasPrefix("-Apple") {
          skipValue = true
          continue
        }
        if value.hasPrefix("-") { continue }
      }
      guard !value.isEmpty else { continue }
      let path = (value as NSString).expandingTildeInPath
      urls.append(URL(fileURLWithPath: path, isDirectory: false))
    }
    return urls
  }

  static func resolve(_ urls: [URL], cancelled: () -> Bool = { false }) -> Resolution {
    var resolution = Resolution()
    var items: [Item] = []
    var seen = Set<String>()
    for url in urls {
      if cancelled() { return Resolution() }
      guard url.isFileURL else {
        resolution.errors.append("Choose a file or folder on a mounted volume.")
        continue
      }
      let url = url.standardizedFileURL
      guard seen.insert(url.path).inserted else { continue }
      do { items.append(try inspect(url)) } catch {
        resolution.errors.append(error.localizedDescription)
      }
    }
    guard let first = items.first else { return resolution }
    if items.count == 1 && first.folder {
      resolution.view = .folder(first.url.path)
    } else {
      let parent = first.url.deletingLastPathComponent()
      if items.allSatisfy({ $0.url.deletingLastPathComponent().path == parent.path }) {
        do {
          try readableDirectory(parent)
          resolution.view = .siblings(
            parent: parent.path, paths: items.map { $0.url.path },
            showHidden: items.contains(where: \.hidden))
        } catch { resolution.errors.append(error.localizedDescription) }
      } else {
        resolution.view = .collection(items.map(\.url))
      }
    }
    return resolution
  }

  private static func inspect(_ url: URL) throws -> Item {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw problem(url, errno) }
    let isLink = (metadata.st_mode & S_IFMT) == S_IFLNK
    let hidden =
      url.lastPathComponent.hasPrefix(".") || (metadata.st_flags & UInt32(UF_HIDDEN)) != 0
    var dangling = false
    if isLink && stat(url.path, &metadata) != 0 {
      let code = errno
      guard code == ENOENT || code == ENOTDIR || code == ELOOP else { throw problem(url, code) }
      dangling = true
    }
    if !dangling && (metadata.st_mode & S_IFMT) == S_IFDIR {
      try readableDirectory(url)
      // Opening a package explicitly reveals it as one selectable item.
      let package = try url.resourceValues(forKeys: [.isPackageKey]).isPackage == true
      return Item(url: url, folder: !package, hidden: hidden)
    }
    if !dangling { try requireReadable(url) }
    return Item(url: url, folder: false, hidden: hidden)
  }

  static func requireReadable(_ url: URL) throws {
    if access(url.path, R_OK) != 0 { throw problem(url, errno) }
  }

  private static func readableDirectory(_ url: URL) throws {
    guard access(url.path, X_OK) == 0 else { throw problem(url, errno) }
    guard let handle = opendir(url.path) else { throw problem(url, errno) }
    closedir(handle)
  }

  private struct OpenError: LocalizedError { var errorDescription: String? }
  private static func problem(_ url: URL, _ code: Int32) -> OpenError {
    let path = url.path
    switch code {
    case ENOENT, ENOTDIR:
      return OpenError(
        errorDescription: "Couldn’t find “\(path)”. Check the path or reconnect its volume.")
    case EACCES, EPERM:
      return OpenError(
        errorDescription:
          "Access to “\(path)” was denied. Check its permissions or choose its enclosing folder with ⌘O."
      )
    default:
      return OpenError(
        errorDescription: "Couldn’t open “\(path)”. " + String(cString: strerror(code)))
    }
  }
}

/// Launch Services may send several open events before AppKit finishes launching.
/// A later, explicit request supersedes slower metadata from an earlier event.
final class OpenItemRequests {
  private let work: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Finger external opens"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 3
    return queue
  }()
  private let inspect: ([URL], () -> Bool) -> OpenItems.Resolution
  private var pending: [URL] = []
  private var launched = false
  private var generation = 0

  init(inspect: @escaping ([URL], () -> Bool) -> OpenItems.Resolution = OpenItems.resolve) {
    self.inspect = inspect
  }

  func launch(arguments: [String]) -> [URL] {
    defer {
      pending.removeAll()
      launched = true
    }
    return pending.isEmpty ? OpenItems.arguments(arguments) : pending
  }

  func receive(_ urls: [URL]) -> [URL] {
    guard launched else {
      pending.append(contentsOf: urls)
      return []
    }
    return urls
  }

  func resolve(_ urls: [URL], completion: @escaping (OpenItems.Resolution) -> Void) {
    generation += 1
    let expected = generation
    work.cancelAllOperations()
    let job = BlockOperation()
    job.addExecutionBlock { [weak job, inspect] in
      let result = inspect(urls) { job?.isCancelled != false }
      guard job?.isCancelled == false else { return }
      DispatchQueue.main.async { [weak self] in
        if self?.generation == expected { completion(result) }
      }
    }
    work.addOperation(job)
  }
}
