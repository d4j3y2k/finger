import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// scripts/check.sh builds this standalone AppKit host against the app's UI code.
// It renders ContentPreview offscreen for each fixture, in light and dark, at
// the panel's size and at Quick Look size, checks what it shows, and writes
// PNGs to the folder given as the first argument for a person to review.

private let paneSize = NSSize(width: 400, height: 440)
private let quickLookSize = NSSize(width: 600, height: 460)

private func wait(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
  let end = Date().addingTimeInterval(timeout)
  while !condition() {
    precondition(Date() < end, "timed out: \(label)")
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
  }
}
private func spin(_ seconds: TimeInterval) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
}
private var fixtureRoot: URL?
private func check(_ condition: Bool, _ message: @autoclosure () -> String) {
  if !condition {
    FileHandle.standardError.write(Data(("FAILED: " + message() + "\n").utf8))
    if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    exit(1)
  }
}

// MARK: - Fixtures

private struct Fixture {
  let name: String
  let match: String?
  /// Quick Look size and both appearances, or only the pane in both.
  let everySize: Bool
  let verify: (ContentPreview) -> Void
}

private let notes = """
  Overlap 01

  The vermilion edition is approved for delivery. Keep the PNG proof with its editable SVG source.

  Paper: Hahnemühle Photo Rag, 308 gsm
  Run: 40 prints, numbered on the back in pencil
  Trim: 3 mm bleed on all sides

  Ship flat. No rolled tubes for this edition. Vermilion ink only.

  """

private let readme = """
  # Finger

  Finger opens to a native Mac worktable with visual previews of files from your \
  current project.

  ## Build

  From the project folder, run `scripts/build.sh`. Each build configures Codex and Claude \
  Code for this checkout.

  ```sh
  scripts/build.sh
  scripts/check.sh   # full suite, including a 10,000-entry GUI bench
  ```

  ## Keys

  - **⌃ Space** shows or hides Finger
  - **Return** opens the selection, *Space* opens Quick Look
  - `⌘↩` shows it in Finder
    - nested items keep their place

  ### Notes

  1. Search looks inside files.
  2. Previews read a bounded prefix. See [the docs](https://example.com/docs).

  > The bench runs ten thousand entries.

  ---

  Run the bench again after a change.

  """

private let swiftSource = """
  import AppKit
  import QuickLookThumbnailing

  // The preview and the main browser have
  // independent scroll positions.
  final class PreviewPane: NSView {
    weak var browser: Browser?
    private var generation = 0
    private let limit = 0x1F + 12_000

    func show(_ entry: Entry) {
      generation += 1
      let ticket = generation
      PreviewReader.read(entry) { [weak self] model in
        guard let self, ticket == self.generation else { return }
        self.apply(model)
      }
    }

    /* A block comment
       spanning two lines. */
    @objc private func refresh(_ sender: Any?) {
      let title = "Reading \\(generation) items…"
      print(title, 3.25, #selector(refresh(_:)))
      if let url = browser?.selection.first, !url.path.isEmpty {
        NSWorkspace.shared.open(url)
      }
    }

    @MainActor
    func layoutRows(width: CGFloat) -> [NSRect] {
      (0..<4).map { NSRect(x: 0, y: CGFloat($0) * 28, width: width, height: 28) }
    }
  }

  """

private let rustSource = """
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

  #[derive(Debug, Clone)]
  struct Entry<'a> {
      name: &'a str,
      size: u64,
  }

  fn main() {
      let entry = Entry { name: "plan.svg", size: 1_024 };
      let pattern = r"^\\d+$";
      let c = 'x';
      println!("{:?} {} {} poisoned: {}", entry, pattern, c, 0.5e3);
  }

  """

