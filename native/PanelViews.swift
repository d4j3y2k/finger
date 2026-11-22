import AppKit

extension NSAppearance {
  var panelDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// System colors for the panel. The old window's palette (Style.swift) is not used here.
enum PanelInk {
  static let chip = NSColor(name: "panel.chip") {
    $0.panelDark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.075)
  }
  static let hover = NSColor(name: "panel.hover") {
    $0.panelDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
  }
  static let tint = NSColor(name: "panel.tint") {
    NSColor.controlAccentColor.withAlphaComponent($0.panelDark ? 0.26 : 0.16)
  }
  static let onAccent = NSColor.white
  static let onAccentQuiet = NSColor(white: 1, alpha: 0.78)
}

enum PanelDraw {
  static func text(
    _ string: String, _ font: NSFont, _ color: NSColor, align: NSTextAlignment = .left
  ) -> NSMutableAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = align
    return NSMutableAttributedString(
      string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
  }

  static func width(_ s: NSAttributedString) -> CGFloat { ceil(s.size().width) }

  /// One line, truncated at the tail, vertically centered in `rect`.
  static func line(_ s: NSAttributedString, in rect: NSRect) {
    let height = ceil(s.size().height)
    let box = NSRect(
      x: rect.minX, y: rect.minY + ((rect.height - height) / 2).rounded(), width: rect.width,
      height: height)
    s.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
  }

  /// Draws a template image in `color`, resolved for the current appearance.
  /// The glyph takes the opaque color and the color's alpha applies on top, so
  /// a translucent label color reads the same as text in that color.
  static func symbol(_ image: NSImage, in rect: NSRect, color: NSColor) {
    let resolved = color.usingColorSpace(.sRGB) ?? color
    let opaque = resolved.withAlphaComponent(1)
    let tinted = NSImage(size: image.size, flipped: false) { box in
      image.draw(in: box)
      opaque.set()
      box.fill(using: .sourceIn)
      return true
    }
    tinted.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent,
      respectFlipped: true, hints: nil)
  }

  static let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

  static func icon(_ image: NSImage?, in rect: NSRect, flipped: Bool) {
    image?.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
  }
}

/// NSWorkspace icons, cached by path.
final class PanelIcons {
  static let shared = PanelIcons()
  private let cache = NSCache<NSString, NSImage>()
  init() { cache.countLimit = 600 }

  func icon(_ path: String) -> NSImage {
    if let hit = cache.object(forKey: path as NSString) { return hit }
    let image = NSWorkspace.shared.icon(forFile: path)
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

// MARK: - Results list

/// A two-line result: icon, name with the typed part in bold, a subtitle, and
/// on the right a time or count and, for folders, a chevron.
final class PanelItemCell: NSView {
  static let identifier = NSUserInterfaceItemIdentifier("panel.item")
  static let height: CGFloat = 40
  static let iconX: CGFloat = 18
  override var isFlipped: Bool { true }

  var icon: NSImage?
  var name = ""
  var highlight: NSRange?
  var subtitle = ""
  var side = ""
  var folder = false
  var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
  var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
  /// Hidden while a flying copy of the icon and name lands here.
  var concealed = false { didSet { if concealed != oldValue { needsDisplay = true } } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    identifier = PanelItemCell.identifier
  }
  required init?(coder: NSCoder) { fatalError() }

  /// The icon's frame, for motion.
  var iconFrame: NSRect {
    NSRect(x: PanelItemCell.iconX, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20)
  }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let pill = NSRect(x: 8, y: 0, width: b.width - 16, height: b.height)
    if chosen {
      NSColor.controlAccentColor.setFill()
      NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
    } else if hovered {
      PanelInk.hover.setFill()
      NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
    }
    let primary: NSColor = chosen ? PanelInk.onAccent : .labelColor
    let quiet: NSColor = chosen ? PanelInk.onAccentQuiet : .secondaryLabelColor
    let right = pill.maxX - 7
    if folder, let chevron = PanelDraw.chevron {
      let size = chevron.size
      let rect = NSRect(
        x: right - 8 + (8 - size.width) / 2, y: ((b.height - size.height) / 2).rounded(),
        width: size.width, height: size.height)
      PanelDraw.symbol(chevron, in: rect, color: chosen ? PanelInk.onAccentQuiet : .tertiaryLabelColor)
    }
    let textRight = right - 8 - 9
    let sideText = PanelDraw.text(side, .monospacedDigitSystemFont(ofSize: 11, weight: .regular), quiet)
    let sideWidth = side.isEmpty ? 0 : min(PanelDraw.width(sideText), 150)
    if sideWidth > 0 {
      PanelDraw.line(
        sideText, in: NSRect(x: textRight - sideWidth, y: 0, width: sideWidth, height: b.height))
    }
    let textX = PanelItemCell.iconX + 22 + 8
    let textWidth = max(0, textRight - (sideWidth > 0 ? sideWidth + 10 : 0) - textX)
    if !concealed {
      PanelDraw.icon(icon, in: iconFrame, flipped: true)
      let title = PanelDraw.text(name, .systemFont(ofSize: 13), primary)
      if let highlight, NSMaxRange(highlight) <= (name as NSString).length {
        title.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: highlight)
      }
      PanelDraw.line(title, in: NSRect(x: textX, y: 4, width: textWidth, height: 17))
    }
    PanelDraw.line(
      PanelDraw.text(subtitle, .systemFont(ofSize: 11), quiet),
      in: NSRect(x: textX, y: 20, width: textWidth, height: 15))
  }
}

