import AppKit
import Darwin

// scripts/check.sh builds this standalone AppKit host against the app's UI
// code and the finger-core folder reader. It drives the summonable panel with
// key events over a fixture home folder, with search injected so the checks
// never depend on what Spotlight has indexed, and writes light and dark PNGs
// of the main states.

private final class TestCore {
  private let process = Process()
  private let input: FileHandle
  private let output: UnsafeMutablePointer<FILE>
  private let lock = NSLock()

  init(_ executable: URL) throws {
    let incoming = Pipe()
    let outgoing = Pipe()
    input = incoming.fileHandleForWriting
    output = fdopen(dup(outgoing.fileHandleForReading.fileDescriptor), "r")!
    process.executableURL = executable
    process.standardInput = incoming
    process.standardOutput = outgoing
    try process.run()
  }

  func forward(_ command: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    lock.lock()
    defer { lock.unlock() }
    var bytes = Data(bytes: command, count: strlen(command))
    bytes.append(10)
    input.write(bytes)
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    if getline(&line, &capacity, output) > 0 { return line }
    free(line)
    return nil
  }

  func finish() {
    try? input.close()
    process.waitUntilExit()
    fclose(output)
  }
}

private var core: TestCore!
private func send(_ service: Int32, _ data: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
  guard service == 0, let data else { return nil }
  return core.forward(data)
}

/// Answers like Spotlight would, a moment later and in two batches, from the fixture.
private final class FixtureSearch: PanelSearching {
  final class Handle: PanelSearchHandle {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  let root: String
  var used: [String: Date] = [:]
  var delay: TimeInterval = 0.04
  private(set) var nameQueries: [String] = []
  private(set) var cancels = 0

  init(root: String) { self.root = root }

  private func walk(_ scope: String) -> [String] {
    var out: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: scope)
    while let relative = enumerator?.nextObject() as? String {
      if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      out.append(scope + "/" + relative)
    }
    return out
  }

  private func later(_ handle: Handle, _ after: TimeInterval, _ body: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
      if handle.cancelled {
        self.cancels += 1
      } else {
        body()
      }
    }
  }

  func recentlyUsed(in home: String, _ done: @escaping ([PanelFile]) -> Void) -> PanelSearchHandle {
    let handle = Handle()
    later(handle, delay) {
      let files = self.used.sorted { $0.value > $1.value }.compactMap { path, date -> PanelFile? in
        var file = PanelFile.quick(path)
        file?.lastUsed = date
        return file
      }
      done(files)
    }
    return handle
  }

  func names(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void)
    -> PanelSearchHandle
  {
    nameQueries.append(query)
    let handle = Handle()
    let matches = walk(scope).filter { PanelMatch.rank(query, in: ($0 as NSString).lastPathComponent) > 0 }
      .compactMap(PanelFile.quick)
    let half = matches.count / 2
    later(handle, delay) { update(Array(matches.prefix(half)), false) }
    later(handle, delay * 2) { update(matches, true) }
    return handle
  }

  func contents(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void)
    -> PanelSearchHandle
  {
    let handle = Handle()
    let matches = walk(scope).filter { path in
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
      return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }.compactMap(PanelFile.quick)
    later(handle, delay * 3) { update(matches, true) }
    return handle
  }
}

/// Records what the panel asks its preview to show, and shows the stand-in.
private final class SpyPreview: PanelPreview {
  let content = ContentPreview()
  var calls: [(URL?, String?)] = []
  var view: NSView { content }
  func show(_ url: URL?, match: String?) {
    calls.append((url, match))
    content.show(url, match: match)
  }
}

private func pump(_ seconds: TimeInterval) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

private func wait(_ label: String, _ condition: () -> Bool) {
  let end = Date().addingTimeInterval(5)
  while !condition() {
    precondition(Date() < end, "timed out: " + label)
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
  }
}

private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> Any = "") {
  if !ok {
    FileHandle.standardError.write("FAILED: \(label) \(detail())\n".data(using: .utf8)!)
    exit(1)
  }
  print("ok -", label)
}

private let arrows: [UInt16: Int] = [
  123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
  126: NSUpArrowFunctionKey,
]

