import CoreServices
import Darwin
import Foundation

/// A file that arrived in Downloads in the last hour.
struct FilingArrival: Equatable {
  let key: FilingKey
  let added: Date
  /// The website it came from, from kMDItemWhereFroms: "billing.harborprint.co".
  let host: String?
  var path: String { key.path }
  var name: String { (key.path as NSString).lastPathComponent }
}

enum FilingArrivals {
  /// Partial downloads from Safari, Chrome, Firefox and others, ignored until they finish.
  static let partial: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]
  static let window: TimeInterval = 3600

  static func isPartial(_ name: String) -> Bool {
    partial.contains((name as NSString).pathExtension.lowercased())
  }

  /// New files in `downloads`, newest first, the same set as the panel's Just Arrived.
  /// Call it off the main thread.
  static func scan(_ downloads: String, now: Date = Date()) -> [FilingArrival] {
    let cutoff = now.addingTimeInterval(-window)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? []
    var found: [FilingArrival] = []
    for name in names where !name.hasPrefix(".") && !isPartial(name) {
      let path = downloads + "/" + name
      let url = URL(fileURLWithPath: path)
      guard
        let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey,
        ]),
        values.isDirectory != true || values.isPackage == true,
        let added = values.addedToDirectoryDate, added >= cutoff,
        let key = FilingKey.of(path)
      else { continue }
      found.append(FilingArrival(key: key, added: added, host: sourceHost(path)))
    }
    return found.sorted { $0.added > $1.added }
  }

  static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

  /// The download's URLs, newest-known first, as the browser recorded them.
  static func whereFroms(_ path: String) -> [String] {
    let size = getxattr(path, whereFromsAttribute, nil, 0, 0, 0)
    if size > 0, size < 1 << 20 {
      var data = Data(count: size)
      let read = data.withUnsafeMutableBytes { getxattr(path, whereFromsAttribute, $0.baseAddress, size, 0, 0) }
      if read == size,
        let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
          as? [String]
      {
        return list
      }
    }
    // Spotlight may know it when the attribute was stripped.
    if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
      let list = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String]
    {
      return list
    }
    return []
  }

  /// The host of the first web address the file came from.
  static func sourceHost(_ path: String) -> String? {
    for entry in whereFroms(path) {
      guard let url = URL(string: entry), let scheme = url.scheme?.lowercased(),
        ["http", "https", "ftp"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty
      else { continue }
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    return nil
  }
}

/// Watches one folder with FSEvents and calls back on the main thread, at most
/// a few times a second.
final class FilingFolderWatcher {
  let folder: String
  private let changed: () -> Void
  private var stream: FSEventStreamRef?

  init(folder: String, changed: @escaping () -> Void) {
    self.folder = folder
    self.changed = changed
  }

  var isRunning: Bool { stream != nil }

  func start() {
    guard stream == nil else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      Unmanaged<FilingFolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
    }
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagWatchRoot)
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault, callback, &context, [folder] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
    else { return }
    FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
    guard FSEventStreamStart(created) else {
      FSEventStreamInvalidate(created)
      FSEventStreamRelease(created)
      return
    }
    stream = created
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit { stop() }
}
