import AppKit
import ImageIO
import QuickLookThumbnailing

enum RowArt {
  static let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "Finger list thumbnails"
    q.maxConcurrentOperationCount = 3
    q.qualityOfService = .utility
    return q
  }()
  static let cache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>()
    c.countLimit = 400
    return c
  }()
  static func glyph(_ entry: Entry) -> String {
    if entry.isDirectory {
      return entry.kind == "symlink" ? "folder.badge.arrow.forward" : "folder.fill"
    }
    if entry.kind == "symlink" { return "arrow.turn.down.right" }
    if entry.kind == "missing" { return "questionmark.folder" }
    switch entry.ext {
    case "png", "jpeg", "jpg", "gif", "heic", "webp", "tif", "tiff", "avif": return "photo"
    case "svg", "ai", "eps": return "beziercurve"
    case "pdf": return "doc.richtext"
    case "wav", "aif", "aiff", "mp3", "m4a", "flac": return "waveform"
    case "mov", "mp4", "mkv": return "film"
    case "zip", "tar", "gz", "7z": return "archivebox"
    case "swift", "rs", "js", "ts", "css", "html", "json", "py", "toml", "yaml", "yml", "c", "md":
      return "chevron.left.forwardslash.chevron.right"
    case "txt", "rtf", "log", "csv": return "doc.text"
    default: return "doc"
    }
  }
}

final class FileRow: NSTableRowView {
  override var isEmphasized: Bool {
    get { true }
    set {}
  }
  override func drawSelection(in dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
    Ink.selected.setFill()
    shape.fill()
  }
  override func drawSeparator(in dirtyRect: NSRect) {
    guard !isSelected else { return }
    Ink.rule.withAlphaComponent(0.42).setFill()
    NSRect(x: 39, y: bounds.height - 1, width: max(0, bounds.width - 39), height: 0.6).fill()
  }
  override var isSelected: Bool {
    didSet { for case let cell as FileCell in subviews { cell.setSelected(isSelected) } }
  }
}

