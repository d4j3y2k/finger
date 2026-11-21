import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum Paper {
  static let desk = NSColor(rgb: 0xF0EFE7)
  static let sheet = NSColor(rgb: 0xFCFBF5)
  static let ink = NSColor(rgb: 0x252921)
  static let muted = NSColor(rgb: 0x5E6358)
  static let line = NSColor(rgb: 0xCBCDC1)
  static let mat = NSColor(rgb: 0xDDE0D4)
  static let green = NSColor(rgb: 0x465E2C)

  static func serif(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .medium)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
      ?? base
  }
}

/// Draw the two tinted controls explicitly so the key and inactive window use
/// the same foreground/background contrast. AppKit still owns input and AX.
final class WorktableButton: NSButton {
  let primary: Bool
  var picked = false { didSet { needsDisplay = true } }

  init(_ title: String, primary: Bool = false) {
    self.primary = primary
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    setButtonType(.momentaryChange)
    font = primary ? .systemFont(ofSize: 13, weight: .semibold) : mono(10, .semibold)
    focusRingType = .exterior
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    let background = primary ? Ink.lime : (picked ? Paper.green : Paper.mat)
    let tone = primary ? Ink.onSelection : (picked ? NSColor.white : Paper.ink)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.45)
    let box = bounds.insetBy(dx: 1, dy: 1)
    let radius: CGFloat = primary ? 7 : 5
    (isHighlighted ? background.blended(withFraction: 0.18, of: .black) ?? background : background)
      .setFill()
    NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
    let text = (primary ? title + "  ↗" : (picked ? "✓ " : "") + title) as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: tone]
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2)),
      withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// A card represents real files. Its mat uses a bounded, local rendering of the primary file.
private final class WorktableArt: Flipped {
  private static let workers: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Finger worktable previews"
    queue.maxConcurrentOperationCount = 3
    queue.qualityOfService = .userInitiated
    return queue
  }()
  private let picture = NSImageView()
  private let sheet = Flipped(color: Paper.sheet)
  private let excerpt = label("", Paper.serif(16), Paper.ink)
  private let fallback = NSImageView()
  private let kind: NSTextField
  private var job: BlockOperation?
  private var request: QLThumbnailGenerator.Request?

  init(file: Entry) {
    kind = label(file.ext.uppercased(), mono(10, .medium), Paper.muted)
    super.init(color: Paper.mat)
    layer?.masksToBounds = true
    picture.imageScaling = .scaleProportionallyUpOrDown
    excerpt.maximumNumberOfLines = 0
    excerpt.cell?.usesSingleLineMode = false
    excerpt.cell?.wraps = true
    excerpt.lineBreakMode = .byWordWrapping
    excerpt.cell?.truncatesLastVisibleLine = false
    sheet.layer?.masksToBounds = true
    kind.alignment = .center
    fallback.image = symbol("doc", 32)
    fallback.contentTintColor = Paper.muted
    fallback.imageScaling = .scaleProportionallyUpOrDown
    sheet.isHidden = true
    sheet.addSubview(excerpt)
    for view in [fallback, kind, picture, sheet] { addSubview(view) }
    setAccessibilityElement(false)
    let job = BlockOperation()
    self.job = job
    job.addExecutionBlock { [weak self, weak job] in
      guard job?.isCancelled == false, ThumbnailFile.cacheKey(for: file.url, pixels: 960) != nil
      else { return }
      let preview = WorktablePreview.read(file)
      guard job?.isCancelled == false else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch preview {
        case .image(let bitmap):
          setImage(bitmap)
        case .text(let sample):
          excerpt.stringValue = sample
          sheet.isHidden = false
          fallback.isHidden = true
          kind.isHidden = true
        case .thumbnail:
          let request = QLThumbnailGenerator.Request(
            fileAt: file.url, size: NSSize(width: 480, height: 360),
            scale: 2, representationTypes: .thumbnail)
          self.request = request
          QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] reply, _ in
            DispatchQueue.main.async {
              if let bitmap = reply?.cgImage { self?.setImage(bitmap) }
              self?.request = nil
            }
          }
        }
      }
    }
    Self.workers.addOperation(job)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit {
    job?.cancel()
    if let request { QLThumbnailGenerator.shared.cancel(request) }
  }
  private func setImage(_ bitmap: CGImage) {
    picture.image = NSImage(
      cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    fallback.isHidden = true
    kind.isHidden = true
  }
  override func layout() {
    super.layout()
    let pad = min(22, min(bounds.width, bounds.height) * 0.09)
    picture.frame = bounds.insetBy(dx: pad, dy: pad)
    let paperWidth = min(bounds.width - 2 * pad, (bounds.height - 2 * pad) * 0.82)
    position(sheet, (bounds.width - paperWidth) / 2, pad, paperWidth, bounds.height - 2 * pad)
    let inset = max(8, min(18, paperWidth * 0.10))
    excerpt.font = Paper.serif(max(10, min(18, paperWidth * 0.091)))
    position(excerpt, inset, inset, paperWidth - 2 * inset, sheet.bounds.height - 2 * inset)
    position(fallback, bounds.midX - 17, bounds.midY - 24, 34, 34)
    position(kind, 4, bounds.midY + 14, bounds.width - 8, 17)
  }
}