private let extraSources: [(String, String, String?)] = [
  (
    "config.toml",
    """
    # Finger build settings
    [package]
    name = "finger"
    version = "0.4.2"
    edition = '2021'
    features.desktop = true

    [dependencies]
    serde = { version = "1.0", features = ["derive"] }
    """, nil
  ),
  (
    "data.json",
    """
    {
      "name": "finger",
      "entries": 10000,
      "ratio": 0.75,
      "enabled": true,
      "owner": null,
      "tags": ["mac", "files"]
    }
    """, nil
  ),
  (
    "settings.yaml",
    """
    # Bench settings
    bench:
      entries: 10000
      samples: 3
      name: "GUI bench"
    folders:
      - path: ~/Developer
        hidden: false
      - path: '/tmp/finger'
    """, nil
  ),
  (
    "tool.py",
    """
    #!/usr/bin/env python3
    \"\"\"Write a demo folder.\"\"\"
    import os

    @dataclass
    class Fixture:
        def build(self, root: str, count: int = 10) -> None:
            for i in range(count):
                path = os.path.join(root, f"sample-{i}.txt")
                open(path, "w").write('hello')  # a comment
            return None
    """, nil
  ),
  (
    "run.sh",
    """
    #!/bin/bash
    set -euo pipefail
    # Build, then run the checks.
    root="$(dirname "$0")/.."
    for f in "$root"/tests/*.swift; do
      echo "checking ${f##*/}" $#
    done
    exit 0
    """, nil
  ),
  (
    "main.go",
    """
    package main

    import "fmt"

    // Entry is one row in a folder.
    type Entry struct {
    \tName string
    \tSize int64
    }

    func main() {
    \te := Entry{Name: "plan.svg", Size: 0x400}
    \tfmt.Println(e, `raw string`)
    }
    """, nil
  ),
  (
    "view.ts",
    """
    import { render } from "./render";

    interface Row { name: string; size?: number }

    export async function show(rows: Row[]): Promise<void> {
      const total = rows.reduce((n, r) => n + (r.size ?? 0), 0);
      console.log(`showing ${rows.length} rows`, total / 1024);
      await render(rows); // draw
    }
    """, nil
  ),
  (
    "Obj.m",
    """
    #import <AppKit/AppKit.h>
    #define LIMIT 128

    @interface Preview : NSView
    @property (nonatomic, copy) NSString *title;
    @end

    @implementation Preview
    - (void)showTitle:(NSString *)title {
        self.title = [title stringByAppendingString:@" (preview)"];
        NSLog(@"%@ %d", self.title, LIMIT);
    }
    @end
    """, nil
  ),
  (
    "budget.csv",
    """
    Month,Prints,Paper,Framing,Total
    Oct,$800,$214,$90,"$1,104"
    Nov,"$1,280",$236,$120,"$1,636"
    Dec,$900,$190,$100,"$1,190"
    Q4,"$2,980",$640,$310,"$3,930"
    """, "paper"
  ),
]

private func makeFixtures(_ root: URL) throws {
  let files = FileManager.default
  try notes.write(to: root.appendingPathComponent("Print notes.txt"), atomically: true, encoding: .utf8)
  try readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
  try swiftSource.write(
    to: root.appendingPathComponent("PreviewPane.swift"), atomically: true, encoding: .utf8)
  try rustSource.write(to: root.appendingPathComponent("launcher.rs"), atomically: true, encoding: .utf8)
  for (name, text, _) in extraSources {
    try (text + "\n").write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  try makePDF(root.appendingPathComponent("Tax estimate.pdf"))
  try makePNG(root.appendingPathComponent("Overlap 01.png"))
  try makeZip(root)
  try makeRTF(root.appendingPathComponent("Letter.rtf"))
  // A long log: more than the 512 KB the preview reads.
  var big = ""
  big.reserveCapacity(900_000)
  for i in 1...11_000 {
    big += "2026-11-21 12:58:\(String(format: "%02d", i % 60)) worker[\(i)] scanned folder \(i) of 11000, 128 entries\n"
  }
  try big.write(to: root.appendingPathComponent("large.log"), atomically: true, encoding: .utf8)
  _ = files
}

private let taxPages: [[(String, String)]] = [
  [
    ("Estimated Tax", ""), ("Q4 2026 · Prepared Nov 16, 2026", ""),
    ("Self-employment income", "$18,420"), ("Business expenses", "(4,115)"),
    ("Net earnings", "14,305"), ("Self-employment tax", "2,021"), ("Income tax estimate", "1,239"),
    ("Payment due January 15", "$3,260"), ("Paper and framing are itemized on page 2.", ""),
  ],
  [
    ("Business Expenses", ""), ("October to December 2026", ""),
    ("Prints, Harbor Print Co.", "$2,980"), ("Paper", "640"), ("Framing", "310"),
    ("Software", "185"), ("Total", "$4,115"),
  ],
]

private func makePDF(_ url: URL) throws {
  var box = CGRect(x: 0, y: 0, width: 612, height: 792)
  guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  for rows in taxPages {
    context.beginPDFPage(nil)
    let ns = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    var y: CGFloat = 792 - 90
    for (index, (label, value)) in rows.enumerated() {
      let title = index == 0
      let font = title ? NSFont.systemFont(ofSize: 30, weight: .semibold) : NSFont.systemFont(ofSize: 15)
      let color = index == 1 ? NSColor.gray : NSColor.black
      (label as NSString).draw(
        at: NSPoint(x: 72, y: y), withAttributes: [.font: font, .foregroundColor: color])
      if !value.isEmpty {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (value as NSString).size(withAttributes: attributes).width
        (value as NSString).draw(at: NSPoint(x: 540 - width, y: y), withAttributes: attributes)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 72, y: y - 12, width: 468, height: 0.75).fill()
      }
      y -= title ? 34 : index == 1 ? 50 : 38
    }
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
  }
  context.closePDF()
}

