import AppKit
import UniformTypeIdentifiers

// MARK: - Inspector layout

func pLabel(
  _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
  color: NSColor = Ink.text, mono: Bool = false
) -> NSTextField {
  let type: NSFont =
    mono
    ? .monospacedSystemFont(ofSize: size, weight: weight)
    : .systemFont(ofSize: size, weight: weight)
  return label(text, type, color)
}

func pName(_ url: URL) -> String {
  url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
}
let previewByteFormatter: ByteCountFormatter = {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  return formatter
}()
func pBytes(_ value: Int) -> String {
  if value < 1_000 { return "\(value) \(value == 1 ? "byte" : "bytes")" }
  return previewByteFormatter.string(fromByteCount: Int64(value))
}
func pCount(_ value: Int, _ unit: String) -> String {
  "\(value.formatted()) \(unit)\(value == 1 ? "" : "s")"
}

func pSymbol(_ url: URL, directory: Bool) -> String {
  if directory { return "folder" }
  let ext = url.pathExtension.lowercased()
  let type = UTType(filenameExtension: ext)
  if ext == "svg" { return "beziercurve" }
  if ext == "pdf" { return "doc.richtext" }
  if type?.conforms(to: .image) == true { return "photo" }
  if type?.conforms(to: .movie) == true { return "film" }
  if type?.conforms(to: .audio) == true { return "waveform" }
  if type?.conforms(to: .sourceCode) == true
    || ["json", "rs", "toml", "ts", "tsx", "sh"].contains(ext)
  {
    return "chevron.left.forwardslash.chevron.right"
  }
  if type?.conforms(to: .archive) == true { return "doc.zipper" }
  if type?.conforms(to: .text) == true || ["md", "txt"].contains(ext) { return "doc.plaintext" }
  return "doc"
}

func pGlyph(_ symbol: String, color: NSColor, size: CGFloat) -> NSImageView {
  let view = NSImageView()
  view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
  view.contentTintColor = color
  view.imageScaling = .scaleProportionallyDown
  view.setAccessibilityElement(false)
  return view
}

class PreviewBlock: NSView {
  override var isFlipped: Bool { true }
  func height(for width: CGFloat) -> CGFloat { 32 }
}

final class PreviewPage: NSView {
  override var isFlipped: Bool { true }
  private var blocks: [PreviewBlock] = []
  func replace(_ blocks: [PreviewBlock]) {
    for old in self.blocks { old.removeFromSuperview() }
    self.blocks = blocks
    for block in blocks { addSubview(block) }
  }
  func arrange(width: CGFloat, minimum: CGFloat, pad: CGFloat) {
    let inner = max(1, width - 2 * pad)
    var y: CGFloat = 12
    for block in blocks {
      let h = block.height(for: inner)
      block.frame = NSRect(x: pad, y: y, width: inner, height: h)
      y += h
    }
    let size = NSSize(width: width, height: max(minimum, y + 16))
    if frame.size != size { setFrameSize(size) }
  }
}

final class PreviewSection: PreviewBlock {
  private let label: NSTextField
  init(_ text: String) {
    label = pLabel(text, size: 10, weight: .semibold, color: Ink.quiet, mono: true)
    super.init(frame: .zero)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat { 33 }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: 0, y: 10, width: bounds.width, height: 15)
  }
}

final class PreviewSmallNote: PreviewBlock {
  private let label: NSTextField
  init(_ text: String) {
    label = pLabel(text, size: 11, color: Ink.quiet)
    super.init(frame: .zero)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    label.frame = bounds.insetBy(dx: 0, dy: 7)
  }
}

