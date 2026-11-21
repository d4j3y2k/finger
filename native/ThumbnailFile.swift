import Darwin
import Foundation

enum ThumbnailFile {
  /// Called on a decoder queue. A preview must never read a named pipe or
  /// materialize a cloud placeholder simply because its row became visible.
  static func cacheKey(for url: URL, pixels: Int) -> NSString? {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      path.map { stat($0, &info) } ?? -1
    }
    guard result == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_flags & UInt32(SF_DATALESS) == 0
    else { return nil }
    if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
      values.ubiquitousItemDownloadingStatus == .notDownloaded
    {
      return nil
    }
    // Exporters may replace a same-size image several times in one second.
    let changed = info.st_ctimespec
    let modified = info.st_mtimespec
    return
      "\(url.path)|\(info.st_dev):\(info.st_ino)|\(info.st_size)|\(modified.tv_sec):\(modified.tv_nsec)|\(changed.tv_sec):\(changed.tv_nsec)|\(pixels)"
      as NSString
  }
}
