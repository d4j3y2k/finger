import AppKit

/// Delivers callbacks in-process. No synthetic event is posted to the window server.
private final class LocalHistoryEvent: NSEvent {
  typealias Tracker = (CGFloat, Phase, Bool, UnsafeMutablePointer<ObjCBool>) -> Void
  weak var destination: NSWindow?
  var kind: EventType = .scrollWheel
  var x: CGFloat = 12, y: CGFloat = 0
  var point = NSPoint(x: 50, y: 50)
  var fingerPhase: Phase = .began, momentum: Phase = []
  var precise = true, inverted = false
  let uptime = ProcessInfo.processInfo.systemUptime
  var tracker: Tracker?, bounds: ClosedRange<CGFloat>?, options: SwipeTrackingOptions = []
  override var type: EventType { kind }
  override var window: NSWindow? { destination }
  override var phase: Phase { fingerPhase }
  override var momentumPhase: Phase { momentum }
  override var deltaX: CGFloat { x }
  override var deltaY: CGFloat { y }
  override var scrollingDeltaX: CGFloat { x }
  override var scrollingDeltaY: CGFloat { y }
  override var locationInWindow: NSPoint { point }
  override var timestamp: TimeInterval { uptime }
  override var hasPreciseScrollingDeltas: Bool { precise }
  override var isDirectionInvertedFromDevice: Bool { inverted }
  override func trackSwipeEvent(
    options: SwipeTrackingOptions = [], dampenAmountThresholdMin lo: CGFloat, max hi: CGFloat,
    usingHandler handler: @escaping Tracker
  ) {
    self.options = options
    bounds = lo...hi
    tracker = handler
  }
  @discardableResult func feed(_ amount: CGFloat, _ phase: Phase, complete: Bool = false) -> Bool {
    var stop: ObjCBool = false
    tracker?(amount, phase, complete, &stop)
    return stop.boolValue
  }
}

