import AppKit
import QuickLookThumbnailing

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
