import AppKit

/// Exercises file ordering in the same offscreen AppKit browser that ran the timing samples.
func checkFileOrder(_ b: Browser, returningTo directory: URL) throws {
  let fm = FileManager.default
  let root = directory.deletingLastPathComponent().appendingPathComponent(
    "Ordering-" + UUID().uuidString)
  let child = root.appendingPathComponent("Subfolder")
  try fm.createDirectory(at: child, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  func file(_ parent: URL, _ name: String, bytes: Int, time: Int) throws {
    let url = parent.appendingPathComponent(name)
    try Data(repeating: 0, count: bytes).write(to: url)
    try fm.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(time))],
      ofItemAtPath: url.path)
  }
  for i in 0..<101 {
    try file(root, "Specimen \(i).dat", bytes: (i * 29) % 101 + 1, time: (i * 47) % 101)
  }
  for (i, name) in ["First.txt", "Middle.txt", "Last.txt"].enumerated() {
    try file(child, name, bytes: i * 10 + 1, time: i)
  }
  func settled() throws {
    try spin(until: { !b.loading && !b.scanning }, "sorted file list")
    try paint(b)
  }
  func order(_ choice: FileOrder) throws {
    b.setFileOrder(choice)
    try settled()
    let checks = b.fileSortMenu().items.filter { $0.state == .on }
    try require(
      checks.map(\.title) == [choice.menuTitle], "Sort menu checkmark for " + choice.rawValue)
  }
  b.visit(root.path)
  try settled()
  try order(.nameAsc)
  try require(
    b.entries[0].isDirectory && b.entries[3].name == "Specimen 2.dat", "Natural filename order")
  try select(b, named: "Specimen 44.dat")
  let row = b.ui.table.selectedRow
  b.ui.table.selectRowIndexes(IndexSet(integersIn: row...row + 1), byExtendingSelection: false)
  let clip = b.ui.scroll.contentView
  clip.scroll(to: NSPoint(x: 0, y: b.ui.table.rect(ofRow: row).minY - 55))
  b.ui.scroll.reflectScrolledClipView(clip)
  let chosen = Set(b.selected.map(\.path))
  let snapshot = b.snapshot()
  let original = snapshot["anchorPath"] as? String
  let delta = snapshot["anchorDelta"] as? CGFloat
  try require(original != nil && delta != nil, "Missing scroll anchor")
  try order(.sizeDesc)
  try require(Set(b.selected.map(\.path)) == chosen, "Sort changed multi-selection")
  if let original, let delta,
    let anchor = b.rows.firstIndex(where: { b.entries[$0].path == original })
  {
    try require(
      abs(b.ui.table.rect(ofRow: anchor).minY - clip.bounds.minY - delta) < 1,
      "Sort displaced visible selection")
  } else {
    throw CheckFailure("Sorted anchor disappeared")
  }
  for choice in FileOrder.allCases {
    try order(choice)
    let files = b.entries.filter { !$0.isDirectory }
    let ascending = choice == .sizeAsc || choice == .modifiedAsc
    if choice.isName {
      try require(
        files.first?.name == (choice == .nameAsc ? "Specimen 0.dat" : "Specimen 100.dat"),
        "Wrong name direction")
    } else {
      let values = files.compactMap { choice.isSize ? $0.size : $0.modified }
      try require(
        values.count == 101 && values == values.sorted(by: ascending ? (<) : (>)),
        "Wrong " + choice.rawValue)
    }
    try require(b.entries.first?.name == "Subfolder", "Sort displaced folder grouping")
  }
  b.setFileOrder(.modifiedAsc)
  b.setFileOrder(.nameDesc)
  b.setFileOrder(.sizeDesc)
  try settled()
  try require(b.entries[1].size == 101, "A late directory read replaced the latest sort")
  try select(b, named: "Subfolder")
  func previewRows() -> [String] {
    let labels = tree(b.ui.preview).compactMap { $0 as? NSTextField }.filter {
      $0.stringValue.hasSuffix(".txt")
    }
    return labels.sorted {
      b.ui.preview.convert($0.bounds, from: $0).minY
        < b.ui.preview.convert($1.bounds, from: $1).minY
    }.map(\.stringValue)
  }
  try spin(
    until: {
      b.ui.preview.layoutSubtreeIfNeeded()
      return previewRows().count == 3
    }, "sorted folder preview")
  let preview = previewRows()
  b.openSelected()
  try spin(
    until: { b.folderPath == child.path && !b.loading && !b.scanning }, "entered sorted folder")
  try settled()
  try require(
    preview == b.entries.map(\.name),
    "Folder preview \(preview) and entered folder order \(b.entries.map(\.name)) differ")
  try order(.modifiedDesc)
  try require(b.ui.sizes.stringValue == "MODIFIED ↓", "Modified column indicator")
  guard let cell = b.tableView(b.ui.table, viewFor: nil, row: 0) as? FileCell else {
    throw CheckFailure("Missing file cell")
  }
  try require(
    !cell.detail.stringValue.isEmpty && cell.detail.toolTip != nil, "Date modified missing from row"
  )
  let frame = b.window.frame
  let fraction = b.ui.fraction
  b.ui.fraction = 0.65
  b.window.setContentSize(NSSize(width: 700, height: 405))
  b.ui.root.layoutSubtreeIfNeeded()
  try require(
    b.ui.sizes.isHidden && b.ui.columns.attributedTitle.string.contains("MODIFIED ↓"),
    "Compact header loses active order")
  cell.frame.size.width = 270
  cell.layoutSubtreeIfNeeded()
  try require(
    cell.detail.isHidden && cell.filename.frame.width >= 210, "Compact filename lacks space")
  b.ui.fraction = fraction
  b.window.setFrame(frame, display: false)
  b.ui.root.layoutSubtreeIfNeeded()
  b.step("back")
  try settled()
  try require(
    b.fileOrder == .modifiedDesc && b.selected.first?.name == "Subfolder",
    "Back restored an obsolete order or selection")
  let expected = b.entries.filter { $0.name.contains("Specimen") && $0.name.contains("9") }.map(
    \.path)
  b.ui.query.stringValue = "Specimen 9"
  b.filter()
  try require(b.rows.map { b.entries[$0].path } == expected, "Filtering reordered the list")
  b.load(b.snapshot(), clear: false)
  try settled()
  try require(b.rows.map { b.entries[$0].path } == expected, "Refresh lost sorted filter")
  b.clearFilter()
  b.ui.query.stringValue = "Specimen 9"
  b.filter()
  b.change(
    ["op": "newFolder", "path": root.path, "name": "New proofs"], success: "Created folder",
    in: root.path)
  try spin(
    until: { !b.busy && !b.scanning && b.selected.first?.name == "New proofs" },
    "new folder from a filtered view")
  try require(
    b.beforeFilter == nil && b.snapshot()["beforeFilter"] == nil,
    "Creating a folder retained obsolete filter history")
  b.ui.query.stringValue = "Specimen 2"
  b.filter()
  b.clearFilter()
  try require(
    b.selected.first?.name == "New proofs", "Clearing the next filter lost the newly created folder"
  )
  let supplied = [b.entries[5].path, b.entries[2].path, b.entries[9].path]
  let record = CollectionRecord(id: UUID().uuidString, name: "Order check", paths: supplied)
  b.collections.append(record)
  b.visit("collection:" + record.id)
  try settled()
  try require(
    b.entries.map(\.path) == supplied && b.fileSortMenu().items.first?.title == "Collection Order",
    "Agent collection order changed")
  b.visit(directory.path)
  try settled()
  b.collections.removeAll { $0.id == record.id }
  try order(.nameAsc)
  print(
    "All six file orders, live preview order, compact metadata, multi-selection, scroll anchoring, filtered refresh, history and supplied collection order passed."
  )
}
