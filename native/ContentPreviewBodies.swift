import AppKit
import PDFKit
import UniformTypeIdentifiers

// The views behind ContentPreview's header. Each draws with dynamic colors in
// draw(_:), so it follows appearance changes and renders offscreen.

/// Room around the content, larger at Quick Look size.
struct ContentMetrics {
  let roomy: Bool
  var side: CGFloat { roomy ? 28 : 20 }
  var top: CGFloat { roomy ? 20 : 14 }
  var mediaSide: CGFloat { roomy ? 24 : 18 }
}

/// A body under the header, made on first use with the pane's metrics.
protocol ContentBodyView: NSView {
  init(frame: NSRect)
  var metrics: ContentMetrics { get set }
}

/// A view filled with one dynamic color.
class ContentFill: NSView {
  var color: NSColor? { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let color else { return }
    color.setFill()
    // Views don't clip to their bounds by default since macOS 14.
    bounds.intersection(dirtyRect).fill(using: .sourceOver)
  }
}

/// A hairline in the separator color.
final class ContentRule: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    let scale = window?.backingScaleFactor ?? 2
    NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill(using: .sourceOver)
  }
}

// MARK: - Text

/// Text view whose container starts after a line-number gutter.
final class ContentTextView: NSTextView {
  var gutter: CGFloat = 0 { didSet { if gutter != oldValue { updateContainer() } } }
  var insets = NSEdgeInsets(top: 14, left: 20, bottom: 18, right: 20) {
    didSet {
      textContainerInset = NSSize(width: 0, height: insets.top)
      updateContainer()
    }
  }
  var lineStarts: [Int] = []
  var numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  override var textContainerOrigin: NSPoint { NSPoint(x: gutter + insets.left, y: insets.top) }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateContainer()
  }

  private func updateContainer() {
    guard let container = textContainer else { return }
    let width = max(40, bounds.width - gutter - insets.left - insets.right)
    if abs(container.size.width - width) > 0.5 {
      container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    }
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard gutter > 0, !lineStarts.isEmpty, let layout = layoutManager, let container = textContainer
    else { return }
    let origin = textContainerOrigin
    let local = NSRect(
      x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
    let glyphs = layout.glyphRange(forBoundingRect: local, in: container)
    guard glyphs.length > 0 || layout.numberOfGlyphs == 0 else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    let starts = lineStarts
    layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
      let character = layout.characterIndexForGlyph(at: range.location)
      // Only the first fragment of a line gets its number.
      var low = 0
      var high = starts.count - 1
      var line = -1
      while low <= high {
        let mid = (low + high) / 2
        if starts[mid] == character {
          line = mid
          break
        }
        if starts[mid] < character { low = mid + 1 } else { high = mid - 1 }
      }
      guard line >= 0 else { return }
      let number = String(line + 1) as NSString
      let size = number.size(withAttributes: attributes)
      // Numbers use the code's font and size, so they share its line top.
      let point = NSPoint(x: self.gutter - 14 - size.width, y: origin.y + fragment.minY)
      number.draw(at: point, withAttributes: attributes)
    }
  }
}

/// Draws background runs, the find highlight and inline code, as rounded
/// boxes around the glyphs rather than the whole line height.
final class ContentLayoutManager: NSLayoutManager {
  override func fillBackgroundRectArray(
    _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange,
    color: NSColor
  ) {
    let style =
      textStorage?.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil)
      as? NSParagraphStyle
    let spacing = style?.lineSpacing ?? 0
    let radius: CGFloat = color == ContentInk.found ? 3 : 4
    for i in 0..<rectCount {
      var rect = rectArray[i]
      // The line's spacing sits below the glyphs; leave it out.
      if rect.height > spacing + 4 { rect.size.height -= spacing }
      rect = rect.insetBy(dx: -1, dy: 0)
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
  }
}

/// Scrollable, selectable text: prose, Markdown or code.
final class ContentTextBody: ContentFill, ContentBodyView {
  let scroll = NSScrollView()
  let textView: ContentTextView
  private(set) var content: ContentText?
  private var pendingReveal: NSRange?
  var metrics = ContentMetrics(roomy: false) { didSet { applyInsets() } }

