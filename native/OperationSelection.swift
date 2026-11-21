import Darwin
import Foundation

/// Captures selected filesystem objects before a sheet, clipboard wait or
/// collision retry. Rust revalidates the tokens as it processes each source.
final class OperationSelection {
  private static let captureQueue = DispatchQueue(
    label: "finger.operation-identities",
    qos: .userInitiated, attributes: .concurrent)
  private let captured = DispatchGroup()
  private var identities: [String: FileIdentity] = [:]

  init(paths: [String], directory: String? = nil) {
    let capture = {
      var result: [String: FileIdentity] = [:]
      result.reserveCapacity(paths.count)
      // Pin the directory for a bulk sibling selection and avoid rewalking its
      // ancestors for every filename. lstat remains the fallback on other volumes.
      let fd =
        paths.count > 64 ? directory.map { open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY) } ?? -1 : -1
      defer { if fd >= 0 { close(fd) } }
      let prefix = directory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
      let prefixBytes = prefix.utf8.count
      for path in paths {
        if fd >= 0, path.utf8.starts(with: prefix.utf8) {
          result[path] = path.withCString { ptr in
            var info = stat()
            guard fstatat(fd, ptr + prefixBytes, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
              if errno == ENOTSUP || errno == ENOSYS { return FileIdentity(path: path) }
              return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
            }
            return .file(
              info.st_dev, info.st_ino, birthSeconds: info.st_birthtimespec.tv_sec,
              nanoseconds: info.st_birthtimespec.tv_nsec)
          }
        } else {
          result[path] = FileIdentity(path: path)
        }
      }
      self.identities = result
    }
    // Bind a clipboard pair at the keystroke. Bulk clipboard/drag reads leave
    // main immediately. The Move picker calls this on its worker before opening.
    if Thread.isMainThread && paths.count > 2 {
      Self.captureQueue.async(group: captured, execute: DispatchWorkItem(block: capture))
    } else {
      capture()
    }
  }

  func protecting(_ command: [String: Any], sources: [String]) -> [String: Any] {
    precondition(!Thread.isMainThread)
    captured.wait()
    var expected: [String: String] = [:]
    expected.reserveCapacity(sources.count)
    for source in sources {
      // The mutation must fail closed if an inaccessible or absent original is replaced.
      expected[source] = identities[source]?.transferToken ?? "unavailable"
    }
    var command = command
    command["expectedSources"] = expected
    return command
  }
}