/// A one-page PDF with a line of text.
private func pdf(_ text: String) -> Data {
  let data = NSMutableData()
  var box = CGRect(x: 0, y: 0, width: 612, height: 792)
  let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
  context.beginPDFPage(nil)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  (text as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
  NSGraphicsContext.restoreGraphicsState()
  context.endPDFPage()
  context.closePDF()
  return data as Data
}

private func makeFixture() -> String {
  let files = FileManager.default
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("Finger Panel " + UUID().uuidString, isDirectory: true)
  let root = base.path
  // The mockup's own example files, so the previews have something to show.
  let launcher = """
    use std::sync::{Mutex, MutexGuard};

    static NAV: Mutex<Navigation> = Mutex::new(Navigation::new());
    static SEARCH: Mutex<Search> = Mutex::new(Search::new());

    /// A handler panic poisons the lock it held.
    /// Start that state fresh instead of failing
    /// every later request for the session.
    fn lock<T: Default>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
        mutex.lock().unwrap_or_else(|poisoned| {
            let mut guard = poisoned.into_inner();
            *guard = T::default();
            mutex.clear_poison();
            guard
        })
    }

    extern "C" fn request(service: i32, input: *const c_char) -> *mut c_char {
        let p = parse(input);
        let reply = catch_unwind(|| match service {
            1 => lock(&NAV).handle(&p),
            2 => lock(&SEARCH).install(&p["names"]),
            _ => error("unknown service"),
        });
        // A panic becomes an error reply, never a crash.
        into_c_string(reply.unwrap_or_else(|_| error("handler panicked")))
    }

    """
  let pane = """
    import AppKit
    import QuickLookThumbnailing

    // The preview and the main browser have
    // independent scroll positions.
    final class PreviewPane: NSView {
      weak var browser: Browser?
      private var generation = 0

      func show(_ entry: Entry) {
        generation += 1
        let ticket = generation
        PreviewReader.read(entry) { [weak self] model in
          guard let self, ticket == self.generation else { return }
          self.apply(model)
        }
      }
    }

    """
  let readme = """
    # Finger

    Finger opens to a native Mac worktable with visual previews of files from your current project.

    ## Build

    From the project folder, run `scripts/build.sh`. Each build configures Codex and Claude Code for this checkout.

    ```
    scripts/build.sh
    scripts/check.sh   # full suite, including a 10,000-entry GUI bench
    ```

    ## Keys

    - **⌥ Space** shows or hides Finger
    - **↩** opens, **⌫** goes up a folder

    """
  let tree: [String: String] = [
    "Developer/dotfiles/zshrc": "export EDITOR=vim\n",
    "Developer/finger/bridge/FingerMCP.swift": "// The MCP bridge speaks JSON-RPC over stdio.\n",
    "Developer/finger/docs/AGENTS-CONNECTION.md": "# Agent connection\n",
    "Developer/finger/docs/archive/2025/notes.md": "Old notes.\n",
    "Developer/finger/native/PreviewPane.swift": pane,
    "Developer/finger/native/Browser.swift": "final class Browser: NSObject {}\n",
    "Developer/finger/native/DestinationRanker.swift": "enum DestinationRanker {}\n",
    "Developer/finger/rust/launcher.rs": launcher,
    "Developer/finger/rust/listing.rs": "pub fn visit_entries() {}\n",
    "Developer/finger/scripts/build.sh": "#!/bin/sh\n",
    "Developer/finger/scripts/check.sh": "#!/bin/sh\n",
    "Developer/finger/Cargo.toml": "[package]\nname = \"finger-core\"\n",
    "Developer/finger/README.md": readme,
    "Developer/keypad/README.md": "# keypad\n",
    "Developer/orphne/README.md": "# orphne\n",
    "Developer/orphne/sketch.js": "export function pattern() {}\n",
    "Developer/playground/scratch.py": "print('hello')\n",
    "Developer/rex/README.md": "# rex\n",
    "Developer/rex/Cargo.toml": "[package]\nname = \"rex\"\n",
    "Developer/spleen/README.md": "# Spleen\n\nA panel you summon with a shortcut.\n",
    "Developer/spleen/Package.swift": "// swift-tools-version: 6.0\n",
    "Developer/spleen/Sources/Panel.swift": "final class Panel: NSPanel {}\n",
    "Developer/spleen/docs/DECISIONS_TRIAL.md": "# Decisions trial\n",
    "Documents/Finances/2026/Tax estimate.pdf": "Tax estimate 2026",
    "Documents/Finances/2026/Q4 budget.csv": "month,cost\nOct,800\n",
    "Downloads/Invoice 1121.pdf": "Invoice 1121",
    "Desktop/Screenshot 2026-11-21 at 11.02.png": "",
    "Studio/Posters/Spring poster.pdf": "Open Studio",
  ]
  for (relative, text) in tree {
    let url = base.appendingPathComponent(relative)
    try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! (url.pathExtension == "pdf" ? pdf(text) : Data(text.utf8)).write(to: url)
  }
  // The practice project from the app bundle, as in the mockup's Studio.
  let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/Demo/Fold Studies")
  try! files.copyItem(at: demo, to: base.appendingPathComponent("Studio/Fold Studies"))
  for extra in ["delivery", "invoices", "refs"] {
    try! files.createDirectory(
      at: base.appendingPathComponent("Studio/Fold Studies/" + extra), withIntermediateDirectories: true)
  }
  // Stable times: everything a month old, folders last so creating children
  // does not move them.
  let old = Date().addingTimeInterval(-31 * 86_400)
  let all = (files.enumerator(atPath: root)?.allObjects as? [String] ?? [])
    .filter { !$0.hasPrefix("Downloads") }
    .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
  for relative in all {
    try? files.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + relative)
  }
  return root
}