final class PreviewDetail: PreviewBlock {
  private let title: NSTextField
  private let value: NSTextField
  init(_ title: String, _ value: String) {
    self.title = pLabel(title, size: 12, color: Ink.quiet)
    self.value = pLabel(value, size: 12)
    self.value.lineBreakMode = .byTruncatingMiddle
    self.value.isSelectable = true
    self.value.toolTip = value
    super.init(frame: .zero)
    addSubview(self.title)
    addSubview(self.value)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat { 27 }
  override func layout() {
    super.layout()
    let left = min(88, bounds.width * 0.30)
    title.frame = NSRect(x: 0, y: 4, width: left - 4, height: 18)
    value.frame = NSRect(x: left, y: 4, width: max(1, bounds.width - left), height: 18)
  }
}

final class PreviewMessage: PreviewBlock {
  private let imageView: NSImageView
  private let label: NSTextField
  init(_ message: String, symbol: String) {
    imageView = pGlyph(symbol, color: Ink.quiet, size: 24)
    label = NSTextField(wrappingLabelWithString: message)
    label.font = .systemFont(ofSize: 13)
    label.textColor = Ink.quiet
    label.lineBreakMode = .byWordWrapping
    super.init(frame: .zero)
    addSubview(imageView)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat {
    70
      + max(
        22,
        label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width - 6), height: 1000))
          .height ?? 22)
  }
  override func layout() {
    super.layout()
    imageView.frame = NSRect(x: 0, y: 18, width: 32, height: 32)
    label.frame = NSRect(x: 0, y: 62, width: bounds.width, height: max(1, bounds.height - 62))
  }
}