private func makePNG(_ url: URL) throws {
  let width = 1600
  let height = 1200
  guard let space = CGColorSpace(name: CGColorSpace.displayP3),
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw CocoaError(.fileWriteUnknown) }
  context.setFillColor(CGColor(colorSpace: space, components: [0.95, 0.93, 0.88, 1])!)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(colorSpace: space, components: [0.89, 0.26, 0.2, 1])!)
  context.fillEllipse(in: CGRect(x: 700, y: 380, width: 640, height: 640))
  context.setFillColor(CGColor(colorSpace: space, components: [0.16, 0.34, 0.72, 0.85])!)
  context.fillEllipse(in: CGRect(x: 360, y: 180, width: 540, height: 540))
  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
  // Where the file came from, as a browser records it.
  let froms = try PropertyListSerialization.data(
    fromPropertyList: ["https://typefoundry.example/overlap-01.png", "https://typefoundry.example/"],
    format: .binary, options: 0)
  setAttribute(url, "com.apple.metadata:kMDItemWhereFroms", froms)
  setAttribute(url, "com.apple.quarantine", Data("0083;6740a2b1;Safari;".utf8))
}

private func setAttribute(_ url: URL, _ name: String, _ data: Data) {
  let result = data.withUnsafeBytes { bytes in
    setxattr(url.path, name, bytes.baseAddress, data.count, 0, 0)
  }
  check(result == 0, "setxattr \(name)")
}

private func makeZip(_ root: URL) throws {
  let stage = root.appendingPathComponent("zip-stage", isDirectory: true)
  let fonts = stage.appendingPathComponent("Fieldwork Sans", isDirectory: true)
  try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
  let sizes = [
    ("FieldworkSans-Regular.otf", 212_000), ("FieldworkSans-Medium.otf", 214_000),
    ("FieldworkSans-Bold.otf", 216_000), ("FieldworkSans-Italic.otf", 220_000),
    ("FieldworkSans-Variable.ttf", 1_100_000),
  ]
  for (name, size) in sizes {
    try Data(repeating: 0x2A, count: size).write(to: fonts.appendingPathComponent(name))
  }
  try Data(repeating: 0x25, count: 3_200_000).write(to: stage.appendingPathComponent("Specimen.pdf"))
  try Data(repeating: 0x4C, count: 4_000).write(to: stage.appendingPathComponent("LICENSE.txt"))
  let zip = Process()
  zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  zip.currentDirectoryURL = stage
  zip.arguments = [
    "-r", "-q", root.appendingPathComponent("font-pack.zip").path, "Fieldwork Sans", "Specimen.pdf",
    "LICENSE.txt",
  ]
  try zip.run()
  zip.waitUntilExit()
  check(zip.terminationStatus == 0, "zip exited \(zip.terminationStatus)")
  try FileManager.default.removeItem(at: stage)
}

