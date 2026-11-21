import AppKit

/// Keeps the immediate parent in reach even when a deeply nested path no longer fits.
final class PathBar: Flipped {
  private var ancestors: [(name: String, path: String)] = []
  private var buttons: [NSButton] = []
  private let overflow = NSButton()
  private let group = label("Collections", mono(10.5), Ink.quiet)
  private var hiddenCount = 0
  private var currentFolder: String?
  var navigate: ((String) -> Void)?

  override init(color: NSColor? = nil) {
    super.init(color: color)
    configure(overflow, title: "…")
    overflow.action = #selector(openAncestors)
    overflow.toolTip = "Show enclosing folders"
    overflow.setAccessibilityLabel("Show enclosing folders")
    addSubview(overflow)
    addSubview(group)
    for _ in 0..<3 {
      let button = NSButton()
      configure(button, title: "")
      button.action = #selector(choose(_:))
      button.isHidden = true
      addSubview(button)
      buttons.append(button)
    }
    setAccessibilityLabel("Enclosing folders")
  }
  required init?(coder: NSCoder) { fatalError() }

  private func configure(_ button: NSButton, title: String) {
    button.title = title
    button.font = mono(10.5, .medium)
    button.isBordered = false
    button.bezelStyle = .inline
    button.contentTintColor = Ink.quiet
    button.alignment = .left
    button.focusRingType = .none
    button.target = self
    button.lineBreakMode = .byTruncatingMiddle
  }
  func set(folder: String?) {
    guard folder != currentFolder else { return }
    currentFolder = folder
    ancestors.removeAll(keepingCapacity: true)
    group.isHidden = folder != nil
    guard let folder else {
      overflow.isHidden = true
      needsLayout = true
      return
    }
    var path = (folder as NSString).deletingLastPathComponent
    if path.isEmpty { path = "/" }
    let home = NSHomeDirectory()
    while !path.isEmpty {
      let title = path == home ? "~" : path == "/" ? "/" : (path as NSString).lastPathComponent
      ancestors.append((title, path))
      if path == "/" || path == home { break }
      let next = (path as NSString).deletingLastPathComponent
      if next == path { break }
      path = next
    }
    ancestors.reverse()
    needsLayout = true
    needsDisplay = true
  }
  private func width(_ name: String) -> CGFloat {
    min(
      155,
      max(
        14,
        ceil((name as NSString).size(withAttributes: [.font: buttons[0].font ?? mono(10.5)]).width)
          + 3))
  }
  override func layout() {
    super.layout()
    group.frame = bounds
    guard !ancestors.isEmpty else {
      overflow.isHidden = true
      for button in buttons { button.isHidden = true }
      return
    }
    let gap: CGFloat = 15
    var start = ancestors.count - 1
    var used = width(ancestors[start].name)
    while start > 0 && ancestors.count - start < buttons.count
      && used + width(ancestors[start - 1].name) + gap + (start > 1 ? 30 : 0) <= bounds.width
    {
      start -= 1
      used += width(ancestors[start].name) + gap
    }
    hiddenCount = start
    overflow.isHidden = start == 0
    position(overflow, 0, 0, 18, bounds.height)
    var x: CGFloat = start == 0 ? 0 : 27
    for (slot, button) in buttons.enumerated() {
      let index = start + slot
      guard ancestors.indices.contains(index) else {
        button.isHidden = true
        continue
      }
      let item = ancestors[index]
      button.isHidden = false
      button.tag = index
      if button.title != item.name {
        button.title = item.name
        button.setAccessibilityLabel("Go to " + item.name)
      }
      if button.toolTip != item.path { button.toolTip = item.path }
      let w = min(width(item.name), max(10, bounds.width - x))
      position(button, x, 0, w, bounds.height)
      x += w + gap
    }
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !ancestors.isEmpty else { return }
    Ink.faint.setStroke()
    for i in buttons.indices where !buttons[i].isHidden && (i > 0 || hiddenCount > 0) {
      let x = buttons[i].frame.minX - 10
      let y = bounds.midY
      let p = NSBezierPath()
      p.lineWidth = 1
      p.move(to: NSPoint(x: x, y: y - 2.5))
      p.line(to: NSPoint(x: x + 2.5, y: y))
      p.line(to: NSPoint(x: x, y: y + 2.5))
      p.stroke()
    }
  }
  @objc private func choose(_ sender: NSButton) {
    if ancestors.indices.contains(sender.tag) { navigate?(ancestors[sender.tag].path) }
  }
  @objc private func openAncestors() {
    let menu = NSMenu()
    for item in ancestors.prefix(hiddenCount).reversed() {
      menu.addItem(
        CommandItem(
          item.name
            + (item.path == "/"
              ? "" : "  —  " + (item.path as NSString).abbreviatingWithTildeInPath)
        ) { [weak self] in self?.navigate?(item.path) })
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height), in: overflow)
  }
}