  override init(frame: NSRect) {
    let storage = NSTextStorage()
    let layout = ContentLayoutManager()
    layout.allowsNonContiguousLayout = true
    layout.backgroundLayoutEnabled = true
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    textView = ContentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
    super.init(frame: frame)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.usesFontPanel = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
    textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    textView.setAccessibilityIdentifier("content-text")
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.contentView.drawsBackground = false
    scroll.documentView = textView
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    scroll.frame = bounds
    if let range = pendingReveal, bounds.width > 0, bounds.height > 0 {
      pendingReveal = nil
      reveal(range)
    }
  }

  func show(_ text: ContentText) {
    content = text
    color = text.style == .code ? ContentInk.editor : nil
    textView.lineStarts = text.lineStarts
    if text.style == .code {
      let digits = max(2, String(max(1, text.lines)).count)
      let width = ceil(("8" as NSString).size(withAttributes: [.font: textView.numberFont]).width)
      textView.gutter = max(42, CGFloat(digits) * width + 22)
    } else {
      textView.gutter = 0
    }
    applyInsets()
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.layoutManager?.replaceTextStorage(text.text)
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    textView.needsDisplay = true
    revealTicket += 1
    revealing = false
    if let first = text.matches.first {
      if bounds.width > 0 && bounds.height > 0 {
        reveal(first)
      } else {
        pendingReveal = first
      }
    } else {
      pendingReveal = nil
    }
  }

  private func applyInsets() {
    let code = content?.style == .code
    let m = metrics
    textView.insets =
      code
      ? NSEdgeInsets(top: m.roomy ? 16 : 10, left: 0, bottom: 18, right: m.roomy ? 22 : 16)
      : NSEdgeInsets(top: m.top, left: m.side, bottom: 20, right: m.side)
  }

  /// Scrolls so the first hit sits a third of the way down. Text above the hit
  /// is laid out in short slices across run loop turns: exact positions need
  /// it, and a hit deep in a large file must not hold up the main thread.
  func reveal(_ range: NSRange) {
    revealTicket += 1
    let ticket = revealTicket
    revealing = true
    func step() {
      guard ticket == revealTicket else { return }
      guard let layout = textView.layoutManager,
        NSMaxRange(range) <= (textView.textStorage?.length ?? 0)
      else {
        revealing = false
        return
      }
      let target = NSMaxRange(range)
      let started = Date()
      var stuck = false
      while layout.firstUnlaidCharacterIndex() < target, Date().timeIntervalSince(started) < 0.012 {
        let from = layout.firstUnlaidCharacterIndex()
        layout.ensureLayout(
          forCharacterRange: NSRange(location: from, length: min(8_000, target - from)))
        if layout.firstUnlaidCharacterIndex() <= from {
          stuck = true
          break
        }
      }
      if !stuck && layout.firstUnlaidCharacterIndex() < target {
        DispatchQueue.main.async(execute: step)
      } else {
        revealing = false
        scrollTo(range)
      }
    }
    step()
  }
  private var revealTicket = 0
  private(set) var revealing = false

  private func scrollTo(_ range: NSRange) {
    guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
    scroll.layoutSubtreeIfNeeded()
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    textView.sizeToFit()
    let visible = scroll.contentView.bounds.height
    let y = max(0, min(rect.midY - visible / 3, textView.frame.height - visible))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func clear() {
    content = nil
    pendingReveal = nil
    revealTicket += 1
    revealing = false
    textView.lineStarts = []
    textView.layoutManager?.replaceTextStorage(NSTextStorage())
  }
}

// MARK: - PDF

final class ContentPDFBody: NSView, ContentBodyView {
  let pdf = PDFView()
  private var pending: PDFSelection?
  var metrics = ContentMetrics(roomy: false) { didSet { applyMargins() } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    pdf.displayMode = .singlePageContinuous
    pdf.displayDirection = .vertical
    pdf.displaysPageBreaks = true
    pdf.autoScales = true
    pdf.pageShadowsEnabled = true
    pdf.backgroundColor = ContentInk.desk
    pdf.setAccessibilityIdentifier("content-pdf")
    applyMargins()
    addSubview(pdf)
  }
  required init?(coder: NSCoder) { fatalError() }

