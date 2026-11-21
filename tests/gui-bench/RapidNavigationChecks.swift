import AppKit

func checkRapidNavigation(_ browser: Browser, directory: URL) throws {
  let fm = FileManager.default
  let final = fm.temporaryDirectory.appendingPathComponent(
    "finger-latest-" + UUID().uuidString, isDirectory: true
  ).standardizedFileURL
  try fm.createDirectory(at: final, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: final) }
  for name in ["Latest only.txt", "Another item.txt"] {
    try Data().write(to: final.appendingPathComponent(name))
  }
  let intermediate = directory.appendingPathComponent("000-open-me", isDirectory: true)
  // Exercise the same callback as an actual sidebar folder click.
  for url in [
    directory, intermediate, directory, final.appendingPathComponent("absent"), directory, final,
  ] {
    browser.ui.rail.pick?(url.path)
    pump(0.005)
  }
  try spin(
    until: { browser.folderPath == final.path && !browser.loading && !browser.scanning },
    "latest rapid navigation")
  browser.ui.query.stringValue = "latest only"
  browser.filter()
  try require(
    browser.rows.count == 1 && browser.selected.map(\.name) == ["Latest only.txt"],
    "Superseded read installed a stale index")
  pump(0.40)
  try require(
    browser.folderPath == final.path && browser.entries.count == 2 && browser.rows.count == 1
      && browser.selected.map(\.name) == ["Latest only.txt"] && browser.lastError == nil
      && !browser.ui.status.stringValue.lowercased().contains("canceled"),
    "A superseded read surfaced partial rows, selection or an error")
  browser.clearFilter()
  browser.visit(directory.path)
  try spin(
    until: { browser.folderPath == directory.path && !browser.loading && !browser.scanning },
    "restore after rapid navigation")
  print("Rapid sidebar navigation retained the latest folder, search index, selection and status.")
  try checkSidebarAliases(browser)
}

func checkSidebarAliases(_ browser: Browser) throws {
  let fm = FileManager.default
  let name = "Finger sidebar " + UUID().uuidString
  let project = "/tmp/" + name
  let physical = "/private/tmp/" + name
  let link = project + " shortcut"
  try fm.createDirectory(atPath: physical, withIntermediateDirectories: false)
  defer { try? fm.removeItem(atPath: physical) }
  try fm.createSymbolicLink(atPath: link, withDestinationPath: physical)
  defer { try? fm.removeItem(atPath: link) }
  let original = (browser.location, browser.project, browser.favorites, browser.recent)
  let defaults = UserDefaults.standard.object(forKey: "favorites")
  defer {
    (browser.location, browser.project, browser.favorites, browser.recent) = original
    UserDefaults.standard.set(defaults, forKey: "favorites")
    browser.updateChrome()
  }
  browser.location = physical
  browser.project = project
  browser.favorites = [physical, project, link]
  browser.recent = [physical, link]
  browser.updateChrome()
  func links() -> [RailLink] { tree(browser.ui.rail).compactMap { $0 as? RailLink } }
  func checked() -> [String] {
    browser.ui.rail.navigationMenu().items.filter { $0.state == .on }.compactMap(\.toolTip)
  }
  func act(_ title: String) throws {
    let actions = browser.actionsMenu()
    let index = actions.indexOfItem(withTitle: title)
    try require(index >= 0, "Folder actions did not offer " + title)
    actions.performActionForItem(at: index)
  }
  try require(
    links().filter { FolderReferences.key($0.key) == physical }.map(\.key) == [project]
      && links().contains { $0.key == link },
    "Sidebar duplicated system aliases across groups or removed a user symlink")
  try require(
    links().filter(\.selected).map(\.key) == [project] && checked() == [project],
    "Sidebar row and compact menu did not mark the preferred project spelling")
  try act("Unpin Folder")
  try require(browser.favorites == [link], "Unpin left duplicate spellings or removed the shortcut")
  try act("Pin Folder")
  try require(browser.favorites == [physical, link], "Pin did not keep the current spelling")
  browser.location = link
  browser.updateChrome()
  try require(
    links().filter(\.selected).map(\.key) == [link] && checked() == [link],
    "User symlink did not keep its own row and compact checkmark")
  try act("Unpin Folder")
  try require(browser.favorites == [physical], "Unpinning the shortcut removed its target")
  print(
    "Sidebar, compact menu and Pin Folder agreed on system aliases and kept a user symlink distinct."
  )
}

func checkCrowdedInspectorSwitching(_ browser: Browser, directory: URL) throws {
  let fm = FileManager.default
  let project = fm.temporaryDirectory.appendingPathComponent(
    "finger-inspector-" + UUID().uuidString, isDirectory: true
  ).standardizedFileURL
  try fm.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: project) }
  // Two real folder rows can reuse the full 100,000-entry on-disk fixture.
  for name in ["exports", "exports-old"] {
    try fm.createSymbolicLink(
      at: project.appendingPathComponent(name), withDestinationURL: directory)
  }
  let note = project.appendingPathComponent("Brief.txt")
  let text = "The latest inspector selection is the brief."
  try Data(text.utf8).write(to: note)
  browser.visit(project.path, selecting: note.path)
  try spin(
    until: { browser.folderPath == project.path && !browser.loading && browser.entries.count == 3 },
    "crowded inspector fixture")
  var times: [Double] = []
  func showsBrief() -> Bool {
    tree(browser.ui.preview).contains { ($0 as? NSTextView)?.string == text }
  }
  for sample in 0..<10 {
    try select(browser, named: "exports")
    pump(0.018)
    try select(browser, named: "exports-old")
    pump(0.018)
    let start = DispatchTime.now().uptimeNanoseconds
    try select(browser, named: "Brief.txt")
    try spin(until: showsBrief, "newly selected brief after two crowded folders")
    if sample > 0 { times.append(ms(start)) }
    pump(0.25)
    try require(
      showsBrief() && browser.selected.first?.path == note.path,
      "An obsolete folder scan replaced the text preview")
  }
  summary("Text preview after two superseded 100k folder scans", times)
  browser.visit(directory.path)
  try spin(
    until: { browser.folderPath == directory.path && !browser.loading },
    "restore after crowded inspector checks")
}
