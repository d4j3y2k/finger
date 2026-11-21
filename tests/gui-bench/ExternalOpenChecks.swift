import AppKit

func checkExternalOpen(_ browser: Browser, returningTo directory: URL) throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(
    "finger-external-window-" + UUID().uuidString,
    isDirectory: true
  ).standardizedFileURL
  let left = root.appendingPathComponent("exports", isDirectory: true)
  let right = root.appendingPathComponent("delivery", isDirectory: true)
  try fm.createDirectory(at: left, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  try fm.createDirectory(at: right, withIntermediateDirectories: true)
  let first = left.appendingPathComponent("Cover.png")
  let second = left.appendingPathComponent("Cover.svg")
  let hidden = left.appendingPathComponent(".Print note")
  let third = right.appendingPathComponent("Brief.txt")
  for item in [first, second, hidden, third] { try Data().write(to: item) }

  let requests = OpenItemRequests()
  func open(_ urls: [URL]) throws {
    var applied = false
    requests.resolve(urls) { result in
      browser.openExternal(result)
      applied = true
    }
    try spin(until: { applied && !browser.loading && !browser.scanning }, "explicit URL routing")
  }
  let originalHidden = browser.showHidden
  let originalProject = browser.project
  let originalCollections = browser.collections
  browser.showHidden = false

  try require(requests.receive([first]).isEmpty, "Early Finder open did not queue")
  try require(requests.receive([second]).isEmpty, "Second early Finder open did not queue")
  try open(requests.launch(arguments: []))
  try require(
    browser.location == left.path
      && Set(browser.selected.map(\.path)) == [first.path, second.path],
    "Cold sibling request did not select both real table rows")
  try open(requests.receive([hidden, second]))
  try require(
    Set(browser.selected.map(\.path)) == [hidden.path, second.path],
    "Explicit hidden selection disappeared")
  try open(requests.receive([second, third]))
  try require(
    browser.collection?.name.hasPrefix("Opened together") == true
      && browser.entries.map(\.path) == [second.path, third.path],
    "Warm cross-directory request lost a collection member")
  try paint(browser)
  for (row, file) in [second, third].enumerated() {
    guard let cell = browser.ui.table.view(atColumn: 0, row: row, makeIfNecessary: true),
      let origin = tree(cell).compactMap({ $0 as? NSTextField }).first(where: {
        $0.accessibilityIdentifier() == "Collection source folder"
      })
    else {
      throw CheckFailure("A collection member lacks its original folder")
    }
    try require(
      !origin.isHidden && origin.toolTip == file.deletingLastPathComponent().path,
      "A collection member showed the wrong source folder")
  }
  let previous = browser.location
  let missing = right.appendingPathComponent("No longer here.png")
  browser.openURL(missing)
  try spin(
    until: { browser.ui.status.stringValue.contains(missing.path) },
    "opening missing file from a saved collection")
  try require(
    browser.ui.status.stringValue.contains("Couldn’t find"),
    "A missing file was reported as a default-app error")
  try open(requests.receive([right.appendingPathComponent("gone.txt")]))
  try require(
    browser.location == previous && browser.ui.status.stringValue.contains("gone.txt"),
    "Invalid warm request changed the view or hid its error")
  try open(requests.receive([right]))
  try require(
    browser.location == right.path && browser.entries.map(\.path) == [third.path],
    "Single folder did not enter")
  let vanishing = right.appendingPathComponent("Short lived.txt")
  try Data().write(to: vanishing)
  var planned: OpenItems.Resolution?
  requests.resolve([vanishing]) { planned = $0 }
  try spin(until: { planned != nil }, "explicit path inspection")
  try fm.removeItem(at: vanishing)
  browser.openExternal(planned!)
  try spin(until: { !browser.loading && !browser.scanning }, "selection after external deletion")
  try require(
    browser.selected.isEmpty && browser.ui.status.stringValue.contains(vanishing.path),
    "A disappeared explicit path selected an unrelated file")

  browser.showHidden = originalHidden
  browser.project = originalProject
  browser.collections = originalCollections
  browser.persistCollections()
  browser.visit(directory.path)
  try spin(until: { !browser.loading && !browser.scanning }, "return from external-request test")
  print(
    "External opens preserved cold sibling selection, warm hidden rows, mixed-folder collection, and actionable missing-path errors in AppKit."
  )
}
