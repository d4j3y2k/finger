import AppKit
import QuartzCore

struct CheckFailure: LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure(message) }
}
func spin(until done: () -> Bool, _ message: String) throws {
  let timeout = Date(timeIntervalSinceNow: 40)
  while !done() {
    if Date() > timeout { throw CheckFailure("Timed out waiting for " + message) }
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0006))
  }
}
func pump(_ seconds: Double) {
  let stop = Date(timeIntervalSinceNow: seconds)
  while Date() < stop {
    _ = RunLoop.main.run(mode: .default, before: min(stop, Date(timeIntervalSinceNow: 0.004)))
  }
}
func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
func ms(_ start: UInt64) -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// An offscreen window has no display-link callback. Cache its real table
/// viewport into an AppKit bitmap to force native row layout and painting.
var benchmarkViewObserver: ((Browser) -> Void)?

struct PaintDuration {
  let layout: Double
  let allocate: Double
  let draw: Double
  let flush: Double
}
@discardableResult
func paint(_ b: Browser) throws -> PaintDuration {
  let layoutStart = DispatchTime.now().uptimeNanoseconds
  let table = b.ui.table
  b.ui.root.layoutSubtreeIfNeeded()
  table.layoutSubtreeIfNeeded()
  let viewport = table.visibleRect.intersection(table.bounds)
  let layout = ms(layoutStart)
  let allocationStart = DispatchTime.now().uptimeNanoseconds
  guard viewport.width >= 100, viewport.height > 0,
    let bitmap = table.bitmapImageRepForCachingDisplay(in: viewport)
  else {
    throw CheckFailure("The file table has no drawable viewport")
  }
  let allocate = ms(allocationStart)
  let renderStart = DispatchTime.now().uptimeNanoseconds
  table.cacheDisplay(in: viewport, to: bitmap)
  let draw = ms(renderStart)
  let flushStart = DispatchTime.now().uptimeNanoseconds
  CATransaction.flush()
  let flush = ms(flushStart)
  benchmarkViewObserver?(b)
  return PaintDuration(layout: layout, allocate: allocate, draw: draw, flush: flush)
}

func select(_ b: Browser, named name: String) throws {
  guard let row = b.rows.firstIndex(where: { b.entries[$0].name == name }) else {
    throw CheckFailure("Missing row " + name)
  }
  b.ui.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  b.ui.table.scrollRowToVisible(row)
}

func key(_ code: UInt16, text: String, in b: Browser) throws {
  guard
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: b.window.windowNumber,
      context: nil,
      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
  else {
    throw CheckFailure("Could not construct a local key event")
  }
  b.ui.table.keyDown(with: event)
}

func replaceSearch(_ query: String, in b: Browser) throws {
  b.focusSearch(select: true)
  guard let editor = b.ui.query.currentEditor() as? NSTextView else {
    throw CheckFailure("Search field has no native field editor")
  }
  editor.insertText(
    query, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
  try require(b.ui.query.stringValue == query, "Search field did not accept text")
}

func verifyPaintedRow(_ b: Browser) throws {
  let visible = b.ui.table.rows(in: b.ui.table.visibleRect)
  try require(
    visible.length > 0 && b.rows.indices.contains(visible.location), "Expected painted file rows")
  guard
    let cell = b.ui.table.view(atColumn: 0, row: visible.location, makeIfNecessary: false)
      as? FileCell
  else {
    throw CheckFailure("First visible row was not materialized")
  }
  try require(
    cell.filename.stringValue == b.entries[b.rows[visible.location]].name,
    "Materialized row text is stale")
}

func summary(_ label: String, _ samples: [Double]) {
  let ordered = samples.sorted()
  let mid = ordered.count / 2
  let median =
    ordered.count.isMultiple(of: 2) ? (ordered[mid] + ordered[mid - 1]) / 2 : ordered[mid]
  let p95 = ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
  print(
    String(
      format: "%@: median %.2f ms, p95 %.2f ms (%d warmed samples)", label, median, p95,
      samples.count))
}

private func capture(_ b: Browser, demo: URL, output: String) throws {
  guard !output.isEmpty else { return }
  b.project = demo.path
  b.visit(demo.path, selecting: demo.appendingPathComponent("exports").path)
  try spin(until: { !b.loading && b.selected.first?.name == "exports" }, "demo folder selection")
  try spin(
    until: {
      let views = tree(b.ui.preview)
      return views.contains { ($0 as? NSTextField)?.stringValue == "FOLDER PREVIEW" }
        && views.filter {
          String(describing: type(of: $0)) == "PreviewPicture" && ($0 as? NSImageView)?.image != nil
        }.count >= 2
    }, "both real demo thumbnails")
  b.window.makeFirstResponder(b.ui.table)
  b.window.setContentSize(NSSize(width: 1150, height: 710))
  b.ui.root.layoutSubtreeIfNeeded()
  pump(0.08)
  try writeWindowPNG(b, output: output)
}

func writeWindowPNG(_ b: Browser, output: String) throws {
  guard let content = b.window.contentView else { throw CheckFailure("No window content") }
  let frame = content.superview ?? content
  guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
    throw CheckFailure("No capture surface")
  }
  frame.cacheDisplay(in: frame.bounds, to: rep)
  guard let image = rep.representation(using: .png, properties: [:]) else {
    throw CheckFailure("PNG encoding failed")
  }
  try image.write(to: URL(fileURLWithPath: output), options: .atomic)
  print("Window PNG: " + output)
}