class PreviewTarget: PreviewBlock, NSDraggingSource, FileDragSource {
  var activate: () -> Void
  var open: (() -> Void)?
  var dragURL: URL?
  let fileDrag = FileDragCapture()
  private var tracking: NSTrackingArea?
  private var pressed: (() -> Void)?
  private var pressLocation: NSPoint?
  private var sessionURL: URL?
  init(action: @escaping () -> Void) {
    activate = action
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 5
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) == nil ? nil : self
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(
      rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
      owner: self)
    addTrackingArea(tracking!)
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func mouseEntered(with event: NSEvent) { applyHover(true) }
  override func mouseExited(with event: NSEvent) { applyHover(false) }
  func applyHover(_ active: Bool) {
    layer?.backgroundColor = active ? Ink.raised.cgColor : NSColor.clear.cgColor
  }
  func resetInteraction() {
    pressed = nil
    pressLocation = nil
    applyHover(false)
  }
  override func mouseDown(with event: NSEvent) {
    pressLocation = event.locationInWindow
    if let open, event.clickCount == 2 || event.modifierFlags.contains(.option) {
      pressed = open
    } else {
      pressed = activate
    }
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      pressed = nil
      pressLocation = nil
    }
    if bounds.contains(convert(event.locationInWindow, from: nil)) { pressed?() }
  }
  func fileDraggingItem() -> NSDraggingItem? {
    guard let dragURL, !bounds.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
      return nil
    }
    cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    return item
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = pressLocation, let url = dragURL else { return }
    let point = event.locationInWindow
    guard hypot(point.x - start.x, point.y - start.y) >= 4, let item = fileDraggingItem() else {
      return
    }
    pressLocation = nil
    pressed = nil
    sessionURL = url
    beginDraggingSession(with: [item], event: event, source: self)
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    [.copy, .move]
  }
  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    if let url = sessionURL {
      fileDrag.begin(sequence: session.draggingSequenceNumber, paths: [url.path])
    }
  }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    fileDrag.end(sequence: session.draggingSequenceNumber)
    sessionURL = nil
  }
  override func accessibilityPerformPress() -> Bool {
    activate()
    return true
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let reveal = menu.addItem(
      withTitle: "Reveal in Browser", action: #selector(menuReveal), keyEquivalent: "")
    reveal.target = self
    if open != nil {
      let item = menu.addItem(withTitle: "Open", action: #selector(menuOpen), keyEquivalent: "")
      item.target = self
    }
    return menu
  }
  @objc private func menuReveal() { activate() }
  @objc private func menuOpen() { open?() }
}

final class PreviewActionLine: PreviewTarget {
  private let title = pLabel("", size: 13, weight: .medium)
  private let detail = pLabel("", size: 10, color: Ink.quiet, mono: true)
  private let glyph = NSImageView()
  private let edge = pGlyph("chevron.right", color: Ink.quiet, size: 10)
  private var symbolName = ""
  init() {
    super.init(action: {})
    title.lineBreakMode = .byTruncatingMiddle
    detail.alignment = .right
    glyph.imageScaling = .scaleProportionallyDown
    for view in [title, detail, glyph, edge] { addSubview(view) }
    setAccessibilityHelp("Reveal in browser")
  }
  convenience init(_ text: String, detail: String, symbol: String, action: @escaping () -> Void) {
    self.init()
    configure(text, detail: detail, symbol: symbol, folder: false, open: nil, action: action)
  }
  func configure(
    _ text: String, detail: String, symbol: String, folder: Bool, open: (() -> Void)?,
    action: @escaping () -> Void
  ) {
    resetInteraction()
    title.stringValue = text
    self.detail.stringValue = detail
    if symbolName != symbol {
      symbolName = symbol
      glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
    }
    glyph.contentTintColor = folder ? Ink.lime : Ink.quiet
    edge.isHidden = !folder
    self.open = open
    activate = action
    setAccessibilityLabel(
      [text, folder ? "folder" : detail].filter { !$0.isEmpty }.joined(separator: ", "))
    needsLayout = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat { 36 }
  override func layout() {
    super.layout()
    let w = bounds.width
    let right: CGFloat =
      (detail.stringValue.isEmpty || w < 210)
      ? (edge.isHidden ? 0 : 17) : min(72, ceil(detail.intrinsicContentSize.width) + 5)
    glyph.frame = NSRect(x: 3, y: 8, width: 24, height: 20)
    title.frame = NSRect(x: 34, y: 9, width: max(1, w - 40 - right), height: 18)
    detail.frame = NSRect(x: max(0, w - right - 3), y: 10, width: right, height: 16)
    edge.frame = NSRect(x: max(0, w - 14), y: 10, width: 12, height: 16)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    Ink.rule.withAlphaComponent(0.56).setFill()
    NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
  }
}

final class PreviewPicture: NSImageView {
  var showTransparency = false
  private static let light = NSColor(rgb: 0xC5C7BD).cgColor
  private static let dark = NSColor(rgb: 0xB7BAAF).cgColor
  override func draw(_ dirtyRect: NSRect) {
    if showTransparency, let size = image?.size, size.width > 0, size.height > 0,
      let context = NSGraphicsContext.current?.cgContext
    {
      let scale = min(bounds.width / size.width, bounds.height / size.height)
      let width = size.width * scale
      let height = size.height * scale
      let imageRect = NSRect(
        x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
      let area = imageRect.intersection(dirtyRect)
      if !area.isEmpty {
        context.saveGState()
        context.clip(to: area)
        context.setShouldAntialias(false)
        context.setFillColor(Self.light)
        context.fill(area)
        context.setFillColor(Self.dark)
        let side: CGFloat = 8
        let firstColumn = Int(floor(area.minX / side))
        let endColumn = Int(ceil(area.maxX / side))
        for y in Int(floor(area.minY / side))..<Int(ceil(area.maxY / side)) {
          let firstDark = (firstColumn + y).isMultiple(of: 2) ? firstColumn : firstColumn + 1
          for x in stride(from: firstDark, to: endColumn, by: 2) {
            context.addRect(
              CGRect(x: CGFloat(x) * side, y: CGFloat(y) * side, width: side, height: side))
          }
        }
        context.fillPath()
        context.restoreGState()
      }
    }
    super.draw(dirtyRect)
  }
}

final class PreviewMat: NSView {
  private let picture = PreviewPicture()
  private let glyph: NSImageView
  init(symbol: String, description: String, small: Bool = false) {
    glyph = pGlyph(symbol, color: Ink.quiet, size: small ? 21 : 34)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Ink.main.cgColor
    layer?.cornerRadius = small ? 5 : 7
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = Ink.rule.cgColor
    picture.imageScaling = .scaleProportionallyUpOrDown
    picture.setAccessibilityElement(true)
    picture.setAccessibilityLabel(description)
    addSubview(glyph)
    addSubview(picture)
  }
  required init?(coder: NSCoder) { fatalError() }
  func setBitmap(_ bitmap: PreviewBitmap) {
    picture.showTransparency = bitmap.mayHaveTransparency
    picture.image = bitmap.image
    picture.needsDisplay = true
    glyph.isHidden = true
  }
  override func layout() {
    super.layout()
    let inset: CGFloat = bounds.width < 180 ? 4 : 8
    picture.frame = bounds.insetBy(dx: inset, dy: inset)
    glyph.frame = bounds.insetBy(dx: 8, dy: 8)
  }
}

final class PreviewHero: PreviewBlock {
  private let mat: PreviewMat
  private let note = pLabel("No visual preview", size: 11, color: Ink.quiet)
  init(symbol: String, description: String) {
    mat = PreviewMat(symbol: symbol, description: description)
    super.init(frame: .zero)
    note.alignment = .center
    note.isHidden = true
    addSubview(mat)
    addSubview(note)
  }
  required init?(coder: NSCoder) { fatalError() }
  func setBitmap(_ bitmap: PreviewBitmap) {
    mat.setBitmap(bitmap)
    note.isHidden = true
  }
  func missingPreview() { note.isHidden = false }
  override func height(for width: CGFloat) -> CGFloat { min(max(180, width * 0.85), 370) + 8 }
  override func layout() {
    super.layout()
    mat.frame = NSRect(x: 0, y: 4, width: bounds.width, height: max(1, bounds.height - 8))
    note.frame = NSRect(
      x: 7, y: bounds.height / 2 + 26, width: max(1, bounds.width - 14), height: 18)
  }
}

final class PreviewCard: PreviewTarget {
  private let mat: PreviewMat
  private let format: NSTextField
  init(_ entry: PreviewEntry, action: @escaping () -> Void) {
    mat = PreviewMat(
      symbol: pSymbol(entry.url, directory: false), description: entry.name, small: true)
    format = pLabel(
      entry.url.pathExtension.uppercased(), size: 9, weight: .semibold, color: Ink.quiet, mono: true
    )
    format.alignment = .left
    format.setAccessibilityElement(false)
    super.init(action: action)
    addSubview(mat)
    addSubview(format)
    toolTip = entry.name
    setAccessibilityLabel("Preview of \(entry.name)")
    setAccessibilityHelp("Reveal in browser")
  }
  required init?(coder: NSCoder) { fatalError() }
  func setBitmap(_ bitmap: PreviewBitmap) { mat.setBitmap(bitmap) }
  override func applyHover(_ active: Bool) {
    mat.layer?.borderColor = active ? Ink.lime.cgColor : Ink.rule.cgColor
  }
  override func layout() {
    super.layout()
    mat.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - 18))
    format.frame = NSRect(x: 0, y: max(0, bounds.height - 15), width: bounds.width, height: 14)
  }
}

final class PreviewStrip: PreviewBlock {
  let cards: [PreviewCard]
  init(_ entries: [PreviewEntry], action: @escaping (URL) -> Void) {
    cards = entries.map { entry in PreviewCard(entry) { action(entry.url) } }
    super.init(frame: .zero)
    for card in cards { addSubview(card) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat {
    if cards.count == 1 { return max(95, min(195, width * 0.55)) + 26 }
    return max(80, min(157, width / CGFloat(cards.count) * 0.94)) + 26
  }
  override func layout() {
    super.layout()
    let gap: CGFloat = 5
    let columns = CGFloat(max(1, cards.count))
    let w = (bounds.width - (columns - 1) * gap) / columns
    for (index, card) in cards.enumerated() {
      let x0 = round(CGFloat(index) * (w + gap))
      let x1 = round(CGFloat(index + 1) * (w + gap) - gap)
      card.frame = NSRect(x: x0, y: 4, width: max(1, x1 - x0), height: max(1, bounds.height - 8))
    }
  }
}

final class PreviewText: PreviewBlock {
  private let textView = NSTextView()
  private var previousWidth: CGFloat = -1
  private var contentHeight: CGFloat = 0
  init(_ text: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.backgroundColor = Ink.main.cgColor
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    textView.textColor = Ink.text
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 8, height: 10)
    textView.textContainer?.widthTracksTextView = false
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.string = text
    textView.setAccessibilityLabel("File contents")
    addSubview(textView)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func height(for width: CGFloat) -> CGFloat {
    guard previousWidth != width else { return contentHeight }
    previousWidth = width
    guard let container = textView.textContainer, let layout = textView.layoutManager else {
      return 120
    }
    container.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    contentHeight = max(50, ceil(layout.usedRect(for: container).height) + 22)
    return contentHeight
  }
  override func layout() {
    super.layout()
    textView.frame = bounds
  }
}
