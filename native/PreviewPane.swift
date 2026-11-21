import AppKit
import Darwin
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// The preview and the main browser have independent scroll positions. Entering
// a preview child hands its URL back to the browser's normal navigation code.
final class PreviewPane: NSView {
  var engine: Engine?
  var onOpen: ((URL) -> Void)?
  var onReveal: ((URL) -> Void)?

  private let eyebrow = pLabel("", size: 10, weight: .semibold, color: Ink.lime, mono: true)
  private let name = pLabel("", size: 27, weight: .semibold, color: Ink.text)
  private let subtitle = pLabel("", size: 12, color: Ink.quiet)
  private let openButton = NSButton()
  private let nameMenu = NSMenu()
  private let divider = NSBox()
  private let scroll = NSScrollView()
  private let page = PreviewPage()
  private let readers = PreviewPane.queue("Finger inspector reads", limit: 2)
  private let decoders = PreviewPane.queue("Finger inspector artwork", limit: 3)
  private static func queue(_ name: String, limit: Int) -> OperationQueue {
    let queue = OperationQueue()
    queue.name = name
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = limit
    return queue
  }
  private let bitmapCache: NSCache<NSString, PreviewBitmap> = {
    let cache = NSCache<NSString, PreviewBitmap>()
    cache.totalCostLimit = 48 * 1_024 * 1_024
    return cache
  }()
  private var requests: [QLThumbnailGenerator.Request] = []
  private var rowPool: [PreviewActionLine] = []
  private var ticket = FileReadTicket()
  private var selectedURL: URL?
  private var selectedOrder: FileOrder = .nameAsc
  private var selectedHidden = false
  private let observation = FolderWatcher()
  private var refreshWork: DispatchWorkItem?
  private var readInProgress = false
  private var changePending = false
  private var readyToRememberScroll = false
  private var scrollHistory: [(url: URL, order: FileOrder, offset: CGFloat)] = []

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = Ink.well.cgColor
    name.maximumNumberOfLines = 2
    name.cell?.usesSingleLineMode = false
    name.cell?.wraps = true
    name.cell?.isScrollable = false
    name.lineBreakMode = .byWordWrapping
    name.cell?.truncatesLastVisibleLine = true
    name.isSelectable = true
    name.focusRingType = .none
    let copyName = nameMenu.addItem(
      withTitle: "Copy Filename", action: #selector(copyFilename), keyEquivalent: "")
    copyName.target = self
    let copyPath = nameMenu.addItem(
      withTitle: "Copy Full Path", action: #selector(copyFullPath), keyEquivalent: "")
    copyPath.target = self
    divider.boxType = .custom
    divider.borderWidth = 0
    divider.fillColor = Ink.rule
    openButton.isBordered = false
    openButton.bezelStyle = .regularSquare
    openButton.imagePosition = .imageOnly
    openButton.imageScaling = .scaleProportionallyDown
    openButton.contentTintColor = Ink.text
    openButton.target = self
    openButton.action = #selector(openSelection)
    openButton.focusRingType = .exterior
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = page
    for view in [eyebrow, name, subtitle, openButton, divider, scroll] { addSubview(view) }
    setAccessibilityRole(.group)
    setAccessibilityLabel("Preview")
    show(urls: [])
  }
  required init?(coder: NSCoder) { fatalError("PreviewPane uses programmatic layout") }

  override func layout() {
    super.layout()
    let w = bounds.width
    let pad: CGFloat = w < 350 ? 16 : 22
    eyebrow.frame = NSRect(x: pad, y: 20, width: max(1, w - 2 * pad - 32), height: 16)
    openButton.frame = NSRect(x: max(0, w - pad - 30), y: 13, width: 34, height: 30)
    let titleWidth = max(1, w - 2 * pad)
    let titleFont = name.font ?? .systemFont(ofSize: 27, weight: .semibold)
    let textWidth = (name.stringValue as NSString).size(withAttributes: [.font: titleFont]).width
    let wraps = textWidth > titleWidth - 5 || name.stringValue.contains(where: \.isNewline)
    let extra = wraps ? ceil(titleFont.ascender - titleFont.descender + titleFont.leading) : 0
    let header = 117 + extra
    name.frame = NSRect(x: pad, y: 42, width: titleWidth, height: 36 + extra)
    subtitle.frame = NSRect(x: pad, y: 85 + extra, width: titleWidth, height: 17)
    divider.frame = NSRect(x: pad, y: header - 1, width: titleWidth, height: 1)
    scroll.frame = NSRect(x: 0, y: header, width: w, height: max(0, bounds.height - header))
    page.arrange(width: scroll.contentSize.width, minimum: scroll.contentSize.height, pad: pad)
  }

  func show(
    urls: [URL], context: URL? = nil, showHidden: Bool = false, order: FileOrder = .nameAsc,
    totalSelectionCount: Int? = nil
  ) {
    let total = max(urls.count, totalSelectionCount ?? urls.count)
    if readyToRememberScroll, let selectedURL {
      scrollHistory.removeAll { $0.url == selectedURL && $0.order == selectedOrder }
      let y = scroll.contentView.bounds.origin.y
      if y > 0 {
        scrollHistory.append((selectedURL, selectedOrder, y))
        if scrollHistory.count > 96 { scrollHistory.removeFirst() }
      }
    }
    readyToRememberScroll = false
    refreshWork?.cancel()
    refreshWork = nil
    changePending = false
    readInProgress = total > 0
    let current = resetJobs()
    selectedURL = total == 1 ? urls.first : nil
    selectedOrder = order
    selectedHidden = showHidden
    scroll.contentView.scroll(to: .zero)
    page.replace([])
    openButton.isHidden = selectedURL == nil
    openButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
    openButton.toolTip = "Open"
    openButton.setAccessibilityLabel("Open selected item")
    name.toolTip = selectedURL?.path
    name.menu = selectedURL == nil ? nil : nameMenu
    subtitle.toolTip = nil
    if total == 0 {
      observation.observe(path: nil) {}
      eyebrow.stringValue = "PREVIEW"
      name.stringValue = "No selection"
      subtitle.stringValue = context?.lastPathComponent ?? ""
      page.replace([
        PreviewMessage("Select a file or folder to inspect it.", symbol: "sidebar.right")
      ])
      needsLayout = true
      return
    }
    if let url = selectedURL {
      eyebrow.stringValue = "PREVIEW"
      name.stringValue = pName(url)
      subtitle.stringValue = "Reading…"
    } else {
      eyebrow.stringValue = "SELECTION"
      name.stringValue = "\(total.formatted()) items"
      subtitle.stringValue = "Reading selection…"
    }
    needsLayout = true
    observation.observe(
      path: selectedURL?.path,
      ready: { [weak self] in
        guard let self, self.ticket === current else { return }
        self.read(urls, total: total, ticket: current, preservingScroll: false)
      }, changed: { [weak self] in self?.scheduleRefresh() })
  }

  private func resetJobs() -> FileReadTicket {
    ticket.cancel()
    readers.cancelAllOperations()
    decoders.cancelAllOperations()
    for request in requests { QLThumbnailGenerator.shared.cancel(request) }
    requests.removeAll()
    ticket = FileReadTicket()
    return ticket
  }

  private func scheduleRefresh() {
    changePending = true
    guard !readInProgress, refreshWork == nil, let url = selectedURL else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.selectedURL == url else { return }
      self.refreshWork = nil
      self.changePending = false
      let fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
      self.read([fresh], total: 1, ticket: self.resetJobs(), preservingScroll: true)
    }
    refreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func read(
    _ urls: [URL], total: Int, ticket current: FileReadTicket, preservingScroll: Bool
  ) {
    readInProgress = true
    let engine = self.engine
    let order = selectedOrder
    let hidden = selectedHidden
    readers.addOperation { [weak self] in
      if current.cancelled { return }
      let model = PreviewReader.read(
        urls, total: total, hidden: hidden, order: order, ticket: current, engine: engine)
      if current.cancelled { return }
      OperationQueue.main.addOperation { [weak self] in
        guard let self, self.ticket === current, let model else { return }
        self.readInProgress = false
        self.display(model, ticket: current, preservingScroll: preservingScroll)
        if self.changePending { self.scheduleRefresh() }
      }
    }
  }

  @objc private func openSelection() { if let selectedURL { onOpen?(selectedURL) } }
  @objc private func copyFilename() { if let selectedURL { copyText(pName(selectedURL)) } }
  @objc private func copyFullPath() { if let selectedURL { copyText(selectedURL.path) } }
  private func copyText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func display(_ model: PreviewModel, ticket: FileReadTicket, preservingScroll: Bool) {
    let offset =
      preservingScroll
      ? scroll.contentView.bounds.origin.y
      : scrollHistory.last {
        $0.url == selectedURL && $0.order == selectedOrder
      }?.offset
    var sections: [PreviewBlock] = []
    switch model {
    case .folder(let folder):
      eyebrow.stringValue = folder.linkTarget == nil ? "FOLDER PREVIEW" : "LINKED FOLDER"
      subtitle.stringValue = [pCount(folder.total, "item"), folder.linkTarget].compactMap { $0 }
        .joined(separator: "  ·  ")
      subtitle.toolTip = folder.linkTarget
      openButton.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
      openButton.toolTip = "Enter folder (→)"
      openButton.setAccessibilityLabel("Enter folder")
      if !folder.media.isEmpty {
        sections.append(makeStrip(folder.media, ticket: ticket, draggable: true))
      }
      if folder.total == 0 {
        sections.append(PreviewMessage("This folder is empty.", symbol: "folder"))
      } else {
        sections.append(PreviewSection("CONTENTS"))
        sections += makeRows(folder.rows, draggable: true)
        if folder.total > folder.rows.count {
          let remaining = folder.total - folder.rows.count
          sections.append(
            PreviewActionLine(
              "See all \(folder.total.formatted()) items",
              detail: "\(remaining.formatted()) more", symbol: "arrow.right.circle"
            ) { [weak self] in self?.openSelection() })
        }
      }
    case .file(let file):
      eyebrow.stringValue =
        file.isLink ? "SYMBOLIC LINK" : file.isBundle ? "BUNDLE PREVIEW" : "FILE PREVIEW"
      subtitle.stringValue = [file.typeName, file.bytes.map(pBytes)].compactMap { $0 }.joined(
        separator: "  ·  ")
      let hero = PreviewHero(
        symbol: pSymbol(file.url, directory: false), description: pName(file.url))
      if let message = file.message {
        sections.append(PreviewMessage(message, symbol: file.isLink ? "link" : "doc"))
      } else if let text = file.text {
        if text.isEmpty {
          sections.append(PreviewMessage("This file is empty.", symbol: "doc.text"))
        } else {
          sections.append(PreviewText(text))
          if file.textIsPrefix {
            sections.append(PreviewSmallNote("Showing the beginning of the file"))
          }
        }
      } else {
        sections.append(hero)
        if file.isBundle {
          hero.setBitmap(PreviewBitmap(NSWorkspace.shared.icon(forFile: file.url.path)))
        } else {
          thumbnail(file.url, pixels: 1400, ticket: ticket, bypassCache: preservingScroll) {
            bitmap in
            if let bitmap { hero.setBitmap(bitmap) } else { hero.missingPreview() }
          }
        }
      }
      sections.append(PreviewSection("DETAILS"))
      if let version = file.version { sections.append(PreviewDetail("Version", version)) }
      if let pages = file.pages { sections.append(PreviewDetail("Pages", pages.formatted())) }
      if let artboard = file.artboard { sections.append(PreviewDetail("Artboard", artboard)) }
      if let dimensions = file.dimensions {
        sections.append(PreviewDetail("Dimensions", "\(dimensions.0) × \(dimensions.1) px"))
      }
      if let date = file.modified {
        sections.append(
          PreviewDetail("Modified", date.formatted(date: .abbreviated, time: .shortened)))
      }
      sections.append(
        PreviewDetail(
          "Location",
          (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
    case .multiple(let total, let bytes, let rows, let media):
      subtitle.stringValue =
        bytes.map { "\(pBytes($0)) across selected files" } ?? "Selected files and folders"
      if !media.isEmpty { sections.append(makeStrip(media, ticket: ticket)) }
      sections.append(PreviewSection("SELECTED ITEMS"))
      sections += makeRows(rows)
      if total > rows.count {
        sections.append(PreviewSmallNote("And \((total - rows.count).formatted()) more"))
      }
    case .error(let error):
      eyebrow.stringValue = "PREVIEW"
      subtitle.stringValue = "Preview unavailable"
      sections.append(PreviewMessage(error, symbol: "exclamationmark.triangle"))
    }
    page.replace(sections)
    needsLayout = true
    layoutSubtreeIfNeeded()
    if let offset {
      let clip = scroll.contentView
      let desired = NSRect(origin: NSPoint(x: 0, y: offset), size: clip.bounds.size)
      clip.scroll(to: clip.constrainBoundsRect(desired).origin)
      scroll.reflectScrolledClipView(clip)
    }
    readyToRememberScroll = true
  }

  private func makeRows(_ items: [PreviewEntry], draggable: Bool = false) -> [PreviewBlock] {
    // The same few rows serve every folder. Reusing their native controls
    // keeps rapid arrow-key browsing from rebuilding a large layer tree.
    while rowPool.count < items.count { rowPool.append(PreviewActionLine()) }
    return items.enumerated().map { index, entry in
      let row = rowPool[index]
      row.configure(
        entry.name, detail: entry.directory ? "" : entry.bytes.map(pBytes) ?? "",
        symbol: pSymbol(entry.url, directory: entry.directory), folder: entry.directory,
        open: { [weak self] in self?.onOpen?(entry.url) },
        action: { [weak self] in self?.onReveal?(entry.url) })
      row.dragURL = draggable ? entry.url : nil
      row.toolTip = entry.url.path + (draggable ? "\nDrag to a folder." : "")
      return row
    }
  }

  private func makeStrip(_ entries: [PreviewEntry], ticket: FileReadTicket, draggable: Bool = false)
    -> PreviewStrip
  {
    let strip = PreviewStrip(entries) { [weak self] url in self?.onReveal?(url) }
    for (index, entry) in entries.enumerated() {
      strip.cards[index].open = { [weak self] in self?.onOpen?(entry.url) }
      if draggable {
        strip.cards[index].dragURL = entry.url
        strip.cards[index].toolTip = entry.name + "\nDrag to a folder."
      }
      thumbnail(entry.url, pixels: entries.count == 1 ? 760 : 460, ticket: ticket) { bitmap in
        if let bitmap { strip.cards[index].setBitmap(bitmap) }
      }
    }
    return strip
  }

  private func thumbnail(
    _ url: URL, pixels: Int, ticket: FileReadTicket, bypassCache: Bool = false,
    completion: @escaping (PreviewBitmap?) -> Void
  ) {
    let cache = bitmapCache
    decoders.addOperation { [weak self] in
      guard !ticket.cancelled else { return }
      guard let key = ThumbnailFile.cacheKey(for: url, pixels: pixels) else {
        OperationQueue.main.addOperation { if !ticket.cancelled { completion(nil) } }
        return
      }
      if !bypassCache, let cached = cache.object(forKey: key) {
        OperationQueue.main.addOperation { if !ticket.cancelled { completion(cached) } }
        return
      }
      let image = PreviewReader.raster(url, pixels: pixels)
      guard !ticket.cancelled else { return }
      OperationQueue.main.addOperation { [weak self] in
        guard let self, self.ticket === ticket else { return }
        if let image {
          let bitmap = PreviewBitmap(image)
          cache.setObject(bitmap, forKey: key, cost: image.bytesPerRow * image.height)
          completion(bitmap)
          return
        }
        let edge = CGFloat(pixels) / 2
        let request = QLThumbnailGenerator.Request(
          fileAt: url, size: NSSize(width: edge, height: edge),
          scale: 2, representationTypes: .thumbnail)
        self.requests.append(request)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { reply, _ in
          OperationQueue.main.addOperation { [weak self] in
            guard let self, self.ticket === ticket else { return }
            self.requests.removeAll { $0 === request }
            guard let image = reply?.cgImage else {
              completion(nil)
              return
            }
            let bitmap = PreviewBitmap(image)
            cache.setObject(bitmap, forKey: key, cost: image.bytesPerRow * image.height)
            completion(bitmap)
          }
        }
      }
    }
  }
}

// MARK: - Reading bounded previews

private struct PreviewEntry {
  let url: URL
  let name: String
  let directory: Bool
  var bytes: Int?
  var isMedia: Bool {
    !directory && PreviewReader.mediaExtensions.contains(url.pathExtension.lowercased())
  }
}
private struct PreviewFolder {
  let rows: [PreviewEntry]
  let media: [PreviewEntry]
  let total: Int
  let linkTarget: String?
}
private struct PreviewFile {
  let url: URL
  let typeName: String
  let bytes: Int?
  let modified: Date?
  var dimensions: (Int, Int)?
  var pages: Int?
  var artboard: String?
  var text: String?
  var textIsPrefix = false
  var message: String?
  var isBundle = false
  var version: String?
  var isLink = false
}
private enum PreviewModel {
  case folder(PreviewFolder)
  case file(PreviewFile)
  case multiple(Int, Int?, [PreviewEntry], [PreviewEntry])
  case error(String)
}
private enum PreviewReader {
  static let mediaExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp", "webp", "svg", "pdf",
    "psd", "mov", "mp4", "m4v",
  ]
  private static let plainExtensions: Set<String> = [
    "rs", "py", "js", "jsx", "ts", "tsx", "css", "scss", "html", "md", "markdown", "rst", "toml",
    "yaml", "yml", "json", "jsonl", "xml", "ini", "conf", "cfg", "env", "sh", "zsh", "bash", "fish",
    "c", "h", "cpp", "hpp", "swift", "java", "kt", "go", "rb", "php", "sql", "tex", "log", "txt",
    "csv", "tsv", "gitignore", "lock",
  ]
  private static let fileKeys: Set<URLResourceKey> = [
    .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
    .contentModificationDateKey, .contentTypeKey, .isPackageKey,
    .ubiquitousItemDownloadingStatusKey,
  ]

  static func read(
    _ urls: [URL], total: Int, hidden: Bool, order: FileOrder, ticket: FileReadTicket,
    engine: Engine?
  ) -> PreviewModel? {
    if total > 1 {
      var rows: [PreviewEntry] = []
      var bytes: Int? = total == urls.count && total <= 128 ? 0 : nil
      for (index, url) in urls.prefix(128).enumerated() {
        if ticket.cancelled { return nil }
        if bytes == nil && index >= 32 { break }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
        if index < 32 {
          rows.append(
            PreviewEntry(
              url: url, name: pName(url), directory: v?.isDirectory == true, bytes: v?.fileSize))
        }
        if let total = bytes, v?.isRegularFile == true, let size = v?.fileSize,
          total <= Int.max - size
        {
          bytes = total + size
        } else {
          bytes = nil
        }
      }
      return .multiple(total, bytes, rows, Array(rows.filter(\.isMedia).prefix(3)))
    }
    guard let url = urls.first else { return nil }
    do {
      let v = try url.resourceValues(forKeys: fileKeys)
      if v.isSymbolicLink == true {
        var targetIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &targetIsDirectory),
          targetIsDirectory.boolValue
        {
          let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
          return try readFolder(
            url, hidden: hidden, order: order, engine: engine, ticket: ticket, linkTarget: target)
        }
      }
      if v.isDirectory == true && v.isSymbolicLink != true {
        if v.isPackage == true {
          var file = PreviewFile(
            url: url, typeName: v.contentType?.localizedDescription ?? "Bundle",
            bytes: nil, modified: v.contentModificationDate)
          file.isBundle = ["app", "bundle", "framework", "appex", "plugin", "kext", "prefpane"]
            .contains(url.pathExtension.lowercased())
          if file.isBundle {
            file.version =
              Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
              as? String
          }
          return .file(file)
        }
        return try readFolder(url, hidden: hidden, order: order, engine: engine, ticket: ticket)
      }
      let ext = url.pathExtension.lowercased()
      let type = v.contentType ?? UTType(filenameExtension: ext)
      let kind =
        v.isSymbolicLink == true
        ? "Symbolic link"
        : type?.localizedDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " file")
      var file = PreviewFile(
        url: url, typeName: kind, bytes: v.fileSize, modified: v.contentModificationDate)
      if v.isSymbolicLink == true {
        file.isLink = true
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        file.message = "Points to \(target)"
      } else if v.isRegularFile != true {
        file.message = "Contents are unavailable for this type of item."
      } else if v.ubiquitousItemDownloadingStatus == .notDownloaded {
        file.message = "Download this file to preview its contents."
      } else if v.fileSize == 0 {
        file.message = "This file is empty."
      } else if ext == "svg" {
        if let prefix = try? readText(url) { file.artboard = SVGViewport.read(prefix.text) }
      } else if type?.conforms(to: .pdf) == true {
        if let pdf = CGPDFDocument(url as CFURL) {
          if pdf.isEncrypted && !pdf.isUnlocked {
            file.message = "This PDF requires a password."
          } else {
            file.pages = pdf.numberOfPages
          }
        }
      } else if type?.conforms(to: .image) == true {
        file.dimensions = imageDimensions(url)
      } else if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
        || plainExtensions.contains(ext) || ext.isEmpty
      {
        // Read only a finite prefix, even if a file changes under us.
        if let preview = try readText(url) {
          file.text = preview.text
          file.textIsPrefix = preview.partial
        }
      }
      return .file(file)
    } catch { return .error(error.localizedDescription) }
  }

  private static func readFolder(
    _ url: URL, hidden: Bool, order: FileOrder, engine: Engine?, ticket: FileReadTicket,
    linkTarget: String? = nil
  ) throws -> PreviewModel {
    struct Reply: Decodable {
      let ok: Bool
      let entries: [Entry]?
      let media: [Entry]?
      let total: Int?
      let error: String?
    }
    guard let engine else { return .error("The folder reader is unavailable.") }
    let data = try engine.folderPreview(url.path, showHidden: hidden, order: order, ticket: ticket)
    let reply = try JSONDecoder().decode(Reply.self, from: data)
    guard reply.ok, let entries = reply.entries, let media = reply.media, let total = reply.total
    else {
      return .error(reply.error ?? "Couldn’t read this folder.")
    }
    func item(_ entry: Entry) -> PreviewEntry {
      PreviewEntry(
        url: entry.url, name: entry.name, directory: entry.isDirectory,
        bytes: entry.size.flatMap(Int.init(exactly:)))
    }
    return .folder(
      PreviewFolder(
        rows: entries.map(item), media: media.map(item), total: total, linkTarget: linkTarget))
  }

  fileprivate static func readText(_ url: URL) throws -> (text: String, partial: Bool)? {
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var attributes = stat()
    guard fstat(fd, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG else { return nil }
    let limit = 12_288
    var buffer = [UInt8](repeating: 0, count: limit + 1)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var bytes = Array(buffer.prefix(min(count, limit)))
    // A newline-only file can otherwise produce a native text surface
    // hundreds of thousands of points tall from a small byte prefix.
    func bounded(_ text: String) -> (text: String, partial: Bool) {
      var lines = 0
      for index in text.indices where text[index].isNewline {
        lines += 1
        if lines == 160, text.index(after: index) < text.endIndex {
          return (String(text[...index]), true)
        }
      }
      return (text, count > limit)
    }
    if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
      if let text = String(data: Data(bytes), encoding: .utf16) { return bounded(text) }
      // The byte limit can cut a surrogate pair between its two code units.
      if count > limit, let text = String(data: Data(bytes.dropLast(2)), encoding: .utf16) {
        return bounded(text)
      }
      return nil
    }
    guard !bytes.contains(0) else { return nil }
    // A bounded read may split a UTF-8 scalar at the end.
    for _ in 0..<4 {
      if let text = String(bytes: bytes, encoding: .utf8) { return bounded(text) }
      if count <= limit || bytes.isEmpty { break }
      bytes.removeLast()
    }
    return nil
  }

  static func raster(_ url: URL, pixels: Int) -> CGImage? {
    let ext = url.pathExtension.lowercased()
    guard ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .image) == true else {
      return nil
    }
    guard
      let src = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
  }

