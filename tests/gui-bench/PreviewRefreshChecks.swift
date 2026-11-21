import AppKit

func checkPreviewRefresh(_ b: Browser, project: URL) throws {
  let fm = FileManager.default
  let root = project.appendingPathComponent("Live inspector", isDirectory: true)
  let exports = root.appendingPathComponent("exports", isDirectory: true)
  try fm.createDirectory(at: exports, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let text = root.appendingPathComponent("brief.txt")
  let early = "early draft"
  let final = "final proof"
  try Data(early.utf8).write(to: text)
  let empty = root.appendingPathComponent("empty.png")
  let byte = root.appendingPathComponent("one.txt")
  try Data().write(to: empty)
  try Data("x".utf8).write(to: byte)
  let utf16 = root.appendingPathComponent("Unicode boundary.txt")
  let unicodePrefix = String(repeating: "x", count: 6142)
  var encoded = Data([0xff, 0xfe])
  encoded.append((unicodePrefix + "🚀 following text").data(using: .utf16LittleEndian)!)
  try encoded.write(to: utf16)
  func labels() -> [String] { tree(b.ui.preview).compactMap { ($0 as? NSTextField)?.stringValue } }
  func showsText(_ value: String) -> Bool {
    tree(b.ui.preview).contains { ($0 as? NSTextView)?.string == value }
  }
  b.visit(root.path, selecting: exports.path)
  try spin(
    until: { !b.loading && labels().contains("This folder is empty.") }, "selected empty folder")
  let incoming = exports.appendingPathComponent("incoming-proof.txt")
  try Data("proof".utf8).write(to: incoming)
  try spin(until: { labels().contains(incoming.lastPathComponent) }, "new file in selected folder")
  let renamed = exports.appendingPathComponent("approved-proof.txt")
  try fm.moveItem(at: incoming, to: renamed)
  try spin(
    until: {
      labels().contains(renamed.lastPathComponent) && !labels().contains(incoming.lastPathComponent)
    }, "renamed preview child")
  try fm.removeItem(at: renamed)
  try spin(until: { labels().contains("This folder is empty.") }, "removed preview child")

  for n in 0..<48 {
    try Data().write(to: exports.appendingPathComponent("proof-\(n).txt"))
  }
  try spin(until: { labels().contains("48 items") }, "burst of folder changes")
  guard let scroll = tree(b.ui.preview).compactMap({ $0 as? NSScrollView }).first else {
    throw CheckFailure("Missing inspector scroll view")
  }
  let clip = scroll.contentView
  clip.scroll(to: NSPoint(x: 0, y: 320))
  scroll.reflectScrolledClipView(clip)
  let expectedOffset = clip.bounds.origin.y
  try require(expectedOffset > 100, "Crowded inspector did not scroll")
  try Data().write(to: incoming)
  try spin(until: { labels().contains("49 items") }, "change in scrolled folder")
  try require(
    clip.bounds.origin.y == expectedOffset, "Refreshing the inspector reset its scroll position")

  try select(b, named: text.lastPathComponent)
  try spin(until: { showsText(early) }, "initial selected text")
  guard let original = tree(b.ui.preview).compactMap({ $0 as? NSTextView }).first else {
    throw CheckFailure("The text preview had no selectable surface")
  }
  let highlight = NSRange(location: 0, length: 5)
  original.setSelectedRange(highlight)
  let sibling = root.appendingPathComponent("Another printed page.txt")
  try Data().write(to: sibling)
  try spin(
    until: { !b.scanning && b.entries.contains { $0.path == sibling.path } }, "sibling export")
  try spin(until: { showsText(early) }, "text preview after unrelated export")
  try require(
    tree(b.ui.preview).contains { $0 === original } && original.selectedRange() == highlight,
    "An unrelated folder change discarded the highlighted text in the preview")
  let writer = try FileHandle(forWritingTo: text)
  try writer.write(contentsOf: Data(final.utf8))
  try writer.close()
  try spin(until: { showsText(final) }, "in-place same-size text edit")
  try Data("atomic version".utf8).write(to: text, options: .atomic)
  try spin(until: { showsText("atomic version") }, "atomic file replacement")
  try Data("after replacement".utf8).write(to: text)
  try spin(until: { showsText("after replacement") }, "subsequent write to replacement file")

  try Data("a delayed event".utf8).write(to: text)
  try select(b, named: exports.lastPathComponent)
  try spin(until: { labels().contains("49 items") }, "reselected folder")
  pump(0.25)
  try require(
    labels().contains("49 items") && !showsText("a delayed event"),
    "A stale file observation replaced the new selection")
  try select(b, named: empty.lastPathComponent)
  try spin(
    until: {
      labels().contains("This file is empty.") && labels().contains { $0.hasSuffix("0 bytes") }
    }, "zero-byte PNG")
  try require(
    !tree(b.ui.preview).contains { String(describing: type(of: $0)) == "PreviewPicture" },
    "Empty PNG requested image artwork")
  try select(b, named: byte.lastPathComponent)
  try spin(
    until: { showsText("x") && labels().contains { $0.hasSuffix("1 byte") } }, "one-byte text")
  try select(b, named: utf16.lastPathComponent)
  try spin(
    until: { showsText(unicodePrefix) && labels().contains("Showing the beginning of the file") },
    "UTF-16 preview ending mid-surrogate")

  let sample = (0..<32).map { exports.appendingPathComponent("proof-\($0).txt") }
  b.ui.preview.show(urls: sample, totalSelectionCount: 100_000)
  try spin(
    until: {
      labels().contains("\(100_000.formatted()) items")
        && labels().contains("And \(99_968.formatted()) more")
    },
    "exact count with a bounded preview sample")
  try require(
    !labels().contains { $0.contains("across selected files") },
    "Large sample implied a complete byte total")
  b.ui.preview.show(urls: [empty, byte])
  try spin(
    until: { labels().contains("1 byte across selected files") }, "exact small-selection byte total"
  )
  b.visit(project.path)
  try spin(until: { !b.loading && b.location == project.path }, "leave inspector fixture")
  try checkThumbnailReplacement(project: project, scratch: root)
  print(
    "Live inspector verified child changes, scroll, in-place and atomic edits, empty files, byte sizes and bounded multi-selection."
  )
}

private func checkThumbnailReplacement(project: URL, scratch: URL) throws {
  let a = try Data(contentsOf: project.appendingPathComponent("exports/Overlap 01.png"))
  let b = try Data(contentsOf: project.appendingPathComponent("exports-old/Overlap 00.png"))
  let length = max(a.count, b.count)
  let target = scratch.appendingPathComponent("latest.png")
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  func export(_ art: Data) throws {
    try (art + Data(repeating: 0, count: length - art.count)).write(to: target, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
  }
  try export(a)
  let cell = FileCell(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
  let entry = Entry.inspect(target.path)
  func pixels() -> Data? {
    guard let image = cell.subviews.compactMap({ $0 as? NSImageView }).first?.image,
      image.size.width == 56
    else { return nil }
    return image.tiffRepresentation
  }
  cell.update(entry, selected: false)
  try spin(until: { pixels() != nil }, "first row thumbnail")
  let original = pixels()
  try export(b)
  cell.update(entry, selected: false)
  try spin(
    until: { pixels() != nil && pixels() != original },
    "replaced row thumbnail with unchanged date and size")
  let fifo = scratch.appendingPathComponent("preview-pipe.png")
  try require(mkfifo(fifo.path, 0o600) == 0, "Could not create the special-file fixture")
  try require(
    ThumbnailFile.cacheKey(for: fifo, pixels: 56) == nil,
    "A named pipe was offered to an image decoder")
}
