import AppKit
import Darwin

struct ProcessSample {
  let rss: Double
  let fds: Int
  let footprint: Double
  let graphics: Double
  let heapInUse: Double
  let heapReserved: Double
  let liveBlocks: UInt32

  init() throws {
    var info = mach_task_basic_info()
    var words = mach_msg_type_number_t(
      MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.stride)
    let status = withUnsafeMutablePointer(to: &info) { p in
      p.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &words)
      }
    }
    guard status == KERN_SUCCESS else { throw CheckFailure("Could not sample process memory") }
    rss = Double(info.resident_size) / 1_048_576
    let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { throw CheckFailure("Could not size descriptor list") }
    var bytes = [UInt8](repeating: 0, count: Int(size) + 1024)
    let used = bytes.withUnsafeMutableBytes { p in
      proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, p.baseAddress, Int32(p.count))
    }
    guard used > 0 else { throw CheckFailure("Could not count descriptors") }
    fds = Int(used) / MemoryLayout<proc_fdinfo>.stride
    var vm = task_vm_info_data_t()
    var vmWords = mach_msg_type_number_t(
      MemoryLayout.size(ofValue: vm) / MemoryLayout<natural_t>.stride)
    let vmStatus = withUnsafeMutablePointer(to: &vm) { p in
      p.withMemoryRebound(to: integer_t.self, capacity: Int(vmWords)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmWords)
      }
    }
    guard vmStatus == KERN_SUCCESS else { throw CheckFailure("Could not sample process footprint") }
    footprint = Double(vm.phys_footprint) / 1_048_576
    graphics = Double(vm.ledger_tag_graphics_footprint) / 1_048_576
    var heap = malloc_statistics_t()
    malloc_zone_statistics(nil, &heap)
    heapInUse = Double(heap.size_in_use) / 1_048_576
    heapReserved = Double(heap.size_allocated) / 1_048_576
    liveBlocks = heap.blocks_in_use
  }
}

private final class SoakLog {
  private let handle: FileHandle
  private let clock = ISO8601DateFormatter()
  private let started = ProcessInfo.processInfo.systemUptime

  init(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
  }
  var seconds: Double { ProcessInfo.processInfo.systemUptime - started }
  func emit(_ event: String, _ fields: [String: Any], echo: Bool = false) throws {
    // Logging runs after each cycle's pool drains. Release Foundation's
    // temporary JSON buffers before collecting the next memory sample.
    try autoreleasepool {
      var record = fields
      record["event"] = event
      record["utc"] = clock.string(from: Date())
      record["elapsedSec"] = (seconds * 100).rounded() / 100
      var encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      encoded.append(0x0a)
      try handle.write(contentsOf: encoded)
      if echo { FileHandle.standardOutput.write(encoded) }
    }
  }
}

private struct SoakCycle {
  let open: Double
  let search: Double
  let refresh: Double
}

private func percentile(_ values: [Double], _ q: Double) -> Double {
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * q)) - 1))]
}

