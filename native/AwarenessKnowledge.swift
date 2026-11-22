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

  /// Posted on the main thread when a source says its rows changed.
  static let changed = Notification.Name("PanelKnowledge.changed")

  private static var sources: [(id: Int, source: () -> [PanelKnowledgeRow], observer: NSObjectProtocol?)] = []
  private static var next = 0

  /// Adds a source of rows. Keep the id to remove it later. With `changes`,
  /// that notification (from `object`) refreshes an open popover.
  @discardableResult
  static func register(
    source: @escaping () -> [PanelKnowledgeRow], changes: Notification.Name? = nil, object: AnyObject? = nil
  ) -> Int {
    next += 1
    let observer = changes.map {
      NotificationCenter.default.addObserver(forName: $0, object: object, queue: .main) { _ in
        NotificationCenter.default.post(name: PanelKnowledge.changed, object: nil)
      }
    }
    sources.append((next, source, observer))
    return next
  }

  static func unregister(_ id: Int) {
    for entry in sources where entry.id == id {
      if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
    }
    sources.removeAll { $0.id == id }
  }

  /// Each source's rows, in the order the sources were registered.
  static var groups: [[PanelKnowledgeRow]] { sources.map { $0.source() } }

  /// Every source's rows, in the order the sources were registered.
  static var rows: [PanelKnowledgeRow] { groups.flatMap { $0 } }
}

extension FilingLog {
  /// Lists what filing noticed and what it sent to Jev in "What Finger knows",
  /// newest first, refreshed as rows arrive.
  @discardableResult
  func registerKnowledge() -> Int {
    PanelKnowledge.register(
      source: { [weak self] in
        // What was sent to Jev first, then what stayed here, each newest first.
        // A row that repeats (moved, put back, moved again) shows once.
        var seen = Set<String>()
        let rows = (self?.pairs ?? []).filter { seen.insert($0.signal + "\u{0}" + $0.sent).inserted }
          .map { PanelKnowledgeRow(signal: $0.signal, sent: $0.sent) }
        return rows.filter { $0.sent != FilingLog.staysHere } + rows.filter { $0.sent == FilingLog.staysHere }
      }, changes: FilingLog.changed, object: self)
  }
}

/// The popover the footer's status opens: what Finger knows right now, in two
/// columns, "Signal" and "Sent to Jev". It lives inside the panel so the panel
/// keeps the keyboard.
final class PanelKnowledgeView: NSView {
  override var isFlipped: Bool { true }
  var rows: [PanelKnowledgeRow] = [] { didSet { needsLayout = true; needsDisplay = true } }
  /// Rows left out because they don't fit: "and 6 more".
  private(set) var more = 0
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

  /// Shows as much of each source's rows as fits in `maxHeight`. The source
  /// with the most rows gives way first, and within it a row that stayed on
  /// this Mac before one that was sent to Jev, from the end.
  func fit(_ groups: [[PanelKnowledgeRow]], width: CGFloat, maxHeight: CGFloat) {
    var kept = groups.filter { !$0.isEmpty }
    let total = kept.reduce(0) { $0 + $1.count }
    rows = kept.flatMap { $0 }
    more = 0
    while rows.count > 1, fittingHeight(width: width) > maxHeight {
      let largest = kept.map(\.count).max() ?? 0
      let candidates = kept.indices.filter { kept[$0].count == largest && largest > 1 }
      guard
        let g = candidates.last(where: { i in kept[i].contains { $0.sent == PanelKnowledge.staysHere } })
          ?? candidates.last
      else { break }
      if let i = kept[g].lastIndex(where: { $0.sent == PanelKnowledge.staysHere }) {
        kept[g].remove(at: i)
      } else {
        kept[g].removeLast()
      }
      rows = kept.flatMap { $0 }
      more = total - rows.count
    }
  }

  private var moreText: String { "and \(more) more" }

  /// The height that fits `rows` at `width`.
  func fittingHeight(width: CGFloat) -> CGFloat {
    let (left, right) = columns(width)
    var h: CGFloat = PanelKnowledgeView.pad + 18 + 8 + 16
    for row in rows {
      h += 12 + max(textHeight(row.signal, PanelKnowledgeView.rowFont, left), textHeight(row.sent, PanelKnowledgeView.rowFont, right))
    }
    if rows.isEmpty { h += 12 + 16 }
    if more > 0 { h += 6 + 16 }
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
    if more > 0 {
      NSColor.separatorColor.setFill()
      NSRect(x: pad, y: y, width: b.width - pad * 2, height: hairline).fill()
      y += 6
      PanelDraw.line(
        PanelDraw.text(moreText, PanelKnowledgeView.rowFont, .tertiaryLabelColor),
        in: NSRect(x: pad, y: y, width: b.width - pad * 2, height: 16))
      y += 16
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