private func captureCompact(_ b: Browser, demo: URL, output: String) throws {
  let exports = demo.appendingPathComponent("exports", isDirectory: true)
  let source = exports.appendingPathComponent("Overlap 01.svg")
  let longName =
    "A very long filename for the approved delivery artwork and its source version 12.svg"
  let file = exports.appendingPathComponent(longName)
  try FileManager.default.copyItem(at: source, to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  b.project = demo.path
  b.window.setContentSize(NSSize(width: 790, height: 505))
  b.visit(exports.path, selecting: file.path)
  try spin(
    until: {
      !b.loading && b.selected.first?.name == longName
        && tree(b.ui.preview).contains {
          String(describing: type(of: $0)) == "PreviewPicture" && ($0 as? NSImageView)?.image != nil
        }
    }, "compact SVG preview")
  b.ui.root.layoutSubtreeIfNeeded()
  guard
    let title = tree(b.ui.preview).compactMap({ $0 as? NSTextField }).first(where: {
      $0.stringValue == longName
    })
  else {
    throw CheckFailure("Inspector title lost its full filename")
  }
  try require(
    title.isSelectable && title.maximumNumberOfLines == 2 && title.frame.height >= 60,
    "Compact filename did not get two selectable lines")
  try require(
    title.toolTip == file.path
      && title.menu?.items.contains(where: { $0.title == "Copy Filename" }) == true,
    "Full filename or path copy affordance is missing")
  try require(
    b.ui.preview.bounds.height - title.frame.maxY >= 215,
    "Wrapped title left too little space for the image")
  try writeWindowPNG(b, output: output)
  print(
    "Compact title verified at \(Int(b.window.contentLayoutRect.width)) pt wide, title height \(Int(title.frame.height)) pt."
  )
}

private func exercise(
  _ b: Browser, directory: URL, count: Int, samples: Int, demo: URL, output: String
) throws {
  let parent = directory.deletingLastPathComponent()
  b.window.setContentSize(NSSize(width: 1150, height: 710))
  b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
  b.window.makeFirstResponder(b.ui.table)
  try capture(b, demo: demo, output: output)
  b.project = parent.path
  let profile = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_PROFILE"] == "1"
  var narrowPhases: [String: [Double]] = [:]
  var opens: [Double] = []
  var broad: [Double] = []
  var narrow: [Double] = []
  var clears: [Double] = []
  var broadCount = -1
  for trial in 0...samples {
    b.visit(parent.path)
    try spin(until: { !b.loading && b.location == parent.path }, "fixture project")
    try select(b, named: directory.lastPathComponent)
    try spin(
      until: {
        tree(b.ui.preview).contains { ($0 as? NSTextField)?.stringValue == "FOLDER PREVIEW" }
      }, "folder inspector")
    // Settle the previous transition outside the timed region.
    pump(0.22)
    let start = DispatchTime.now().uptimeNanoseconds
    try key(124, text: String(UnicodeScalar(NSRightArrowFunctionKey)!), in: b)
    try spin(until: { !b.loading && b.location == directory.path }, "folder open")
    try paint(b)
    let elapsed = ms(start)
    try require(
      b.rows.count == count && b.ui.table.numberOfRows == count,
      "Folder-open visible row count mismatch")
    try verifyPaintedRow(b)
    if trial == 0 {
      print(String(format: "First open of %d entries through table paint: %.2f ms", count, elapsed))
    } else {
      opens.append(elapsed)
    }
    if broadCount < 0 { broadCount = b.entries.filter { $0.name.contains("plate-") }.count }

    let search = DispatchTime.now().uptimeNanoseconds
    try replaceSearch("plate-", in: b)
    try spin(until: { b.rows.count == broadCount }, "broad search")
    try paint(b)
    if trial > 0 { broad.append(ms(search)) }
    try verifyPaintedRow(b)

    let exact = DispatchTime.now().uptimeNanoseconds
    try replaceSearch("zzzz-proof-final.svg", in: b)
    try spin(until: { b.rows.count == 1 }, "exact search")
    let ready = ms(exact)
    let phases = try paint(b)
    if trial > 0 {
      narrow.append(ms(exact))
      if profile {
        narrowPhases["Native edit to result", default: []].append(ready)
        narrowPhases["View layout", default: []].append(phases.layout)
        narrowPhases["Bitmap allocation", default: []].append(phases.allocate)
        narrowPhases["AppKit viewport drawing", default: []].append(phases.draw)
        narrowPhases["Transaction flush", default: []].append(phases.flush)
        let floor = DispatchTime.now().uptimeNanoseconds
        try paint(b)
        narrowPhases["Unchanged viewport repaint", default: []].append(ms(floor))
      }
    }
    try require(
      b.selected.first?.name == "zzzz-proof-final.svg", "Exact search selected the wrong item")
    try verifyPaintedRow(b)

    let reset = DispatchTime.now().uptimeNanoseconds
    b.clearFilter()
    try paint(b)
    if trial > 0 { clears.append(ms(reset)) }
    try require(b.rows.count == count, "Clearing search lost rows")
  }
  summary("Folder open through table paint", opens)
  summary("Search matching \(broadCount) rows", broad)
  summary("Search matching one row", narrow)
  summary("Clear filter to all rows", clears)
  if profile {
    print("Breakdown of a one-result search, in milliseconds:")
    for name in [
      "Native edit to result", "View layout", "Bitmap allocation", "AppKit viewport drawing",
      "Transaction flush", "Unchanged viewport repaint",
    ] {
      if let values = narrowPhases[name] { summary(name, values) }
    }
  }

  let sparse = IndexSet([count - 5, count - 1])
  b.ui.table.selectRowIndexes(sparse, byExtendingSelection: false)
  let panel = NSPanel(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
  b.previewPanel = panel
  b.displayQuickLook(at: sparse.first)
  b.stepQuickLook(1)
  b.stepQuickLook(1)
  try require(
    panel.title == b.entries[b.rows[count - 1]].name, "Quick Look left its selected group")
  b.stepQuickLook(-1)
  try require(
    panel.title == b.entries[b.rows[count - 5]].name && b.ui.table.selectedRowIndexes == sparse,
    "Quick Look changed the selection or traversed an unselected row")
  b.displayQuickLook(at: nil)
  b.previewPanel = nil

  let tail = IndexSet(integersIn: (count - 2)..<count)
  b.ui.table.selectRowIndexes(tail, byExtendingSelection: false)
  b.ui.table.scrollRowToVisible(count - 1)
  try paint(b)
  let selected = b.selected.map(\.path)
  let position = b.ui.scroll.contentView.bounds.origin.y
  try require(
    selected.count == 2 && position > 1000, "Failed to establish deep selection and scroll")
  let child = directory.appendingPathComponent("000-open-me", isDirectory: true)
  b.openURL(child)
  try spin(until: { b.location == child.path && !b.loading }, "child")
  b.step("back")
  try spin(until: { b.location == directory.path && !b.loading }, "history restoration")
  try paint(b)
  let returned = b.ui.scroll.contentView.bounds.origin.y
  try require(
    b.selected.map(\.path) == selected && returned == position,
    "Back selection or offset changed (\(position) → \(returned))")
  try verifyPaintedRow(b)
  print("Back restored both selected paths and scroll offset \(returned) exactly.")
}

@_cdecl("finger_run")
public func benchRun(
  _ request: FingerRequest, _ release: FingerRelease, _ list: FingerList,
  _ query: FingerQuery, _ dropIndex: FingerDropIndex
) {
  autoreleasepool {
    do {
      guard let identifier = Bundle.main.bundleIdentifier,
        identifier.hasPrefix("local.finger.gui-bench."),
        CommandLine.arguments.count == 6, let n = Int(CommandLine.arguments[2]),
        let samples = Int(CommandLine.arguments[3])
      else {
        throw CheckFailure("Use tests/gui-bench/run.py to start the isolated harness")
      }
      let worktableVisit = ProcessInfo.processInfo.environment["FINGER_QA_WORKTABLE_VISIT"]
      defer {
        if worktableVisit != "first" { UserDefaults.standard.removePersistentDomain(forName: identifier) }
      }
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      app.finishLaunching()
      let transport = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_TRANSFER"] ?? "typed"
      let json = transport == "json"
      let ownedIndex = transport == "typed"
      let clipboard = NSPasteboard.withUniqueName()
      defer { clipboard.releaseGlobally() }
      let b = Browser(
        engine: Engine(
          request, release, json ? nil : list,
          ownedIndex ? query : nil, ownedIndex ? dropIndex : nil), clipboard: clipboard)
      if let worktableVisit {
        try checkWorktable(b, demo: URL(fileURLWithPath: CommandLine.arguments[4]),
          returning: worktableVisit == "return", capture: CommandLine.arguments[5])
        return
      }
      if let image = ProcessInfo.processInfo.environment["FINGER_GUI_VOLUME_RECOVERY"] {
        try checkVolumeRecovery(
          b, folder: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
          mount: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true),
          image: URL(fileURLWithPath: image))
        return
      }
      if ProcessInfo.processInfo.environment["FINGER_GUI_MOVE_PICKER"] == "1" {
        try profileMovePicker(
          b, folder: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), count: n,
          samples: samples)
        return
      }
      if let bridge = ProcessInfo.processInfo.environment["FINGER_GUI_BULK_BRIDGE"] {
        try profileBulkSelection(
          b, folder: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), count: n,
          samples: samples, bridge: bridge)
        return
      }
      if ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_TRANSFERS_ONLY"] == "1" {
        b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try checkTransfers(
          b, returningTo: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        return
      }
      try autoreleasepool {
        if let path = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_COMPACT_CAPTURE"] {
          try captureCompact(
            b, demo: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true), output: path
          )
        }
        print(
          "Benchmarking \(n) mixed entries with \(transport) listing transfer. First usable table paint includes indexing, filtering and native row drawing."
        )
        try exercise(
          b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
          count: n, samples: samples,
          demo: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true),
          output: CommandLine.arguments[5])
        try checkQuickLookRefresh(
          b, demo: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true))
        try checkPreviewRefresh(
          b, project: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true))
        try checkFileOrder(
          b, returningTo: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        try checkTransfers(
          b, returningTo: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        try checkExternalOpen(
          b, returningTo: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        try checkFolderRecovery(
          b, returningTo: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        try checkRapidNavigation(
          b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        if n >= 100_000 && ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_PROFILE"] == "1" {
          try checkCrowdedInspectorSwitching(
            b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        }
        try checkHistorySwipes(
          b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        if let artwork = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_ARTWORK"] {
          try checkArtworkPressure(b, project: URL(fileURLWithPath: artwork, isDirectory: true))
        }
      }
      // Native alert sheets can order their offscreen parent during preflight.
      b.window.orderOut(nil)
      b.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
      if let value = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_SOAK_MINUTES"],
        let minutes = Double(value),
        let log = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_SOAK_LOG"]
      {
        try runSoak(
          b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
          count: n, minutes: minutes, log: URL(fileURLWithPath: log))
      }
      if let value = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_PROBE_CYCLES"],
        let cycles = Int(value),
        let mode = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_PROBE_MODE"],
        let log = ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_SOAK_LOG"]
      {
        try runMemoryProbe(
          b, directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
          count: n, cycles: cycles, mode: mode, log: URL(fileURLWithPath: log))
      }
      b.window.orderOut(nil)
    } catch {
      FileHandle.standardError.write(
        Data(("GUI check failed: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
}
