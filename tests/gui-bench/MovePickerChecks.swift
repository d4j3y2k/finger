import AppKit

/// Invoke the production Move command and cancel the real attached sheet.
func profileMovePicker(_ b: Browser, folder: URL, count: Int, samples: Int) throws {
  b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
  b.project = folder.deletingLastPathComponent().path
  b.visit(folder.path)
  try spin(until: { !b.loading && !b.scanning && b.rows.count == count }, "disposable Move project")
  try paint(b)
  let delivery = folder.deletingLastPathComponent().appendingPathComponent(
    "delivery", isDirectory: true)
  func sheetControl(noInferredAnimation: Bool) {
    let start = DispatchTime.now().uptimeNanoseconds
    let p = MovePicker(
      parent: b.window, sources: [folder.appendingPathComponent("example.svg")],
      candidates: [delivery], move: true, project: folder.deletingLastPathComponent()
    ) { _ in }
    let built = ms(start)
    if noInferredAnimation { p.panel.animationBehavior = .none }
    b.window.beginSheet(p.panel)
    let shown = ms(start)
    _ = p.panel.makeFirstResponder(p.table)
    let focused = ms(start)
    p.panel.contentView?.layoutSubtreeIfNeeded()
    let laidOut = ms(start)
    p.cancel()
    print(
      String(
        format:
          "move-picker native-control suppress-inferred-animation=%d build=%.2fms beginSheet=%.2fms focus=%.2fms layout=%.2fms",
        noInferredAnimation ? 1 : 0, built,
        shown - built, focused - shown, laidOut - focused))
  }
  for suppressed in [false, true, false, true] {
    sheetControl(noInferredAnimation: suppressed)
    pump(0.08)
  }
  func run(_ selectionCount: Int, _ trial: String) throws {
    b.ui.table.selectRowIndexes(
      IndexSet(integersIn: 0..<selectionCount), byExtendingSelection: false)
    try require(b.ui.table.numberOfSelectedRows == selectionCount, "Wrong Move source selection")
    pump(0.10)
    let start = DispatchTime.now().uptimeNanoseconds
    var previous = start
    var gap: UInt64 = 0
    func tick() {
      let current = DispatchTime.now().uptimeNanoseconds
      gap = max(gap, current - previous)
      previous = current
    }
    let timer = Timer(timeInterval: 0.002, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    var preparation = -1.0
    var preparationGap = -1.0
    let willOpen = NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification, object: b.window, queue: nil
    ) { _ in
      preparation = ms(start)
      // Observe the start of the native sheet animation without counting this
      // synchronous notification as a new opportunity for the main loop to run.
      preparationGap = Double(max(gap, DispatchTime.now().uptimeNanoseconds - previous)) / 1_000_000
    }
    defer { NotificationCenter.default.removeObserver(willOpen) }
    b.chooseTransfer(move: true)
    let synchronous = ms(start)
    try spin(until: { b.picker != nil && b.window.attachedSheet != nil }, "Move picker to appear")
    guard let picker = b.picker else { throw CheckFailure("Picker disappeared") }
    picker.panel.contentView?.layoutSubtreeIfNeeded()
    let wall = ms(start)
    tick()
    let choices = (0..<picker.table.numberOfRows).compactMap { index in
      picker.tableView(picker.table, viewFor: nil, row: index)?.toolTip
    }
    try require(
      choices.first == folder.deletingLastPathComponent().appendingPathComponent("delivery").path,
      "Expected delivery to lead this project's Move suggestions, got \(choices)")
    try require(!choices.contains(folder.path), "Move offered its only source folder")
    try require(
      tree(picker.panel.contentView!).contains {
        ($0 as? NSTextField)?.stringValue == "Move \(selectionCount.formatted()) items"
      }, "Sheet showed a sampled source count")
    picker.cancel()
    try spin(until: { b.picker == nil && b.window.attachedSheet == nil }, "dismiss Move sheet")
    print(
      String(
        format:
          "move-picker entries=%d selected=%d trial=%@ invoke=%.2fms prepare=%.2fms prepGap=%.2fms ready=%.2fms mainGap=%.2fms",
        count, selectionCount, trial, synchronous, preparation, preparationGap, wall,
        Double(gap) / 1_000_000))
    fflush(stdout)
  }
  for size in [2, count] {
    try autoreleasepool { try run(size, "warmup") }
    for trial in 1...samples { try autoreleasepool { try run(size, String(trial)) } }
  }
  let selected = b.fileSelection
  var captured = false
  b.listingQueue.async {
    let start = DispatchTime.now().uptimeNanoseconds
    let paths = selected.map(\.path)
    let enumerated = ms(start)
    let bound = OperationSelection(paths: paths, directory: folder.path)
    withExtendedLifetime(bound) {
      print(
        String(
          format: "move-picker identity-control entries=%d snapshotPaths=%.2fms bind=%.2fms", count,
          enumerated, ms(start) - enumerated))
    }
    DispatchQueue.main.async { captured = true }
  }
  try spin(until: { captured }, "Move identity capture control")
  try checkMovePickerSafety(b, in: folder.deletingLastPathComponent())
  b.window.orderOut(nil)
}