private func makeRTF(_ url: URL) throws {
  let text = NSMutableAttributedString(
    string: "Studio letter\n",
    attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
  text.append(
    NSAttributedString(
      string: "Dear Fold Studies,\n\nThe proofs for Overlap 01 are ready to collect on Friday.\n",
      attributes: [.font: NSFont.systemFont(ofSize: 13)]))
  let data = try text.data(
    from: NSRange(location: 0, length: text.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  try data.write(to: url)
}

// MARK: - Rendering

private final class Backdrop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

private final class Stage {
  let window: NSWindow
  let preview = ContentPreview()
  init(size: NSSize, dark: Bool) {
    window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
    preview.frame = backdrop.bounds
    preview.autoresizingMask = [.width, .height]
    backdrop.addSubview(preview)
    window.contentView = backdrop
  }
  func resize(_ size: NSSize) {
    window.setContentSize(size)
    window.contentView?.layoutSubtreeIfNeeded()
  }
}

private func snapshot(_ view: NSView) -> NSBitmapImageRep {
  view.layoutSubtreeIfNeeded()
  view.displayIfNeeded()
  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
  view.cacheDisplay(in: view.bounds, to: rep)
  if let pdf = descendants(view, PDFView.self).first, pdf.document != nil {
    drawPages(pdf, into: rep, root: view)
  }
  return rep
}

private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
  (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
}

/// PDFView draws page content in background tiles that an offscreen window
/// never gets, so cacheDisplay leaves the pages blank. Paint each visible page
/// where PDFView laid it out, with its highlighted selections, so the PNG shows
/// what the pane shows on screen.
private func drawPages(_ pdf: PDFView, into rep: NSBitmapImageRep, root: NSView) {
  guard let document = pdf.document, let context = NSGraphicsContext(bitmapImageRep: rep) else {
    return
  }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  let cg = context.cgContext
  let visible = pdf.convert(pdf.bounds, to: root)
  cg.clip(to: root.isFlipped ? flip(visible, root) : visible)
  for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { continue }
    let box = page.bounds(for: pdf.displayBox)
    var rect = pdf.convert(pdf.convert(box, from: page), to: root)
    if root.isFlipped { rect = flip(rect, root) }
    guard rect.intersects(visible) else { continue }
    cg.saveGState()
    cg.translateBy(x: rect.minX, y: rect.minY)
    cg.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
    cg.translateBy(x: -box.minX, y: -box.minY)
    page.draw(with: pdf.displayBox, to: cg)
    cg.restoreGState()
  }
  for selection in pdf.highlightedSelections ?? [] {
    for page in selection.pages {
      var rect = pdf.convert(pdf.convert(selection.bounds(for: page), from: page), to: root)
      if root.isFlipped { rect = flip(rect, root) }
      cg.saveGState()
      cg.setBlendMode(.multiply)
      cg.setFillColor((selection.color ?? .findHighlightColor).cgColor)
      cg.fill(rect.insetBy(dx: -1, dy: -1))
      cg.restoreGState()
    }
  }
  NSGraphicsContext.restoreGraphicsState()
}

private func flip(_ rect: NSRect, _ view: NSView) -> NSRect {
  NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
}

private func write(_ rep: NSBitmapImageRep, _ url: URL) {
  let png = rep.representation(using: .png, properties: [:])!
  try! png.write(to: url)
}

/// Mean brightness of a region given in points from the top left.
private func brightness(_ rep: NSBitmapImageRep, _ rect: NSRect) -> CGFloat {
  let scale = CGFloat(rep.pixelsWide) / rep.size.width
  var total: CGFloat = 0
  var count: CGFloat = 0
  var y = rect.minY
  while y < rect.maxY {
    var x = rect.minX
    while x < rect.maxX {
      if let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) {
        total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        count += 1
      }
      x += 4
    }
    y += 4
  }
  return count > 0 ? total / count : 0
}

/// Whether a region holds the find highlight's yellow.
private func yellow(_ rep: NSBitmapImageRep, _ rect: NSRect) -> Bool {
  let scale = CGFloat(rep.pixelsWide) / rep.size.width
  var y = rect.minY
  while y < rect.maxY {
    var x = rect.minX
    while x < rect.maxX {
      if let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB),
        c.redComponent > 0.9, c.greenComponent > 0.85, c.blueComponent < 0.4
      {
        return true
      }
      x += 2
    }
    y += 2
  }
  return false
}

/// Fraction of sampled pixels in a region that differ from the first sample.
private func variety(_ rep: NSBitmapImageRep, _ rect: NSRect) -> CGFloat {
  let scale = CGFloat(rep.pixelsWide) / rep.size.width
  var first: NSColor?
  var differ: CGFloat = 0
  var count: CGFloat = 0
  var y = rect.minY
  while y < rect.maxY {
    var x = rect.minX
    while x < rect.maxX {
      if let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale)) {
        if let f = first {
          if abs(f.redComponent - c.redComponent) + abs(f.greenComponent - c.greenComponent)
            + abs(f.blueComponent - c.blueComponent) > 0.06
          {
            differ += 1
          }
        } else {
          first = c
        }
        count += 1
      }
      x += 3
    }
    y += 3
  }
  return count > 0 ? differ / count : 0
}

// MARK: - Checks