  private func applyMargins() {
    let side = metrics.roomy ? 24.0 : 16.0
    pdf.pageBreakMargins = NSEdgeInsets(top: 14, left: side, bottom: 0, right: side)
  }

  override func layout() {
    super.layout()
    pdf.frame = bounds
    if let first = pending, bounds.width > 0 {
      pending = nil
      reveal(first)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    pdf.backgroundColor = ContentInk.desk
  }

  func show(_ document: PDFDocument, matches: [PDFSelection]) {
    pdf.document = document
    pdf.highlightedSelections = matches.isEmpty ? nil : matches
    pdf.autoScales = true
    if let first = matches.first {
      if bounds.width > 0 { reveal(first) } else { pending = first }
    } else {
      pending = nil
      if let page = document.page(at: 0) { pdf.go(to: page) }
    }
  }

  private func reveal(_ selection: PDFSelection) {
    pdf.layoutDocumentView()
    guard let page = selection.pages.first else { return }
    let hit = selection.bounds(for: page)
    // Show the hit with the lines above it, not pinned to the top edge.
    let scale = max(pdf.scaleFactor, 0.01)
    let above = bounds.height / 3 / scale
    let target = NSRect(x: hit.minX, y: hit.maxY, width: hit.width, height: above)
    pdf.go(to: target, on: page)
  }

  /// The document stays until the next PDF replaces it: PDFKit can still be
  /// rendering its pages in the background, and they must not lose it.
  func clear() {
    pending = nil
    pdf.highlightedSelections = nil
  }
}

// MARK: - Facts

/// Label and value rows under an image or archive, as Quick Look lists them.
final class ContentFactsView: NSView {
  var rows: [(String, String)] = [] { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  private let font = NSFont.systemFont(ofSize: 12)
  private let spacing: CGFloat = 4

  private var labelWidth: CGFloat { floor(bounds.width * 0.38) }
  private var valueWidth: CGFloat { max(20, bounds.width - labelWidth - 10) }

  private func valueAttributes() -> [NSAttributedString.Key: Any] {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byCharWrapping
    return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
  }

  func height(for width: CGFloat) -> CGFloat {
    guard !rows.isEmpty else { return 0 }
    let valueWidth = max(20, width - floor(width * 0.38) - 10)
    var y: CGFloat = 12
    for (_, value) in rows {
      let size = (value as NSString).boundingRect(
        with: NSSize(width: valueWidth, height: 400), options: [.usesLineFragmentOrigin],
        attributes: valueAttributes())
      y += max(ceil(size.height), 15) + spacing
    }
    return y
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !rows.isEmpty else { return }
    NSColor.separatorColor.setFill()
    let scale = window?.backingScaleFactor ?? 2
    NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill(using: .sourceOver)
    let label = NSMutableParagraphStyle()
    label.alignment = .right
    label.lineBreakMode = .byTruncatingTail
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: label,
    ]
    var y: CGFloat = 12
    for (name, value) in rows {
      let valueRect = (value as NSString).boundingRect(
        with: NSSize(width: valueWidth, height: 400), options: [.usesLineFragmentOrigin],
        attributes: valueAttributes())
      let h = max(ceil(valueRect.height), 15)
      (name as NSString).draw(
        with: NSRect(x: 0, y: y, width: labelWidth, height: 15), options: [.usesLineFragmentOrigin],
        attributes: labelAttributes)
      (value as NSString).draw(
        with: NSRect(x: labelWidth + 10, y: y, width: valueWidth, height: h),
        options: [.usesLineFragmentOrigin], attributes: valueAttributes())
      y += h + spacing
    }
  }
}

// MARK: - Images

/// The picture, fit to the pane, with rounded corners and a card edge.
final class ContentImageCard: NSView {
  var image: NSImage? { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let image else { return }
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(
      effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.4 : 0.12)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    NSColor.windowBackgroundColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    image.draw(
      in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    ContentInk.card.setStroke()
    shape.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
    shape.stroke()
  }
}

final class ContentImageBody: NSView, ContentBodyView {
  private let scroll = NSScrollView()
  private let page = Flipped()
  let card = ContentImageCard()
  let facts = ContentFactsView()
  private(set) var content: ContentImage?
  var metrics = ContentMetrics(roomy: false) { didSet { needsLayout = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = page
    page.addSubview(card)
    page.addSubview(facts)
    card.setAccessibilityElement(true)
    card.setAccessibilityRole(.image)
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ image: ContentImage) {
    content = image
    card.image = image.image
    card.setAccessibilityLabel(image.dimensions.map { "Image, \($0)" } ?? "Image")
    facts.rows = image.facts.rows
    needsLayout = true
    scroll.contentView.scroll(to: .zero)
  }

  override func layout() {
    super.layout()
    scroll.frame = bounds
    let side = metrics.mediaSide
    let width = max(1, bounds.width - side * 2)
    var size = NSSize(width: width, height: width * 0.75)
    if let image = content?.image, image.size.width > 0, image.size.height > 0 {
      let aspect = image.size.height / image.size.width
      size = NSSize(width: width, height: (width * aspect).rounded())
      // A tall picture fits the pane's height instead.
      let tallest = max(160, bounds.height - 34)
      if size.height > tallest {
        size = NSSize(width: (tallest / aspect).rounded(), height: tallest)
      }
      // A small picture shows at one point per pixel, not blown up.
      if let pixels = content?.pixels, CGFloat(pixels.0) < size.width {
        let scale = CGFloat(pixels.0) / size.width
        size = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
      }
    }
    card.frame = NSRect(
      x: (side + (width - size.width) / 2).rounded(), y: 16, width: size.width, height: size.height)
    let factsHeight = facts.height(for: width)
    facts.frame = NSRect(x: side, y: card.frame.maxY + 16, width: width, height: factsHeight)
    let total = max(bounds.height, facts.frame.maxY + 18)
    page.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: total)
  }
}

// MARK: - Archives

/// The archive's contents as an indented tree. It draws only visible rows.
final class ContentArchiveList: NSView {
  var archive: ContentArchive? {
    didSet {
      icons.removeAll()
      needsDisplay = true
    }
  }
  static let rowHeight: CGFloat = 28
  private var icons: [String: NSImage] = [:]
  override var isFlipped: Bool { true }