func checkHistorySwipes(_ browser: Browser, directory: URL) throws {
  let window = BrowserWindow(
    contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
    styleMask: .borderless, backing: .buffered, defer: true)
  var steps: [Bool] = []
  var allowed = true
  window.canTrackHistory = { $0.x >= 10 }
  window.canStepHistory = { _ in allowed }
  window.stepHistory = { back in
    guard allowed else { return false }
    steps.append(back)
    return true
  }
  func event(_ x: CGFloat = 12, y: CGFloat = 0, kind: NSEvent.EventType = .scrollWheel)
    -> LocalHistoryEvent
  {
    let e = LocalHistoryEvent()
    e.destination = window
    e.x = x
    e.y = y
    e.kind = kind
    return e
  }
  func begin(_ e: LocalHistoryEvent) -> Bool { window.handleHistoryScroll(e, enabled: true) }
  try require(
    !window.wantsScrollEventsForSwipeTracking(on: .vertical)
      && window.wantsScrollEventsForSwipeTracking(on: .horizontal)
        == NSEvent.isSwipeTrackingFromScrollEventsEnabled,
    "History swipe did not follow the AppKit preference and horizontal scroll-edge contract")
  let vertical = event(2, y: 22)
  let diagonal = event(4, y: 4)
  let coarse = event()
  let momentum = event()
  let outside = event()
  let noWindow = event()
  let ended = event()
  let tentative = event()
  coarse.precise = false
  momentum.momentum = .changed
  outside.point.x = 0
  noWindow.destination = nil
  ended.fingerPhase = .ended
  tentative.fingerPhase = .mayBegin
  for e in [vertical, diagonal, coarse, momentum, outside, noWindow, ended, tentative] {
    try require(!begin(e) && e.tracker == nil, "History consumed an ineligible scroll")
  }
  try require(
    !window.handleHistoryScroll(event(), enabled: false), "Disabled fluid swiping started a tracker"
  )
  allowed = false
  try require(
    !window.wantsScrollEventsForSwipeTracking(on: .horizontal) && !begin(event()),
    "Unavailable history consumed a scroll")
  allowed = true
  for inverted in [false, true] {
    for direction in [CGFloat(1), -1] {
      let e = event(12 * direction)
      let count = steps.count
      e.inverted = inverted
      try require(
        begin(e) && e.bounds == (direction > 0 ? 0...1 : -1...0)
          && e.options.contains([.lockDirection, .clampGestureAmount]),
        "Incorrect native swipe direction or configuration")
      try require(
        !e.feed(direction, .changed) && steps.count == count, "History committed before lift")
      try require(
        e.feed(direction, .ended) && steps.count == count + 1 && steps.last == (direction > 0),
        "Logical swipe direction depended on device inversion")
      try require(
        e.feed(direction, [], complete: true) && steps.count == count + 1,
        "Completion committed a second history step")
    }
  }
  let prior = steps.count
  let cancelled = event()
  _ = begin(cancelled)
  cancelled.feed(0.9, .cancelled)
  cancelled.feed(1, .ended)
  let superseded = event()
  _ = begin(superseded)
  let next = event()
  _ = begin(next)
  superseded.feed(1, .ended)
  let rawCancel = event()
  rawCancel.fingerPhase = .cancelled
  _ = begin(rawCancel)
  next.feed(1, .ended)
  let interrupted = event()
  _ = begin(interrupted)
  window.cancelHistorySwipe()
  interrupted.feed(1, .ended)
  _ = window.handleHistorySwipe(event(kind: .swipe))
  let disabled = event()
  _ = begin(disabled)
  _ = window.handleHistoryScroll(event(), enabled: false)
  disabled.feed(1, .ended)
  let changedHistory = event()
  _ = begin(changedHistory)
  allowed = false
  changedHistory.feed(1, .ended)
  allowed = true
  let reversal = event()
  _ = begin(reversal)
  reversal.feed(-1, .ended)
  try require(
    steps.count == prior, "A cancelled, superseded, reversed or interrupted swipe navigated")

  let fluid = event()
  _ = begin(fluid)
  try require(
    window.handleHistorySwipe(event(kind: .swipe)) && steps.count == prior,
    "A discrete event escaped an active fluid swipe")
  fluid.feed(1, .ended)
  try require(
    window.handleHistorySwipe(event(kind: .swipe)) && steps.count == prior + 1,
    "Paired fluid/discrete reports navigated twice")
  try require(
    window.handleHistorySwipe(event(kind: .swipe)) && window.handleHistorySwipe(event(kind: .swipe))
      && steps.count == prior + 3,
    "Distinct consecutive discrete swipes were suppressed")
  let followup = event()
  followup.fingerPhase = .changed
  try require(
    begin(followup) && followup.tracker == nil, "Trailing stream started a second native tracker")
  try require(
    window.handleHistorySwipe(event(-1, kind: .swipe)) && steps.last == false,
    "Discrete forward swipe chose the wrong direction")
  try require(
    !window.handleHistorySwipe(event(0, y: 1, kind: .swipe)), "Discrete vertical swipe navigated")

  // Also commit through the browser's production history and hit-testing closures.
  let child = directory.appendingPathComponent("000-open-me", isDirectory: true)
  try select(browser, named: "000-open-me")
  let selected = browser.selected.map(\.path)
  let scrollY = browser.ui.scroll.contentView.bounds.origin.y
  browser.visit(child.path)
  try spin(
    until: { browser.folderPath == child.path && !browser.loading }, "history swipe child fixture")
  try paint(browser)
  let e = event()
  e.destination = browser.window
  e.point = browser.ui.body.convert(NSPoint(x: 80, y: 50), to: nil)
  try require(
    browser.window.handleHistoryScroll(e, enabled: true), "Browser rejected history swipe in list")
  e.feed(0.8, .ended)
  try spin(
    until: { browser.folderPath == directory.path && !browser.loading }, "history swipe Back")
  try paint(browser)
  try require(
    browser.selected.map(\.path) == selected
      && browser.ui.scroll.contentView.bounds.origin.y == scrollY,
    "History swipe failed to restore browser selection and scroll")
  guard
    let wheel = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
      wheel1: -82, wheel2: 0, wheel3: 0), let verticalWheel = NSEvent(cgEvent: wheel)
  else { throw CheckFailure("Cannot construct a local vertical scroll sample") }
  browser.ui.scroll.scrollWheel(with: verticalWheel)
  try spin(
    until: { browser.ui.scroll.contentView.bounds.origin.y > scrollY },
    "native vertical table scroll")
  try require(
    browser.folderPath == directory.path && browser.selected.map(\.path) == selected,
    "Native vertical scrolling changed history or selection")
  print(
    "History swipes followed system direction and preference gates, preserved vertical scrolling, ignored duplicate/cancelled streams and restored the selected row and scroll."
  )
}