@main
private enum ContentPreviewChecks {
  static func main() throws {
    let output = URL(
      fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath + "/build/content-preview",
      isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "Finger ContentPreview " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    fixtureRoot = root
    defer { try? FileManager.default.removeItem(at: root) }
    try makeFixtures(root)
    try run(root, output)
  }

  static func run(_ root: URL, _ output: URL) throws {
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    var notesSeen = ""
    let fixtures: [Fixture] = [
      Fixture(name: "Print notes.txt", match: "vermilion", everySize: true) { p in
        check(p.report.kind == .prose, "txt kind \(p.report.kind)")
        check(p.report.lines == 9, "txt lines \(String(describing: p.report.lines))")
        check(p.report.matches == 2, "txt matches \(p.report.matches)")
        check(p.headerDetail.hasPrefix("Plain Text · ") && p.headerDetail.hasSuffix(" bytes · 9 lines"),
          "txt header \(p.headerDetail)")
        notesSeen = p.textView?.string ?? ""
      },
      Fixture(name: "README.md", match: "bench", everySize: true) { p in
        check(p.report.kind == .markdown, "md kind \(p.report.kind)")
        check(p.report.matches == 3, "md matches \(p.report.matches)")
        let shown = p.textView?.string ?? ""
        // Rendered, not raw: no heading marks, bold stars or backticks.
        check(!shown.contains("# Finger") && !shown.contains("**") && !shown.contains("`scripts"),
          "md shows raw Markdown")
        check(shown.contains("•\t⌃ Space shows or hides Finger"), "md list item")
        check(shown.contains("scripts/check.sh   # full suite"), "md fenced block")
      },
      Fixture(name: "PreviewPane.swift", match: nil, everySize: true) { p in
        check(p.report.kind == .code, "swift kind \(p.report.kind)")
        check(p.report.lines == 34, "swift lines \(String(describing: p.report.lines))")
        check(p.report.matches == 0, "swift matches \(p.report.matches)")
        check(p.headerDetail.hasPrefix("Swift Source · ") && p.headerDetail.hasSuffix(" · 34 lines"),
          "swift header \(p.headerDetail)")
        checkColors(p)
      },
      Fixture(name: "launcher.rs", match: "poisoned", everySize: true) { p in
        check(p.report.kind == .code, "rs kind \(p.report.kind)")
        check(p.report.lines == 29, "rs lines \(String(describing: p.report.lines))")
        check(p.report.matches == 3, "rs matches \(p.report.matches)")
      },
      Fixture(name: "Tax estimate.pdf", match: "paper", everySize: true) { p in
        check(p.report.kind == .pdf, "pdf kind \(p.report.kind)")
        check(p.report.pages == 2, "pdf pages \(String(describing: p.report.pages))")
        check(p.report.matches == 2, "pdf matches \(p.report.matches)")
        check(p.pdfView?.highlightedSelections?.count == 2, "pdf highlighted selections")
        check(p.headerDetail.hasSuffix(" · 2 pages"), "pdf header \(p.headerDetail)")
      },
      Fixture(name: "Overlap 01.png", match: nil, everySize: true) { p in
        check(p.report.kind == .image, "png kind \(p.report.kind)")
        check(p.headerDetail.hasPrefix("PNG Image · ") && p.headerDetail.hasSuffix(" · 1600 × 1200"),
          "png header \(p.headerDetail)")
        let facts = Dictionary(p.imageFacts, uniquingKeysWith: { a, _ in a })
        check(facts["Dimensions"] == "1600 × 1200", "png dimensions \(facts)")
        check(facts["Color"] == "Display P3", "png color \(facts)")
        check(facts["From"] == "typefoundry.example, Safari", "png from \(facts)")
        check(facts["Where"] != nil && facts["Modified"] != nil, "png where/modified \(facts)")
      },
      Fixture(name: "font-pack.zip", match: nil, everySize: true) { p in
        check(p.report.kind == .archive, "zip kind \(p.report.kind)")
        check(p.report.items == 7, "zip files \(String(describing: p.report.items))")
        let rows = p.archiveRows
        check(rows.count == 8, "zip rows \(rows.count)")
        check(rows[0].directory && rows[0].name == "Fieldwork Sans" && rows[0].detail == "5 items",
          "zip folder row \(rows[0])")
        check(rows[1].depth == 1 && rows[1].name == "FieldworkSans-Bold.otf", "zip nested \(rows[1])")
        check(rows[6].name == "LICENSE.txt" && rows[6].depth == 0, "zip file row \(rows[6])")
        check(p.headerDetail.hasSuffix(" · 7 files"), "zip header \(p.headerDetail)")
      },
      Fixture(name: "Letter.rtf", match: nil, everySize: true) { p in
        check(p.report.kind == .quickLook, "rtf kind \(p.report.kind)")
        check(p.quickLookView?.previewItem?.previewItemURL?.lastPathComponent == "Letter.rtf",
          "Quick Look item")
      },
      Fixture(name: "large.log", match: nil, everySize: false) { p in
        check(p.report.kind == .code, "log kind \(p.report.kind)")
        check(p.report.capped, "log not capped")
        let lines = p.report.lines ?? 0
        check(lines > 1_000 && lines <= 10_000, "log lines \(lines)")
        check(p.textView?.string.hasSuffix("Showing the first \(lines.formatted()) lines") == true,
          "log note")
        check(p.headerDetail.hasSuffix(" · \(lines.formatted())+ lines"), "log header \(p.headerDetail)")
      },
    ] + extraSources.map { name, _, match in
      Fixture(name: name, match: match, everySize: false) { p in
        check(p.report.kind == (name.hasSuffix(".csv") ? .sheet : .code), "\(name) kind \(p.report.kind)")
        if name.hasSuffix(".csv") {
          check(p.report.lines == 5 && p.report.matches == 1, "csv rows/matches \(p.report)")
        }
      }
    }

    print("note: PDFView renders page content in background tiles that an offscreen window never gets; the PDF PNGs paint each page where PDFView laid it out, with its highlighted selections")
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    var written = 0
    for fixture in fixtures {
      for dark in [false, true] {
        let stage = Stage(size: paneSize, dark: dark)
        let sizes = fixture.everySize ? [("pane", paneSize), ("quicklook", quickLookSize)] : [("pane", paneSize)]
        for (label, size) in sizes {
          stage.resize(size)
          let file = url(fixture.name)
          stage.preview.show(file, match: fixture.match)
          // The header appears at once, before anything is read.
          check(stage.preview.headerTitle == fixture.name, "header at once \(fixture.name)")
          wait("load \(fixture.name)") { stage.preview.report.kind != .loading && !stage.preview.revealing }
          fixture.verify(stage.preview)
          if fixture.match != nil, [.prose, .markdown, .code].contains(stage.preview.report.kind) {
            checkHighlight(stage.preview, fixture.name)
          }
          // PDF pages and Quick Look draw a moment after loading.
          spin(stage.preview.report.kind == .pdf || stage.preview.report.kind == .quickLook ? 0.8 : 0.05)
          let rep = snapshot(stage.window.contentView!)
          let png = output.appendingPathComponent(
            "\((fixture.name as NSString).deletingPathExtension)-\((fixture.name as NSString).pathExtension)-\(dark ? "dark" : "light")-\(label).png")
          write(rep, png)
          written += 1
          let body = NSRect(x: 20, y: 70, width: size.width - 40, height: size.height - 90)
          let drawn = variety(rep, body)
          if stage.preview.report.kind == .quickLook {
            print("quick look \(dark ? "dark" : "light") \(label): \(drawn > 0.01 ? "drew content" : "blank offscreen") (\(String(format: "%.3f", drawn)))")
          } else {
            check(drawn > 0.01, "\(fixture.name) body looks blank (\(drawn))")
          }
        }
        stage.preview.show(nil, match: nil)
        stage.window.close()
      }
      print("ok", fixture.name)
    }
    let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    check(before == after, "the zip preview extracted files: \(after)")
    check(notesSeen.contains("vermilion edition"), "notes text")

    try checkSymbols(root, output)
    try checkHostileZip(root)
    try checkLoading(root, output)
    try checkAppearance(root, output)
    print("checks passed; wrote \(written + 10) PNGs to \(output.path)")
  }

  /// Every hit has the find highlight, and the first is scrolled into view.
  static func checkHighlight(_ p: ContentPreview, _ name: String) {
    guard let text = p.textView, let storage = text.textStorage else {
      check(false, "\(name) has no text view")
      return
    }
    var highlighted = 0
    storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      if let color = value as? NSColor, color == NSColor.findHighlightColor { highlighted += 1 }
    }
    check(highlighted == p.report.matches, "\(name) highlighted \(highlighted) of \(p.report.matches)")
  }