final class PanelHeaderCell: NSView {
  static let identifier = NSUserInterfaceItemIdentifier("panel.header")
  static let height: CGFloat = 26
  override var isFlipped: Bool { true }
  var title = ""
  var aside = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    identifier = PanelHeaderCell.identifier
  }
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let line = NSRect(x: 18, y: b.height - 17, width: b.width - 36, height: 14)
    let asideText = PanelDraw.text(aside, .systemFont(ofSize: 11), .tertiaryLabelColor, align: .right)
    let asideWidth = aside.isEmpty ? 0 : PanelDraw.width(asideText)
    if asideWidth > 0 {
      PanelDraw.line(
        asideText, in: NSRect(x: line.maxX - asideWidth, y: line.minY, width: asideWidth, height: 14))
    }
    PanelDraw.line(
      PanelDraw.text(title, .systemFont(ofSize: 11, weight: .semibold), .secondaryLabelColor),
      in: NSRect(
        x: line.minX, y: line.minY, width: line.width - asideWidth - 8, height: line.height))
  }
}

final class PanelRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawBackground(in dirtyRect: NSRect) {}
}

/// The results table. It never takes focus from the search field and leaves
/// selection to the panel controller.
final class PanelTable: NSTableView {
  var onClick: ((_ row: Int, _ clicks: Int, _ point: NSPoint) -> Void)?
  var onHover: ((Int) -> Void)?
  private var tracking: NSTrackingArea?

  override var acceptsFirstResponder: Bool { false }
  override func menu(for event: NSEvent) -> NSMenu? { nil }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    onClick?(row(at: point), event.clickCount, point)
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
  override func mouseMoved(with event: NSEvent) {
    onHover?(row(at: convert(event.locationInWindow, from: nil)))
  }
  override func mouseExited(with event: NSEvent) { onHover?(-1) }
}

// MARK: - Search row

/// The folders you are in, one chip per level, inside the search field.
final class PanelChipsView: NSView {
  struct Chip {
    let path: String?
    let title: String
    let icon: NSImage?
  }
  override var isFlipped: Bool { true }
  var chips: [Chip] = [] { didSet { measure() } }
  var maxWidth: CGFloat = 400 { didSet { if maxWidth != oldValue { measure() } } }
  var hiddenPath: String? { didSet { needsDisplay = true } }
  var onClick: ((String) -> Void)?
  private(set) var rects: [NSRect] = []
  private(set) var contentWidth: CGFloat = 0
  private var titleWidths: [CGFloat] = []
  private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var tracking: NSTrackingArea?

  static let height: CGFloat = 24
  static let font = NSFont.systemFont(ofSize: 13)
  private static let separatorFont = NSFont.systemFont(ofSize: 15)

  func rect(for path: String) -> NSRect? {
    guard let i = chips.firstIndex(where: { $0.path == path }), i < rects.count else { return nil }
    return rects[i]
  }

  /// A chip's size and look, shared with the flying copy.
  static func chipWidth(title: String, limit: CGFloat = 136) -> CGFloat {
    let w = min(limit, PanelDraw.width(PanelDraw.text(title, font, .labelColor)))
    return 5 + 16 + 5 + w + 8
  }

