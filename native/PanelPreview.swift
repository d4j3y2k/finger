import AppKit

/// The right-hand side of the panel for a file.
///
/// `show` runs on the main thread each time the selected file changes, and
/// with nil when nothing is selected or a folder is selected (the panel shows
/// its own folder peek then). `match` is the query when the file was found by
/// its contents ("Inside Files"), and nil otherwise.
protocol PanelPreview: AnyObject {
  var view: NSView { get }
  func show(_ url: URL?, match: String?)
}

/// The file's own content: code, Markdown, text, PDF pages, images, sheets
/// and archives, with a content match highlighted.
extension ContentPreview: PanelPreview {
  var view: NSView { self }
}

/// What a folder holds, shown when the folder is selected, with the item you
/// would land on tinted. Clicking an item goes in with that item selected.
/// The header is ContentPreview's, so a folder and a file read as one design.
final class PanelFolderPeek: NSView {
  struct Content {
    var folder: PanelFile
    var title: String
    var subtitle: String
    /// Nil while the folder is still being read.
    var items: [PanelFile]?
    var total: Int
    var landing: String?
  }
  override var isFlipped: Bool { true }
  let header = ContentHeader()
  var content: Content? {
    didSet {
      if let content {
        header.show(
          name: content.title, detail: content.subtitle,
          icon: PanelIcons.shared.icon(content.folder.path))
        header.toolTip = content.folder.path
      }
      header.isHidden = content == nil
      needsDisplay = true
    }
  }
  /// The right-hand text of an item: a size or an item count.
  var side: (PanelFile) -> String = { _ in "" }
  var onPick: ((String) -> Void)?
  private var rowRects: [(NSRect, String)] = []
  private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var tracking: NSTrackingArea?
  static let rows = 8
  static let rowHeight: CGFloat = 28

  override init(frame: NSRect) {
    super.init(frame: frame)
    // The search field keeps the keyboard; the folder's name is not for selecting.
    header.name.isSelectable = false
    header.isHidden = true
    addSubview(header)
  }
  required init?(coder: NSCoder) { fatalError() }

  /// The same side margin as ContentPreview at this width.
  private var margin: CGFloat { ContentMetrics(roomy: bounds.width >= 520).side }

  /// Where the first item row starts, below the header.
  var firstRowY: CGFloat { header.height + 7 }

  override func layout() {
    super.layout()
    header.side = margin
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    rowRects = []
    guard let content, let items = content.items else { return }
    let b = bounds
    let inset = margin
    // Rows line up with the header: icons under its icon, a little inset for the tint.
    let left = inset - 7
    let right = b.width - inset + 7
    if items.isEmpty {
      PanelDraw.line(
        PanelDraw.text("Empty folder", .systemFont(ofSize: 12), .tertiaryLabelColor, align: .center),
        in: NSRect(x: 0, y: firstRowY + 10, width: b.width, height: 18))
      return
    }
    var y = firstRowY
    let h = PanelFolderPeek.rowHeight
    for item in items.prefix(PanelFolderPeek.rows) {
      let r = NSRect(x: left, y: y, width: right - left, height: h)
      if item.path == content.landing {
        PanelInk.tint.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
      } else if item.path == hovered {
        PanelInk.hover.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
      }
      PanelDraw.icon(
        PanelIcons.shared.icon(item.path), in: NSRect(x: inset - 1, y: y + 5, width: 18, height: 18),
        flipped: true)
      let sideText = PanelDraw.text(
        side(item), .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor)
      let sideWidth = min(110, PanelDraw.width(sideText))
      PanelDraw.line(sideText, in: NSRect(x: right - 7 - sideWidth, y: y, width: sideWidth, height: h))
      let nameX = inset + 25
      PanelDraw.line(
        PanelDraw.text(item.name, .systemFont(ofSize: 12), .labelColor),
        in: NSRect(x: nameX, y: y, width: right - 7 - sideWidth - 12 - nameX, height: h))
      rowRects.append((r, item.path))
      y += h
    }
    if content.total > PanelFolderPeek.rows {
      PanelDraw.line(
        PanelDraw.text(
          "and \(content.total - PanelFolderPeek.rows) more", .systemFont(ofSize: 12),
          .tertiaryLabelColor),
        in: NSRect(x: inset + 25, y: y + 6, width: right - inset - 32, height: 16))
    }
  }

  private func path(at event: NSEvent) -> String? {
    let p = convert(event.locationInWindow, from: nil)
    return rowRects.first { $0.0.contains(p) }?.1
  }
  override func mouseDown(with event: NSEvent) {
    if let path = path(at: event) { onPick?(path) }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseMoved(with event: NSEvent) { hovered = path(at: event) }
  override func mouseExited(with event: NSEvent) { hovered = nil }
}
