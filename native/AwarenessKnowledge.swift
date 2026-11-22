import AppKit

/// One line of "What Finger knows": a signal, and what of it is sent to Jev.
struct PanelKnowledgeRow: Equatable {
  var signal: String
  var sent: String
}

/// Everything that can add rows to "What Finger knows". Awareness registers
/// its signals; other parts of Finger, such as Jev filing, add their own.
/// Main thread only. Sources are asked each time the popover opens.
enum PanelKnowledge {
  /// The second column for anything that is never sent.
  static let staysHere = "Stays on this Mac"

  private static var sources: [(id: Int, source: () -> [PanelKnowledgeRow])] = []
  private static var next = 0

  /// Adds a source of rows. Keep the id to remove it later.
  @discardableResult
  static func register(source: @escaping () -> [PanelKnowledgeRow]) -> Int {
    next += 1
    sources.append((next, source))
    return next
  }

  static func unregister(_ id: Int) { sources.removeAll { $0.id == id } }

  /// Every source's rows, in the order the sources were registered.
  static var rows: [PanelKnowledgeRow] { sources.flatMap { $0.source() } }
}

/// The popover the footer's status opens: what Finger knows right now, in two
/// columns, "Signal" and "Sent to Jev". It lives inside the panel so the panel
/// keeps the keyboard.
final class PanelKnowledgeView: NSView {
  override var isFlipped: Bool { true }
  var rows: [PanelKnowledgeRow] = [] { didSet { needsLayout = true; needsDisplay = true } }
  var note = "File contents and full paths stay on this Mac. Turn this off with Use Activity in Finger’s menu bar menu."
  static let title = "What Finger knows right now"
  static let width: CGFloat = 460
  private static let pad: CGFloat = 14
  private static let rowFont = NSFont.systemFont(ofSize: 12)
  private static let noteFont = NSFont.systemFont(ofSize: 11.5)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.masksToBounds = true
    setAccessibilityRole(.popover)
    setAccessibilityLabel(PanelKnowledgeView.title)
  }
  required init?(coder: NSCoder) { fatalError() }

  private var fill: NSColor {
    effectiveAppearance.panelDark
      ? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.2, alpha: 1)
      : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
  }

  private func columns(_ width: CGFloat) -> (left: CGFloat, right: CGFloat) {
    let inner = width - PanelKnowledgeView.pad * 2
    let right = (inner * 0.4).rounded()
    return (inner - right - 12, right)
  }

  /// Wrapped text, measured and drawn with the same attributes.
  private static func wrapped(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 1
    return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
  }

  private func textHeight(_ s: String, _ font: NSFont, _ width: CGFloat) -> CGFloat {
    let rect = PanelKnowledgeView.wrapped(s, font, .labelColor).boundingRect(
      with: NSSize(width: max(1, width), height: 1000), options: [.usesLineFragmentOrigin])
    return ceil(rect.height) + 1
  }

  /// The height that fits `rows` at `width`.
  func fittingHeight(width: CGFloat) -> CGFloat {
    let (left, right) = columns(width)
    var h: CGFloat = PanelKnowledgeView.pad + 18 + 8 + 16
    for row in rows {
      h += 12 + max(textHeight(row.signal, PanelKnowledgeView.rowFont, left), textHeight(row.sent, PanelKnowledgeView.rowFont, right))
    }
    if rows.isEmpty { h += 12 + 16 }
    h += 10 + textHeight(note, PanelKnowledgeView.noteFont, width - PanelKnowledgeView.pad * 2) + PanelKnowledgeView.pad
    return ceil(h)
  }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    fill.setFill()
    NSBezierPath(roundedRect: b, xRadius: 12, yRadius: 12).fill()
    NSColor.separatorColor.setStroke()
    let edge = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
    edge.lineWidth = 1
    edge.stroke()
    let pad = PanelKnowledgeView.pad
    let (left, right) = columns(b.width)
    var y = pad
    PanelDraw.line(
      PanelDraw.text(PanelKnowledgeView.title, .systemFont(ofSize: 13, weight: .semibold), .labelColor),
      in: NSRect(x: pad, y: y, width: b.width - pad * 2, height: 18))
    y += 18 + 8
    let head = NSFont.systemFont(ofSize: 11, weight: .semibold)
    PanelDraw.line(PanelDraw.text("Signal", head, .secondaryLabelColor), in: NSRect(x: pad, y: y, width: left, height: 14))
    PanelDraw.line(
      PanelDraw.text("Sent to Jev", head, .secondaryLabelColor),
      in: NSRect(x: pad + left + 12, y: y, width: right, height: 14))
    y += 16
    let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
    func wrapped(_ s: String, _ color: NSColor) -> NSAttributedString {
      PanelKnowledgeView.wrapped(s, PanelKnowledgeView.rowFont, color)
    }
    let shown = rows.isEmpty ? [PanelKnowledgeRow(signal: "Nothing yet", sent: "")] : rows
    for row in shown {
      NSColor.separatorColor.setFill()
      NSRect(x: pad, y: y, width: b.width - pad * 2, height: hairline).fill()
      y += 6
      let h = max(
        textHeight(row.signal, PanelKnowledgeView.rowFont, left), textHeight(row.sent, PanelKnowledgeView.rowFont, right))
      wrapped(row.signal, rows.isEmpty ? .secondaryLabelColor : .labelColor).draw(
        with: NSRect(x: pad, y: y, width: left, height: h), options: [.usesLineFragmentOrigin])
      wrapped(row.sent, .secondaryLabelColor).draw(
        with: NSRect(x: pad + left + 12, y: y, width: right, height: h), options: [.usesLineFragmentOrigin])
      y += h + 6
    }
    y += 10
    let note = PanelKnowledgeView.wrapped(self.note, PanelKnowledgeView.noteFont, .secondaryLabelColor)
    note.draw(
      with: NSRect(x: pad, y: y, width: b.width - pad * 2, height: max(0, b.height - y - pad / 2)),
      options: [.usesLineFragmentOrigin])
  }

  // Clicks inside stay inside.
  override func mouseDown(with event: NSEvent) {}
}