  /// Keywords, strings and comments get Xcode's colors.
  static func checkColors(_ p: ContentPreview) {
    guard let storage = p.textView?.textStorage else { return check(false, "no code text") }
    let text = storage.string as NSString
    func color(of word: String) -> NSColor? {
      let range = text.range(of: word)
      guard range.location != NSNotFound else { return nil }
      return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    check(color(of: "final") == ContentInk.keyword, "keyword color")
    check(color(of: "\"Reading") == ContentInk.string, "string color")
    check(color(of: "// The preview") == ContentInk.comment, "comment color")
    check(color(of: "NSView") == ContentInk.type, "type color")
    check(color(of: "apply(") == ContentInk.call, "call color")
    check(color(of: "@objc") == ContentInk.attribute, "attribute color")
    check(color(of: "3.25") == ContentInk.number, "number color")
  }

  /// Keyboard symbols and arrows draw as text glyphs, never as color emoji,
  /// in plain text, code and Markdown (including inline code).
  static func checkSymbols(_ root: URL, _ output: URL) throws {
    let symbols = ["⌘", "⌥", "⇧", "⌫", "↩", "⇥", "→", "←"]
    let line = symbols.joined(separator: " ")
    let files = [
      ("keys.txt", "Shortcuts: \(line)\nPress ⌘↩ to open.\n"),
      ("keys.swift", "// Shortcuts: \(line)\nlet open = \"⌘↩\" // \(line)\n"),
      ("keys.md", "# Keys ⌘↩\n\nShortcuts: \(line), **⌥→** and `⌘↩` or `\(line)`.\n\n- `⇧⌫` deletes\n"),
    ]
    for (name, text) in files {
      try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
      for dark in [false, true] {
        let stage = Stage(size: paneSize, dark: dark)
        stage.preview.show(root.appendingPathComponent(name), match: nil)
        wait("load \(name)") { stage.preview.report.kind != .loading }
        guard let view = stage.preview.textView, let storage = view.textStorage,
          let layout = view.layoutManager, let container = view.textContainer
        else { return check(false, "\(name) has no text view") }
        // Layout settles fonts: a character the font lacks gets a fallback font here.
        layout.ensureLayout(for: container)
        let ns = storage.string as NSString
        var found = Set<String>()
        for symbol in symbols {
          var search = NSRange(location: 0, length: ns.length)
          while true {
            let hit = ns.range(of: symbol, range: search)
            if hit.location == NSNotFound { break }
            let font = storage.attribute(.font, at: hit.location, effectiveRange: nil) as? NSFont
            let fontName = font?.fontName ?? "none"
            check(!fontName.localizedCaseInsensitiveContains("emoji"),
              "\(name): \(symbol) draws with \(fontName)")
            if let font {
              var units = Array(symbol.utf16)
              var glyphs = [CGGlyph](repeating: 0, count: units.count)
              check(CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count),
                "\(name): \(fontName) has no glyph for \(symbol)")
            }
            found.insert(symbol)
            search = NSRange(location: NSMaxRange(hit), length: ns.length - NSMaxRange(hit))
          }
        }
        check(found.count == symbols.count, "\(name): found only \(found.sorted())")
        let png = output.appendingPathComponent(
          "keys-\((name as NSString).pathExtension)-\(dark ? "dark" : "light")-pane.png")
        write(snapshot(stage.window.contentView!), png)
        stage.window.close()
      }
    }
    print("ok symbols draw as text in text, code and Markdown")
  }

