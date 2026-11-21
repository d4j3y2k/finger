import AppKit

func checkFolderRecovery(_ b: Browser, returningTo original: URL) throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(
    "finger-recovery-" + UUID().uuidString, isDirectory: true)
  let watched = root.appendingPathComponent("Live exports", isDirectory: true)
  let parked = root.appendingPathComponent("Temporarily offline", isDirectory: true)
  try fm.createDirectory(at: watched, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  for number in 0..<55 {
    try Data().write(to: watched.appendingPathComponent(String(format: "Page %02d.txt", number)))
  }

  b.visit(watched.path)
  try spin(until: { !b.scanning && b.entries.count == 55 }, "initial live exports")
  let pair = IndexSet(integersIn: 41..<43)
  b.ui.table.selectRowIndexes(pair, byExtendingSelection: false)
  b.ui.table.scrollRowToVisible(42)
  try paint(b)
  let selected = b.selected.map(\.path)
  let offset = b.ui.scroll.contentView.bounds.minY
  try fm.moveItem(at: watched, to: parked)
  try spin(
    until: { !b.scanning && b.lastError != nil && !b.ui.retry.isHidden }, "directory disappearance")
  try require(
    !b.ui.emptyDetail.stringValue.isEmpty, "Missing directory had no persistent explanation")
  try fm.moveItem(at: parked, to: watched)
  try spin(
    until: { !b.scanning && b.entries.count == 55 && b.lastError == nil },
    "automatic directory recovery")
  try paint(b)
  try require(
    b.selected.map(\.path) == selected && b.ui.scroll.contentView.bounds.minY == offset,
    "A temporarily unavailable directory lost its selected files or scroll position")
  try require(
    b.ui.retry.isHidden && b.ui.status.stringValue == "Folder reopened",
    "Recovery left stale error details")
  let before = b.snapshot()
  b.visit(root.path)
  try spin(until: { !b.scanning && b.folderPath == root.path }, "leaving the export folder")
  for number in 0..<10 {
    try Data().write(to: watched.appendingPathComponent("New export \(number).txt"))
  }
  b.step("back")
  try spin(until: { !b.scanning && b.entries.count == 65 }, "return to updated exports")
  try paint(b)
  let after = b.snapshot()
  try require(
    b.selected.map(\.path) == selected
      && before["anchorPath"] as? String == after["anchorPath"] as? String
      && before["anchorDelta"] as? CGFloat == after["anchorDelta"] as? CGFloat
      && b.ui.scroll.contentView.bounds.minY > offset,
    "New files inserted above the viewport shifted its selected contents on Back")
  // A print exporter can keep a directory busy for minutes. Its first pages
  // should appear while the exporter is still writing the rest.
  let streamStarted = DispatchTime.now().uptimeNanoseconds
  var firstArrival: Double?
  var intermediateCounts = Set<Int>()
  for page in 1...30 {
    try Data().write(to: watched.appendingPathComponent("Incoming \(page).txt"))
    pump(0.055)
    if b.entries.count > 65 {
      if firstArrival == nil { firstArrival = ms(streamStarted) }
      intermediateCounts.insert(b.entries.count)
    }
  }
  try spin(until: { !b.scanning && b.entries.count == 95 }, "the last page of a live export")
  try paint(b)
  try require(
    intermediateCounts.count >= 2,
    "The folder stayed stale until the continuous export stopped")
  try require(
    b.selected.map(\.path) == selected
      && b.snapshot()["anchorPath"] as? String == before["anchorPath"] as? String
      && b.snapshot()["anchorDelta"] as? CGFloat == before["anchorDelta"] as? CGFloat,
    "Live inserts moved the selected pages within the viewport")
  if let firstArrival {
    print(
      String(
        format:
          "Live export displayed its first update in %.0f ms and %d distinct counts during the stream.",
        firstArrival, intermediateCounts.count))
  }
  b.visit(original.path)
  try spin(until: { !b.scanning }, "leaving the recovery fixture")
  print(
    "Directory recovery and new exports inserted during navigation preserved the selection and viewport."
  )
}
