import AppKit

/// The right-hand side of the panel for a file. A richer content preview
/// plugs in here later; `PanelInfoPreview` is the stand-in.
///
/// `show` runs on the main thread each time the selected file changes, and
/// with nil when nothing is selected or a folder is selected (the panel shows
/// its own folder peek then). `match` is the query when the file was found by
/// its contents rather than its name.
protocol PanelPreview: AnyObject {
  var view: NSView { get }
  func show(_ url: URL?, match: String?)
}

/// Placeholder preview: a large icon, the name, kind, size and modified date.
final class PanelInfoPreview: PanelPreview {
  private let info: PanelInfoView
  init(home: String = NSHomeDirectory()) { info = PanelInfoView(place: PanelPlace(home: home)) }
  var view: NSView { info }
  func show(_ url: URL?, match: String?) { info.show(url, match: match) }
}

final class PanelInfoView: NSView {
  override var isFlipped: Bool { true }
  private let iconView = NSImageView()
  private let title = NSTextField(wrappingLabelWithString: "")
  private let subtitle = NSTextField(labelWithString: "")
  private let found = NSTextField(wrappingLabelWithString: "")
  private let empty = NSTextField(labelWithString: "No Selection")
  private var facts: [(NSTextField, NSTextField)] = []
  private var shown: URL?
  private var generation = 0
  private static let work = DispatchQueue(label: "finger.panel.info", qos: .userInitiated)
  private let place: PanelPlace