final class WorktableCard: Flipped {
  let group: ResumeGroup
  private let art: WorktableArt
  private let titleField: NSTextField
  private let folder: NSTextField
  private let reason: NSTextField
  private let reasonMark = NSImageView()
  private var chips: [WorktableButton] = []
  private let choose: ([Entry], Bool) -> Void
  private let preview: () -> Void
  var compact = false { didSet { if compact != oldValue { needsLayout = true } } }

  init(
    _ group: ResumeGroup, choose: @escaping ([Entry], Bool) -> Void, preview: @escaping () -> Void
  ) {
    self.group = group
    self.choose = choose
    self.preview = preview
    art = WorktableArt(file: group.primary)
    let name = group.primary.url.deletingPathExtension().lastPathComponent
    titleField = label(name.isEmpty ? group.primary.name : name, font(24, .bold), Paper.ink)
    folder = label(group.relativeFolder, mono(10.5), Paper.muted)
    reason = label(group.reason, font(12, .medium), Paper.green)
    super.init(color: Paper.sheet)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = true
    layer?.borderColor = Paper.line.cgColor
    layer?.borderWidth = 1
    reasonMark.image = symbol(
      group.changed ? "sparkle" : (group.files.count > 1 ? "link" : "clock"), 12, .semibold)
    reasonMark.contentTintColor = Paper.green
    for view in [art, folder, titleField, reasonMark, reason] { addSubview(view) }
    for (index, file) in group.files.enumerated() {
      let chip = WorktableButton(file.ext.isEmpty ? "File" : file.ext.uppercased())
      chip.tag = index
      chip.target = self
      chip.action = #selector(chooseFile(_:))
      chip.setAccessibilityLabel("Select " + file.name)
      chip.setAccessibilityIdentifier(file.path)
      chip.toolTip = file.path + "\nCommand-click to add or remove this file."
      addSubview(chip)
      chips.append(chip)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(group.files.map(\.name).joined(separator: ", "))
    setAccessibilityHelp("Select these files. Double-click to preview.")
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "Select files") { [weak self] in
        guard let self else { return false }
        self.choose(self.group.files, false)
        return true
      }
    ])
    reason.toolTip = group.reason
    folder.toolTip = group.primary.url.deletingLastPathComponent().path
    toolTip = group.files.map(\.name).joined(separator: " + ")
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return (hit as? NSButton) ?? self
  }
  override func mouseDown(with event: NSEvent) {
    choose(group.files, event.modifierFlags.contains(.command))
    if event.clickCount == 2 { preview() }
  }
  @objc private func chooseFile(_ sender: NSButton) {
    choose([group.files[sender.tag]], NSApp.currentEvent?.modifierFlags.contains(.command) == true)
  }
  func updateSelection(_ paths: Set<String>) {
    let active = group.files.contains { paths.contains($0.path) }
    layer?.borderColor = active ? Paper.green.cgColor : Paper.line.cgColor
    layer?.borderWidth = active ? 2 : 1
    for (index, chip) in chips.enumerated() {
      let selected = paths.contains(group.files[index].path)
      chip.picked = selected
      chip.setAccessibilityValue(selected ? 1 : 0)
    }
  }
  override func layout() {
    super.layout()
    let w = bounds.width
    let h = bounds.height
    let horizontal = compact && w >= 320
    let artWidth = horizontal ? floor(w * 0.40) : w - 4
    let artHeight = horizontal ? h - 4 : h - 116
    position(art, 2, 2, artWidth, artHeight)
    let left: CGFloat = horizontal ? artWidth + 17 : 18
    let top: CGFloat = horizontal ? max(12, (h - 108) / 2) : artHeight + 12
    let textWidth = max(0, w - left - 14)
    titleField.font = font(horizontal ? 19 : 23, .semibold)
    position(folder, left, top, textWidth, 17)
    position(titleField, left, top + 19, textWidth, 29)
    position(reasonMark, left + 1, top + 53, 12, 13)
    position(reason, left + 18, top + 50, textWidth - 18, 20)
    var x = left
    for chip in chips {
      let width = max(
        43,
        ceil((chip.title as NSString).size(withAttributes: [.font: mono(10, .semibold)]).width) + 24
      )
      chip.isHidden = x + width > w - 8
      position(chip, x, top + 75, width, 21)
      x += width + 5
    }
  }
}
