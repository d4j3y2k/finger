import AppKit
import Quartz

/// Receives the panel's keys before the search field does, and Quick Look control.
protocol PanelKeyHandler: AnyObject {
  func handleKey(_ event: NSEvent) -> Bool
  func beginQuickLook(_ panel: QLPreviewPanel)
  func endQuickLook(_ panel: QLPreviewPanel)
}

/// A borderless, non-activating floating panel, like Spotlight. It takes key
/// focus without bringing Finger to the front.
final class FingerPanel: NSPanel {
  static let size = NSSize(width: 820, height: 500)
  static let radius: CGFloat = 24
  weak var keys: PanelKeyHandler?

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: FingerPanel.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    setAccessibilityLabel("Search")
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // Key equivalents reach the main menu before sendEvent. Claim the panel's
  // own Command keys first so the browser's menu items (⌘↑, ⌘↓, ⌘↩) stay out.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, let keys, keys.handleKey(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let keys, keys.handleKey(event) { return }
    super.sendEvent(event)
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { keys != nil }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { keys?.beginQuickLook(panel) }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { keys?.endQuickLook(panel) }

  /// Centered on the screen with the pointer, in its upper third.
  func placeOnPointerScreen() {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        ?? NSScreen.main
    else { return }
    let visible = screen.visibleFrame
    let width = min(FingerPanel.size.width, visible.width - 32)
    let height = min(FingerPanel.size.height, visible.height - 32)
    let top = visible.maxY - visible.height * 0.16
    let y = max(visible.minY + 16, top - height)
    setFrame(
      NSRect(x: (visible.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height),
      display: false)
  }
}

/// The system material behind the panel: Liquid Glass on macOS 26, otherwise
/// a behind-window visual effect with the same rounded corners.
enum PanelMaterial {
  static func wrap(_ content: NSView) -> NSView {
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.cornerRadius = FingerPanel.radius
      glass.style = .regular
      content.autoresizingMask = [.width, .height]
      glass.contentView = content
      return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = roundedMask(FingerPanel.radius)
    content.frame = effect.bounds
    content.autoresizingMask = [.width, .height]
    effect.addSubview(content)
    return effect
  }

  static func roundedMask(_ radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