final class FileCell: NSTableCellView {
  private let icon = NSImageView()
  let filename = label("", font(14, .medium), Ink.text)
  let detail = label("", mono(10.5), Ink.quiet)
  private var origin: NSTextField?
  private var thumbnailGeneration = 0
  private var thumbnail = false
  private var selected = false
  private var directory = false
  private var order: FileOrder?
  private var glyphName = "doc"
  private static let coloredIcons = NSCache<NSString, NSImage>()
  private var thumbnailJob: Operation?
  private static let formatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
  }()
  private static let currentYearDate: DateFormatter = {
    let format = DateFormatter()
    format.setLocalizedDateFormatFromTemplate("MMMdjm")
    return format
  }()
  private static let earlierDate: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .medium
    return format
  }()
  private static let fullDate: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .full
    format.timeStyle = .medium
    return format
  }()
  static func detailWidth(for width: CGFloat, order: FileOrder?) -> CGFloat {
    if order?.isModified == true { return width >= 355 ? 112 : 0 }
    return width >= 280 ? 61 : 0
  }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(icon)
    addSubview(filename)
    addSubview(detail)
    detail.alignment = .right
    filename.lineBreakMode = .byTruncatingMiddle
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 3
    icon.layer?.masksToBounds = true
    textField = filename
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let d = Self.detailWidth(for: bounds.width, order: order)
    position(icon, 9, (bounds.height - 22) / 2, 22, 22)
    let hasOrigin = origin?.isHidden == false
    position(
      filename, 42, hasOrigin ? bounds.height - 21 : (bounds.height - 19) / 2,
      bounds.width - 53 - d, 19)
    if hasOrigin, let origin { position(origin, 42, 3, bounds.width - 53 - d, 14) }
    detail.isHidden = d == 0
    position(detail, bounds.width - d - 8, (bounds.height - 15) / 2, d, 15)
  }
  func update(_ item: Entry, selected: Bool, order: FileOrder? = .nameAsc, project: String? = nil) {
    thumbnailJob?.cancel()
    directory = item.isDirectory
    thumbnailGeneration += 1
    thumbnail = false
    filename.stringValue = item.name
    filename.toolTip = item.name
    toolTip = item.path
    var accessibilityName = item.name + (item.isDirectory ? ", folder" : "")
    if order == nil {
      let parent = (item.path as NSString).deletingLastPathComponent
      let text: String
      if let project, parent == project {
        text = (project as NSString).lastPathComponent
      } else if let project, parent.hasPrefix(project + "/") {
        text = String(parent.dropFirst(project.count + 1))
      } else {
        text = (parent as NSString).abbreviatingWithTildeInPath
      }
      if origin == nil {
        let field = label("", mono(10), Ink.quiet, "Collection source folder")
        field.lineBreakMode = .byTruncatingHead
        addSubview(field)
        origin = field
        needsLayout = true
      }
      origin?.stringValue = text.isEmpty ? "/" : text
      origin?.toolTip = parent
      origin?.isHidden = false
      accessibilityName += ", in " + parent
    } else {
      origin?.isHidden = true
    }
    if self.order != order {
      self.order = order
      needsLayout = true
    }
    if order?.isModified == true {
      if let seconds = item.modified {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let thisYear = Calendar.autoupdatingCurrent.isDate(
          date, equalTo: Date(), toGranularity: .year)
        detail.stringValue = (thisYear ? Self.currentYearDate : Self.earlierDate).string(from: date)
        detail.toolTip = Self.fullDate.string(from: date)
      } else {
        detail.stringValue = "—"
        detail.toolTip = "Date modified unavailable"
      }
    } else {
      detail.stringValue =
        item.isDirectory
        ? "›"
        : item.kind == "missing"
          ? "missing"
          : item.size.map {
            $0 < 1_000 ? String($0) + " B" : Self.formatter.string(fromByteCount: $0)
          } ?? ""
      detail.toolTip = nil
    }
    detail.font = item.isDirectory && order?.isModified != true ? font(16) : mono(10.5)
    glyphName = RowArt.glyph(item)
    setSelected(selected)
    setAccessibilityLabel(accessibilityName)
    guard !item.isDirectory,
      ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "avif"].contains(item.ext)
    else { return }
    let generation = thumbnailGeneration
    let job = BlockOperation()
    job.addExecutionBlock { [weak self, weak job] in
      guard job?.isCancelled == false,
        let key = ThumbnailFile.cacheKey(for: item.url, pixels: 56)
      else { return }
      let image: NSImage
      if let cached = RowArt.cache.object(forKey: key) {
        image = cached
      } else {
        guard job?.isCancelled == false,
          let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 56,
            ] as CFDictionary)
        else { return }
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        RowArt.cache.setObject(image, forKey: key)
      }
      DispatchQueue.main.async {
        guard let self, self.thumbnailGeneration == generation else { return }
        self.install(image)
      }
    }
    thumbnailJob = job
    RowArt.queue.addOperation(job)
  }
  private func install(_ img: NSImage) {
    thumbnail = true
    icon.contentTintColor = nil
    icon.image = img
  }
  func setSelected(_ yes: Bool) {
    selected = yes
    filename.textColor = yes ? Ink.onSelection : Ink.text
    detail.textColor = yes ? Ink.onSelection.withAlphaComponent(0.75) : Ink.quiet
    origin?.textColor = detail.textColor
    if !thumbnail {
      let color = yes ? Ink.onSelection : (directory ? Ink.lime : Ink.quiet)
      let key = (glyphName + (yes ? "-selected" : "-normal")) as NSString
      if let image = Self.coloredIcons.object(forKey: key) {
        icon.image = image
      } else if let source = symbol(glyphName, directory ? 18 : 16) {
        let image = NSImage(size: source.size, flipped: false) { rect in
          source.draw(in: rect)
          color.setFill()
          rect.fill(using: .sourceAtop)
          return true
        }
        image.isTemplate = false
        Self.coloredIcons.setObject(image, forKey: key)
        icon.image = image
      }
      icon.contentTintColor = nil
    }
  }
}

final class BrowserTable: NSTableView, FileDragSource {
  let fileDrag = FileDragCapture()
  var onCopy: ((Bool) -> Void)?
  var onPaste: (() -> Void)?
  @objc func copy(_ sender: Any?) { onCopy?(false) }
  @objc func cut(_ sender: Any?) { onCopy?(true) }
  @objc func paste(_ sender: Any?) { onPaste?() }
  var handleKey: ((NSEvent) -> Bool)?
  var context: ((Int) -> NSMenu?)?
  override func keyDown(with event: NSEvent) {
    if handleKey?(event) != true { super.keyDown(with: event) }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = self.row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    return context?(row)
  }
}
