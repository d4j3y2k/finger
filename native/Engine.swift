import Darwin
import Foundation

public typealias FingerRequest =
  @convention(c) (Int32, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
public typealias FingerRelease = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

public typealias FingerEntrySink =
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt8, UInt8, Int64, Int64)
  -> Void
public typealias FingerCancelled = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
public typealias FingerList =
  @convention(c) (
    UnsafePointer<CChar>?, UInt8, UnsafeMutableRawPointer?, FingerEntrySink,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?, FingerCancelled?
  ) -> UnsafeMutablePointer<CChar>?
public typealias FingerQuery =
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int>?) ->
  UnsafePointer<Int>?
public typealias FingerDropIndex = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// Owns the index built with this particular listing. A slow, superseded
/// listing can be discarded without changing the current window's search.
final class FolderSearchIndex {
  private let handle: UnsafeMutableRawPointer
  private let query: FingerQuery
  private let release: FingerDropIndex

  init(_ handle: UnsafeMutableRawPointer, query: FingerQuery, release: FingerDropIndex) {
    self.handle = handle
    self.query = query
    self.release = release
  }

  // Rust owns this buffer until the next query. Copy it before returning.
  // A nil result is the complete, unfiltered listing.
  func matching(_ text: String) -> [Int]? {
    var count = 0
    let base = text.withCString { query(handle, $0, &count) }
    guard count >= 0 else { return nil }
    guard count > 0, let base else { return [] }
    return Array(UnsafeBufferPointer(start: base, count: count))
  }

  deinit { release(handle) }
}

struct BrowserListing {
  let entries: [Entry]
  let warnings: [String]
  let index: FolderSearchIndex?
}

final class FileReadTicket: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  func cancel() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private final class FolderAccumulator {
  let ticket: FileReadTicket?
  let prefix: String
  var entries: [Entry] = []
  init(_ path: String, ticket: FileReadTicket?) {
    prefix = path.hasSuffix("/") ? path : path + "/"
    self.ticket = ticket
  }
}
private let folderCancelled: FingerCancelled = { context in
  guard let context else { return 0 }
  return Unmanaged<FolderAccumulator>.fromOpaque(context).takeUnretainedValue().ticket?.cancelled
    == true ? 1 : 0
}
private let receiveEntry: FingerEntrySink = {
  context, bytes, count, tag, directory, size, modified in
  guard let context, let bytes else { return }
  let folder = Unmanaged<FolderAccumulator>.fromOpaque(context).takeUnretainedValue()
  let name = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  let kind: String
  switch tag {
  case 1: kind = "folder"
  case 2: kind = "symlink"
  case 3: kind = "other"
  default: kind = "file"
  }
  folder.entries.append(
    Entry(
      name: name, path: folder.prefix + name, kind: kind, isDirectory: directory != 0,
      size: size < 0 ? nil : size, modified: modified == Int64.min ? nil : modified))
}

struct Entry: Codable, Equatable {
  let name: String
  let path: String
  let kind: String
  let isDirectory: Bool
  let size: Int64?
  let modified: Int64?
  var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
  var ext: String { (name as NSString).pathExtension.lowercased() }

  static func inspect(_ path: String) -> Entry {
    // A collection can span many folders. Ordinary local rows need just the
    // metadata from one lstat; leave links, providers and errors to Foundation.
    var info = stat()
    if path.hasPrefix("/"), path.withCString({ lstat($0, &info) }) == 0,
      info.st_flags & UInt32(SF_DATALESS) == 0
    {
      let kind = info.st_mode & mode_t(S_IFMT)
      if kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) {
        let directory = kind == mode_t(S_IFDIR)
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Entry(
          name: (path as NSString).lastPathComponent, path: path,
          kind: directory ? "folder" : "file",
          isDirectory: directory, size: directory ? nil : Int64(info.st_size),
          modified: Int64(modified))
      }
    }
    let url = URL(fileURLWithPath: path)
    let v = try? url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ])
    var targetDir: ObjCBool = false
    let directory =
      v?.isDirectory == true
      || (v?.isSymbolicLink == true
        && FileManager.default.fileExists(atPath: path, isDirectory: &targetDir)
        && targetDir.boolValue)
    return Entry(
      name: url.lastPathComponent, path: path,
      kind: v == nil
        ? "missing" : v?.isSymbolicLink == true ? "symlink" : directory ? "folder" : "file",
      isDirectory: directory, size: v?.fileSize.map(Int64.init),
      modified: v?.contentModificationDate.map { Int64($0.timeIntervalSince1970) })
  }
}
struct ListResponse: Decodable {
  let ok: Bool
  let entries: [Entry]?
  let error: String?
  let warnings: [String]?
}
struct CoreError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