  var rowCount: Int { (archive?.rows.count ?? 0) + ((archive?.more ?? 0) > 0 ? 1 : 0) }

  private func icon(_ row: ContentArchive.Row) -> NSImage {
    let key = row.directory ? "/" : (row.name as NSString).pathExtension.lowercased()
    if let cached = icons[key] { return cached }
    let image = NSWorkspace.shared.icon(for: row.type ?? .data)
    icons[key] = image
    return image
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let archive else { return }
    let h = Self.rowHeight
    let first = max(0, Int(dirtyRect.minY / h))
    let last = min(rowCount - 1, Int(dirtyRect.maxY / h))
    guard first <= last else { return }
    let name = NSMutableParagraphStyle()
    name.lineBreakMode = .byTruncatingMiddle
    let nameAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
      .paragraphStyle: name,
    ]
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    for index in first...last {
      let y = CGFloat(index) * h
      if index >= archive.rows.count {
        let more = "and \(archive.more.formatted()) more" as NSString
        more.draw(
          at: NSPoint(x: 6, y: y + 7),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
          ])
        continue
      }
      let row = archive.rows[index]
      let x = 6 + CGFloat(min(row.depth, 12)) * 24
      icon(row).draw(
        in: NSRect(x: x, y: y + 5, width: 18, height: 18), from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
      let detail = row.detail as NSString
      let detailWidth = ceil(detail.size(withAttributes: detailAttributes).width)
      detail.draw(
        at: NSPoint(x: bounds.width - 6 - detailWidth, y: y + 6.5), withAttributes: detailAttributes)
      (row.name as NSString).draw(
        with: NSRect(
          x: x + 26, y: y + 6.5, width: max(10, bounds.width - x - 26 - detailWidth - 18), height: 16),
        options: [.usesLineFragmentOrigin], attributes: nameAttributes)
    }
  }
}

final class ContentArchiveBody: NSView, ContentBodyView {
  private let scroll = NSScrollView()
  private let page = Flipped()
  let list = ContentArchiveList()
  let facts = ContentFactsView()
  var metrics = ContentMetrics(roomy: false) { didSet { needsLayout = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = page
    page.addSubview(list)
    page.addSubview(facts)
    list.setAccessibilityElement(true)
    list.setAccessibilityRole(.list)
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ archive: ContentArchive) {
    list.archive = archive
    list.setAccessibilityLabel(
      "Archive contents, " + ContentPreviewReader.plural(archive.files, "file"))
    facts.rows = archive.facts.rows
    needsLayout = true
    scroll.contentView.scroll(to: .zero)
  }

  override func layout() {
    super.layout()
    scroll.frame = bounds
    let side = metrics.side
    let width = max(1, bounds.width - side * 2)
    list.frame = NSRect(
      x: side, y: 8, width: width, height: CGFloat(list.rowCount) * ContentArchiveList.rowHeight)
    let factsHeight = facts.height(for: width)
    facts.frame = NSRect(x: side, y: list.frame.maxY + 14, width: width, height: factsHeight)
    page.frame = NSRect(
      x: 0, y: 0, width: scroll.contentSize.width, height: max(bounds.height, facts.frame.maxY + 18))
  }
}

// MARK: - Spreadsheets

/// CSV and TSV as a grid with row numbers, drawing only what is visible.
final class ContentSheetGrid: NSView {
  private(set) var sheet: ContentSheet?
  private var widths: [CGFloat] = []
  private var matchSet = Set<Int>()
  static let rowHeight: CGFloat = 26
  static let numberWidth: CGFloat = 30
  private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  private let bold = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
  override var isFlipped: Bool { true }