  private func measure() {
    let separator = PanelDraw.width(PanelDraw.text("›", PanelChipsView.separatorFont, .labelColor))
    let gaps = CGFloat(max(0, chips.count - 1)) * (separator + 10)
    let fixed = chips.reduce(CGFloat(0)) { $0 + ($1.path == nil ? 14 : 34) } + gaps
    let real = max(1, chips.filter { $0.path != nil }.count)
    let limit = max(36, min(136, (maxWidth - fixed) / CGFloat(real)))
    var x: CGFloat = 0
    var out: [NSRect] = []
    titleWidths = []
    for chip in chips {
      if !out.isEmpty { x += 5 + separator + 5 }
      let natural = PanelDraw.width(PanelDraw.text(chip.title, PanelChipsView.font, .labelColor))
      let w = chip.path == nil ? 14 : 5 + 16 + 5 + min(limit, natural) + 8
      titleWidths.append(chip.path == nil ? natural : min(limit, natural))
      out.append(NSRect(x: x, y: 0, width: w, height: PanelChipsView.height))
      x += w
    }
    rects = out
    contentWidth = x
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let sep = PanelDraw.text("›", PanelChipsView.separatorFont, .tertiaryLabelColor)
    let sepWidth = PanelDraw.width(sep)
    for (i, chip) in chips.enumerated() where i < rects.count {
      let r = rects[i]
      if i > 0 {
        PanelDraw.line(sep, in: NSRect(x: r.minX - 5 - sepWidth, y: r.minY, width: sepWidth, height: r.height))
      }
      guard let path = chip.path else {
        PanelDraw.line(PanelDraw.text("…", PanelChipsView.font, .tertiaryLabelColor), in: r)
        continue
      }
      if path == hiddenPath { continue }
      let current = i == chips.count - 1 || hovered == i
      PanelChipsView.drawChip(
        in: r, icon: chip.icon, title: chip.title, titleWidth: titleWidths[i], fill: PanelInk.chip,
        text: current ? .labelColor : .secondaryLabelColor, flipped: true)
    }
  }

  static func drawChip(
    in r: NSRect, icon: NSImage?, title: String, titleWidth: CGFloat, fill: NSColor, text: NSColor,
    flipped: Bool
  ) {
    fill.setFill()
    NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
    PanelDraw.icon(
      icon, in: NSRect(x: r.minX + 5, y: r.minY + (r.height - 16) / 2, width: 16, height: 16),
      flipped: flipped)
    PanelDraw.line(
      PanelDraw.text(title, font, text),
      in: NSRect(x: r.minX + 26, y: r.minY, width: titleWidth + 1, height: r.height))
  }

  private func index(at event: NSEvent) -> Int? {
    let p = convert(event.locationInWindow, from: nil)
    return rects.firstIndex { $0.contains(p) }.flatMap { chips[$0].path == nil ? nil : $0 }
  }
  override func mouseDown(with event: NSEvent) {
    if let i = index(at: event), let path = chips[i].path { onClick?(path) }
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
  override func mouseMoved(with event: NSEvent) { hovered = index(at: event) }
  override func mouseExited(with event: NSEvent) { hovered = nil }
}

/// The 21pt search field.
final class PanelField: NSTextField {
  static let textFont = NSFont.systemFont(ofSize: 21)

  init() {
    super.init(frame: .zero)
    isBordered = false
    isBezeled = false
    drawsBackground = false
    focusRingType = .none
    font = PanelField.textFont
    textColor = .labelColor
    usesSingleLineMode = true
    lineBreakMode = .byClipping
    cell?.isScrollable = true
    cell?.wraps = false
    isEditable = true
    isSelectable = true
    setAccessibilityLabel("Search files")
  }
  required init?(coder: NSCoder) { fatalError() }