@main
private enum PanelChecks {
  static func main() throws {
    precondition(
      CommandLine.arguments.count >= 2,
      "Pass the path to the finger-core executable, and optionally a folder for screenshots.")
    core = try TestCore(URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { core.finish() }
    let shots = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    run(shots: shots)
  }
}

private func run(shots: String?) {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  let root = makeFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let dev = root + "/Developer"
  let finger = dev + "/finger"
  let now = Date()
  let search = FixtureSearch(root: root)
  search.used = [
    finger + "/rust/launcher.rs": now.addingTimeInterval(-12 * 60),
    root + "/Studio/Fold Studies/exports/Print notes.txt": now.addingTimeInterval(-61 * 60),
    finger + "/README.md": now.addingTimeInterval(-2 * 3600),
    root + "/Documents/Finances/2026/Q4 budget.csv": now.addingTimeInterval(-26 * 3600),
    dev + "/spleen/docs/DECISIONS_TRIAL.md": now.addingTimeInterval(-2 * 86_400),
    dev + "/rex/README.md": now.addingTimeInterval(-2 * 86_400 - 600),
  ]
  let spy = SpyPreview()
  let engine = Engine(send, { free($0) })
  let c = PanelController(engine: engine, search: search, home: root, preview: spy)
  c.hidesOnResignKey = false
  var opened: [URL] = []
  var revealed: [URL] = []
  c.opener = { opened.append($0) }
  c.revealer = { revealed.append($0) }
  let panel = c.panel
  panel.appearance = NSAppearance(named: .aqua)
  c.showOffscreen()
  check(panel.isVisible, "the panel is up (offscreen)")
  check(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey, "borderless, non-activating, can become key")

  func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
    let characters = arrows[code].map { String(UnicodeScalar(UInt16($0))!) } ?? chars
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
    panel.sendEvent(event)
  }
  func type(_ text: String) {
    for ch in text {
      switch ch {
      case "/": key(44, "/")
      case "~": key(50, "~", .shift)
      case " ": key(49, " ")
      default: key(0, String(ch))
      }
    }
  }
  let ret: UInt16 = 36, esc: UInt16 = 53, del: UInt16 = 51, tab: UInt16 = 48
  let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
  func name(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "nil" }
  func settle() {
    pump(0.05)
    c.finishMotion()
    c.root.layoutSubtreeIfNeeded()
  }

  // The file preview loads off the main thread; wait for it and for any
  // match to be scrolled into view.
  func waitPreview() {
    guard let file = c.selectedItem?.file, !file.isFolder else { return }
    wait("preview of \(file.name)") {
      spy.content.report.url?.path == file.path && spy.content.report.kind != .loading
        && !spy.content.revealing
    }
  }

