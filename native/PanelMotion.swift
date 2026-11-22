import AppKit

/// Where things were before a move between folders, so the folder can fly
/// into its chip going in and back out going up.
struct PanelMotionSnapshot {
  var selected: String?
  var title: String
  var icon: NSImage?
  var iconFrame: NSRect?
  var chipFrames: [String: NSRect]
}

// Going into a folder, its row's icon and name glide into the new chip while
// the new list slides in from the right. Going up reverses both.
extension PanelController {
  // MARK: - Motion

  var motionOn: Bool {
    allowsMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func captureMotion() -> PanelMotionSnapshot {
    var chipFrames: [String: NSRect] = [:]
    for chip in chips.chips {
      if let path = chip.path, let rect = chips.rect(for: path) {
        chipFrames[path] = chips.convert(rect, to: root)
      }
    }
    var iconFrame: NSRect?
    if let row = selectedRow, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
      as? PanelItemCell
    {
      let visible = scroll.contentView.documentVisibleRect
      if table.rect(ofRow: row).intersects(visible) {
        iconFrame = cell.convert(cell.iconFrame, to: root)
      }
    }
    let file = selectedItem?.file
    return PanelMotionSnapshot(
      selected: file?.path, title: file.map { place.name($0.path) } ?? "",
      icon: file.map { PanelIcons.shared.icon($0.path) }, iconFrame: iconFrame,
      chipFrames: chipFrames)
  }

  /// Going in: the list slides in from the right and the folder glides into
  /// its chip. Going up reverses both.
  func runMotion(_ direction: Direction, _ snapshot: PanelMotionSnapshot, listOnly: Bool) {
    if direction == .into, !listOnly { flyIn(snapshot) }
    if direction == .up { flyOut(snapshot) }
    slide(listHost, from: direction == .into ? 44 : -44)
    fade(previewHost)
  }

  func flyIn(_ snapshot: PanelMotionSnapshot) {
    guard let entered = folder, snapshot.selected == entered, let from = snapshot.iconFrame,
      let rect = chips.rect(for: entered)
    else { return }
    let to = chips.convert(rect, to: root)
    let flyer = PanelFlyer(icon: snapshot.icon, title: snapshot.title, selected: true)
    let start = NSPoint(x: from.minX - 3, y: from.midY - PanelChipsView.height / 2)
    chips.hiddenPath = entered
    fly(flyer, from: start, to: to.origin, toChip: true) { [weak self] in
      self?.chips.hiddenPath = nil
    }
  }

  func flyOut(_ snapshot: PanelMotionSnapshot) {
    guard let path = selectedPath, let from = snapshot.chipFrames[path], let row = selectedRow,
      table.rect(ofRow: row).intersects(scroll.contentView.documentVisibleRect)
    else { return }
    table.layoutSubtreeIfNeeded()
    guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PanelItemCell
    else { return }
    let icon = cell.convert(cell.iconFrame, to: root)
    let flyer = PanelFlyer(icon: PanelIcons.shared.icon(path), title: place.name(path), selected: false)
    concealedPath = path
    cell.concealed = true
    let end = NSPoint(x: icon.minX - 3, y: icon.midY - PanelChipsView.height / 2)
    fly(flyer, from: from.origin, to: end, toChip: false) { [weak self] in
      guard let self else { return }
      self.reveal(concealed: path)
    }
  }

  func reveal(concealed path: String) {
    guard concealedPath == path else { return }
    concealedPath = nil
    if let row = rowIndex(of: path) {
      (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PanelItemCell)?.concealed = false
    }
  }

  func fly(
    _ flyer: PanelFlyer, from: NSPoint, to: NSPoint, toChip: Bool, done: @escaping () -> Void
  ) {
    flyer.setFrameOrigin(from)
    root.addSubview(flyer, positioned: .above, relativeTo: nil)
    flyers.append(flyer)
    let ticket = motionTicket
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.25, 1)
      context.allowsImplicitAnimation = true
      flyer.animator().setFrameOrigin(to)
      flyer.selectedFace.animator().alphaValue = toChip ? 0 : 1
      flyer.chipFace.animator().alphaValue = toChip ? 1 : 0
    } completionHandler: { [weak self, weak flyer] in
      guard let self, let flyer, ticket == self.motionTicket else { return }
      flyer.removeFromSuperview()
      self.flyers.removeAll { $0 === flyer }
      done()
    }
  }

  func slide(_ view: NSView, from offset: CGFloat) {
    guard let layer = view.layer else { return }
    let move = CABasicAnimation(keyPath: "transform.translation.x")
    move.fromValue = offset
    move.toValue = 0
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let group = CAAnimationGroup()
    group.animations = [move, fade]
    group.duration = 0.26
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.25, 1)
    group.fillMode = .backwards
    layer.add(group, forKey: "panel.slide")
  }

  func fade(_ view: NSView) {
    guard let layer = view.layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.24
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(fade, forKey: "panel.fade")
  }

  /// A keystroke during an animation lands it at once.
  func finishMotion() {
    guard !flyers.isEmpty || listHost.layer?.animation(forKey: "panel.slide") != nil
      || previewHost.layer?.animation(forKey: "panel.fade") != nil || concealedPath != nil
      || chips.hiddenPath != nil
    else { return }
    motionTicket += 1
    for flyer in flyers {
      flyer.layer?.removeAllAnimations()
      flyer.removeFromSuperview()
    }
    flyers.removeAll()
    chips.hiddenPath = nil
    if let path = concealedPath { reveal(concealed: path) }
    listHost.layer?.removeAnimation(forKey: "panel.slide")
    previewHost.layer?.removeAnimation(forKey: "panel.fade")
  }

  /// Whether motion is still running, for checks.
  var isAnimating: Bool {
    !flyers.isEmpty || listHost.layer?.animation(forKey: "panel.slide") != nil
  }
}
