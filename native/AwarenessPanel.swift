import AppKit

// How the panel uses awareness: Working On at the top of Home, blue dots on
// the trail to it, landing on the trail when entering a folder, why lines in
// the folder peek, and the footer status that opens "What Finger knows".
extension PanelController {
  func awarenessInstalled(_ old: PanelAwareness?) {
    old?.onChange = nil
    if let awareness {
      workingOn = { [weak self] in self?.awareness?.workingFiles ?? [] }
      awareness.onChange = { [weak self] in self?.awarenessChanged() }
    } else {
      workingOn = nil
    }
    peek.marked = { [weak self] in self?.awarenessSnapshot.marked($0) ?? false }
    footer.onStatus = { [weak self] in self?.toggleKnowledge() }
    NotificationCenter.default.removeObserver(self, name: PanelKnowledge.changed, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(knowledgeChanged), name: PanelKnowledge.changed, object: nil)
    awarenessChanged()
  }

  var awarenessSnapshot: AwarenessSnapshot { awareness?.snapshot ?? .empty }

  /// A new snapshot: redraw what depends on it, keeping the selection.
  func awarenessChanged() {
    if knowledgeShown { refreshKnowledge() }
    guard panel.isVisible else {
      updateFooter()
      return
    }
    if isAnimating {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.awarenessChanged() }
      return
    }
    if folder == nil && trimmedQuery.isEmpty {
      rebuild(userMoved ? .keep : .path(homeSelected))
    } else {
      rebuild(.keep)
    }
    updatePreview(force: true)
    updateFooter()
  }

  /// The right-hand text of a Working On row: "Open in Illustrator", "Edited 12 min ago".
  func awarenessSide(_ file: PanelFile) -> String? { awarenessSnapshot.side(file.path) }

  /// A blue dot: something you are working on, or a folder on the way there.
  /// Home's own lists don't need one.
  func awarenessDot(_ item: PanelItem) -> Bool {
    // The move list's folders carry Jev's percentages instead.
    item.origin != .home && filing?.isMoving != true && awarenessSnapshot.marked(item.file.path)
  }

  /// After where you left off, entering a folder lands on the trail.
  func awarenessLanding(_ list: [PanelFile]) -> String? {
    awarenessSnapshot.landing(among: list.map(\.path))
  }

  /// "Fold Studies in Illustrator · finger in Terminal", or nil.
  var awarenessStatus: String? {
    let text = awarenessSnapshot.footer
    return text.isEmpty ? nil : text
  }

  // MARK: What Finger knows

  var knowledgeShown: Bool { knowledgeView.superview != nil && !knowledgeView.isHidden }

  /// A source's rows changed, such as filing's log: an open popover follows.
  @objc func knowledgeChanged() {
    if knowledgeShown { refreshKnowledge() }
  }

  func toggleKnowledge() {
    if knowledgeShown { hideKnowledge() } else { showKnowledge() }
  }

  func showKnowledge() {
    if knowledgeView.superview == nil { root.addSubview(knowledgeView) }
    knowledgeView.isHidden = false
    footer.statusOpen = true
    refreshKnowledge()
  }

  func refreshKnowledge() {
    let width = min(PanelKnowledgeView.width, root.bounds.width - 20)
    let room = root.bounds.height - PanelRootView.footerHeight - PanelRootView.searchHeight - 12
    knowledgeView.fit(PanelKnowledge.groups, width: width, maxHeight: room)
    let height = min(knowledgeView.fittingHeight(width: width), room)
    knowledgeView.frame = NSRect(x: 10, y: PanelRootView.footerHeight + 6, width: width, height: height)
    knowledgeView.needsDisplay = true
  }

  @discardableResult
  func hideKnowledge() -> Bool {
    footer.statusOpen = false
    guard knowledgeShown else { return false }
    knowledgeView.isHidden = true
    return true
  }
}
