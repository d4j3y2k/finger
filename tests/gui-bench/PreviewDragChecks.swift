import AppKit

func checkPreviewDrags(_ b: Browser, returningTo directory: URL) throws {
  let fm = FileManager.default
  let root = directory.deletingLastPathComponent().appendingPathComponent(
    "Preview drag " + UUID().uuidString)
  let source = root.appendingPathComponent("exports")
  let destination = root.appendingPathComponent("delivery")
  for folder in [source, destination] {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  defer { try? fm.removeItem(at: root) }
  let svg = source.appendingPathComponent("Proof.svg")
  let text = source.appendingPathComponent("Brief.txt")
  let copySource = source.appendingPathComponent("For delivery.txt")
  try Data(
    #"<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8"/></svg>"#
      .utf8
  ).write(to: svg)
  try Data("approved original".utf8).write(to: text)
  try Data("delivery copy".utf8).write(to: copySource)
  b.favorites.append(destination.path)
  defer { b.favorites.removeAll { $0 == destination.path } }
  func selectSource() throws {
    b.visit(root.path, selecting: source.path)
    try spin(
      until: { b.folderPath == root.path && !b.loading && b.selected.first?.path == source.path },
      "folder preview drag source")
  }
  func target(_ url: URL, card: Bool) throws -> PreviewTarget {
    var result: PreviewTarget?
    try spin(
      until: {
        b.ui.root.layoutSubtreeIfNeeded()
        result = tree(b.ui.preview).compactMap { $0 as? PreviewTarget }.first {
          $0.dragURL?.path == url.path
            && ($0.accessibilityLabel() == "Preview of " + url.lastPathComponent) == card
        }
        return result != nil
      }, "materialized preview drag source")
    return result!
  }
  func drag(_ view: PreviewTarget, _ url: URL) throws -> DragFixture {
    guard let item = view.fileDraggingItem(), let writer = item.item as? NSPasteboardWriting else {
      throw CheckFailure("Preview source did not vend a native drag item")
    }
    let d = DragFixture(window: b.window, source: view)
    try require(
      d.draggingPasteboard.writeObjects([writer]) && FileDrop.files(d).map(\.path) == [url.path],
      "Preview source wrote the wrong file URL")
    view.fileDrag.begin(sequence: d.draggingSequenceNumber, paths: [url.path])
    try require(
      FileDrop.payload(d)?.selection != nil, "Native preview drag omitted its source identity")
    return d
  }
  func drop(_ d: DragFixture) throws {
    guard let row = b.rows.firstIndex(where: { b.entries[$0].path == destination.path }) else {
      throw CheckFailure("Missing sibling drop target")
    }
    try withDragModifiers([]) {
      try require(
        b.tableView(b.ui.table, validateDrop: d, proposedRow: row, proposedDropOperation: .on)
          == .move,
        "Sibling folder rejected the preview drag")
      try require(
        b.tableView(b.ui.table, acceptDrop: d, row: row, dropOperation: .on), "Preview drop failed")
    }
  }
  try selectSource()
  let tile = try target(svg, card: true)
  let tileDrag = try drag(tile, svg)
  try drop(tileDrag)
  let moved = destination.appendingPathComponent(svg.lastPathComponent)
  try spin(
    until: { !b.busy && fm.fileExists(atPath: moved.path) }, "preview tile to sibling folder")
  try require(!fm.fileExists(atPath: svg.path), "Preview move left a duplicate source")
  tile.fileDrag.end(sequence: tileDrag.draggingSequenceNumber)

  try selectSource()
  let rowCopy = try target(copySource, card: false)
  let copy = try drag(rowCopy, copySource)
  guard
    let pinned = tree(b.ui.rail).compactMap({ $0 as? RailLink }).first(where: {
      $0.key == destination.path
    })
  else {
    throw CheckFailure("Missing pinned folder for preview copy")
  }
  try withDragModifiers(.option) {
    try require(
      pinned.draggingEntered(copy) == .copy && pinned.performDragOperation(copy),
      "Pinned folder rejected preview Option-copy")
  }
  let copied = destination.appendingPathComponent(copySource.lastPathComponent)
  try spin(until: { !b.busy && fm.fileExists(atPath: copied.path) }, "preview row to sidebar")
  try require(
    (try? Data(contentsOf: copied)) == Data("delivery copy".utf8)
      && fm.fileExists(atPath: copySource.path),
    "Preview row Option-copy did not preserve both files")
  rowCopy.fileDrag.end(sequence: copy.draggingSequenceNumber)

  let rowView = try target(text, card: false)
  let stale = try drag(rowView, text)
  let original = root.appendingPathComponent("preserved-original.txt")
  try fm.moveItem(at: text, to: original)
  try Data("replacement".utf8).write(to: text)
  try drop(stale)
  try spin(until: { b.window.attachedSheet != nil && !b.busy }, "replacement refusal")
  try require(
    (try? String(contentsOf: original, encoding: .utf8)) == "approved original"
      && (try? String(contentsOf: text, encoding: .utf8)) == "replacement"
      && !fm.fileExists(atPath: destination.appendingPathComponent(text.lastPathComponent).path),
    "Preview drag moved a replaced source")
  if let sheet = b.window.attachedSheet {
    b.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
  }
  rowView.fileDrag.end(sequence: stale.draggingSequenceNumber)
  try spin(until: { b.window.attachedSheet == nil }, "dismiss preview drag refusal")
  try selectSource()
  let current = try target(text, card: false)
  let point = current.convert(NSPoint(x: current.bounds.midX, y: current.bounds.midY), to: nil)
  func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    guard
      let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: modifiers, timestamp: 0,
        windowNumber: b.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
        pressure: 1)
    else {
      throw CheckFailure("Cannot construct a local preview click")
    }
    return event
  }
  var opened: URL?
  let onOpen = b.ui.preview.onOpen
  b.ui.preview.onOpen = { opened = $0 }
  current.mouseDown(with: try click(.leftMouseDown, modifiers: .option))
  current.mouseUp(with: try click(.leftMouseUp, modifiers: .option))
  b.ui.preview.onOpen = onOpen
  try require(
    opened?.path == text.path && b.folderPath == root.path,
    "Option-click no longer opens the preview child")
  current.mouseDown(with: try click(.leftMouseDown))
  current.mouseUp(with: try click(.leftMouseUp))
  try spin(
    until: { b.folderPath == source.path && !b.loading && b.selected.first?.path == text.path },
    "ordinary click after a drag")
  b.visit(directory.path)
  try spin(until: { b.folderPath == directory.path && !b.loading }, "leave preview drag fixture")
  print(
    "Preview tile moved to a sibling folder. Row Option-copy to sidebar, stale-source refusal, click and Option-click passed."
  )
}