private func cycle(_ b: Browser, directory: URL, size: Int, index: Int) throws -> SoakCycle {
  let layout = [
    NSSize(width: 1150, height: 710), NSSize(width: 746, height: 430),
    NSSize(width: 968, height: 610), NSSize(width: 1250, height: 755),
  ]
  b.window.setContentSize(layout[index % layout.count])
  b.ui.root.layoutSubtreeIfNeeded()
  try require(!b.window.isVisible, "Offscreen test window unexpectedly became visible")
  let parent = directory.deletingLastPathComponent()
  b.visit(parent.path)
  try spin(until: { !b.loading && b.location == parent.path }, "soak project")
  try select(b, named: directory.lastPathComponent)
  try spin(
    until: {
      tree(b.ui.preview).contains { ($0 as? NSTextField)?.stringValue == "FOLDER PREVIEW" }
    }, "folder inspector")
  let open = DispatchTime.now().uptimeNanoseconds
  try key(124, text: String(UnicodeScalar(NSRightArrowFunctionKey)!), in: b)
  try spin(until: { !b.loading && b.location == directory.path }, "large folder")
  try paint(b)
  let openMs = ms(open)
  try require(b.rows.count == size, "Large folder contained an unexpected entry count")
  try verifyPaintedRow(b)

  let queries = ["plate-", "source-", "plate svg", "zzzz-proof-final", "no-matches-for-this-query"]
  let query = queries[index % queries.count]
  let words = query.split(separator: " ")
  let matches = b.entries.filter { entry in words.allSatisfy { entry.name.contains($0) } }.count
  let edit = DispatchTime.now().uptimeNanoseconds
  try replaceSearch(query, in: b)
  try spin(until: { b.rows.count == matches }, "search presentation")
  if matches > 0 {
    try paint(b)
    try verifyPaintedRow(b)
  } else {
    try require(!b.ui.empty.isHidden && b.selected.isEmpty, "Empty search presented stale rows")
  }
  let searchMs = ms(edit)
  b.clearFilter()
  try require(b.rows.count == size, "Clear did not restore the directory")

  let media = ["zzzz-proof-final.png", "zzzz-proof-final.svg"][index % 2]
  try select(b, named: media)
  try spin(
    until: {
      tree(b.ui.preview).contains {
        String(describing: type(of: $0)) == "PreviewPicture" && ($0 as? NSImageView)?.image != nil
      }
    }, "actual selected image preview")
  let row = min(size - 2, size / 4 + (index * 887) % max(1, size * 3 / 4 - 2))
  let chosen = IndexSet(integersIn: row..<(row + 2))
  b.ui.table.selectRowIndexes(chosen, byExtendingSelection: false)
  b.ui.table.scrollRowToVisible(row + 1)
  try paint(b)
  let paths = b.selected.map(\.path)
  let y = b.ui.scroll.contentView.bounds.origin.y
  try require(paths.count == 2 && y > 0, "Could not establish cross-navigation state")

  let head = directory.appendingPathComponent("000-open-me", isDirectory: true)
  var target = head
  b.openURL(target)
  try spin(until: { !b.loading && b.location == target.path }, "nested folder")
  var levels = 1
  if index.isMultiple(of: 3) {
    for part in ["next", "empty"] {
      target = target.appendingPathComponent(part, isDirectory: true)
      b.openURL(target)
      try spin(until: { !b.loading && b.location == target.path }, "deep folder")
      levels += 1
    }
    try require(b.rows.isEmpty && !b.ui.empty.isHidden, "Deep empty folder retained old files")
  }
  for _ in 0..<levels {
    target = target.deletingLastPathComponent()
    b.step("back")
    try spin(until: { !b.loading && b.location == target.path }, "back navigation")
  }
  try paint(b)
  try require(
    b.selected.map(\.path) == paths && b.ui.scroll.contentView.bounds.origin.y == y,
    "Selection or scroll drift after back on cycle \(index)")

  // Exercise the actual directory watcher with a create, rename and removal.
  // Both paths lie inside the runner's generated, initially empty namespace.
  let draft = directory.appendingPathComponent("soak-write-\(index).txt")
  let renamed = directory.appendingPathComponent("soak-renamed-\(index).txt")
  try require(
    !FileManager.default.fileExists(atPath: draft.path)
      && !FileManager.default.fileExists(atPath: renamed.path), "Soak fixture collided")
  func refreshed(after revision: Int, message: String, verify: () -> Bool) throws {
    var checked = revision
    try spin(
      until: {
        guard !b.loading, !b.scanning, b.revision > checked else { return false }
        checked = b.revision
        return verify()
      }, message)
  }
  let writer = DispatchTime.now().uptimeNanoseconds
  var revision = b.revision
  try Data("test cycle \(index)\n".utf8).write(to: draft, options: .withoutOverwriting)
  try refreshed(after: revision, message: "external create") {
    b.entries.count == size + 1 && b.entries.contains { $0.name == draft.lastPathComponent }
  }
  revision = b.revision
  try FileManager.default.moveItem(at: draft, to: renamed)
  try refreshed(after: revision, message: "external rename") {
    b.entries.contains { $0.name == renamed.lastPathComponent }
  }
  revision = b.revision
  try FileManager.default.removeItem(at: renamed)
  try refreshed(after: revision, message: "external removal") {
    b.entries.count == size && !b.entries.contains { $0.name == renamed.lastPathComponent }
  }
  try paint(b)
  let refreshMs = ms(writer)
  try require(
    b.selected.map(\.path) == paths && b.ui.scroll.contentView.bounds.origin.y == y,
    "Passive refresh moved selection or scroll on cycle \(index)")
  let visible = b.ui.table.rows(in: b.ui.table.visibleRect)
  let first = b.ui.table.rowView(atRow: visible.location, makeIfNecessary: false)
  try require(
    first?.identifier?.rawValue == "BrowserFileRow", "Visible file row lacks its reuse identifier")
  try require(
    !b.ui.root.subviews.contains { $0 is NSImageView },
    "A completed entry transition still covers the file list")
  return SoakCycle(open: openMs, search: searchMs, refresh: refreshMs)
}