  private static func imageDimensions(_ url: URL) -> (Int, Int)? {
    guard
      let src = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = info[kCGImagePropertyPixelWidth] as? Int,
      let h = info[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = info[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? (h, w) : (w, h)
  }
}

// Parse only the root element of the bounded SVG text sample. A viewBox
// remains meaningful for vector sources whose width and height are relative.
private final class SVGViewport: NSObject, XMLParserDelegate {
  private var result: String?
  static func read(_ prefix: String) -> String? {
    let delegate = SVGViewport()
    let parser = XMLParser(data: Data(prefix.utf8))
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.result
  }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    defer { parser.abortParsing() }
    guard elementName.split(separator: ":").last == "svg" else { return }
    if let width = attributes["width"], let height = attributes["height"],
      !width.contains("%"), !height.contains("%"), width.count <= 24, height.count <= 24
    {
      result = width + " × " + height
    } else if let box = attributes["viewBox"] {
      let parts = box.split { $0.isWhitespace || $0 == "," }
      if parts.count == 4, parts.allSatisfy({ Double($0)?.isFinite == true && $0.count <= 24 }) {
        result = String(parts[2]) + " × " + String(parts[3])
      }
    }
  }
}

// MARK: - Inspector layout

private func pLabel(
  _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
  color: NSColor = Ink.text, mono: Bool = false
) -> NSTextField {
  let type: NSFont =
    mono
    ? .monospacedSystemFont(ofSize: size, weight: weight)
    : .systemFont(ofSize: size, weight: weight)
  return label(text, type, color)
}

private func pName(_ url: URL) -> String {
  url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
}
private let previewByteFormatter: ByteCountFormatter = {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  return formatter
}()
private func pBytes(_ value: Int) -> String {
  if value < 1_000 { return "\(value) \(value == 1 ? "byte" : "bytes")" }
  return previewByteFormatter.string(fromByteCount: Int64(value))
}
private func pCount(_ value: Int, _ unit: String) -> String {
  "\(value.formatted()) \(unit)\(value == 1 ? "" : "s")"
}

private func pSymbol(_ url: URL, directory: Bool) -> String {
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

private func pGlyph(_ symbol: String, color: NSColor, size: CGFloat) -> NSImageView {
  let view = NSImageView()
  view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
  view.contentTintColor = color
  view.imageScaling = .scaleProportionallyDown
  view.setAccessibilityElement(false)
  return view
}

private final class PreviewBitmap {
  let image: NSImage
  let mayHaveTransparency: Bool
  init(_ nsImage: NSImage) {
    image = nsImage
    mayHaveTransparency = false
  }
  init(_ cg: CGImage) {
    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    mayHaveTransparency = [.alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast]
      .contains(cg.alphaInfo)
  }
}

class PreviewBlock: NSView {
  override var isFlipped: Bool { true }
  func height(for width: CGFloat) -> CGFloat { 32 }
}

private final class PreviewPage: NSView {
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

private final class PreviewSection: PreviewBlock {
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

private final class PreviewSmallNote: PreviewBlock {
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

private final class PreviewDetail: PreviewBlock {
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

private final class PreviewMessage: PreviewBlock {
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

private final class PreviewActionLine: PreviewTarget {
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

private final class PreviewPicture: NSImageView {
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

private final class PreviewMat: NSView {
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

private final class PreviewHero: PreviewBlock {
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

private final class PreviewCard: PreviewTarget {
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

private final class PreviewStrip: PreviewBlock {
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

private final class PreviewText: PreviewBlock {
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

enum WorktablePreview {
  case image(CGImage), text(String), thumbnail

  static func read(_ file: Entry) -> WorktablePreview {
    if let image = PreviewReader.raster(file.url, pixels: 960) { return .image(image) }
    let type = UTType(filenameExtension: file.ext)
    if (type?.conforms(to: .text) == true || ["md", "log", "json", "yaml", "toml"].contains(file.ext)),
      let sample = try? PreviewReader.readText(file.url), !sample.text.isEmpty
    {
      return .text(String(sample.text.prefix(700)))
    }
    return .thumbnail
  }
}
