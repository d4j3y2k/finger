import AppKit

/// Scroll views keep vertical movement and forward horizontal gestures when
/// their content is already at an edge. AppKit decides whether a swipe commits.
final class BrowserWindow: NSWindow {
  var canTrackHistory: ((NSPoint) -> Bool)?
  var canStepHistory: ((Bool) -> Bool)?
  var stepHistory: ((Bool) -> Bool)?

  private final class FluidSwipe {
    let back: Bool
    init(back: Bool) { self.back = back }
  }
  private enum Source { case fluid, discrete }
  private var active: FluidSwipe?
  private var last: (source: Source, back: Bool, time: TimeInterval)?

  override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
    axis == .horizontal && attachedSheet == nil && NSEvent.isSwipeTrackingFromScrollEventsEnabled
      && (canStepHistory?(true) == true || canStepHistory?(false) == true)
  }

  override func scrollWheel(with event: NSEvent) {
    if !handleHistoryScroll(event, enabled: NSEvent.isSwipeTrackingFromScrollEventsEnabled) {
      super.scrollWheel(with: event)
    }
  }

  override func swipe(with event: NSEvent) {
    if !handleHistorySwipe(event) { super.swipe(with: event) }
  }

  private func eligible(_ event: NSEvent) -> Bool {
    attachedSheet == nil && event.window === self
      && canTrackHistory?(event.locationInWindow) == true
  }

  // The system can report a discrete swipe adjacent to the phased stream.
  // Suppress only the other representation of the same direction.
  private func duplicate(_ source: Source, back: Bool, at time: TimeInterval) -> Bool {
    guard let last else { return false }
    return last.source != source && last.back == back && abs(time - last.time) < 0.25
  }

  func handleHistoryScroll(_ event: NSEvent, enabled: Bool) -> Bool {
    guard enabled else {
      cancelHistorySwipe()
      return false
    }
    guard event.type == .scrollWheel, eligible(event),
      event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty
    else { return false }
    if event.phase.contains(.cancelled) {
      cancelHistorySwipe()
      return false
    }
    guard event.phase.contains(.began) || event.phase.contains(.changed) else { return false }
    if event.phase.contains(.began) {
      cancelHistorySwipe()
      last = nil
    }
    let dx = event.scrollingDeltaX
    let dy = event.scrollingDeltaY
    guard abs(dx) > 1.8 * abs(dy) else { return false }
    if active != nil { return true }
    // AppKit already applies the user's Natural Scrolling preference to dx.
    let back = dx > 0
    if duplicate(.fluid, back: back, at: event.timestamp) { return true }
    guard canStepHistory?(back) == true else { return false }
    let swipe = FluidSwipe(back: back)
    active = swipe
    event.trackSwipeEvent(
      options: [.lockDirection, .clampGestureAmount],
      dampenAmountThresholdMin: back ? 0 : -1, max: back ? 1 : 0
    ) { [weak self] amount, phase, complete, stop in
      guard let self, self.active === swipe else {
        stop.pointee = true
        return
      }
      guard self.attachedSheet == nil else {
        self.cancelHistorySwipe()
        stop.pointee = true
        return
      }
      guard phase.contains(.ended) || phase.contains(.cancelled) || complete else { return }
      self.active = nil
      self.last = (.fluid, back, ProcessInfo.processInfo.systemUptime)
      stop.pointee = true
      if phase.contains(.ended), !phase.contains(.cancelled), back ? amount > 0 : amount < 0,
        self.canStepHistory?(back) == true
      {
        _ = self.stepHistory?(back)
      }
    }
    return true
  }

  func handleHistorySwipe(_ event: NSEvent) -> Bool {
    guard event.type == .swipe, eligible(event), abs(event.deltaX) > abs(event.deltaY) else {
      return false
    }
    let back = event.deltaX > 0
    if active != nil { return true }
    if duplicate(.discrete, back: back, at: event.timestamp) {
      last = nil
      return true
    }
    guard stepHistory?(back) == true else { return false }
    last = (.discrete, back, event.timestamp)
    return true
  }

  func cancelHistorySwipe() {
    if let active { last = (.fluid, active.back, ProcessInfo.processInfo.systemUptime) }
    active = nil
  }

  override func resignKey() {
    cancelHistorySwipe()
    super.resignKey()
  }
}
