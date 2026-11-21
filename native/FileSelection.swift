import Foundation

/// AppKit supplies the index set on main. The immutable listing and visible row
/// map are Swift value snapshots, so a worker can read the same selection later.
struct FileSelection {
  let entries: [Entry]
  let rows: [Int]
  let indexes: IndexSet

  var first: Entry? {
    indexes.first.flatMap { entry(at: $0) }
  }

  func entry(at row: Int) -> Entry? {
    guard rows.indices.contains(row) else { return nil }
    return entries[rows[row]]
  }

  func map<T>(limit: Int = .max, _ transform: (Entry) -> T) -> [T] {
    var result: [T] = []
    result.reserveCapacity(min(limit, indexes.count))
    for row in indexes {
      if result.count == limit { break }
      if rows.indices.contains(row) { result.append(transform(entries[rows[row]])) }
    }
    return result
  }
}

/// A basename cannot contain NUL or a slash. Large fully selected folders
/// travel through history as one exact list instead of repeating the parent
/// path in a JSON value for each row. An in-app move can make a member absolute.
enum FullFolderSelection {
  static func names(_ entries: [Entry]) -> String { entries.map(\.name).joined(separator: "\0") }

  static func restored(_ packed: [String: String], folder: String?, entries: [Entry], rows: [Int])
    -> IndexSet?
  {
    guard let parent = packed["folder"], let names = packed["names"] else { return nil }
    let local = folder == parent
    if local, rows.count == entries.count, names == Self.names(entries) {
      return IndexSet(integersIn: rows.indices)
    }
    let members = Set(names.split(separator: "\0"))
    var indexes = IndexSet()
    var start: Int?
    for (row, index) in rows.enumerated() {
      let item = entries[index]
      let included = (local && members.contains(item.name[...])) || members.contains(item.path[...])
      if included {
        if start == nil { start = row }
      } else if let first = start {
        indexes.insert(integersIn: first..<row)
        start = nil
      }
    }
    if let first = start { indexes.insert(integersIn: first..<rows.count) }
    return indexes
  }
}