private func checkMovePickerSafety(_ b: Browser, in disposable: URL) throws {
  let fm = FileManager.default
  let container = disposable.appendingPathComponent("picker-checks", isDirectory: true)
  let project = container.appendingPathComponent("Design", isDirectory: true)
  let exports = project.appendingPathComponent("exports", isDirectory: true)
  let selectedFolder = exports.appendingPathComponent("Edition", isDirectory: true)
  let nested = selectedFolder.appendingPathComponent("Child", isDirectory: true)
  let delivery = project.appendingPathComponent("delivery", isDirectory: true)
  let away = container.appendingPathComponent("Earlier/delivery", isDirectory: true)
  for path in [nested, delivery, away] {
    try fm.createDirectory(at: path, withIntermediateDirectories: true)
  }
  let files = (0..<70).map { exports.appendingPathComponent("Proof-\($0).svg") }
  for path in files { try Data("original".utf8).write(to: path) }
  let foreign = away.appendingPathComponent("Mixed source.svg")
  try Data().write(to: foreign)
  let link = exports.appendingPathComponent("linked.svg")
  try fm.createSymbolicLink(at: link, withDestinationURL: files[0])
  b.project = project.path
  b.visit(exports.path)
  try spin(
    until: { !b.loading && !b.scanning && b.folderPath == exports.path }, "Move safety fixture")

  // Bulk descriptor-relative reads must agree with lstat, including links and missing names.
  let paths = (files + [link, exports.appendingPathComponent("missing.svg")]).map(\.path)
  var compared: Bool?
  b.listingQueue.async {
    let captured = OperationSelection(paths: paths, directory: exports.path)
    let expected = captured.protecting([:], sources: paths)["expectedSources"] as? [String: String]
    let valid = paths.allSatisfy { expected?[$0] == FileIdentity(path: $0).transferToken }
    DispatchQueue.main.async { compared = valid }
  }
  try spin(until: { compared != nil }, "bulk identity comparison")
  try require(
    compared == true, "Bulk binding differed from lstat on a symlink, missing name or regular file")

  // Replacing a same-sized UI selection while candidates are prepared must cancel the request.
  try select(b, named: files[0].lastPathComponent)
  b.chooseTransfer(move: true)
  try select(b, named: files[1].lastPathComponent)
  for _ in 0..<2 {
    var drained = false
    b.listingQueue.async(flags: .barrier) { DispatchQueue.main.async { drained = true } }
    try spin(until: { drained }, "stale Move request")
  }
  try require(b.picker == nil, "Move retargeted a newer same-count selection")
  b.chooseTransfer(move: true)
  // Filtering to the same paths creates a fresh row map, as a passive reload can.
  b.filter(state: ["selected": [files[1].path]])
  try spin(until: { b.picker != nil }, "unchanged selection after refreshed row storage")
  let saved = project.appendingPathComponent("saved-original.svg")
  guard let pending = b.picker,
    let deliveryRow = (0..<pending.table.numberOfRows).first(where: {
      pending.tableView(pending.table, viewFor: nil, row: $0)?.toolTip == delivery.path
    })
  else { throw CheckFailure("Missing real destination from stale-file test") }
  pending.table.selectRowIndexes(IndexSet(integer: deliveryRow), byExtendingSelection: false)
  try fm.moveItem(at: files[1], to: saved)
  try Data("replacement".utf8).write(to: files[1])
  b.picker?.confirm()
  try require(
    b.ui.status.stringValue == "Moving \(files[1].lastPathComponent) to delivery…"
      && b.ui.status.toolTip == b.ui.status.stringValue,
    "Unexpected single-item operation status: \(b.ui.status.stringValue)")
  try spin(
    until: { !b.busy && b.picker == nil && b.window.attachedSheet != nil }, "stale file error")
  let alert = b.window.attachedSheet!
  try require(
    tree(alert.contentView!).contains {
      ($0 as? NSTextField)?.stringValue.contains("no longer the item") == true
    }, "Move omitted the binding error")
  let remaining = try String(contentsOf: files[1], encoding: .utf8)
  try require(
    remaining == "replacement"
      && !fm.fileExists(atPath: delivery.appendingPathComponent(files[1].lastPathComponent).path),
    "Move touched the replacement")
  b.window.endSheet(alert)
  alert.orderOut(nil)
  let batch = project.appendingPathComponent("Batch A", isDirectory: true)
  try fm.createDirectory(at: batch, withIntermediateDirectories: true)
  try Data("copy fixture".utf8).write(to: batch.appendingPathComponent("Contents.txt"))
  b.transfer([batch.path], to: delivery.path, move: false)
  try require(
    b.ui.status.stringValue == "Copying Batch A to delivery…"
      && b.ui.status.toolTip == b.ui.status.stringValue,
    "Single-folder copy progress did not identify the folder and destination")
  try spin(until: { !b.busy }, "copying one disposable folder")
  let copied = try String(
    contentsOf: delivery.appendingPathComponent("Batch A/Contents.txt"), encoding: .utf8)
  try require(copied == "copy fixture", "Named copy status did not accompany the expected transfer")
  b.transfer([files[2].path, files[3].path], to: delivery.path, move: false)
  try require(
    b.ui.status.stringValue == "Copying 2 items to delivery…",
    "Multi-file copy status omitted count or destination")
  try spin(until: { !b.busy }, "copying two disposable files")

  // The item beyond the 32 filenames used for ranking belongs to a different project.
  b.favorites = [selectedFolder.path, nested.path, away.path, delivery.path]
  UserDefaults.standard.set([away.path], forKey: "recentDestinations")
  b.receiveCollection(
    "Mixed selection", Array(files.prefix(32)) + [foreign, selectedFolder], bringForward: false)
  try spin(
    until: { !b.loading && !b.scanning && b.collection?.name == "Mixed selection" },
    "mixed Move sources")
  b.ui.table.selectAll(nil)
  b.chooseTransfer(move: true)
  try spin(until: { b.picker != nil }, "mixed Move choices")
  let picker = b.picker!
  let choices = (0..<picker.table.numberOfRows).compactMap {
    picker.tableView(picker.table, viewFor: nil, row: $0)?.toolTip
  }
  try require(
    choices.first == away.path && !choices.contains(selectedFolder.path)
      && !choices.contains(nested.path),
    "Mixed-source ranking lost its external destination or included a selected ancestor: \(choices)"
  )
  picker.cancel()
  print(
    "Move checks preserved mixed-project ranking, excluded selected folders and descendants, rejected a changed UI selection and protected a replaced file after the sheet opened."
  )
}
