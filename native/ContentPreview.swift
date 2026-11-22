import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// What ContentPreview is showing, for tests and the panel's accessibility.
struct ContentPreviewReport {
  enum Kind: String { case empty, loading, prose, markdown, code, pdf, image, archive, sheet, quickLook, message }
  var kind = Kind.empty
  var url: URL?
  var lines: Int?
  var pages: Int?
  var items: Int?
  var matches = 0
  var capped = false
  var message: String?
}

/// The search panel's right-hand preview: a file's own content, not its icon.
/// PDF pages, colored code, formatted Markdown, readable text, large images,
/// spreadsheets and zip contents; anything else goes to Quick Look.
final class ContentPreview: NSView {
  private let header = ContentHeader()
  private let host = Flipped()
  private var current: NSView?
  // Each kind of body is made the first time it is needed, then reused.
  private var madeText: ContentTextBody?
  private var madePDF: ContentPDFBody?
  private var madeImage: ContentImageBody?
  private var madeArchive: ContentArchiveBody?
  private var madeSheet: ContentSheetBody?
  private var textBody: ContentTextBody { made(&madeText) }
  private var pdfBody: ContentPDFBody { made(&madePDF) }
  private var imageBody: ContentImageBody { made(&madeImage) }
  private var archiveBody: ContentArchiveBody { made(&madeArchive) }
  private var sheetBody: ContentSheetBody { made(&madeSheet) }
  private var bodies: [ContentBodyView?] { [madeText, madePDF, madeImage, madeArchive, madeSheet] }
  private var metrics = ContentMetrics(roomy: false)
  private func made<T: ContentBodyView>(_ slot: inout T?) -> T {
    if let view = slot { return view }
    let view = T(frame: host.bounds)
    view.metrics = metrics
    slot = view
    return view
  }
  private var quickLook: QLPreviewView?
  private let note = NSTextField(wrappingLabelWithString: "")
  private let spinner = NSProgressIndicator()
  private var ticket = FileReadTicket()
  private var staleBody: DispatchWorkItem?
  private var spinnerDelay: DispatchWorkItem?

  private static let readers: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Finger content preview"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 3
    return queue
  }()

  private(set) var report = ContentPreviewReport()
  var headerTitle: String { header.name.stringValue }
  var headerDetail: String { header.detail.stringValue }
  /// Called on the main thread when a show() has finished loading.
  var onLoad: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    note.font = .systemFont(ofSize: 13)
    note.textColor = .secondaryLabelColor
    note.alignment = .center
    note.isSelectable = false
    note.setAccessibilityIdentifier("content-message")
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    header.isHidden = true
    addSubview(header)
    addSubview(host)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Preview")
  }
  convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 400, height: 440)) }
  required init?(coder: NSCoder) { fatalError("ContentPreview uses programmatic layout") }

  deinit {
    ticket.cancel()
    quickLook?.close()
  }

  /// nil clears. `match` is the search text when the file was found by its contents:
  /// highlight it and scroll to the first hit.
  func show(_ url: URL?, match: String?) {
    ticket.cancel()
    staleBody?.cancel()
    spinnerDelay?.cancel()
    spinner.stopAnimation(nil)
    let current = FileReadTicket()
    ticket = current
    guard let url else {
      header.isHidden = true
      setBody(nil)
      report = ContentPreviewReport()
      setAccessibilityLabel("Preview")
      return
    }
    // The header appears at once from the name alone; size and extra follow.
    let kind = ContentPreviewReader.kind(of: url)
    header.isHidden = false
    let type = url.hasDirectoryPath ? UTType.folder : UTType(filenameExtension: url.pathExtension)
    header.show(name: url.lastPathComponent, detail: kind, icon: NSWorkspace.shared.icon(for: type ?? .data))
    header.toolTip = url.path
    setAccessibilityLabel("Preview of \(url.lastPathComponent)")
    report = ContentPreviewReport(kind: .loading, url: url)
    needsLayout = true
    // Keep the last body for a moment so moving through a list doesn't flash.
    let stale = DispatchWorkItem { [weak self] in
      guard let self, self.ticket === current else { return }
      self.setBody(nil)
    }
    staleBody = stale
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: stale)
    let spin = DispatchWorkItem { [weak self] in
      guard let self, self.ticket === current else { return }
      self.spinner.startAnimation(nil)
    }
    spinnerDelay = spin
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: spin)
    Self.readers.addOperation { [weak self] in
      guard !current.cancelled else { return }
      let load = ContentPreviewReader.read(url, match: match, ticket: current)
      DispatchQueue.main.async {
        guard let self, self.ticket === current, !current.cancelled, let load else { return }
        self.apply(load)
      }
    }
  }

  private func apply(_ load: ContentLoad) {
    staleBody?.cancel()
    spinnerDelay?.cancel()
    spinner.stopAnimation(nil)
    var parts = [load.kind]
    if let bytes = load.bytes {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
    }
    if let extra = load.extra { parts.append(extra) }
    header.detail.stringValue = parts.joined(separator: " · ")
    if let icon = load.icon { header.icon.image = icon }
    var next = ContentPreviewReport(kind: .message, url: load.url)
    switch load.body {
    case .text(let text):
      next.kind = text.style == .code ? .code : text.style == .markdown ? .markdown : .prose
      next.lines = text.lines
      next.matches = text.matches.count
      next.capped = text.partial
      setBody(textBody)
      textBody.show(text)
    case .pdf(let document, let matches):
      next.kind = .pdf
      next.pages = document.pageCount
      next.matches = matches.count
      setBody(pdfBody)
      pdfBody.show(document, matches: matches)
    case .image(let image):
      next.kind = .image
      header.thumbnail(image.image)
      setBody(imageBody)
      imageBody.show(image)
    case .archive(let archive):
      next.kind = .archive
      next.items = archive.files
      setBody(archiveBody)
      archiveBody.show(archive)
    case .sheet(let sheet):
      next.kind = .sheet
      next.lines = sheet.totalRows
      next.matches = sheet.matches.count
      next.capped = sheet.partial
      setBody(sheetBody)
      sheetBody.show(sheet)
    case .quickLook:
      next.kind = .quickLook
      if quickLook == nil {
        quickLook = QLPreviewView(frame: host.bounds, style: .normal)
        quickLook?.shouldCloseWithWindow = false
        quickLook?.autostarts = false
        quickLook?.setAccessibilityIdentifier("content-quicklook")
      }
      if let quickLook {
        setBody(quickLook)
        quickLook.previewItem = load.url as NSURL
      } else {
        next.kind = .message
        next.message = "Quick Look can’t preview this file."
        note.stringValue = next.message!
        setBody(note)
      }
    case .message(let text):
      next.message = text
      note.stringValue = text
      setBody(note)
    }
    report = next
    onLoad?()
  }

  private func setBody(_ view: NSView?) {
    if current !== view {
      if let old = current {
        old.removeFromSuperview()
        if old === quickLook { quickLook?.previewItem = nil }
        if old === madeText { madeText?.clear() }
        if old === madePDF { madePDF?.clear() }
      }
      current = view
      if let view { host.addSubview(view) }
    }
    host.addSubview(spinner, positioned: .above, relativeTo: nil)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    let wide = bounds.width >= 520
    if wide != metrics.roomy {
      metrics = ContentMetrics(roomy: wide)
      for body in bodies { body?.metrics = metrics }
      header.side = metrics.side
    }
    let top = header.isHidden ? 0 : header.height
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
    host.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    if let current, current !== note { current.frame = host.bounds }
    let noteHeight = ceil(note.sizeThatFits(NSSize(width: host.bounds.width - 48, height: 200)).height)
    note.frame = NSRect(
      x: 24, y: max(0, host.bounds.height * 0.4 - noteHeight / 2), width: max(1, host.bounds.width - 48),
      height: noteHeight)
    spinner.frame = NSRect(x: host.bounds.midX - 8, y: min(120, host.bounds.midY) - 8, width: 16, height: 16)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // Custom views resolve their dynamic colors as they draw; have them redraw.
    let views: [NSView?] = [madeText?.textView, madeImage?.card, madeArchive?.list, madeSheet?.grid]
    for view in views { view?.needsDisplay = true }
  }

  // MARK: Test hooks

  /// The scrolled offset of the current body, for checking a reveal.
  var bodyScrollOffset: CGFloat {
    switch current {
    case let body as ContentTextBody: return body.scroll.contentView.bounds.origin.y
    case let body as ContentSheetBody: return body.scroll.contentView.bounds.origin.y
    default: return 0
    }
  }
  /// True while a match is still being scrolled into view.
  var revealing: Bool { (current as? ContentTextBody)?.revealing ?? false }
  var textView: NSTextView? { (current as? ContentTextBody)?.textView }
  var pdfView: PDFView? { (current as? ContentPDFBody)?.pdf }
  var quickLookView: QLPreviewView? { current as? QLPreviewView }
  var archiveRows: [ContentArchive.Row] { (current as? ContentArchiveBody)?.list.archive?.rows ?? [] }
  var imageFacts: [(String, String)] { (current as? ContentImageBody)?.facts.rows ?? [] }
}