  /// A zip whose one entry is nested 30,000 folders deep, and one with a
  /// directory that claims more bytes than the file holds.
  static func checkHostileZip(_ root: URL) throws {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
    let name = Array(String(repeating: "a/", count: 30_000).utf8) + Array("x.txt".utf8)
    var central = le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
    central += le32(0) + le32(0) + le32(5) + le16(name.count) + le16(0) + le16(0) + le16(0)
    central += le16(0) + le32(0) + le32(0) + name
    let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count)
      + le32(0) + le16(0)
    try Data(central + end).write(to: root.appendingPathComponent("deep.zip"))
    let lying = le32(0x0605_4B50) + le16(0) + le16(0) + le16(9) + le16(9) + le32(50_000_000)
      + le32(10) + le16(0)
    try Data(Array(repeating: 0, count: 40) + lying).write(to: root.appendingPathComponent("lying.zip"))
    let stage = Stage(size: paneSize, dark: false)
    stage.preview.show(root.appendingPathComponent("deep.zip"), match: nil)
    wait("deep zip") { stage.preview.report.kind != .loading }
    check(stage.preview.report.kind == .archive && stage.preview.report.items == 1, "deep zip \(stage.preview.report)")
    check(stage.preview.archiveRows.count == ZipIndex.maxDepth, "deep zip rows \(stage.preview.archiveRows.count)")
    stage.preview.show(root.appendingPathComponent("lying.zip"), match: nil)
    wait("lying zip") { stage.preview.report.kind != .loading }
    check(stage.preview.report.kind != .archive, "lying zip listed")
    stage.window.close()
    print("ok hostile zips")
  }

  /// A newer show() wins, nothing freezes, and nil clears.
  static func checkLoading(_ root: URL, _ output: URL) throws {
    let stage = Stage(size: paneSize, dark: false)
    var loads = 0
    stage.preview.onLoad = { loads += 1 }
    // Watch the main thread while a large file loads.
    var last = Date()
    var longest: TimeInterval = 0
    let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
      let now = Date()
      longest = max(longest, now.timeIntervalSince(last))
      last = now
    }
    RunLoop.main.add(timer, forMode: .common)
    let started = Date()
    stage.preview.show(root.appendingPathComponent("large.log"), match: "folder 4000 of")
    let returned = Date().timeIntervalSince(started)
    check(returned < 0.05, "show() took \(returned)s on the main thread")
    wait("large file") { stage.preview.report.kind != .loading && !stage.preview.revealing }
    spin(0.2)
    timer.invalidate()
    check(stage.preview.report.matches == 1, "large match \(stage.preview.report.matches)")
    check(stage.preview.bodyScrollOffset > 40_000, "large match scrolled \(stage.preview.bodyScrollOffset)")
    let largeShot = snapshot(stage.window.contentView!)
    write(largeShot, output.appendingPathComponent("large-log-match-light-pane.png"))
    check(yellow(largeShot, NSRect(x: 0, y: 60, width: paneSize.width, height: paneSize.height - 60)),
      "large-log match not visible after reveal")
    // A phrase past the 512 KB that was read highlights nothing, not each word.
    stage.preview.show(root.appendingPathComponent("large.log"), match: "folder 9000 of")
    wait("large file, late match") { stage.preview.report.kind != .loading }
    check(stage.preview.report.matches == 0, "late match \(stage.preview.report.matches)")
    print(String(format: "large file: show() %.1f ms, longest main-thread stall %.0f ms", returned * 1000, longest * 1000))
    check(longest < 0.3, "main thread stalled \(longest)s")

    // A minified file is one enormous line.
    var minified = "var a=["
    while minified.utf8.count < 400_000 { minified += "{\"id\":\(minified.utf8.count),\"name\":\"row\"}," }
    minified += "];\n"
    try minified.write(to: root.appendingPathComponent("bundle.min.js"), atomically: true, encoding: .utf8)
    longest = 0
    last = Date()
    let watch = Timer(timeInterval: 0.005, repeats: true) { _ in
      let now = Date()
      longest = max(longest, now.timeIntervalSince(last))
      last = now
    }
    RunLoop.main.add(watch, forMode: .common)
    stage.preview.show(root.appendingPathComponent("bundle.min.js"), match: nil)
    wait("minified file") { stage.preview.report.kind != .loading }
    spin(0.5)
    _ = snapshot(stage.window.contentView!)
    spin(0.2)
    watch.invalidate()
    print(String(format: "minified file: longest main-thread stall %.0f ms", longest * 1000))
    check(longest < 0.3, "main thread stalled \(longest)s on one long line")
    check(stage.preview.textView?.string.hasSuffix("1 line cut at 3,000 characters") == true,
      "minified note")

    // Many long paragraphs, with the hit at the end.
    let paragraph = String(repeating: "Prints on cotton rag paper keep their color for decades. ", count: 52)
    let longText = (1...150).map { "\($0). " + paragraph }.joined(separator: "\n") + "\nThe last word: vermilion.\n"
    try longText.write(to: root.appendingPathComponent("long-lines.txt"), atomically: true, encoding: .utf8)
    longest = 0
    last = Date()
    let watchLong = Timer(timeInterval: 0.005, repeats: true) { _ in
      let now = Date()
      longest = max(longest, now.timeIntervalSince(last))
      last = now
    }
    RunLoop.main.add(watchLong, forMode: .common)
    stage.preview.show(root.appendingPathComponent("long-lines.txt"), match: "vermilion")
    wait("long lines") { stage.preview.report.kind != .loading && !stage.preview.revealing }
    spin(0.5)
    let longShot = snapshot(stage.window.contentView!)
    watchLong.invalidate()
    write(longShot, output.appendingPathComponent("long-lines-match-light-pane.png"))
    print(String(format: "long paragraphs: longest main-thread stall %.0f ms", longest * 1000))
    check(stage.preview.report.matches == 1, "long-lines match")
    // The hit is on screen: yellow pixels in the visible body.
    check(yellow(longShot, NSRect(x: 0, y: 60, width: paneSize.width, height: paneSize.height - 60)),
      "long-lines match not visible after reveal")
    check(longest < 0.3, "main thread stalled \(longest)s revealing a late match")

    // Rapid selection: only the last one lands.
    loads = 0
    for name in ["Tax estimate.pdf", "large.log", "Overlap 01.png", "launcher.rs", "Print notes.txt"] {
      stage.preview.show(root.appendingPathComponent(name), match: nil)
    }
    wait("last selection") { stage.preview.report.kind != .loading }
    spin(0.6)
    check(stage.preview.report.url?.lastPathComponent == "Print notes.txt", "stale load won")
    check(loads == 1, "\(loads) loads applied for one final selection")
    check(stage.preview.headerTitle == "Print notes.txt", "header")

    stage.preview.show(nil, match: nil)
    check(stage.preview.report.kind == .empty, "nil clears")
    spin(0.3)
    check(stage.preview.report.kind == .empty && loads == 1, "cleared preview stays clear")
    stage.window.close()
    print("ok loading")
  }

  /// The same preview redraws in the new appearance without a new show().
  static func checkAppearance(_ root: URL, _ output: URL) throws {
    let stage = Stage(size: paneSize, dark: false)
    stage.preview.show(root.appendingPathComponent("PreviewPane.swift"), match: nil)
    wait("appearance load") { stage.preview.report.kind != .loading }
    let light = snapshot(stage.window.contentView!)
    stage.window.appearance = NSAppearance(named: .darkAqua)
    spin(0.05)
    let dark = snapshot(stage.window.contentView!)
    write(light, output.appendingPathComponent("appearance-before-light.png"))
    write(dark, output.appendingPathComponent("appearance-after-dark.png"))
    let region = NSRect(x: 60, y: 70, width: 300, height: 300)
    let (l, d) = (brightness(light, region), brightness(dark, region))
    check(l > 0.6 && d < 0.35, String(format: "appearance change: light %.2f, dark %.2f", l, d))
    stage.window.close()
    print("ok appearance")
  }
}
