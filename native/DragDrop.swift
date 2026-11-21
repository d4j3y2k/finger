import AppKit

protocol FileDragSource: AnyObject {
  var fileDrag: FileDragCapture { get }
}

/// A sequence belongs to one AppKit drag. A delayed completion from an older
/// sequence must not discard the next set of selected filesystem identities.
final class FileDragCapture {
  private var active: (sequence: Int, paths: Set<String>, selection: OperationSelection)?
  func begin(sequence: Int, paths: [String]) {
    active = (sequence, Set(paths), OperationSelection(paths: paths))
  }
  func end(sequence: Int) {
    if active?.sequence == sequence { active = nil }
  }
  func selection(sequence: Int, paths: [String]) -> OperationSelection? {
    guard let active, active.sequence == sequence, active.paths == Set(paths) else { return nil }
    return active.selection
  }
}

enum FileDrop {
  struct Payload {
    let paths: [String]
    let selection: OperationSelection?
  }
  static func operation(_ info: NSDraggingInfo) -> NSDragOperation {
    let allowed = info.draggingSourceOperationMask
    guard !allowed.isEmpty, info.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
      return []
    }
    let flags = NSEvent.modifierFlags
    let localMove = info.draggingSource != nil || flags.contains(.command)
    let preferred: NSDragOperation = localMove && !flags.contains(.option) ? .move : .copy
    if allowed.contains(preferred) { return preferred }
    if allowed.contains(.copy) { return .copy }
    if allowed.contains(.move) { return .move }
    return []
  }
  static func files(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
  static func payload(_ info: NSDraggingInfo) -> Payload? {
    let paths = files(info).map(\.path)
    guard !paths.isEmpty else { return nil }
    if let source = info.draggingSource as? FileDragSource {
      guard
        let selection = source.fileDrag.selection(
          sequence: info.draggingSequenceNumber, paths: paths)
      else { return nil }
      return Payload(paths: paths, selection: selection)
    }
    return Payload(paths: paths, selection: nil)
  }
}
