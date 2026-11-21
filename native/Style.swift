import AppKit

extension NSColor {
  convenience init(rgb: UInt32) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }
}
enum Ink {
  static let rail = NSColor(rgb: 0x191B18)
  static let main = NSColor(rgb: 0x21231F)
  static let well = NSColor(rgb: 0x181A17)
  static let raised = NSColor(rgb: 0x2F322C)
  static let rule = NSColor(rgb: 0x3B3E36)
  static let text = NSColor(rgb: 0xF2F1E8)
  static let quiet = NSColor(rgb: 0xB0B2A6)
  static let faint = NSColor(rgb: 0x85897C)
  static let lime = NSColor(rgb: 0xD5F581)
  static let issue = NSColor(rgb: 0xFFB09C)
  static let selected = NSColor(rgb: 0xD5F581)
  static let onSelection = NSColor(rgb: 0x20261B)
}
func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
  .systemFont(ofSize: size, weight: weight)
}
func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
  .monospacedSystemFont(ofSize: size, weight: weight)
}
func label(_ value: String, _ type: NSFont, _ color: NSColor, _ identifier: String? = nil)
  -> NSTextField
{
  let field = NSTextField(labelWithString: value)
  field.font = type
  field.textColor = color
  field.lineBreakMode = .byTruncatingTail
  field.maximumNumberOfLines = 1
  if let identifier { field.setAccessibilityIdentifier(identifier) }
  return field
}
func symbol(_ name: String, _ size: CGFloat = 14, _ weight: NSFont.Weight = .regular) -> NSImage? {
  NSImage(systemSymbolName: name, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}
class Flipped: NSView {
  override var isFlipped: Bool { true }
  init(color: NSColor? = nil) {
    super.init(frame: .zero)
    if let color {
      wantsLayer = true
      layer?.backgroundColor = color.cgColor
    }
  }
  required init?(coder: NSCoder) { fatalError() }
}
final class Mark: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let box = bounds.insetBy(dx: 1, dy: 1)
    Ink.lime.setFill()
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.24, yRadius: box.width * 0.24).fill()
    let u = box.width / 32
    Ink.onSelection.setStroke()
    for i in 0..<3 {
      let k = CGFloat(i) * 4 * u
      let path = NSBezierPath()
      path.lineWidth = 2.1 * u
      path.lineCapStyle = .round
      let x = box.minX
      let y = box.minY
      path.move(to: NSPoint(x: x + 7 * u + k, y: y + 6 * u))
      path.line(to: NSPoint(x: x + 7 * u + k, y: y + 17 * u))
      path.curve(
        to: NSPoint(x: x + 18 * u, y: y + 26 * u - k),
        controlPoint1: NSPoint(x: x + 7 * u + k, y: y + 23 * u - k / 2),
        controlPoint2: NSPoint(x: x + 12 * u + k / 2, y: y + 26 * u - k))
      path.line(to: NSPoint(x: x + 25 * u, y: y + 26 * u - k))
      path.stroke()
    }
  }
}
final class ActionButton: NSButton {
  let handler: () -> Void
  init(
    _ title: String, icon: String? = nil, help: String, accent: Bool = false,
    perform: @escaping () -> Void
  ) {
    handler = perform
    super.init(frame: .zero)
    self.title = title
    if let icon {
      image = symbol(icon, 13, .semibold)
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    target = self
    action = #selector(fire)
    bezelStyle = .accessoryBarAction
    isBordered = true
    font = .systemFont(ofSize: 12, weight: .medium)
    contentTintColor = accent ? Ink.lime : Ink.text
    toolTip = help
    setAccessibilityLabel(help)
    setAccessibilityIdentifier(help)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func fire() { handler() }
}
final class LayoutRoot: Flipped {
  var arrange: (() -> Void)?
  override func layout() {
    super.layout()
    arrange?()
  }
}
func position(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
  v.frame = NSRect(
    x: x.rounded(.down), y: y.rounded(.down), width: max(0, w.rounded(.down)),
    height: max(0, h.rounded(.down)))
}
