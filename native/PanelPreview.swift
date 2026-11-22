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
    /// Why this folder matters to what you are working on, with a blue dot.
    var why: String? = nil
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
  /// Items that get a blue dot after their name.
  var marked: (String) -> Bool = { _ in false }
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

  /// Where the first item row starts, below the header and the why line.
  var firstRowY: CGFloat {
    guard let why = whyText else { return header.height + 7 }
    return header.height + 10 + PanelFolderPeek.height(of: why, width: whyWidth) + 10
  }

  private static let whyFont = NSFont.systemFont(ofSize: 12)
  private var whyText: NSAttributedString? {
    guard let why = content?.why, !why.isEmpty else { return nil }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 2
    return NSAttributedString(
      string: why,
      attributes: [.font: PanelFolderPeek.whyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
  }
  private var whyWidth: CGFloat { max(40, bounds.width - margin * 2 - 13) }
  private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    ceil(text.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height)
  }

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
    if let why = whyText {
      let top = header.height + 10
      NSColor.controlAccentColor.setFill()
      NSBezierPath(ovalIn: NSRect(x: inset, y: top + 6, width: 5, height: 5)).fill()
      let height = PanelFolderPeek.height(of: why, width: whyWidth)
      why.draw(with: NSRect(x: inset + 13, y: top, width: whyWidth, height: height), options: [.usesLineFragmentOrigin])
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
      let dotted = marked(item.path)
      let nameText = PanelDraw.text(item.name, .systemFont(ofSize: 12), .labelColor)
      let nameRoom = right - 7 - sideWidth - 12 - nameX - (dotted ? 11 : 0)
      PanelDraw.line(nameText, in: NSRect(x: nameX, y: y, width: nameRoom, height: h))
      if dotted {
        NSColor.controlAccentColor.setFill()
        let x = nameX + min(PanelDraw.width(nameText), nameRoom) + 6
        NSBezierPath(ovalIn: NSRect(x: x, y: y + ((h - 5) / 2).rounded(), width: 5, height: 5)).fill()
      }
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