  var placeholder: String = "" {
    didSet {
      placeholderAttributedString = NSAttributedString(
        string: placeholder,
        attributes: [.font: PanelField.textFont, .foregroundColor: NSColor.tertiaryLabelColor])
    }
  }
}

/// The gray rest of a name after the caret.
final class PanelGhost: NSTextField {
  init() {
    super.init(frame: .zero)
    isBordered = false
    isBezeled = false
    drawsBackground = false
    isEditable = false
    isSelectable = false
    font = PanelField.textFont
    textColor = .tertiaryLabelColor
    lineBreakMode = .byClipping
    usesSingleLineMode = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Footer

enum PanelAction {
  case activate, reveal, quickLook, intoFolder, up
}

struct PanelHint: Equatable {
  let keys: String
  let label: String
  let action: PanelAction
}

/// Status on the left; clickable key hints on the right that follow the selection.
final class PanelFooter: NSView {
  override var isFlipped: Bool { true }
  var status = "" { didSet { if status != oldValue { needsDisplay = true } } }
  var hints: [PanelHint] = [] { didSet { if hints != oldValue { needsDisplay = true } } }
  var onHint: ((PanelAction) -> Void)?
  private(set) var hintRects: [NSRect] = []
  private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var tracking: NSTrackingArea?
  private static let font = NSFont.systemFont(ofSize: 11.5)
  private static let keyFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

  private func measure() -> [NSRect] {
    var x = bounds.width - 10
    var out: [NSRect] = []
    for hint in hints.reversed() {
      let w =
        6 + PanelDraw.width(PanelDraw.text(hint.keys, PanelFooter.keyFont, .labelColor)) + 5
        + PanelDraw.width(PanelDraw.text(hint.label, PanelFooter.font, .labelColor)) + 6
      x -= w
      out.insert(NSRect(x: x, y: (bounds.height - 22) / 2, width: w, height: 22), at: 0)
      x -= 2
    }
    return out
  }

  override func draw(_ dirtyRect: NSRect) {
    hintRects = measure()
    for (i, hint) in hints.enumerated() {
      let r = hintRects[i]
      if hovered == i {
        PanelInk.hover.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
      }
      let keys = PanelDraw.text(hint.keys, PanelFooter.keyFont, .labelColor)
      let kw = PanelDraw.width(keys)
      PanelDraw.line(keys, in: NSRect(x: r.minX + 6, y: r.minY, width: kw, height: r.height))
      PanelDraw.line(
        PanelDraw.text(hint.label, PanelFooter.font, hovered == i ? .labelColor : .secondaryLabelColor),
        in: NSRect(x: r.minX + 6 + kw + 5, y: r.minY, width: r.maxX - 6 - (r.minX + 11 + kw), height: r.height))
    }
    let left: CGFloat = 16
    let limit = (hintRects.first?.minX ?? bounds.width) - 12
    PanelDraw.line(
      PanelDraw.text(status, PanelFooter.font, .secondaryLabelColor),
      in: NSRect(x: left, y: 0, width: max(0, limit - left), height: bounds.height))
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let i = hintRects.firstIndex(where: { $0.contains(p) }), i < hints.count {
      onHint?(hints[i].action)
    }
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
  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    hovered = hintRects.firstIndex { $0.contains(p) }
  }
  override func mouseExited(with event: NSEvent) { hovered = nil }
}

// MARK: - Motion

/// A copy of a folder's icon and name that glides between its row and its
/// chip, turning from the blue selection into the gray chip on the way.
final class PanelFlyer: NSView {
  let selectedFace: PanelChipFace
  let chipFace: PanelChipFace

  init(icon: NSImage?, title: String, selected: Bool) {
    let width = PanelChipsView.chipWidth(title: title)
    let frame = NSRect(x: 0, y: 0, width: width, height: PanelChipsView.height)
    selectedFace = PanelChipFace(frame: frame, icon: icon, title: title, chip: false)
    chipFace = PanelChipFace(frame: frame, icon: icon, title: title, chip: true)
    super.init(frame: frame)
    wantsLayer = true
    layer?.shadowOpacity = 0.18
    layer?.shadowRadius = 9
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    addSubview(selectedFace)
    addSubview(chipFace)
    selectedFace.alphaValue = selected ? 1 : 0
    chipFace.alphaValue = selected ? 0 : 1
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PanelChipFace: NSView {
  private let icon: NSImage?
  private let title: String
  private let chip: Bool
  override var isFlipped: Bool { true }

  init(frame: NSRect, icon: NSImage?, title: String, chip: Bool) {
    self.icon = icon
    self.title = title
    self.chip = chip
    super.init(frame: frame)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let titleWidth = bounds.width - 34
    let fill: NSColor
    if chip {
      // An opaque chip color, so the gray reads over the rows it crosses.
      fill = effectiveAppearance.panelDark ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.89, alpha: 1)
    } else {
      fill = .controlAccentColor
    }
    PanelChipsView.drawChip(
      in: bounds, icon: icon, title: title, titleWidth: titleWidth, fill: fill,
      text: chip ? .labelColor : .white, flipped: true)
  }
}

/// Holds the panel's parts and draws the hairlines between them.
final class PanelRootView: NSView {
  static let searchHeight: CGFloat = 56
  static let footerHeight: CGFloat = 32
  var listWidth: CGFloat = 426 { didSet { needsDisplay = true } }
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
    NSColor.separatorColor.setFill()
    let top = b.height - PanelRootView.searchHeight
    NSRect(x: 0, y: top - hairline, width: b.width, height: hairline).fill()
    NSRect(x: 0, y: PanelRootView.footerHeight, width: b.width, height: hairline).fill()
    NSRect(
      x: listWidth, y: PanelRootView.footerHeight, width: hairline,
      height: top - PanelRootView.footerHeight
    ).fill()
  }
}
