import Foundation

enum FileOrder: String, CaseIterable {
  case nameAsc, nameDesc, modifiedDesc, modifiedAsc, sizeDesc, sizeAsc

  /// Matches the order tag in the Rust directory enumeration callback.
  var wireIndex: UInt8 {
    switch self {
    case .nameAsc: return 0
    case .nameDesc: return 1
    case .modifiedDesc: return 2
    case .modifiedAsc: return 3
    case .sizeDesc: return 4
    case .sizeAsc: return 5
    }
  }

  var menuTitle: String {
    switch self {
    case .nameAsc: return "Name, A to Z"
    case .nameDesc: return "Name, Z to A"
    case .modifiedDesc: return "Date Modified, Newest First"
    case .modifiedAsc: return "Date Modified, Oldest First"
    case .sizeDesc: return "Size, Largest First"
    case .sizeAsc: return "Size, Smallest First"
    }
  }

  var isModified: Bool { self == .modifiedAsc || self == .modifiedDesc }
  var isSize: Bool { self == .sizeAsc || self == .sizeDesc }
  var isName: Bool { self == .nameAsc || self == .nameDesc }
  var arrow: String { self == .nameAsc || self == .modifiedAsc || self == .sizeAsc ? "↑" : "↓" }
}