final class Engine {
  let request: FingerRequest
  let release: FingerRelease
  let listEntries: FingerList?
  let query: FingerQuery?
  let releaseIndex: FingerDropIndex?
  init(
    _ request: FingerRequest, _ release: FingerRelease, _ listEntries: FingerList? = nil,
    _ query: FingerQuery? = nil, _ releaseIndex: FingerDropIndex? = nil
  ) {
    self.request = request
    self.release = release
    self.listEntries = listEntries
    self.query = query
    self.releaseIndex = releaseIndex
  }
  func data(_ command: [String: Any], service: Int32 = 0) throws -> Data {
    let input = try JSONSerialization.data(withJSONObject: command)
    return try input.withUnsafeBytes { bytes in
      var terminated = Array(bytes.bindMemory(to: UInt8.self))
      terminated.append(0)
      return try terminated.withUnsafeBytes { source in
        guard let ptr = request(service, source.bindMemory(to: CChar.self).baseAddress) else {
          throw CoreError(message: "The file engine returned an empty response.")
        }
        defer { release(ptr) }
        return Data(bytes: ptr, count: strlen(ptr))
      }
    }
  }
  func call(_ command: [String: Any], service: Int32 = 0) throws -> [String: Any] {
    let response =
      try JSONSerialization.jsonObject(with: data(command, service: service)) as? [String: Any]
      ?? [:]
    guard response["ok"] as? Bool == true else {
      throw CoreError(message: response["error"] as? String ?? "The operation did not complete.")
    }
    return response
  }
  func folderPreview(
    _ path: String, showHidden: Bool, order: FileOrder, ticket: FileReadTicket
  ) throws -> Data {
    guard !ticket.cancelled else { throw CancellationError() }
    guard let listEntries else {
      return try data([
        "op": "preview", "path": path, "showHidden": showHidden, "sort": order.rawValue,
      ])
    }
    // The inspector requests a bounded JSON reply from the same cancellable Rust listing.
    let flags: UInt8 = 0x80 | (order.wireIndex << 1) | (showHidden ? 1 : 0)
    let folder = FolderAccumulator(path, ticket: ticket)
    let report = withExtendedLifetime(folder) {
      path.withCString {
        listEntries(
          $0, flags, Unmanaged.passUnretained(folder).toOpaque(), receiveEntry, nil, folderCancelled
        )
      }
    }
    guard let report else {
      throw CoreError(message: "The folder reader returned an empty preview.")
    }
    defer { release(report) }
    return Data(bytes: report, count: strlen(report))
  }
  func list(_ path: String, showHidden: Bool, order: FileOrder = .nameAsc) throws -> [Entry] {
    try readFolder(path, showHidden: showHidden, order: order).entries
  }
  func readFolder(
    _ path: String, showHidden: Bool, order: FileOrder = .nameAsc, ticket: FileReadTicket? = nil
  ) throws -> BrowserListing {
    if ticket?.cancelled == true { throw CancellationError() }
    if let listEntries {
      let folder = FolderAccumulator(path, ticket: ticket)
      let stop: FingerCancelled? = ticket == nil ? nil : folderCancelled
      let flags = (order.wireIndex << 1) | (showHidden ? 1 : 0)
      let context = Unmanaged.passUnretained(folder).toOpaque()
      var ownedIndex: UnsafeMutableRawPointer?
      let report = path.withCString { path in
        if query != nil, releaseIndex != nil {
          return listEntries(path, flags, context, receiveEntry, &ownedIndex, stop)
        }
        return listEntries(path, flags, context, receiveEntry, nil, stop)
      }
      let index: FolderSearchIndex?
      if let ownedIndex, let query, let releaseIndex {
        index = FolderSearchIndex(ownedIndex, query: query, release: releaseIndex)
      } else {
        index = nil
      }
      var warnings: [String]?
      if let report {
        defer { release(report) }
        let data = Data(bytes: report, count: strlen(report))
        let status = try JSONDecoder().decode(ListResponse.self, from: data)
        if !status.ok { throw CoreError(message: status.error ?? "Could not read folder.") }
        warnings = status.warnings
      }
      return BrowserListing(entries: folder.entries, warnings: warnings ?? [], index: index)
    }
    let reply = try JSONDecoder().decode(
      ListResponse.self,
      from: data([
        "id": 0, "op": "list", "path": path, "showHidden": showHidden, "sort": order.rawValue,
      ]))
    guard let entries = reply.entries, reply.ok else {
      throw CoreError(message: reply.error ?? "Could not read folder.")
    }
    return BrowserListing(entries: entries, warnings: reply.warnings ?? [], index: nil)
  }
}

struct CollectionRecord: Codable {
  var id: String
  var name: String
  var paths: [String]
}
