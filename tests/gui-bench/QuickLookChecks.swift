import AppKit
import Quartz

private final class ObservedPreview: QLPreviewView {
  var assignments = 0
  var refreshes = 0
  override var previewItem: QLPreviewItem! {
    get { super.previewItem }
    set {
      assignments += 1
      super.previewItem = newValue
    }
  }
  override func refreshPreviewItem() {
    refreshes += 1
    super.refreshPreviewItem()
  }
}

func checkQuickLookRefresh(_ b: Browser, demo: URL) throws {
  let fm = FileManager.default
  let dir = demo.deletingLastPathComponent().appendingPathComponent(
    "QuickLook-" + UUID().uuidString)
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  let png = dir.appendingPathComponent("Overlap 01.png")
  let svg = dir.appendingPathComponent("Overlap 01.svg")
  for file in [png, svg] {
    try fm.copyItem(at: demo.appendingPathComponent("exports/" + file.lastPathComponent), to: file)
  }
  b.visit(dir.path)
  try spin(until: { !b.scanning && b.entries.count == 2 }, "the two Quick Look sources")
  b.ui.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
  let panel = NSPanel(
    contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
  guard let view = ObservedPreview(frame: panel.contentView!.bounds, style: .normal) else {
    throw CheckFailure("Quick Look preview is unavailable")
  }
  panel.alphaValue = 0
  panel.contentView = view
  panel.orderBack(nil)
  b.previewPanel = panel
  b.panelView = view
  defer {
    b.displayQuickLook(at: nil)
    panel.orderOut(nil)
    b.previewPanel = nil
    b.panelView = nil
    b.setFileOrder(.nameAsc)
  }
  func showing(_ url: URL) -> Bool {
    panel.title == url.lastPathComponent && (view.previewItem as? NSURL)?.path == url.path
  }
  b.displayQuickLook(at: b.ui.table.selectedRowIndexes.first)
  b.stepQuickLook(1)
  try require(showing(svg), "Could not page from the PNG to the SVG")
  let assignments = view.assignments
  let refreshes = view.refreshes
  let inserted = dir.appendingPathComponent("A new file.txt")
  try Data("Earlier row".utf8).write(to: inserted)
  try spin(until: { b.entries.count == 3 && !b.scanning }, "watcher insertion above the selection")
  try require(showing(svg) && b.quickLookRow == 2, "Quick Look followed the old row at insertion")
  b.setFileOrder(.nameDesc)
  try spin(
    until: { b.entries.first?.path == svg.path && !b.scanning }, "descending Quick Look group")
  try require(showing(svg) && b.quickLookRow == 0, "Sorting switched the current Quick Look file")
  try fm.removeItem(at: inserted)
  try spin(until: { b.entries.count == 2 && !b.scanning }, "unrelated removal")
  try require(
    showing(svg) && Set(b.selected.map(\.path)) == [svg.path, png.path]
      && view.assignments == assignments && view.refreshes == refreshes,
    "Unrelated directory changes reloaded the preview or disturbed its selection")
  b.stepQuickLook(1)
  try require(showing(png), "Paging did not adopt the selected group's new order")
  b.stepQuickLook(-1)
  try require(showing(svg), "Could not return to the SVG in the selected group")
  try fm.removeItem(at: svg)
  try spin(until: { b.entries.count == 1 && !b.scanning }, "removal of the previewed member")
  try require(
    showing(png) && b.selected.map(\.path) == [png.path], "Surviving member was not previewed")
  try fm.removeItem(at: png)
  try spin(until: { b.entries.isEmpty && !b.scanning }, "an empty Quick Look group")
  try require(
    view.previewItem == nil && b.quickLookRow == nil, "Quick Look retained a deleted file")
  print(
    "Quick Look kept its SVG, selection and loaded preview through insertion, sort and unrelated removal; deletion fell back to the surviving PNG."
  )
}
