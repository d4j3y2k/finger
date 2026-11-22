import AppKit

/// Filing's colors, on top of the panel's.
enum FilingInk {
  static let onAccentTint = NSColor(white: 1, alpha: 0.24)
  static let track = NSColor(name: "filing.track") {
    $0.panelDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09)
  }
  static let button = NSColor(name: "filing.button") {
    $0.panelDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)
  }
  static let barFill = NSColor(name: "filing.bar") {
    NSColor.controlAccentColor.withAlphaComponent($0.panelDark ? 0.24 : 0.12)
  }
  static let hud = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.88)
}

enum FilingDraw {
  static func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  }

  /// A 4pt probability bar.
  static func probability(_ p: Double, in rect: NSRect, track: NSColor, fill: NSColor) {
    track.setFill()
    rounded(rect, rect.height / 2).fill()
    let width = max(rect.height, (rect.width * CGFloat(min(1, max(0, p)))).rounded())
    fill.setFill()
    rounded(NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), rect.height / 2).fill()
  }

  static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

  static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)

  static func chipWidth(_ text: String) -> CGFloat {
    PanelDraw.width(PanelDraw.text(text, chipFont, .labelColor)) + 14
  }

  /// A rounded button with a label, filled with the accent color when primary.
  static func button(_ title: String, in rect: NSRect, primary: Bool, hovered: Bool) {
    let fill: NSColor = primary ? .controlAccentColor : FilingInk.button
    fill.setFill()
    rounded(rect, 6).fill()
    if hovered {
      NSColor(white: primary ? 1 : 0.5, alpha: primary ? 0.1 : 0.08).setFill()
      rounded(rect, 6).fill()
    }
    PanelDraw.line(
      PanelDraw.text(title, .systemFont(ofSize: 12), primary ? .white : .labelColor, align: .center),
      in: rect)
  }

  static func buttonWidth(_ title: String) -> CGFloat {
    PanelDraw.width(PanelDraw.text(title, .systemFont(ofSize: 12), .labelColor)) + 22
  }
}

// MARK: - Rows

extension PanelItemCell {
  /// Draws a filing chip ("⇥ invoices", "refs?") or Jev's probability at the
  /// right edge of the text, and returns the width it took with its gap.
  func drawFiling(right: CGFloat, height: CGFloat) -> CGFloat {
    if let p = probability {
      let pctWidth: CGFloat = 32
      let pct = PanelDraw.text(
        FilingDraw.percent(p), .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        chosen ? PanelInk.onAccentQuiet : .secondaryLabelColor, align: .right)
      PanelDraw.line(pct, in: NSRect(x: right - pctWidth, y: 0, width: pctWidth, height: height))
      let bar = NSRect(x: right - pctWidth - 8 - 56, y: ((height - 4) / 2).rounded(), width: 56, height: 4)
      FilingDraw.probability(
        p, in: bar, track: chosen ? FilingInk.onAccentTint : FilingInk.track,
        fill: chosen ? .white : .controlAccentColor)
      return pctWidth + 8 + 56 + 10
    }
    guard let chip = filingChip else { return 0 }
    let width = FilingDraw.chipWidth(chip.text)
    let rect = NSRect(x: right - width, y: ((height - 17) / 2).rounded(), width: width, height: 17)
    let fill: NSColor
    let ink: NSColor
    if chosen {
      fill = FilingInk.onAccentTint
      ink = .white
    } else if chip.confident {
      fill = PanelInk.tint
      ink = .controlAccentColor
    } else {
      fill = PanelInk.chip
      ink = .secondaryLabelColor
    }
    fill.setFill()
    FilingDraw.rounded(rect, rect.height / 2).fill()
    PanelDraw.line(PanelDraw.text(chip.text, FilingDraw.chipFont, ink, align: .center), in: rect)
    return width + 8
  }
}

extension PanelChipsView {
  static func pillWidth(_ text: String, limit: CGFloat) -> CGFloat {
    min(limit, PanelDraw.width(PanelDraw.text(text, font, .labelColor)) + 16)
  }

