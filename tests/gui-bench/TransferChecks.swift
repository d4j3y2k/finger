import AppKit
import ObjectiveC

/// WindowServer supplies this object during a physical drag. The delegate and
/// sidebar receiver below still use real AppKit pasteboard items and real files.
final class DragFixture: NSObject, NSDraggingInfo {
  let draggingPasteboard = NSPasteboard.withUniqueName()
  let draggingSource: Any?
  let draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = [.move, .copy]
  let draggingLocation = NSPoint.zero, draggedImageLocation = NSPoint.zero
  let draggedImage: NSImage? = nil
  private static var nextSequence = 0
  let draggingSequenceNumber: Int
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  let springLoadingHighlight: NSSpringLoadingHighlight = .none
  init(window: NSWindow, source: Any?) {
    Self.nextSequence += 1
    draggingSequenceNumber = Self.nextSequence
    draggingDestinationWindow = window
    draggingSource = source
  }
  deinit { draggingPasteboard.releaseGlobally() }
  func slideDraggedImage(to point: NSPoint) {}
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

/// Set the modifier read in this test process only. This avoids synthesizing a
/// system-wide keyboard event or depending on which keys the user is holding.
func withDragModifiers(_ flags: NSEvent.ModifierFlags, _ action: () throws -> Void) throws {
  guard let method = class_getClassMethod(NSEvent.self, NSSelectorFromString("modifierFlags"))
  else {
    throw CheckFailure("Cannot simulate drag modifiers")
  }
  let fixed: @convention(block) (AnyObject) -> UInt = { _ in flags.rawValue }
  let replacement = imp_implementationWithBlock(fixed)
  let previous = method_setImplementation(method, replacement)
  defer {
    method_setImplementation(method, previous)
    imp_removeBlock(replacement)
  }
  try action()
}

func checkTransfers(_ b: Browser, returningTo directory: URL) throws {
  try require(b.clipboard.name != NSPasteboard.general.name, "Tests need a private clipboard")
  let fm = FileManager.default
  let root = directory.deletingLastPathComponent().appendingPathComponent(
    "Transfers-" + UUID().uuidString)
  let src = root.appendingPathComponent("Work")
  let dest = src.appendingPathComponent("Delivery")
  let sidebar = root.appendingPathComponent("Pinned")
  let foreign = root.appendingPathComponent("External")
  for dir in [dest, sidebar, foreign] {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  defer { try? fm.removeItem(at: root) }
  func write(_ parent: URL, _ name: String, _ contents: String) throws -> URL {
    let file = parent.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return file
  }
  func bytes(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
  func settled() throws {
    try spin(until: { !b.busy && !b.loading && !b.scanning }, "file-transfer refresh")
  }
  func visit(_ dir: URL) throws {
    b.visit(dir.path)
    try settled()
  }
  func row(_ name: String) throws -> Int {
    guard let r = b.rows.firstIndex(where: { b.entries[$0].name == name }) else {
      throw CheckFailure("No row for " + name)
    }
    return r
  }
  func drag(_ urls: [URL], local: Bool) throws -> DragFixture {
    let d = DragFixture(window: b.window, source: local ? b.ui.table : nil)
    var writers: [NSPasteboardWriting] = []
    for url in urls {
      if local {
        let index = try row(url.lastPathComponent)
        guard let writer = b.tableView(b.ui.table, pasteboardWriterForRow: index) else {
          throw CheckFailure("No drag writer")
        }
        writers.append(writer)
      } else {
        writers.append(url as NSURL)
      }
    }
    try require(d.draggingPasteboard.writeObjects(writers), "Could not publish drag URLs")
    try require(
      FileDrop.files(d).map(\.path) == urls.map(\.path), "Pasteboard URL ordering changed")
    if local {
      b.ui.table.fileDrag.begin(sequence: d.draggingSequenceNumber, paths: urls.map(\.path))
    }
    return d
  }
  func tableDrop(
    _ d: DragFixture, _ r: Int, _ position: NSTableView.DropOperation,
    _ modifiers: NSEvent.ModifierFlags, _ operation: NSDragOperation
  ) throws {
    try withDragModifiers(modifiers) {
      try require(
        b.tableView(b.ui.table, validateDrop: d, proposedRow: r, proposedDropOperation: position)
          == operation, "Unexpected table drag operation")
      try require(
        b.tableView(b.ui.table, acceptDrop: d, row: r, dropOperation: position),
        "Table rejected accepted payload")
    }
    try settled()
  }
  func sheet(_ word: String) throws -> NSWindow {
    var found: NSWindow?
    try spin(
      until: {
        guard let s = b.window.attachedSheet, let view = s.contentView else { return false }
        if tree(view).contains(where: {
          ($0 as? NSTextField)?.stringValue.contains(word) == true
            || ($0 as? NSButton)?.title == word
        }) {
          found = s
          return true
        }
        return false
      }, "sheet containing " + word)
    return found!
  }
  let first = try write(src, "A.txt", "first")
  let second = try write(src, "B.txt", "second")
  let option = try write(src, "Option.txt", "copy")
  let pin = try write(src, "Pinned.txt", "sidebar")
  let external = try write(foreign, "External.txt", "outside")
  let stale = try write(src, "Collision.txt", "earlier")
  let incumbent = try write(dest, "Collision.txt", "existing")
  let dragSource = try write(src, "Replace during drag.txt", "drag original")
  let keep = try write(src, "Edition.txt", "incoming")
  let oldEdition = try write(dest, "Edition.txt", "published")
  b.favorites.append(sidebar.path)
  try visit(src)
  defer { b.favorites.removeAll { $0 == sidebar.path } }
  let delivery = try row("Delivery")
  try tableDrop(drag([first, second], local: true), delivery, .on, [], .move)
  let movedA = dest.appendingPathComponent(first.lastPathComponent)
  let movedB = dest.appendingPathComponent(second.lastPathComponent)
  try require(
    bytes(first) == nil && bytes(second) == nil && bytes(movedA) == "first"
      && bytes(movedB) == "second", "Local drop did not move both files")
  try require(b.undoActions.last?.receipts.count == 2, "Move receipt omitted a dragged file")
  b.restoreAction(false)
  try settled()
  try require(
    bytes(first) == "first" && bytes(second) == "second" && bytes(movedA) == nil,
    "Undo did not restore dragged pair")
  b.restoreAction(true)
  try settled()
  try require(
    bytes(first) == nil && bytes(second) == nil && bytes(movedB) == "second",
    "Redo did not move pair")
  try tableDrop(drag([option], local: true), try row("Delivery"), .on, .option, .copy)
  try require(
    bytes(option) == "copy" && bytes(dest.appendingPathComponent("Option.txt")) == "copy",
    "Option-drag moved a source")
  try tableDrop(drag([external], local: false), try row("Delivery"), .above, [], .copy)
  try require(
    bytes(external) == "outside" && bytes(src.appendingPathComponent("External.txt")) == "outside"
      && bytes(dest.appendingPathComponent("External.txt")) == nil,
    "External between-row copy targeted the wrong folder")
  let railDrag = try drag([pin], local: true)
  guard
    let link = tree(b.ui.rail).compactMap({ $0 as? RailLink }).first(where: {
      $0.key == sidebar.path
    })
  else { throw CheckFailure("Missing pinned drop target") }
  try withDragModifiers([]) {
    try require(
      link.draggingEntered(railDrag) == .move && link.draggingUpdated(railDrag) == .move,
      "Sidebar drag validation")
    b.busy = true
    let busyAccepted = link.performDragOperation(railDrag)
    b.busy = false
    try require(
      !busyAccepted && link.performDragOperation(railDrag),
      "Sidebar failed to recheck destination availability")
  }
  try settled()
  try require(
    bytes(pin) == nil && bytes(sidebar.appendingPathComponent("Pinned.txt")) == "sidebar",
    "Sidebar did not move the file")
  let active = try drag([dragSource], local: true)
  b.ui.table.fileDrag.end(sequence: railDrag.draggingSequenceNumber)
  try require(FileDrop.payload(railDrag) == nil, "Old session inherited a new drag capture")
  let original = root.appendingPathComponent("Rescued original.txt")
  try fm.moveItem(at: dragSource, to: original)
  _ = try write(src, dragSource.lastPathComponent, "drag replacement")
  try tableDrop(active, try row("Delivery"), .on, [], .move)
  let staleDrag = try sheet("Some items could not be transferred")
  try require(
    bytes(original) == "drag original" && bytes(dragSource) == "drag replacement"
      && bytes(dest.appendingPathComponent(dragSource.lastPathComponent)) == nil,
    "A drag moved a replacement source")
  b.window.endSheet(staleDrag, returnCode: .alertFirstButtonReturn)
  try spin(until: { b.window.attachedSheet == nil }, "stale drag dismissal")
  b.ui.table.fileDrag.end(sequence: active.draggingSequenceNumber)
  let invalid = DragFixture(window: b.window, source: nil)
  invalid.draggingPasteboard.setString("text", forType: .string)
  try require(
    b.tableView(b.ui.table, validateDrop: invalid, proposedRow: -1, proposedDropOperation: .on)
      .isEmpty && !b.tableView(b.ui.table, acceptDrop: invalid, row: -1, dropOperation: .on),
    "Accepted a non-file pasteboard")

  try select(b, named: stale.lastPathComponent)
  b.copyFiles(cut: true)
  try visit(dest)
  b.pasteFiles(forceMove: false)
  let collision = try sheet("Keep Both")
  let saved = root.appendingPathComponent("Original collision.txt")
  try fm.moveItem(at: stale, to: saved)
  _ = try write(src, stale.lastPathComponent, "replacement")
  b.window.endSheet(collision, returnCode: .alertFirstButtonReturn)
  let failed = try sheet("Some items could not be transferred")
  try require(
    bytes(saved) == "earlier" && bytes(stale) == "replacement" && bytes(incumbent) == "existing"
      && !fm.fileExists(atPath: dest.appendingPathComponent("Collision 2.txt").path),
    "Keep Both retargeted a replacement")
  b.window.endSheet(failed, returnCode: .alertFirstButtonReturn)
  try spin(until: { b.window.attachedSheet == nil }, "error dismissal")
  try visit(src)
  try select(b, named: keep.lastPathComponent)
  b.copyFiles(cut: true)
  try visit(dest)
  b.pasteFiles(forceMove: false)
  let retry = try sheet("Keep Both")
  b.clipboard.clearContents()
  try require(b.clipboard.writeObjects([external as NSURL]), "Updating private clipboard")
  b.window.endSheet(retry, returnCode: .alertFirstButtonReturn)
  let numbered = dest.appendingPathComponent("Edition 2.txt")
  try spin(until: { bytes(numbered) == "incoming" && !b.busy }, "numbered destination")
  try settled()
  try require(
    bytes(keep) == nil && bytes(oldEdition) == "published" && b.pasteSources() == [external.path],
    "Keep Both overwrote a file or a newer clipboard generation")
  b.restoreAction(false)
  try settled()
  try require(
    bytes(keep) == "incoming" && bytes(numbered) == nil && bytes(oldEdition) == "published",
    "Undo used the wrong collision receipt")
  b.clipboard.clearContents()
  try visit(directory)
  try checkPreviewDrags(b, returningTo: directory)
  print(
    "Drag writers, table and sidebar drops, local move, Option and external copy, drag identity, multi-file Undo/Redo, clipboard generations and Keep Both replacement checks passed."
  )
}