/// The icon or thumbnail, the name, and "Kind · size · extra".
final class ContentHeader: NSView {
  let icon = ContentIcon()
  let name = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")
  private let rule = ContentRule()
  var side: CGFloat = 20 { didSet { needsLayout = true } }
  let height: CGFloat = 58
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    name.font = .systemFont(ofSize: 14, weight: .semibold)
    name.textColor = .labelColor
    name.lineBreakMode = .byTruncatingMiddle
    name.isSelectable = true
    name.setAccessibilityIdentifier("content-name")
    detail.font = .systemFont(ofSize: 11.5)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingTail
    detail.setAccessibilityIdentifier("content-detail")
    for view in [icon, name, detail, rule] { addSubview(view) }
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(name value: String, detail text: String, icon image: NSImage) {
    name.stringValue = value
    detail.stringValue = text
    icon.image = image
    icon.thumbnail = false
  }

  func thumbnail(_ image: NSImage) {
    icon.image = image
    icon.thumbnail = true
  }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: side - 2, y: 13, width: 34, height: 32)
    let x = side + 40
    let width = max(1, bounds.width - x - side)
    name.frame = NSRect(x: x, y: 11, width: width, height: 19)
    detail.frame = NSRect(x: x, y: 30, width: width, height: 16)
    rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
  }
}

/// A file icon, or a small rounded thumbnail for pictures.
final class ContentIcon: NSView {
  var image: NSImage? { didSet { needsDisplay = true } }
  var thumbnail = false { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let image else { return }
    if !thumbnail {
      let side: CGFloat = 32
      image.draw(
        in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      return
    }
    // Fill a 34 × 26 rounded box, cropping the long side.
    let box = NSRect(x: 0, y: (bounds.height - 26) / 2, width: 34, height: 26)
    let size = image.size
    guard size.width > 0, size.height > 0 else { return }
    let scale = max(box.width / size.width, box.height / size.height)
    let crop = NSSize(width: box.width / scale, height: box.height / scale)
    let source = NSRect(
      x: (size.width - crop.width) / 2, y: (size.height - crop.height) / 2, width: crop.width,
      height: crop.height)
    let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    image.draw(
      in: box, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    ContentInk.card.setStroke()
    shape.lineWidth = 0.5
    shape.stroke()
  }
}