  /// "Move Invoice 1121.pdf to", in the accent color, where the path chips go.
  static func drawPill(_ text: String, in rect: NSRect) {
    PanelInk.tint.setFill()
    FilingDraw.rounded(rect, 6).fill()
    PanelDraw.line(
      PanelDraw.text(text, font, .controlAccentColor),
      in: NSRect(x: rect.minX + 8, y: rect.minY, width: rect.width - 16, height: rect.height))
  }
}

// MARK: - The Jev bar

/// Above a new download's preview: the folder Jev suggests, how sure it is,
/// Finger's own reason, and what to do.
final class FilingBar: NSView {
  struct Content: Equatable {
    var folder: String
    var name: String
    var parent: String
    var probability: Double
    var why: String?
    var tier: FilingTier
  }

  enum Button: Equatable { case other, file, choose }

  override var isFlipped: Bool { true }
  var content: Content? { didSet { if content != oldValue { needsDisplay = true } } }
  var onPress: ((Button) -> Void)?
  private(set) var buttonRects: [(Button, NSRect)] = []
  private var hovered: Button? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var tracking: NSTrackingArea?

  static let side: CGFloat = 14
  static let top: CGFloat = 10
  static let bottom: CGFloat = 10
  static let pad: CGFloat = 11
  private static let whyFont = NSFont.systemFont(ofSize: 12)

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }
  required init?(coder: NSCoder) { fatalError() }

  var buttons: [(Button, String, Bool)] {
    guard let content else { return [] }
    if content.tier == .confident {
      return [(.other, "Other…", false), (.file, "File to " + content.name, true)]
    }
    return [(.choose, "Choose Folder…", true)]
  }

  var label: String { "Suggested by Jev · " + (content?.tier.name ?? "") }

  private func whyText(width: CGFloat) -> (NSAttributedString, CGFloat)? {
    guard let why = content?.why, !why.isEmpty else { return nil }
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.12
    style.lineBreakMode = .byWordWrapping
    let text = NSAttributedString(
      string: why, attributes: [.font: FilingBar.whyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    let box = text.boundingRect(
      with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let line = ceil(FilingBar.whyFont.ascender - FilingBar.whyFont.descender + FilingBar.whyFont.leading) * 1.12
    return (text, min(ceil(box.height), ceil(line * 2) + 1))
  }

  /// The height this bar wants at `width`, margins included.
  func height(for width: CGFloat) -> CGFloat {
    let inner = width - FilingBar.side * 2 - FilingBar.pad * 2 - 2
    let why = whyText(width: inner).map { 6 + $0.1 } ?? 0
    return FilingBar.top + FilingBar.pad + 20 + why + 9 + 23 + FilingBar.pad - 1 + FilingBar.bottom
  }

  override func draw(_ dirtyRect: NSRect) {
    buttonRects = []
    guard let content else { return }
    let box = NSRect(
      x: FilingBar.side, y: FilingBar.top, width: bounds.width - FilingBar.side * 2,
      height: bounds.height - FilingBar.top - FilingBar.bottom)
    FilingInk.barFill.setFill()
    FilingDraw.rounded(box, 10).fill()
    let left = box.minX + FilingBar.pad + 1
    let right = box.maxX - FilingBar.pad - 1
    var y = box.minY + FilingBar.pad
    // Folder, name and parent, probability.
    PanelDraw.icon(PanelIcons.shared.icon(content.folder), in: NSRect(x: left, y: y + 1, width: 18, height: 18), flipped: true)
    let pctWidth: CGFloat = 34
    PanelDraw.line(
      PanelDraw.text(
        FilingDraw.percent(content.probability), .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        .secondaryLabelColor, align: .right),
      in: NSRect(x: right - pctWidth, y: y, width: pctWidth, height: 20))
    let barRect = NSRect(x: right - pctWidth - 8 - 64, y: y + 8, width: 64, height: 4)
    FilingDraw.probability(content.probability, in: barRect, track: FilingInk.track, fill: .controlAccentColor)
    let title = PanelDraw.text(content.name, .systemFont(ofSize: 13, weight: .semibold), .labelColor)
    title.append(PanelDraw.text("  " + content.parent, .systemFont(ofSize: 11.5), .secondaryLabelColor))
    let nameX = left + 26
    PanelDraw.line(title, in: NSRect(x: nameX, y: y, width: barRect.minX - 10 - nameX, height: 20))
    y += 20
    if let (why, height) = whyText(width: right - left) {
      y += 6
      why.draw(
        with: NSRect(x: left, y: y, width: right - left, height: height),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine, .usesFontLeading])
      y += height
    }
    y += 9
    // Label and buttons.
    var x = right
    for (button, title, primary) in buttons.reversed() {
      let w = FilingDraw.buttonWidth(title)
      x -= w
      let rect = NSRect(x: x, y: y, width: w, height: 23)
      FilingDraw.button(title, in: rect, primary: primary, hovered: hovered == button)
      buttonRects.insert((button, rect), at: 0)
      x -= 6
    }
    PanelDraw.line(
      PanelDraw.text(label, .systemFont(ofSize: 11), .secondaryLabelColor),
      in: NSRect(x: left, y: y, width: max(0, x - 8 - left), height: 23))
  }

  func button(at point: NSPoint) -> Button? { buttonRects.first { $0.1.contains(point) }?.0 }

  /// Presses a button as a click would, for checks.
  func press(_ button: Button) { onPress?(button) }

  override func mouseDown(with event: NSEvent) {
    if let button = button(at: convert(event.locationInWindow, from: nil)) { onPress?(button) }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseMoved(with event: NSEvent) { hovered = button(at: convert(event.locationInWindow, from: nil)) }
  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func accessibilityLabel() -> String? {
    guard let content else { return nil }
    return "Jev suggests \(content.name), \(FilingDraw.percent(content.probability)). \(content.why ?? "")"
  }
}

// MARK: - The toast

/// A HUD at the bottom of the panel: "Moved Invoice 1121.pdf to invoices  Undo".
final class FilingToast: NSView {
  override var isFlipped: Bool { true }
  private(set) var message = ""
  private(set) var action: String?
  private var handler: (() -> Void)?
  private var hideWork: DispatchWorkItem?
  private var actionRect = NSRect.zero
  static let font = NSFont.systemFont(ofSize: 13)
  static let actionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  /// How long a toast stays up.
  var lifetime: TimeInterval = 5

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }
  required init?(coder: NSCoder) { fatalError() }

  var isShowing: Bool { !isHidden }

  /// Shows a message, with an optional action such as Undo, centered at the
  /// bottom of `container`.
  func show(_ text: String, action: String? = nil, in container: NSView, bottom: CGFloat, _ handler: (() -> Void)? = nil) {
    message = text
    self.action = action
    self.handler = handler
    let textWidth = PanelDraw.width(PanelDraw.text(text, FilingToast.font, .white))
    let actionWidth = action.map { PanelDraw.width(PanelDraw.text($0, FilingToast.actionFont, .white)) + 14 } ?? 0
    let width = min(container.bounds.width - 32, 28 + textWidth + actionWidth)
    let height: CGFloat = 34
    let y = container.isFlipped ? container.bounds.height - bottom - height : bottom
    frame = NSRect(x: ((container.bounds.width - width) / 2).rounded(), y: y, width: width, height: height)
    if superview !== container { container.addSubview(self, positioned: .above, relativeTo: nil) }
    setAccessibilityLabel(text)
    isHidden = false
    alphaValue = 1
    needsDisplay = true
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
    NSAccessibility.post(
      element: self, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  func dismiss() {
    hideWork?.cancel()
    hideWork = nil
    isHidden = true
    handler = nil
  }

  /// Runs the action as a click would, for checks.
  func performAction() {
    let run = handler
    dismiss()
    run?()
  }

  override func draw(_ dirtyRect: NSRect) {
    FilingInk.hud.setFill()
    FilingDraw.rounded(bounds, 12).fill()
    var right = bounds.width - 14
    if let action {
      let w = PanelDraw.width(PanelDraw.text(action, FilingToast.actionFont, .white))
      actionRect = NSRect(x: right - w - 4, y: 0, width: w + 8, height: bounds.height)
      PanelDraw.line(
        PanelDraw.text(action, FilingToast.actionFont, .white), in: NSRect(x: right - w, y: 0, width: w, height: bounds.height))
      right -= w + 14
    } else {
      actionRect = .zero
    }
    PanelDraw.line(
      PanelDraw.text(message, FilingToast.font, .white), in: NSRect(x: 14, y: 0, width: max(0, right - 14), height: bounds.height))
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if action != nil, actionRect.contains(p) { performAction() }
  }
}