  func snapshot(_ title: String) {
    guard let shots else { return }
    settle()
    waitPreview()
    wait("searches settle") { !c.footer.status.contains("Searching") }
    for (suffix, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      panel.appearance = NSAppearance(named: look)
      pump(0.08)
      let view = c.root
      view.layoutSubtreeIfNeeded()
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      view.cacheDisplay(in: view.bounds, to: rep)
      let dark = look == .darkAqua
      let size = view.bounds.size
      let margin: CGFloat = 48
      let canvas = NSImage(
        size: NSSize(width: size.width + margin * 2, height: size.height + margin * 2), flipped: false
      ) { rect in
        // A quiet desktop, then the panel's material and its contents.
        let wall = dark
          ? NSGradient(colors: [NSColor(srgbRed: 0.23, green: 0.33, blue: 0.41, alpha: 1), NSColor(srgbRed: 0.23, green: 0.19, blue: 0.16, alpha: 1)])!
          : NSGradient(colors: [NSColor(srgbRed: 0.73, green: 0.81, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.91, green: 0.80, blue: 0.66, alpha: 1)])!
        wall.draw(in: rect, angle: -35)
        let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: frame, xRadius: FingerPanel.radius, yRadius: FingerPanel.radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.28)
        shadow.set()
        (dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 0.9)
          : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 0.9)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // draw(in:) alone copies, wiping the material under the panel's clear pixels.
        rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return true
      }
      let pixels = NSSize(width: canvas.size.width * 2, height: canvas.size.height * 2)
      let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      out.size = canvas.size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
      NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
        canvas.draw(in: NSRect(origin: .zero, size: canvas.size))
      }
      NSGraphicsContext.restoreGraphicsState()
      let file = (shots as NSString).appendingPathComponent("\(title)-\(suffix).png")
      try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
    }
    panel.appearance = NSAppearance(named: .aqua)
    print("   wrote \(title)-light.png and \(title)-dark.png")
  }

  // Home: Just Arrived and Recents, newest first.
  wait("home lists") { c.sectionTitles == ["Just Arrived", "Recents"] }
  check(c.items(in: "Just Arrived").map(\.file.name) == ["Invoice 1121.pdf"], "Just Arrived lists the new download")
  check(
    c.items(in: "Recents").map(\.file.name).prefix(3) == ["launcher.rs", "Print notes.txt", "README.md"],
    "Recents are newest first", c.items(in: "Recents").map(\.file.name))
  // A Rust file from Recents shows its code, with no box behind it.
  key(down, "")
  check(name(c.selectedPath) == "launcher.rs", "↓ moves to Recents")
  waitPreview()
  check(spy.content.report.kind == .code && spy.calls.last?.1 == nil, "a code file previews as code, with no match")
  snapshot("home")

  // Global search ranks the folder named by the prefix first and completes it.
  type("dev")
  wait("search for dev") { c.items(in: "Files & Folders").first?.file.path == dev && !search.nameQueries.isEmpty }
  wait("search finished") { c.footer.status.hasSuffix("results") || c.footer.status.hasSuffix("result") }
  check(c.completion == "eloper", "inline completion for a search result", c.completion)
  check(!c.ghost.isHidden && c.ghost.stringValue == "eloper" && c.ghost.frame.minX > c.field.frame.minX + 20,
    "gray completion sits after the typed text", c.ghost.frame)
  snapshot("search-dev")

  // ↩ on a folder goes in. It becomes a chip and lands on the most recently used item.
  key(ret, "\r")
  wait("inside Developer") { c.folder == dev && !c.rows.isEmpty }
  check(c.chipTitles == ["Developer"], "the folder becomes a chip", c.chipTitles)
  check(c.field.stringValue.isEmpty && c.field.placeholder == "Search in Developer", "the field is cleared for the folder")
  check(
    c.itemNames == ["dotfiles", "finger", "keypad", "orphne", "playground", "rex", "spleen"],
    "folder items come from the core, folders first and alphabetical", c.itemNames)
  check(name(c.selectedPath) == "finger", "entering lands on the most recently used item", name(c.selectedPath))
  wait("the peek reads finger") { c.peek.content?.items != nil }
  check(c.peek.content?.landing == finger + "/rust", "the folder peek tints where you would land", c.peek.content?.landing ?? "nil")
  check(c.footer.hints.contains { $0.keys == "⌫" }, "footer offers ⌫ Up while browsing")
  snapshot("inside-developer")

  // Typing filters the folder and completes the name.
  type("sp")
  wait("filtered") { c.items(in: "In Developer").map(\.file.name) == ["spleen"] }
  check(name(c.selectedPath) == "spleen" && c.completion == "leen", "typing narrows and completes", c.completion)
  if case .header(let section) = c.rows[0] {
    check(section.aside == "1 of 7", "the section counts matches", section.aside)
  }
  snapshot("typing-sp")

  // ↩ goes in; ⌫ on the empty field goes up and lands on the folder you came out of.
  key(ret, "\r")
  wait("inside spleen") { c.folder == dev + "/spleen" && !c.rows.isEmpty }
  check(c.chipTitles == ["Developer", "spleen"], "each level is a chip", c.chipTitles)
  key(del, "\u{7f}")
  wait("back in Developer") { c.folder == dev && c.selectedPath != nil }
  check(name(c.selectedPath) == "spleen", "⌫ up lands on the folder you came out of", name(c.selectedPath))

  // ↓ then ⌘↑ from a deeper folder; ← on an empty field also goes up.
  key(down, "")
  check(name(c.selectedPath) == "spleen", "↓ stops at the last item")
  key(up, "")
  check(name(c.selectedPath) == "rex", "↑ moves the selection")
  key(right, "")
  wait("→ goes into rex") { c.folder == dev + "/rex" && !c.rows.isEmpty }
  key(left, "")
  wait("← goes up") { c.folder == dev && name(c.selectedPath) == "rex" }
  key(tab, "\t")
  wait("⇥ goes into rex") { c.folder == dev + "/rex" && !c.rows.isEmpty }
  key(up, "", .command)
  wait("⌘↑ goes up") { c.folder == dev && name(c.selectedPath) == "rex" }
  check(c.lastSelection(in: dev) == dev + "/rex", "the folder remembers its last selection")

  // Esc clears the text, then returns to the search you started from, then hides.
  type("x")
  wait("typed x") { c.query == "x" }
  key(esc, "\u{1b}")
  check(c.query.isEmpty && c.folder == dev, "first Esc clears the text")
  key(esc, "\u{1b}")
  wait("search restored") { c.folder == nil && c.query == "dev" && c.selectedPath == dev }
  check(c.field.stringValue == "dev" && c.chipTitles.isEmpty, "second Esc restores the query and selection")
  key(esc, "\u{1b}")
  check(!panel.isVisible, "third Esc hides the panel")

  // A path typed without stopping: `/` goes into the top folder match.
  c.showOffscreen()
  check(c.field.stringValue == "dev", "the query survives hiding")
  key(esc, "\u{1b}")
  check(c.query.isEmpty, "Esc clears the restored query")
  type("dev/fi/ru")
  wait("typed a path") { c.folder == finger && c.query == "ru" && name(c.selectedPath) == "rust" }
  check(c.chipTitles == ["Developer", "finger"], "`/` opened each folder in turn", c.chipTitles)
  check(c.completion == "st", "and the last part completes", c.completion)
  key(ret, "\r")
  wait("inside rust") { c.folder == finger + "/rust" && !c.rows.isEmpty }
  check(name(c.selectedPath) == "launcher.rs", "rust lands on the file used last", name(c.selectedPath))
  check(spy.calls.last?.0?.lastPathComponent == "launcher.rs" && spy.calls.last?.1 == nil, "the preview gets the selected file")
  key(del, "\u{7f}")
  wait("back in finger") { c.folder == finger && name(c.selectedPath) == "rust" }
  snapshot("inside-finger")

  // Clicking a chip jumps there.
  key(ret, "\r")
  wait("into rust again") { c.folder == finger + "/rust" && !c.rows.isEmpty }
  c.root.layoutSubtreeIfNeeded()
  let chip = c.chips.rect(for: dev)!
  let point = c.chips.convert(NSPoint(x: chip.midX, y: chip.midY), to: nil)
  c.chips.mouseDown(
    with: NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
  wait("chip click") { c.folder == dev && name(c.selectedPath) == "finger" }
  check(true, "clicking a chip jumps to that folder and lands on the way back")

  // Deeper levels collapse to first › … › last two.
  c.enter(finger + "/docs/archive/2025")
  wait("deep") { c.folder == finger + "/docs/archive/2025" && !c.rows.isEmpty }
  check(c.chipTitles == ["Developer", "…", "archive", "2025"], "deep paths collapse", c.chipTitles)
  c.go(to: dev)
  wait("back to Developer") { c.folder == dev && name(c.selectedPath) == "finger" }

  // Inside a folder, typing also searches below it.
  type("readme")
  wait("deeper results") { c.items(in: "Deeper in Developer").count == 5 }
  check(c.sectionTitles.first == "Deeper in Developer", "nothing directly inside matches, so deeper comes first", c.sectionTitles)
  check(
    c.items(in: "Deeper in Developer").first?.file.path == finger + "/README.md",
    "deeper matches rank by recency", c.items(in: "Deeper in Developer").map(\.file.path))
  check(c.completion == ".md", "completion keeps the name's own case", c.completion)
  waitPreview()
  check(
    spy.content.report.kind == .markdown && spy.calls.last?.1 == nil,
    "a name match previews Markdown without highlighting", spy.content.report.kind)
  snapshot("deeper-readme")

  // And inside its files; the preview hears what matched.
  key(esc, "\u{1b}")
  type("poison")
  wait("inside files") { c.items(in: "Inside Files").map(\.file.name) == ["launcher.rs"] }
  check(spy.calls.last?.1 == "poison", "a content match passes the query to the preview", spy.calls.last?.1 ?? "nil")
  waitPreview()
  check(spy.content.report.matches == 4, "the preview highlights every match", spy.content.report.matches)
  snapshot("inside-files")
  key(esc, "\u{1b}")

  // The folder peek: clicking an item goes in with it selected.
  check(name(c.selectedPath) == "finger", "clearing the text lands back on finger", name(c.selectedPath))
  c.peek.display()
  let rowPoint = c.peek.convert(NSPoint(x: 40, y: 75 + 28 * 2 + 14), to: nil)
  c.peek.mouseDown(
    with: NSEvent.mouseEvent(
      with: .leftMouseDown, location: rowPoint, modifierFlags: [], timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
  wait("peek click") { c.folder == finger && name(c.selectedPath) == "native" }
  check(true, "clicking a peek item goes in with that item selected")
  check(
    c.peek.header.frame.height == 58 && c.peek.header.name.font == NSFont.systemFont(ofSize: 14, weight: .semibold),
    "the folder peek uses the file preview's header")

  // A Swift file.
  key(ret, "\r")
  wait("inside native") { c.folder == finger + "/native" && !c.rows.isEmpty }
  type("prev")
  wait("PreviewPane") { name(c.selectedPath) == "PreviewPane.swift" }
  waitPreview()
  check(spy.content.report.kind == .code && spy.content.headerTitle == "PreviewPane.swift", "a Swift file previews as code")
  snapshot("code-swift")
  key(esc, "\u{1b}")

  // Motion: a keystroke during an animation finishes it at once.
  c.allowsMotion = true
  c.go(to: dev)
  wait("up to Developer") { c.folder == dev }
  key(ret, "\r")
  wait("into finger") { c.folder == finger && !c.rows.isEmpty }
  let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  check(c.isAnimating != still, still ? "Reduce Motion keeps navigation still" : "going in animates")
  key(down, "")
  check(!c.isAnimating && c.flyers.isEmpty && c.chips.hiddenPath == nil, "a keystroke lands the animation at once")

  // ~ on the empty home field goes Home; ⌫ from Home leaves browsing.
  key(esc, "\u{1b}")
  wait("left browsing") { c.folder == nil }
  if !c.query.isEmpty { key(esc, "\u{1b}") }
  if !panel.isVisible { c.showOffscreen() }
  if !c.query.isEmpty { key(esc, "\u{1b}") }
  check(c.folder == nil && c.query.isEmpty, "back on Home")
  type("~")
  wait("Home") { c.folder == root && !c.rows.isEmpty }
  check(c.chipTitles == ["Home"], "there is a Home chip only in Home", c.chipTitles)
  check(c.itemNames.prefix(4) == ["Desktop", "Developer", "Documents", "Downloads"], "Home lists its folders", c.itemNames)
  key(del, "\u{7f}")
  wait("left Home") { c.folder == nil }

  // ↩ on a file opens it and hides; ⌘↩ shows it in Finder.
  type("launcher")
  wait("found launcher") { name(c.selectedPath) == "launcher.rs" }
  key(ret, "\r", .command)
  check(revealed.last?.lastPathComponent == "launcher.rs" && !panel.isVisible, "⌘↩ shows in Finder and hides")
  c.showOffscreen()
  wait("still found") { name(c.selectedPath) == "launcher.rs" }
  key(ret, "\r")
  check(opened.last?.lastPathComponent == "launcher.rs" && !panel.isVisible, "↩ opens a file and hides")
  check(search.cancels >= 0, "stale searches were cancelled: \(search.cancels)")
  print("panel checks passed")
}
