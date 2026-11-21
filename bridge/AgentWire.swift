import Darwin
import Foundation

struct FingerAgentError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct AgentRequest: Codable {
  let action: String
  var selectionID: String?
  var offset: Int?
  var limit: Int?
  var name: String?
  var itemIDs: [Int]?
}

struct AgentItem: Codable {
  let id: Int
  let name: String
  let path: String
}

struct AgentReply: Codable {
  var error: String?
  var selectionID: String?
  var folder: String?
  var total: Int?
  var items: [AgentItem]?
  var nextOffset: Int?
  var name: String?
  var collection: String?
}

// One length-prefixed JSON request and reply per local connection. The bridge never
// opens a selected path. Only the running window supplies item names and URLs.
enum AgentWire {
  static let maximumSize = 4 * 1024 * 1024

  static func socketPath() throws -> String {
    #if FINGER_BRIDGE_TESTS
      if let fixture = ProcessInfo.processInfo.environment["FINGER_FIXTURE_SOCKET"] {
        return fixture
      }
    #endif
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    guard length > 0, length <= buffer.count else {
      throw FingerAgentError("The macOS user temporary directory is unavailable.")
    }
    // Named from the system per-user directory, independent of a client's TMPDIR.
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
      .appendingPathComponent("finger-agent", isDirectory: true)
      .appendingPathComponent("window.sock").path
  }

  static func descriptor() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw systemError("Open local socket") }
    configure(fd)
    return fd
  }

  static func configure(_ fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    var timeout = timeval(tv_sec: 6, tv_usec: 0)
    let size = socklen_t(MemoryLayout.size(ofValue: timeout))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  }

  static func withAddress<T>(
    _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
  ) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw FingerAgentError("The macOS local socket path is too long.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
      bytes.withUnsafeBytes { target.copyBytes(from: $0) }
    }
    return try withUnsafePointer(to: &address) {
      try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  static func call(_ request: AgentRequest) throws -> AgentReply {
    let fd = try descriptor()
    defer { close(fd) }
    let result = try withAddress(socketPath()) { Darwin.connect(fd, $0, $1) }
    guard result == 0 else {
      throw FingerAgentError(
        "Cannot reach Finger. Open Finger.app in this macOS login and try again.")
    }
    try write(request, to: fd)
    return try read(AgentReply.self, from: fd)
  }

  static func read<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
    let header = try readBytes(4, from: fd)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= maximumSize else {
      throw FingerAgentError("Invalid local message size.")
    }
    return try JSONDecoder().decode(type, from: readBytes(length, from: fd))
  }

  static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= maximumSize else { throw FingerAgentError("The local reply is too large.") }
    var length = UInt32(data.count).bigEndian
    var message = Data(bytes: &length, count: 4)
    message.append(data)
    try message.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw systemError("Send local message") }
        sent += n
      }
    }
  }

  private static func readBytes(_ count: Int, from fd: Int32) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      var received = 0
      while received < count {
        let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: received), count - received)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else {
          throw FingerAgentError("The local connection closed before the message finished.")
        }
        received += n
      }
    }
    return data
  }

  static func systemError(_ action: String) -> FingerAgentError {
    FingerAgentError("\(action): \(String(cString: strerror(errno)))")
  }
}