  func load(_ sheet: ContentSheet) {
    self.sheet = sheet
    matchSet = Set(sheet.matches.map { $0.row * 4_096 + $0.column })
    widths = (0..<sheet.columns).map { column in
      var widest: CGFloat = 36
      for (r, row) in sheet.rows.prefix(200).enumerated() where column < row.count {
        let size = (row[column] as NSString).size(withAttributes: [.font: r == 0 ? bold : font])
        widest = max(widest, ceil(size.width) + 16)
      }
      return min(widest, 220)
    }
    frame.size = contentSize
    needsDisplay = true
  }

  var contentSize: NSSize {
    guard let sheet else { return .zero }
    let footer: CGFloat = sheet.partial ? 26 : 0
    return NSSize(
      width: Self.numberWidth + widths.reduce(0, +) + 1,
      height: CGFloat(sheet.rows.count) * Self.rowHeight + 1 + footer)
  }

  func cellRect(row: Int, column: Int) -> NSRect {
    let x = Self.numberWidth + widths.prefix(column).reduce(0, +)
    return NSRect(
      x: x, y: CGFloat(row) * Self.rowHeight, width: widths[column], height: Self.rowHeight)
  }

  private static func numeric(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return false }
    let stripped = t.filter { !"$€£¥%,()+-. ".contains($0) }
    return !stripped.isEmpty && stripped.allSatisfy(\.isNumber)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let sheet else { return }
    let h = Self.rowHeight
    let first = max(0, Int(dirtyRect.minY / h))
    let last = min(sheet.rows.count - 1, Int(dirtyRect.maxY / h))
    let gridWidth = contentSize.width - 1
    let tableHeight = CGFloat(sheet.rows.count) * h
    ContentInk.editor.setFill()
    NSRect(x: 0, y: 0, width: gridWidth, height: tableHeight).fill(using: .sourceOver)
    ContentInk.fill.setFill()
    NSRect(x: 0, y: 0, width: Self.numberWidth, height: tableHeight).fill(using: .sourceOver)
    NSRect(x: Self.numberWidth, y: 0, width: gridWidth - Self.numberWidth, height: h)
      .fill(using: .sourceOver)
    if first <= last {
      let clip = NSMutableParagraphStyle()
      clip.lineBreakMode = .byTruncatingTail
      for r in first...last {
        let row = sheet.rows[r]
        let y = CGFloat(r) * h
        let number = "\(r + 1)" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
          .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = number.size(withAttributes: numberAttributes)
        number.draw(
          at: NSPoint(x: (Self.numberWidth - size.width) / 2, y: y + (h - size.height) / 2),
          withAttributes: numberAttributes)
        for (c, value) in row.enumerated() where c < widths.count {
          let cell = cellRect(row: r, column: c)
          guard cell.intersects(dirtyRect) else { continue }
          let hit = matchSet.contains(r * 4_096 + c)
          if hit {
            ContentInk.found.setFill()
            cell.insetBy(dx: 1, dy: 1).fill()
          }
          let p = NSMutableParagraphStyle()
          p.lineBreakMode = .byTruncatingTail
          p.alignment = r > 0 && Self.numeric(value) ? .right : .left
          let attributes: [NSAttributedString.Key: Any] = [
            .font: r == 0 ? bold : font,
            .foregroundColor: hit ? ContentInk.foundInk : NSColor.labelColor, .paragraphStyle: p,
          ]
          (value as NSString).draw(
            with: NSRect(x: cell.minX + 7, y: y + 5, width: cell.width - 14, height: h - 8),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
      }
    }
    // Grid lines
    NSColor.separatorColor.setFill()
    let scale = window?.backingScaleFactor ?? 2
    let line = 1 / scale
    var x = Self.numberWidth
    NSRect(x: 0, y: 0, width: line, height: tableHeight).fill(using: .sourceOver)
    NSRect(x: x, y: 0, width: line, height: tableHeight).fill(using: .sourceOver)
    for w in widths {
      x += w
      NSRect(x: x, y: 0, width: line, height: tableHeight).fill(using: .sourceOver)
    }
    for r in max(0, first)...max(0, last + 1) where CGFloat(r) * h <= tableHeight {
      NSRect(x: 0, y: CGFloat(r) * h, width: gridWidth, height: line).fill(using: .sourceOver)
    }
    if sheet.partial {
      let note = "Showing the first \(sheet.rows.count.formatted()) rows" as NSString
      note.draw(
        at: NSPoint(x: 2, y: tableHeight + 8),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
  }
}

final class ContentSheetBody: NSView, ContentBodyView {
  let scroll = NSScrollView()
  let grid = ContentSheetGrid()
  private let page = Flipped()
  var metrics = ContentMetrics(roomy: false) { didSet { needsLayout = true } }
  private var pendingReveal = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = page
    page.addSubview(grid)
    grid.setAccessibilityElement(true)
    grid.setAccessibilityRole(.table)
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ sheet: ContentSheet) {
    grid.load(sheet)
    grid.setAccessibilityLabel("Table, " + ContentPreviewReader.plural(sheet.totalRows, "row"))
    pendingReveal = !sheet.matches.isEmpty
    needsLayout = true
    scroll.contentView.scroll(to: .zero)
  }

  override func layout() {
    super.layout()
    scroll.frame = bounds
    let side: CGFloat = metrics.roomy ? 24 : 14
    let size = grid.contentSize
    grid.frame = NSRect(x: side, y: 12, width: size.width, height: size.height)
    page.frame = NSRect(
      x: 0, y: 0, width: max(scroll.contentSize.width, size.width + side * 2),
      height: max(scroll.contentSize.height, size.height + 30))
    if pendingReveal, bounds.width > 0, let first = grid.sheet?.matches.first {
      pendingReveal = false
      let cell = grid.cellRect(row: first.row, column: first.column).offsetBy(dx: side, dy: 12)
      let visible = scroll.contentView.bounds.size
      let x = max(0, min(cell.midX - visible.width / 2, page.frame.width - visible.width))
      let y = max(0, min(cell.midY - visible.height / 3, page.frame.height - visible.height))
      scroll.contentView.scroll(to: NSPoint(x: cell.maxX < visible.width ? 0 : x, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }
}