  init(place: PanelPlace) {
    self.place = place
    super.init(frame: .zero)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.alignment = .center
    title.maximumNumberOfLines = 2
    title.lineBreakMode = .byTruncatingMiddle
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    subtitle.alignment = .center
    subtitle.lineBreakMode = .byTruncatingTail
    found.font = .systemFont(ofSize: 12)
    found.textColor = .secondaryLabelColor
    found.alignment = .center
    found.maximumNumberOfLines = 2
    empty.font = .systemFont(ofSize: 15)
    empty.textColor = .tertiaryLabelColor
    empty.alignment = .center
    for label in ["Kind", "Size", "Modified", "Where"] {
      let key = NSTextField(labelWithString: label)
      key.font = .systemFont(ofSize: 12)
      key.textColor = .secondaryLabelColor
      key.alignment = .right
      let value = NSTextField(labelWithString: "")
      value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      value.textColor = .labelColor
      value.lineBreakMode = .byTruncatingMiddle
      facts.append((key, value))
    }
    for view in [iconView, title, subtitle, found, empty] as [NSView] { addSubview(view) }
    for (key, value) in facts {
      addSubview(key)
      addSubview(value)
    }
    show(nil, match: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ url: URL?, match: String?) {
    let same = url == shown
    shown = url
    let hasItem = url != nil
    for view in [iconView, title, subtitle, found] as [NSView] { view.isHidden = !hasItem }
    for (key, value) in facts {
      key.isHidden = !hasItem
      value.isHidden = !hasItem
    }
    empty.isHidden = hasItem
    found.stringValue = match.map { "Found “\($0)” inside" } ?? ""
    found.isHidden = match == nil || !hasItem
    needsLayout = true
    guard let url, !same else { return }
    generation += 1
    let ticket = generation
    iconView.image = PanelIcons.shared.icon(url.path)
    title.stringValue = url.lastPathComponent
    subtitle.stringValue = ""
    for (_, value) in facts { value.stringValue = "" }
    PanelInfoView.work.async { [weak self] in
      let values = try? url.resourceValues(forKeys: [
        .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey,
      ])
      DispatchQueue.main.async {
        guard let self, ticket == self.generation else { return }
        self.apply(url, values)
      }
    }
  }

  private func apply(_ url: URL, _ values: URLResourceValues?) {
    let file = PanelFile(path: url.path, isFolder: false)
    var kind = values?.localizedTypeDescription ?? PanelText.kind(file)
    if let first = kind.first { kind = first.uppercased() + kind.dropFirst() }
    let size = PanelText.size(values?.fileSize.map(Int64.init))
    subtitle.stringValue = size.isEmpty ? kind : kind + " · " + size
    let modified = values?.contentModificationDate.map { PanelText.fullDate.string(from: $0) } ?? "—"
    let rows = [kind, size.isEmpty ? "—" : size, modified, place.whereText(url.path)]
    for (i, (_, value)) in facts.enumerated() { value.stringValue = rows[i] }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let b = bounds
    let inset: CGFloat = 20
    let width = b.width - inset * 2
    empty.frame = NSRect(x: inset, y: b.height / 2 - 12, width: width, height: 22)
    iconView.frame = NSRect(x: (b.width - 112) / 2, y: 26, width: 112, height: 112)
    title.preferredMaxLayoutWidth = width
    let titleHeight = min(40, ceil(title.sizeThatFits(NSSize(width: width, height: 60)).height))
    title.frame = NSRect(x: inset, y: 152, width: width, height: titleHeight)
    var y = title.frame.maxY + 2
    subtitle.frame = NSRect(x: inset, y: y, width: width, height: 16)
    y += 18
    if !found.isHidden {
      found.frame = NSRect(x: inset, y: y + 6, width: width, height: 16)
      y += 24
    }
    y += 14
    let keyWidth = (width * 0.36).rounded()
    for (key, value) in facts {
      key.frame = NSRect(x: inset, y: y, width: keyWidth, height: 16)
      value.frame = NSRect(x: inset + keyWidth + 10, y: y, width: width - keyWidth - 10, height: 16)
      y += 20
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard shown != nil, let first = facts.first?.0 else { return }
    NSColor.separatorColor.setFill()
    let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
    NSRect(x: 20, y: first.frame.minY - 10, width: bounds.width - 40, height: hairline).fill()
  }
}

/// What a folder holds, shown when the folder is selected, with the item you
/// would land on tinted. Clicking an item goes in with that item selected.
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
  var content: Content? { didSet { needsDisplay = true } }
  /// The right-hand text of an item: a size or an item count.
  var side: (PanelFile) -> String = { _ in "" }
  var onPick: ((String) -> Void)?
  private var rowRects: [(NSRect, String)] = []
  private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var tracking: NSTrackingArea?
  static let rows = 8

  override func draw(_ dirtyRect: NSRect) {
    rowRects = []
    guard let content else { return }
    let b = bounds
    PanelDraw.icon(
      PanelIcons.shared.icon(content.folder.path), in: NSRect(x: 2, y: 2, width: 52, height: 52),
      flipped: true)
    PanelDraw.line(
      PanelDraw.text(content.title, .systemFont(ofSize: 15, weight: .semibold), .labelColor),
      in: NSRect(x: 66, y: 8, width: b.width - 68, height: 20))
    PanelDraw.line(
      PanelDraw.text(content.subtitle, .systemFont(ofSize: 12), .secondaryLabelColor),
      in: NSRect(x: 66, y: 29, width: b.width - 68, height: 16))
    let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: 68, width: b.width, height: hairline).fill()
    guard let items = content.items else { return }
    if items.isEmpty {
      PanelDraw.line(
        PanelDraw.text("Empty folder", .systemFont(ofSize: 12), .tertiaryLabelColor, align: .center),
        in: NSRect(x: 0, y: 84, width: b.width, height: 18))
      return
    }
    var y: CGFloat = 75
    for item in items.prefix(PanelFolderPeek.rows) {
      let r = NSRect(x: 0, y: y, width: b.width, height: 28)
      if item.path == content.landing {
        PanelInk.tint.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
      } else if item.path == hovered {
        PanelInk.hover.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
      }
      PanelDraw.icon(
        PanelIcons.shared.icon(item.path), in: NSRect(x: 8, y: y + 5, width: 18, height: 18),
        flipped: true)
      let sideText = PanelDraw.text(
        side(item), .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor)
      let sideWidth = min(110, PanelDraw.width(sideText))
      PanelDraw.line(sideText, in: NSRect(x: r.maxX - 8 - sideWidth, y: y, width: sideWidth, height: 28))
      PanelDraw.line(
        PanelDraw.text(item.name, .systemFont(ofSize: 12), .labelColor),
        in: NSRect(x: 34, y: y, width: r.width - 34 - sideWidth - 18, height: 28))
      rowRects.append((r, item.path))
      y += 28
    }
    if content.total > PanelFolderPeek.rows {
      PanelDraw.line(
        PanelDraw.text(
          "and \(content.total - PanelFolderPeek.rows) more", .systemFont(ofSize: 12),
          .tertiaryLabelColor),
        in: NSRect(x: 8, y: y + 6, width: b.width - 16, height: 16))
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