func runSoak(_ b: Browser, directory: URL, count: Int, minutes: Double, log: URL) throws {
  let out = try SoakLog(log)
  try out.emit(
    "start",
    [
      "plannedMinutes": minutes, "entries": count, "pid": getpid(),
      "sourceSHA256": ProcessInfo.processInfo.environment["FINGER_GUI_BENCH_SOURCE_ID"]
        ?? "unknown",
    ], echo: true)
  var cycles = 0
  var warm: [ProcessSample] = []
  var batch: [SoakCycle] = []
  var baseline: (rss: Double, heap: Double, fds: Double)?
  var driftCount = 0
  var longCount = 0
  var nextSummary = 300.0
  var peakRSS = 0.0
  var peakFDs = 0
  do {
    while out.seconds < minutes * 60 {
      cycles += 1
      let start = out.seconds
      let sample = try autoreleasepool {
        try cycle(b, directory: directory, size: count, index: cycles)
      }
      let usage = try ProcessSample()
      peakRSS = max(peakRSS, usage.rss)
      peakFDs = max(peakFDs, usage.fds)
      batch.append(sample)
      if baseline == nil {
        warm.append(usage)
        if warm.count == 12 {
          baseline = (
            percentile(warm.map(\.rss), 0.5), percentile(warm.map(\.heapInUse), 0.5),
            percentile(warm.map { Double($0.fds) }, 0.5)
          )
          try out.emit(
            "warmup",
            [
              "cycles": cycles, "baselineRSSMiB": baseline!.rss,
              "baselineHeapMiB": baseline!.heap, "baselineFDs": baseline!.fds,
            ], echo: true)
        }
      } else if let baseline {
        let drifting =
          usage.fds > Int(baseline.fds) + 48 || usage.rss > baseline.rss + 192
          || usage.heapInUse > baseline.heap + 128
        driftCount = drifting ? driftCount + 1 : 0
        try require(
          driftCount < 12, "Memory or descriptor growth persisted across twelve consecutive cycles")
        longCount = (sample.open > 2000 || sample.search > 1000) ? longCount + 1 : 0
        try require(
          longCount < 4, "UI latency exceeded the endurance limit across four consecutive cycles")
      }
      try out.emit(
        "sample",
        [
          "cycle": cycles, "openMs": sample.open, "searchMs": sample.search,
          "watchThreeChangesMs": sample.refresh, "rssMiB": usage.rss, "fds": usage.fds,
          "footprintMiB": usage.footprint, "heapInUseMiB": usage.heapInUse,
          "liveBlocks": usage.liveBlocks,
        ])
      if out.seconds >= nextSummary || cycles == 1 {
        try out.emit(
          "phase",
          [
            "cycles": cycles, "openP50Ms": percentile(batch.map(\.open), 0.5),
            "openP95Ms": percentile(batch.map(\.open), 0.95),
            "searchP50Ms": percentile(batch.map(\.search), 0.5),
            "searchP95Ms": percentile(batch.map(\.search), 0.95), "rssMiB": usage.rss,
            "footprintMiB": usage.footprint, "heapInUseMiB": usage.heapInUse,
            "peakRSSMiB": peakRSS, "fds": usage.fds, "peakFDs": peakFDs,
          ], echo: true)
        batch.removeAll(keepingCapacity: true)
        if cycles > 1 { nextSummary += 300 }
      }
      let period = Double(8 + (cycles * 3) % 7)
      let seconds = min(minutes * 60 - out.seconds, period - (out.seconds - start))
      if seconds > 0 {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: end) } }
      }
    }
    try out.emit(
      "complete", ["cycles": cycles, "peakRSSMiB": peakRSS, "peakFDs": peakFDs], echo: true)
  } catch {
    try out.emit("failure", ["cycle": cycles, "message": error.localizedDescription], echo: true)
    throw error
  }
}

/// Identify changes in live allocations separately from allocator high-water
/// capacity, and count old AppKit views through weak references.
func runMemoryProbe(_ b: Browser, directory: URL, count: Int, cycles: Int, mode: String, log: URL)
  throws
{
  let out = try SoakLog(log)
  let observed = NSHashTable<NSView>.weakObjects()
  benchmarkViewObserver = { browser in for view in tree(browser.ui.root) { observed.add(view) } }
  defer { benchmarkViewObserver = nil }
  try out.emit("probeStart", ["mode": mode, "cycles": cycles, "pid": getpid()], echo: true)
  for i in 1...cycles {
    _ = try autoreleasepool { try cycle(b, directory: directory, size: count, index: i) }
    let drain = {
      let end = Date(timeIntervalSinceNow: 0.35)
      while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
    }
    if mode == "drained" { autoreleasepool(invoking: drain) } else { drain() }
    if i == 1 || i.isMultiple(of: 5) || i == cycles {
      try autoreleasepool {
        let usage = try ProcessSample()
        let views = tree(b.ui.root)
        let attached = Set(views.map(ObjectIdentifier.init))
        let removed = observed.allObjects.filter { !attached.contains(ObjectIdentifier($0)) }
        let classes = Dictionary(grouping: removed) { String(describing: type(of: $0)) }.mapValues(
          \.count)
        try out.emit(
          "probe",
          [
            "mode": mode, "cycle": i, "rssMiB": usage.rss, "fds": usage.fds,
            "footprintMiB": usage.footprint, "graphicsMiB": usage.graphics,
            "heapInUseMiB": usage.heapInUse, "heapReservedMiB": usage.heapReserved,
            "liveBlocks": usage.liveBlocks, "attachedViews": views.count,
            "detachedViews": removed.count,
            "detachedClasses": classes,
            "transitionOverlays": b.ui.root.subviews.filter { $0 is NSImageView }.count,
          ],
          echo: i == cycles)
      }
    }
  }
}
