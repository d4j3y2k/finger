import AppKit
import Quartz

private func worktableBridgeSelection() throws -> [String] {
  guard let bridge = ProcessInfo.processInfo.environment["FINGER_QA_WORKTABLE_MCP"],
    ProcessInfo.processInfo.environment["FINGER_FIXTURE_SOCKET"] != nil
  else { throw CheckFailure("The Worktable check needs an isolated MCP endpoint") }
  var response: Result<[String: Any], Error>?
  DispatchQueue.global(qos: .userInitiated).async {
    let payload = Result { try readMCP(bridge, limit: 4) }
    DispatchQueue.main.async { response = payload }
  }
  try spin(until: { response != nil }, "the Worktable MCP selection")
  let reply = try response!.get()
  guard let items = reply["items"] as? [[String: Any]],
    let count = reply["total"] as? Int, items.count == count
  else { throw CheckFailure("The bridge returned an incomplete selection") }
  return items.compactMap { $0["path"] as? String }
}

func checkWorktable(_ browser: Browser, demo: URL, returning: Bool, capture: String) throws {
  browser.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
  browser.window.setContentSize(NSSize(width: 1150, height: 710))
  browser.start(at: demo.path, resume: true)
  let home = browser.homeView
  try spin(until: { browser.homeSelection != nil && !home.visibleGroups.isEmpty }, "Fold Studies on the Worktable")
  let png = demo.appendingPathComponent("exports/Overlap 01.png")
  let svg = demo.appendingPathComponent("exports/Overlap 01.svg")
  if returning {
    let newFile = demo.appendingPathComponent("exports/Overlap 02.png").path
    guard let newGroup = home.visibleGroups.first(where: { $0.files.contains { $0.path == newFile } }) else {
      throw CheckFailure("The new export was absent from the next launch")
    }
    try require(newGroup.changed, "The new export had no change-since-visit indication")
    try require(home.visibleGroups.filter(\.changed).count == 1, "Untouched files were also marked changed")
    print("Fresh launch surfaced the new Overlap 02.png and identified it as changed since the previous visit.")
    return
  }

  guard let current = home.visibleGroups.first else { throw CheckFailure("No work to resume") }
  try require(current.primary.path == png.path && current.related.contains { $0.path == svg.path },
    "The first card didn't pair the current PNG with its SVG source")
  try require(!home.visibleGroups.contains(where: \.changed), "First visit announced unobserved changes")
  func press(_ text: String, code: UInt16) throws {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window.windowNumber, context: nil,
      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
    else { throw CheckFailure("Could not make a Worktable key event") }
    home.keyDown(with: event)
  }
  func replaceQuery(_ text: String) throws {
    browser.window.makeFirstResponder(home.query)
    guard let editor = home.query.currentEditor() as? NSTextView else {
      throw CheckFailure("The Worktable search field did not receive keyboard focus")
    }
    editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
  }
  try press("r", code: 15)
  try spin(until: { home.query.stringValue == "r" }, "typing from the Worktable into search")
  try replaceQuery("01.svg")
  try spin(until: { home.visibleGroups.first?.primary.path == svg.path && home.selected.map(\.path) == [svg.path] },
    "promotion and selection of the matching SVG source")
  try replaceQuery("Revision notes")
  try spin(until: { home.visibleGroups.count == 1 && home.visibleGroups[0].primary.name == "Revision notes.txt" },
    "narrowed results from the archived edition")
  try replaceQuery("absent-file-649")
  try spin(until: { home.visibleGroups.isEmpty && home.selected.isEmpty }, "an empty filter result and cleared selection")
  try replaceQuery("")
  try spin(until: { home.visibleGroups.first?.primary.path == png.path }, "the unfiltered Worktable")

  guard let card = tree(home).compactMap({ $0 as? WorktableCard }).first(where: { $0.group.primary.path == png.path }),
    let chip = tree(card).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == svg.path }),
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1)
  else { throw CheckFailure("The source chip or card was unavailable") }
  try spin(until: { tree(card).compactMap { ($0 as? NSImageView)?.image }.contains {
    $0.size.width >= 300 && abs($0.size.width / $0.size.height - 4.0 / 3.0) < 0.01
  } }, "the full-color 4:3 Fold Studies artwork")
  chip.performClick(nil)
  try require(home.selected.map(\.path) == [svg.path], "The SVG chip selected the wrong file")
  home.select(home.selected, extending: true)
  try require(home.selected.isEmpty, "Extending the selection failed to toggle off the last file")
  browser.refreshWorktable()
  try spin(until: { browser.homeTicket == nil }, "the refreshed Worktable")
  try require(home.selected.isEmpty && browser.homeSelection?.isEmpty == true,
    "A refresh silently selected a file after explicit deselection")
  card.mouseDown(with: click)
  try require(home.selected.map(\.path) == [png.path, svg.path], "The pair was not selected in order")
  try press(" ", code: 49)
  try spin(until: { (browser.panelView?.previewItem as? NSURL)?.path == png.path }, "Quick Look for the selected PNG")
  browser.stepQuickLook(1)
  try spin(until: { (browser.panelView?.previewItem as? NSURL)?.path == svg.path }, "Quick Look for the paired SVG")
  browser.dismissQuickLook()
  let paths = try worktableBridgeSelection()
  try require(paths == [png.path, svg.path], "MCP selection differed from the Worktable after preview")
  let prompt = CodexHandoff.prompt(for: home.selected)
  let draft = CodexHandoff.draftURL(prompt: prompt).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
  try require(prompt.contains(png.path) && prompt.contains(svg.path) && draft?.host == "new" &&
    draft?.queryItems?.first(where: { $0.name == "prompt" })?.value == prompt,
    "The Codex draft did not preserve both selected paths")
  print("Typing narrowed the cards. Quick Look paged between the PNG and SVG. MCP and the Codex draft included both paths.")
  if !capture.isEmpty {
    browser.window.makeFirstResponder(home)
    home.layoutSubtreeIfNeeded()
    pump(0.35)
    try writeWindowPNG(browser, output: capture)
  }
  if let compact = ProcessInfo.processInfo.environment["FINGER_QA_WORKTABLE_COMPACT"] {
    browser.window.setContentSize(NSSize(width: 700, height: 505))
    home.layoutSubtreeIfNeeded()
    pump(0.1)
    try writeWindowPNG(browser, output: compact)
  }

  browser.browseFromWorktable()
  try spin(until: { browser.homeSelection == nil && browser.location == demo.path && !browser.loading }, "the project folder browser")
  browser.showWorktable()
  try spin(until: { browser.homeSelection != nil && home.visibleGroups.first?.primary.path == png.path }, "returning to the Worktable")
  browser.saveWorkspace()
  _ = UserDefaults.standard.synchronize()
  print("The folder browser opened on Fold Studies and returned to the Worktable.")
}
