import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// scripts/check.sh builds this standalone AppKit host against the app's code
// and runs Jev filing over a fixture home with its own Downloads folder:
// a fake Jev transport (nothing reaches TypeSafe), a fake key store (no real
// Keychain), fixture Spotlight evidence, and real moves and undo through the
// finger-core executable in a temporary folder. It writes light and dark PNGs
// of Home with chips, an arrival's Jev bar and the move list.

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

// MARK: - Fakes

/// Answers like Jev, from a table of folder-name probabilities per file.
/// It records every request and never touches the network.
private final class FakeJev: FilingTransport {
  var answers: [String: [String: Double]] = [:]
  var status = 200
  var retryAfter: String?
  var hold = false
  private(set) var requests: [URLRequest] = []
  private(set) var cancelled = 0

  var bodies: [[String: Any]] {
    requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    do {
      while hold { try await Task.sleep(nanoseconds: 5_000_000) }
    } catch {
      cancelled += 1
      throw error
    }
    let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    guard status == 200 else { return (Data("{}".utf8), response) }
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let state = body["state"] as! [String: Any]
    let file = state["file"] as! String
    let destinations = state["destinations"] as! [[String: String]]
    let table = answers[file] ?? [:]
    var probabilities: [String: Double] = [:]
    var named = 0.0
    var unnamed: [String] = []
    for entry in destinations {
      if let p = table[entry["folder"]!] {
        probabilities[entry["id"]!] = p
        named += p
      } else {
        unnamed.append(entry["id"]!)
      }
    }
    for id in unnamed { probabilities[id] = max(0, 1 - named) / Double(unnamed.count) }
    if unnamed.isEmpty, named < 1, let first = destinations.first?["id"] { probabilities[first]! += 1 - named }
    let choice = probabilities.max { $0.value < $1.value }!.key
    let reply: [String: Any] = [
      "answers": ["destination": ["type": "choice", "choice": choice, "probabilities": probabilities]]
    ]
    return (try JSONSerialization.data(withJSONObject: reply), response)
  }
}

/// A key store in memory, standing in for the login Keychain.
private final class FakeStore: FilingSecretStore {
  var secret: String?
  private(set) var reads = 0
  init(_ secret: String? = nil) { self.secret = secret }
  func read() throws -> String? {
    reads += 1
    return secret
  }
  func save(_ secret: String) throws { self.secret = secret }
  func remove() throws { secret = nil }
}

/// Spotlight's answers, from walking the fixture.
private final class FixtureEvidence: FilingEvidenceSource {
  let home: String
  var used: [(path: String, used: Date)] = []
  private(set) var calls = 0
  init(home: String) { self.home = home }

  private func walk(excluding: String) -> [String] {
    var out: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: home)
    while let relative = enumerator?.nextObject() as? String {
      let path = home + "/" + relative
      if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      if path == excluding || path.hasPrefix(excluding + "/") { continue }
      out.append(path)
    }
    return out
  }

  func files(from host: String, excluding: String) -> [String] {
    calls += 1
    return walk(excluding: excluding).filter { FilingArrivals.sourceHost($0)?.contains(host) == true }
  }

  func files(named stem: String, ext: String, excluding: String) -> [String] {
    calls += 1
    return walk(excluding: excluding).filter {
      let name = ($0 as NSString).lastPathComponent.lowercased()
      return name.hasPrefix(stem.lowercased()) && (ext.isEmpty || name.hasSuffix("." + ext.lowercased()))
    }
  }

  func recentlyUsed() -> [(path: String, used: Date)] { used }
}

/// Recents and name searches for the panel, from the fixture.
private final class FixtureSearch: PanelSearching {
  final class Handle: PanelSearchHandle {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  let root: String
  var used: [String: Date] = [:]
  init(root: String) { self.root = root }

  func recentlyUsed(in home: String, _ done: @escaping ([PanelFile]) -> Void) -> PanelSearchHandle {
    let handle = Handle()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      guard !handle.cancelled else { return }
      done(
        self.used.sorted { $0.value > $1.value }.compactMap { path, date in
          var file = PanelFile.quick(path)
          file?.lastUsed = date
          return file
        })
    }
    return handle
  }

  func names(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void)
    -> PanelSearchHandle
  {
    let handle = Handle()
    let matches = (FileManager.default.enumerator(atPath: scope)?.allObjects as? [String] ?? [])
      .filter { !$0.contains("/.") && PanelMatch.rank(query, in: ($0 as NSString).lastPathComponent) > 0 }
      .compactMap { PanelFile.quick(scope + "/" + $0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { if !handle.cancelled { update(matches, true) } }
    return handle
  }

  func contents(_ query: String, in scope: String, _ update: @escaping ([PanelFile], Bool) -> Void)
    -> PanelSearchHandle
  {
    let handle = Handle()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { if !handle.cancelled { update([], true) } }
    return handle
  }
}

private final class SpyPreview: PanelPreview {
  let content = ContentPreview()
  var view: NSView { content }
  func show(_ url: URL?, match: String?) { content.show(url, match: match) }
}

// MARK: - Helpers

private func pump(_ seconds: TimeInterval) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

private func wait(_ label: String, timeout: TimeInterval = 6, _ condition: () -> Bool) {
  let end = Date().addingTimeInterval(timeout)
  while !condition() {
    if Date() >= end {
      FileHandle.standardError.write("FAILED: timed out: \(label)\n".data(using: .utf8)!)
      cleanUp()
      exit(1)
    }
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
  }
}

private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> Any = "") {
  if !ok {
    FileHandle.standardError.write("FAILED: \(label) \(detail())\n".data(using: .utf8)!)
    cleanUp()
    exit(1)
  }
  print("ok -", label)
}

/// Filing's preferences in memory, so the checks create no preference domains.
private final class MemoryPreferences: FilingPreferences {
  private var values: [String: Any] = [:]
  private let lock = NSLock()
  func data(forKey key: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[key] as? Data
  }
  func stringArray(forKey key: String) -> [String]? {
    lock.lock()
    defer { lock.unlock() }
    return values[key] as? [String]
  }
  func set(_ value: Any?, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
  }
}

private var fixtures: [String] = []

/// Removes the fixtures, on success or failure.
private func cleanUp() {
  for root in fixtures { try? FileManager.default.removeItem(atPath: root) }
  fixtures.removeAll()
}

private func setWhereFroms(_ path: String, _ urls: [String]) {
  let data = try! PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
  let status = data.withUnsafeBytes {
    setxattr(path, FilingArrivals.whereFromsAttribute, $0.baseAddress, data.count, 0, 0)
  }
  precondition(status == 0, "setxattr failed for \(path)")
}

/// The mockup's invoice from Harbor Print Co., as a one-page PDF.
private func invoicePDF(number: Int) -> Data {
  let data = NSMutableData()
  var box = CGRect(x: 0, y: 0, width: 612, height: 792)
  let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
  context.beginPDFPage(nil)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, gray: CGFloat = 0.1, right: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: gray, alpha: 1),
      .kern: weight == .bold && size < 20 ? 1.6 : 0,
    ]
    let string = NSAttributedString(string: s, attributes: attributes)
    string.draw(at: NSPoint(x: right ? x - string.size().width : x, y: y))
  }
  text("HARBOR PRINT CO.", 60, 712, 15, .bold)
  text("114 Water Street", 60, 690, 11, gray: 0.35)
  text("Portland, ME 04101", 60, 675, 11, gray: 0.35)
  text("billing@harborprint.co", 60, 660, 11, gray: 0.35)
  text("Invoice", 552, 706, 30, .regular, right: true)
  text("No. \(number)", 552, 684, 11, gray: 0.35, right: true)
  text("Issued Nov 21, 2026", 552, 669, 11, gray: 0.35, right: true)
  text("Due Dec 21, 2026", 552, 654, 11, gray: 0.35, right: true)
  text("BILL TO", 60, 610, 9, .semibold, gray: 0.45)
  text("Fold Studies", 60, 592, 11, .medium)
  text("22 Fore Street, Studio 4", 60, 577, 11, gray: 0.35)
  text("Portland, ME 04101", 60, 562, 11, gray: 0.35)
  let rows = [("Overlap 01 prints, 12 × 16 in", "40", "$30.00", "$1,200.00"), ("Proof prints", "2", "$40.00", "$80.00")]
  var y: CGFloat = 510
  NSColor(white: 0.85, alpha: 1).setFill()
  NSRect(x: 60, y: y + 20, width: 492, height: 0.8).fill()
  for (item, qty, rate, amount) in rows {
    text(item, 60, y, 11)
    text(qty, 380, y, 11, right: true)
    text(rate, 460, y, 11, right: true)
    text(amount, 552, y, 11, right: true)
    y -= 22
  }
  text("Total  $1,280.00", 552, y - 14, 13, .semibold, right: true)
  NSGraphicsContext.restoreGraphicsState()
  context.endPDFPage()
  context.closePDF()
  return data as Data
}

/// A photo of a paper fold, as HEIC.
private func paperPhoto(_ path: String, tilt: CGFloat) {
  let width = 1200, height = 900
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.53, green: 0.56, blue: 0.48, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  func shape(_ points: [CGPoint], _ color: CGColor) {
    context.setFillColor(color)
    context.beginPath()
    context.addLines(between: points)
    context.closePath()
    context.fillPath()
  }
  shape(
    [CGPoint(x: 390, y: 160 + tilt), CGPoint(x: 1010, y: 120), CGPoint(x: 900, y: 610), CGPoint(x: 420, y: 700)],
    CGColor(srgbRed: 0.35, green: 0.37, blue: 0.31, alpha: 0.9))
  shape(
    [CGPoint(x: 360, y: 200 + tilt), CGPoint(x: 980, y: 160), CGPoint(x: 870, y: 650), CGPoint(x: 390, y: 740)],
    CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1))
  shape(
    [CGPoint(x: 520, y: 330), CGPoint(x: 820, y: 300), CGPoint(x: 760, y: 560)],
    CGColor(srgbRed: 0.84, green: 0.83, blue: 0.78, alpha: 1))
  let image = context.makeImage()!
  let url = URL(fileURLWithPath: path) as CFURL
  let destination =
    CGImageDestinationCreateWithURL(url, UTType.heic.identifier as CFString, 1, nil)
    ?? CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
  precondition(CGImageDestinationFinalize(destination), "couldn't write \(path)")
}

private func makeFixture(_ label: String) -> String {
  let files = FileManager.default
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("Finger Filing \(label) " + UUID().uuidString, isDirectory: true)
  let root = base.path
  fixtures.append(root)
  let tree: [String: String] = [
    "Developer/finger/README.md": "# Finger\n",
    "Developer/finger/docs/AGENTS-CONNECTION.md": "# Agent connection\n",
    "Documents/Finances/2026/Q4 budget.csv": "month,cost\nOct,800\n",
    "Documents/Finances/2026/Tax estimate.txt": "Tax estimate 2026\n",
    "Documents/Letters/Lease.txt": "Lease\n",
    "Desktop/Screenshot 2026-11-21 at 11.02.txt": "",
    "Studio/Fold Studies/delivery/Overlap 00.txt": "Delivered.\n",
    "Studio/Posters/Spring poster.txt": "Open Studio\n",
    "Downloads/meeting-notes.txt": "Notes from Thursday.\n",
  ]
  for (relative, text) in tree {
    let url = base.appendingPathComponent(relative)
    try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
  }
  let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/Demo/Fold Studies")
  for folder in ["exports", "exports-old"] {
    try! files.copyItem(
      at: demo.appendingPathComponent(folder), to: base.appendingPathComponent("Studio/Fold Studies/" + folder))
  }
  let studies = root + "/Studio/Fold Studies"
  for folder in ["invoices", "refs"] {
    try! files.createDirectory(atPath: studies + "/" + folder, withIntermediateDirectories: true)
  }
  // Earlier invoices from the same sender, filed in invoices.
  for number in [1119, 1120] {
    let path = studies + "/invoices/Invoice \(number).pdf"
    try! invoicePDF(number: number).write(to: URL(fileURLWithPath: path))
    setWhereFroms(path, ["https://billing.harborprint.co/invoices/\(number).pdf", "https://billing.harborprint.co/"])
  }
  for (index, number) in [4790, 4791, 4795].enumerated() {
    paperPhoto(studies + "/refs/IMG_\(number).HEIC", tilt: CGFloat(index * 20))
  }
  // Today's downloads.
  let invoice = root + "/Downloads/Invoice 1121.pdf"
  try! invoicePDF(number: 1121).write(to: URL(fileURLWithPath: invoice))
  setWhereFroms(invoice, ["https://billing.harborprint.co/invoices/1121.pdf", "https://billing.harborprint.co/"])
  paperPhoto(root + "/Downloads/IMG_4821.HEIC", tilt: 40)
  setWhereFroms(root + "/Downloads/meeting-notes.txt", ["https://docs.example.org/export/notes.txt"])
  // A download still in progress, and a hidden file.
  try! Data("partial".utf8).write(to: URL(fileURLWithPath: root + "/Downloads/Big Archive.zip.crdownload"))
  try! Data().write(to: URL(fileURLWithPath: root + "/Downloads/.DS_Store"))
  // Everything but the downloads is a month old.
  let old = Date().addingTimeInterval(-31 * 86_400)
  let all = (files.enumerator(atPath: root)?.allObjects as? [String] ?? [])
    .filter { !$0.hasPrefix("Downloads") }
    .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
  for relative in all {
    try? files.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + relative)
  }
  return root
}

/// How the fake Jev ranks the fixture's downloads, by folder name.
private let jevTable: [String: [String: Double]] = [
  "Invoice 1121.pdf": ["invoices": 0.91, "2026": 0.06, "Desktop": 0.03],
  "IMG_4821.HEIC": ["refs": 0.58, "Desktop": 0.24, "Documents": 0.18],
  "meeting-notes.txt": ["Documents": 0.41, "Desktop": 0.33, "Letters": 0.26],
]

private func coordinator(
  _ root: String, store: FakeStore, jev: FakeJev, evidence: FixtureEvidence, log: FilingLog,
  environment: [String: String] = [:]
) -> FilingCoordinator {
  let credentials = FilingCredentials(store: store, environment: environment)
  return FilingCoordinator(
    home: root, credentials: credentials, transport: jev, evidence: evidence,
    memory: FilingMemory(preferences: MemoryPreferences()), log: log, preferences: MemoryPreferences())
}

// MARK: - Checks

@main
private enum FilingChecks {
  static func main() throws {
    precondition(
      CommandLine.arguments.count >= 2,
      "Pass the path to the finger-core executable, and optionally a folder for screenshots.")
    core = try TestCore(URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { core.finish() }
    let shots = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    tiersAndWords()
    requestBody()
    keychain()
    arrivalsAndCoordinator(makeFixture("Coordinator"))
    panelChecks(makeFixture("Panel"), shots: shots)
    cleanUp()
    print("filing checks passed")
  }
}

private func tiersAndWords() {
  let home = "/Users/someone"
  check(FilingTier(0.85) == .confident && FilingTier(0.91) == .confident, "85% and up is Confident")
  check(FilingTier(0.8499) == .likely && FilingTier(0.5) == .likely, "50% up to 85% is Likely")
  check(FilingTier(0.4999) == .unsure && FilingTier(0) == .unsure, "below 50% is Unsure")
  func verdict(_ folder: String, _ p: Double) -> FilingVerdict {
    FilingVerdict(ranked: [FilingRanked(folder: folder, probability: p), FilingRanked(folder: home + "/Desktop", probability: 1 - p)], why: nil)
  }
  let invoices = home + "/Studio/Fold Studies/invoices"
  let refs = home + "/Studio/Fold Studies/refs"
  check(
    verdict(invoices, 0.91).chip(home: home) == FilingChip(text: "⇥ invoices", confident: true),
    "a Confident row's chip is “⇥ invoices” in the accent tint")
  check(
    verdict(invoices, 0.85).chip(home: home)?.confident == true
      && verdict(refs, 0.8499).chip(home: home) == FilingChip(text: "refs?", confident: false),
    "the chip changes at exactly 85%")
  check(
    verdict(refs, 0.58).chip(home: home) == FilingChip(text: "refs?", confident: false),
    "a Likely row's chip is a gray “refs?”")
  check(
    verdict(refs, 0.5).chip(home: home) != nil && verdict(refs, 0.4999).chip(home: home) == nil,
    "an Unsure row has no chip, from just below 50%")
  check(verdict(home, 0.9).chip(home: home)?.text == "⇥ Home", "Home reads as Home, not the user name")
  check(verdict(invoices, 0.91).tabAction == .file(to: invoices), "⇥ files a Confident download at once")
  check(verdict(refs, 0.58).tabAction == .choose(preselect: refs), "⇥ on Likely opens the move list on Jev's folder")
  check(verdict(refs, 0.3).tabAction == .choose(preselect: nil), "⇥ on Unsure opens the move list")
  check(FilingTabAction.of(nil) == .choose(preselect: nil), "⇥ on a file Jev hasn't ranked opens the move list")

  let e = FilingEvidence(sameHost: ["Invoice 1119.pdf", "Invoice 1120.pdf"])
  check(
    FilingText.why(file: "Invoice 1121.pdf", host: "billing.harborprint.co", evidence: e)
      == "Invoices 1119 and 1120 from billing.harborprint.co are filed here.",
    "the why line names the earlier invoices and their sender",
    FilingText.why(file: "Invoice 1121.pdf", host: "billing.harborprint.co", evidence: e) ?? "nil")
  check(
    FilingText.why(file: "Invoice 1121.pdf", host: "billing.harborprint.co", evidence: FilingEvidence(sameHost: ["Invoice 1120.pdf"]))
      == "Invoice 1120 from billing.harborprint.co is filed here.", "one earlier invoice")
  let photo = FilingEvidence(sameKind: 3, project: "Fold Studies", projectUsed: Date().addingTimeInterval(-3600))
  check(
    FilingText.why(file: "IMG_4821.HEIC", host: nil, evidence: photo)
      == "3 other HEIC files are here, and Fold Studies is what you’re working on.",
    "photos and the project you are working on", FilingText.why(file: "IMG_4821.HEIC", host: nil, evidence: photo) ?? "nil")
  check(FilingText.why(file: "x.txt", host: nil, evidence: FilingEvidence()) == nil, "no evidence, no why")
  check(FilingText.shortHost("billing.harborprint.co") == "harborprint.co" && FilingText.shortHost("a.b.co.uk") == "b.co.uk", "short hosts for rows")
}

private func requestBody() {
  let home = "/Users/someone"
  let folders = [
    home + "/Studio/Fold Studies/invoices", home + "/Documents/Finances/2026", home + "/Desktop", home,
  ].map { FilingJev.Folder($0, home: home) }
  let request = try! FilingJev.request(
    file: "Invoice 1121.pdf", host: "billing.harborprint.co", folders: folders, key: "test-key-not-real")
  check(request.url == URL(string: "https://api.typesafe.ai/v1/systemone") && request.httpMethod == "POST", "Jev's endpoint")
  check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real", "the key goes only in the Authorization header")
  let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
  check(Set(body.keys) == ["model", "state", "questions"] && body["model"] as? String == "jev-1.14.0", "model jev-1.14.0")
  let state = body["state"] as! [String: Any]
  check(Set(state.keys) == ["file", "source", "destinations"], "state holds the file, its source and destinations", state.keys)
  check(state["file"] as? String == "Invoice 1121.pdf" && state["source"] as? String == "billing.harborprint.co", "basename and host only")
  let destinations = state["destinations"] as! [[String: String]]
  check(destinations.allSatisfy { Set($0.keys).isSubset(of: ["id", "folder", "in"]) }, "each folder is an id, a name and its parent's name")
  check(
    destinations.map { $0["folder"]! } == ["invoices", "2026", "Desktop", "Home"]
      && destinations.map { $0["in"] ?? "-" } == ["Fold Studies", "Finances", "Home", "-"],
    "folder names, with Home for the home folder", destinations)
  let text = String(data: request.httpBody!, encoding: .utf8)!
  check(!text.contains("/") && !text.contains("someone") && !text.contains("test-key"), "no paths, user name or key in the body", text)
  let noSource = try! JSONSerialization.jsonObject(
    with: FilingJev.request(file: "/private/x/Notes.txt", host: nil, folders: folders, key: "k").httpBody!) as! [String: Any]
  check(
    (noSource["state"] as! [String: Any])["source"] == nil && (noSource["state"] as! [String: Any])["file"] as? String == "Notes.txt",
    "without a website there is no source, and a path is cut to its name")

  let reply = """
    {"answers":{"destination":{"type":"choice","choice":"d0","probabilities":{"d0":0.91,"d1":0.06,"d2":0.02,"d3":0.01}}}}
    """
  check(try! FilingJev.probabilities(Data(reply.utf8), count: 4) == [0.91, 0.06, 0.02, 0.01], "Jev's probabilities come back in the order sent")
  check((try? FilingJev.probabilities(Data("{}".utf8), count: 4)) == nil, "an unreadable reply is an error")
  let partial = #"{"answers":{"destination":{"type":"choice","choice":"d0","probabilities":{"d0":0.9,"d1":0.1}}}}"#
  check((try? FilingJev.probabilities(Data(partial.utf8), count: 4)) == nil, "an incomplete ranking is an error")

  var backoff = FilingBackoff()
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  backoff.failed(FilingJevError.status(500, retryAfter: nil), at: t0)
  check(!backoff.allows(t0.addingTimeInterval(29)) && backoff.allows(t0.addingTimeInterval(30)), "the first failure waits 30 s")
  backoff.failed(FilingJevError.status(500, retryAfter: nil), at: t0)
  check(!backoff.allows(t0.addingTimeInterval(59)) && backoff.allows(t0.addingTimeInterval(60)), "then twice as long")
  backoff.failed(FilingJevError.status(429, retryAfter: 600), at: t0)
  check(!backoff.allows(t0.addingTimeInterval(599)), "Retry-After is honored")
  for _ in 0..<12 { backoff.failed(URLError(.timedOut), at: t0) }
  check(backoff.allows(t0.addingTimeInterval(30 * 60)), "and it never waits more than 30 min")
  backoff.failed(FilingJevError.status(401, retryAfter: nil), at: t0)
  check(backoff.waitingForKey && !backoff.allows(t0.addingTimeInterval(86_400)), "a refused key waits for a new key")
  backoff.keyChanged()
  check(backoff.allows(t0), "a new key tries again")
}

private func keychain() {
  let store = FakeStore("  key-from-keychain-123 \n")
  let both = FilingCredentials(store: store, environment: ["FINGER_JEV_API_KEY": "env-key-4567890"])
  check(both.cachedSource == nil, "the Keychain isn't read until needed")
  check(both.key == "key-from-keychain-123" && both.source == .keychain, "the Keychain comes first, trimmed")
  check(both.statusText == "Jev is on · key in Keychain", "the menu says where the key is", both.statusText)
  _ = both.key
  check(store.reads == 1, "the Keychain is read once", store.reads)
  let env = FilingCredentials(store: FakeStore(), environment: ["TYPESAFE_API_KEY": "env-key-4567890"])
  check(env.key == "env-key-4567890" && env.source == .environment("TYPESAFE_API_KEY"), "then TYPESAFE_API_KEY")
  let preferred = FilingCredentials(
    store: FakeStore(), environment: ["TYPESAFE_API_KEY": "second-key-000", "FINGER_JEV_API_KEY": "first-key-000"])
  check(preferred.key == "first-key-000", "FINGER_JEV_API_KEY before TYPESAFE_API_KEY")
  let empty = FakeStore()
  let off = FilingCredentials(store: empty, environment: [:])
  check(off.key == nil && off.source == .none && off.statusText == "Jev is off · no TypeSafe key", "no key: Jev is off")
  check((try? off.save("has spaces in it")) == nil && (try? off.save("short")) == nil, "a pasted key must be one token")
  try! off.save("  sk-live-abcdef0123456789\n")
  check(empty.secret == "sk-live-abcdef0123456789" && off.source == .keychain, "Save stores the trimmed key in the store")
  try! off.remove()
  check(empty.secret == nil && off.source == .none, "Remove deletes it; Jev is off again")
  let fallback = FilingCredentials(store: FakeStore("kc-key-0000000"), environment: ["FINGER_JEV_API_KEY": "env-key-4567890"])
  try! fallback.remove()
  check(fallback.key == "env-key-4567890", "removing the Keychain key falls back to the environment")

  // The sheet: paste, save, remove; the field never keeps the key.
  let sheetStore = FakeStore()
  let sheetCredentials = FilingCredentials(store: sheetStore, environment: [:])
  _ = sheetCredentials.key
  let sheet = FilingKeyWindow(credentials: sheetCredentials)
  check(!sheet.saveButton.isEnabled && !sheet.removeButton.isEnabled, "nothing to save or remove yet")
  check(sheet.status.stringValue.hasPrefix("Jev is off"), "the sheet says Jev is off", sheet.status.stringValue)
  sheet.field.stringValue = "  sk-test-0123456789abcdef  "
  sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  check(sheet.saveButton.isEnabled, "a pasted key can be saved")
  sheet.savePressed()
  check(sheetStore.secret == "sk-test-0123456789abcdef" && sheet.field.stringValue.isEmpty, "Save stores it and clears the field")
  check(sheet.removeButton.isEnabled, "now it can be removed")
  sheet.removePressed()
  check(sheetStore.secret == nil && sheet.status.stringValue == "Removed. Jev is off.", "Remove deletes it", sheet.status.stringValue)
  sheet.window?.close()
  check(FilingKeychain.service == "com.d4j3y2k.Finger.jev", "the Keychain item's service")

  // The menu bar item.
  let menuStore = FakeStore()
  let menuCredentials = FilingCredentials(store: menuStore, environment: [:])
  _ = menuCredentials.key
  let jevMenu = FilingKeyMenu(credentials: menuCredentials)
  let menu = FingerStatusMenu(
    loginItem: FingerLoginItem(agents: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)),
    showPanel: {}, openWindow: {}, editShortcut: {}, quit: {})
  menu.shortcuts = { nil }
  menu.addJev(jevMenu)
  let titles = menu.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
  check(
    titles.suffix(4) == ["Jev is off · no TypeSafe key", "Jev API Key…", "—", "Quit Finger"],
    "the menu says Jev is off and offers Jev API Key… above Quit", titles)
  check(!jevMenu.status.isEnabled, "the status line is not a command")
  try! menuCredentials.save("sk-menu-0123456789")
  check(jevMenu.status.title == "Jev is on · key in Keychain", "saving a key turns it on in the menu", jevMenu.status.title)
}

private func arrivalsAndCoordinator(_ root: String) {
  let downloads = root + "/Downloads"
  let found = FilingArrivals.scan(downloads)
  check(
    Set(found.map(\.name)) == ["Invoice 1121.pdf", "IMG_4821.HEIC", "meeting-notes.txt"],
    "arrivals are this hour's downloads, without partial or hidden files", found.map(\.name))
  check(FilingArrivals.scan(downloads, now: Date().addingTimeInterval(2 * 3600)).isEmpty, "after an hour they are not new")
  check(
    found.first { $0.name == "Invoice 1121.pdf" }?.host == "billing.harborprint.co"
      && found.first { $0.name == "IMG_4821.HEIC" }?.host == nil,
    "the source host comes from kMDItemWhereFroms")
  check(["a.download", "b.crdownload", "c.part"].allSatisfy(FilingArrivals.isPartial), "Safari, Chrome and Firefox partials")

  let jev = FakeJev()
  jev.answers = jevTable
  let evidence = FixtureEvidence(home: root)
  let now = Date()
  evidence.used = [
    (root + "/Studio/Fold Studies/exports/Print notes.txt", now.addingTimeInterval(-3600)),
    (root + "/Documents/Finances/2026/Q4 budget.csv", now.addingTimeInterval(-26 * 3600)),
  ]
  let log = FilingLog()
  let store = FakeStore("sk-fake-0123456789")
  let c = coordinator(root, store: store, jev: jev, evidence: evidence, log: log)
  var clock = Date()
  c.now = { clock }
  var changes = 0
  c.changed = { _ in changes += 1 }
  c.start()
  check(c.isWatching, "Downloads is watched with FSEvents")
  wait("three verdicts") { c.arrivals.count == 3 && c.arrivals.allSatisfy { c.verdict(for: $0.path) != nil } }
  check(jev.requests.count == 3, "Jev is asked once per download", jev.requests.count)
  let invoice = downloads + "/Invoice 1121.pdf"
  let local = c.local(for: invoice)!
  let studies = root + "/Studio/Fold Studies"
  check(local.candidates.first?.folder == studies + "/invoices", "locally, invoices leads for the invoice", local.candidates.map(\.folder))
  check(local.candidates.first?.evidence.sameHost.sorted() == ["Invoice 1119.pdf", "Invoice 1120.pdf"], "because the same sender's invoices are there")
  check(local.candidates.count >= 6, "with other folders from the project, Desktop and Documents", local.candidates.map { ($0.folder as NSString).lastPathComponent + ":\($0.score)" })
  let verdict = c.verdict(for: invoice)!
  check(verdict.top?.folder == studies + "/invoices" && abs(verdict.top!.probability - 0.91) < 0.0001, "Jev ranks invoices at 91%")
  check(verdict.tier == .confident, "so it is Confident")
  check(verdict.why == "Invoices 1119 and 1120 from billing.harborprint.co are filed here.", "with a local why", verdict.why ?? "nil")
  check(c.verdict(for: downloads + "/IMG_4821.HEIC")?.tier == .likely, "the photo is Likely")
  check(c.verdict(for: downloads + "/meeting-notes.txt")?.tier == .unsure, "the notes are Unsure")
  let sent = jev.bodies.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
  check(sent.allSatisfy { !$0.contains(root) && !$0.contains("\\/") && !$0.contains("/") }, "no request holds a path")
  check(
    sent.allSatisfy { !$0.contains("HARBOR") && !$0.contains("Notes from Thursday") && !$0.contains("sk-fake") },
    "or the file's contents, or the key")
  let invoiceBody = jev.bodies.first { ($0["state"] as? [String: Any])?["file"] as? String == "Invoice 1121.pdf" }!
  let destinations = (invoiceBody["state"] as! [String: Any])["destinations"] as! [[String: String]]
  check((1...FilingJev.candidateLimit).contains(destinations.count), "about ten candidates", destinations.count)
  check(destinations.first?["folder"] == "invoices", "local order leads", destinations.map { $0["folder"]! })
  check(log.pairs.contains { $0.signal == "Invoice 1121.pdf arrived from billing.harborprint.co" && $0.sent == "Its file name and billing.harborprint.co" }, "the log says what was sent", log.pairs)
  check(
    log.pairs.contains { $0.signal.hasSuffix("folders it might belong in") && $0.sent.hasPrefix("Folder names: invoices") },
    "including the folder names")
  check(
    log.pairs.contains { $0.signal.contains("are filed in invoices") && $0.sent == FilingLog.staysHere },
    "and what stays on this Mac")
  check(log.rows.allSatisfy { !$0.signal.contains(root) && !$0.sent.contains(root) && !$0.sent.contains("sk-fake") }, "the log holds no paths or key")

  // Cached by path, size and modification time.
  let asked = jev.requests.count
  var scanned = false
  c.scan { scanned = true }
  wait("rescan") { scanned }
  pump(0.2)
  check(jev.requests.count == asked, "a cached file isn't asked about again")
  try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: invoice)
  c.scan()
  wait("asked again after a change") { jev.requests.count == asked + 1 && c.verdict(for: invoice) != nil }
  check(true, "a changed modification time asks again")

  // A new download arrives through FSEvents once it finishes.
  let partial = downloads + "/Statement 0425.pdf.crdownload"
  try! invoicePDF(number: 425).write(to: URL(fileURLWithPath: partial))
  pump(0.8)
  check(!c.arrivals.contains { $0.name.hasPrefix("Statement") }, "a partial download is ignored")
  jev.hold = true
  try! FileManager.default.moveItem(atPath: partial, toPath: downloads + "/Statement 0425.pdf")
  setWhereFroms(downloads + "/Statement 0425.pdf", ["https://bank.example.com/statements/0425.pdf"])
  wait("FSEvents sees the finished file") { c.arrivals.contains { $0.name == "Statement 0425.pdf" } }
  check(true, "when it finishes, it arrives")
  wait("asking about the statement") { c.isAsking }
  check(!c.isAsking || c.verdict(for: downloads + "/Statement 0425.pdf") == nil, "the panel is never blocked: the request runs in the background")
  // Cancellation: the file leaves while Jev is thinking.
  try! FileManager.default.removeItem(atPath: downloads + "/Statement 0425.pdf")
  wait("the request is cancelled") { jev.cancelled == 1 && !c.isAsking }
  check(c.verdicts.keys.allSatisfy { !$0.path.hasSuffix("Statement 0425.pdf") }, "a cancelled request leaves no verdict")
  jev.hold = false

  // Failures back off; the clock decides when to ask again.
  jev.status = 503
  let next = downloads + "/Invoice 1122.pdf"
  try! invoicePDF(number: 1122).write(to: URL(fileURLWithPath: next))
  setWhereFroms(next, ["https://billing.harborprint.co/invoices/1122.pdf"])
  let before = jev.requests.count
  c.scan()
  wait("the failed request") { jev.requests.count == before + 1 && !c.isAsking && c.backoff.failures == 1 }
  jev.status = 200
  c.retryNow()
  pump(0.2)
  check(jev.requests.count == before + 1, "after a failure Finger waits before asking again")
  clock = clock.addingTimeInterval(31)
  c.retryNow()
  wait("asked after backing off") { c.verdict(for: next) != nil }
  check(jev.requests.count == before + 2 && c.backoff.failures == 0, "then asks again, once")
  // A refused key waits for a new one.
  jev.status = 401
  let third = downloads + "/Invoice 1123.pdf"
  try! invoicePDF(number: 1123).write(to: URL(fileURLWithPath: third))
  c.scan()
  wait("refused") { c.backoff.waitingForKey }
  jev.status = 200
  clock = clock.addingTimeInterval(600)
  c.retryNow()
  pump(0.2)
  check(c.verdict(for: third) == nil, "a refused key isn't retried on a timer")
  try! c.credentials.save("sk-fake-new-0123456789")
  wait("a new key asks again") { c.verdict(for: third) != nil }
  check(true, "a new key asks again")
  // Without a key there are no verdicts to show.
  try! c.credentials.remove()
  check(c.verdict(for: invoice) == nil && !c.jevOn, "without a key, no verdicts")
  c.stop()
  check(!c.isWatching, "stop ends the watch")
  check(changes > 0, "changes were reported to the panel")
}

private func panelChecks(_ root: String, shots: String?) {
  let downloads = root + "/Downloads"
  let studies = root + "/Studio/Fold Studies"
  let now = Date()
  let search = FixtureSearch(root: root)
  search.used = [
    studies + "/exports/Print notes.txt": now.addingTimeInterval(-61 * 60),
    root + "/Developer/finger/README.md": now.addingTimeInterval(-2 * 3600),
    root + "/Documents/Finances/2026/Q4 budget.csv": now.addingTimeInterval(-26 * 3600),
  ]
  let evidence = FixtureEvidence(home: root)
  evidence.used = search.used.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
  let jev = FakeJev()
  jev.answers = jevTable
  let log = FilingLog()
  let store = FakeStore("sk-fake-0123456789")
  let coordinator = coordinator(root, store: store, jev: jev, evidence: evidence, log: log)
  let spy = SpyPreview()
  let c = PanelController(engine: Engine(send, { free($0) }), search: search, home: root, preview: spy)
  c.hidesOnResignKey = false
  c.allowsMotion = false
  var opened: [URL] = []
  c.opener = { opened.append($0) }
  c.attachFiling(coordinator)
  let filing = c.filing!
  filing.toast.lifetime = 60
  var settled = 0
  filing.settled = { settled += 1 }
  coordinator.start()
  let panel = c.panel
  panel.appearance = NSAppearance(named: .aqua)
  c.showOffscreen()

  func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
    let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
    let characters = arrows[code].map { String(UnicodeScalar(UInt16($0))!) } ?? chars
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    if flags.contains(.command) && panel.performKeyEquivalent(with: event) { return }
    panel.sendEvent(event)
  }
  func type(_ text: String) { for ch in text { key(ch == " " ? 49 : 0, String(ch)) } }
  let ret: UInt16 = 36, esc: UInt16 = 53, tab: UInt16 = 48
  func select(_ name: String) {
    guard let row = c.rows.firstIndex(where: { $0.item?.file.name == name }) else {
      check(false, "row \(name) is listed", c.itemNames)
      return
    }
    c.select(row, reveal: true)
  }
  func cell(_ name: String) -> PanelItemCell? {
    guard let row = c.rows.firstIndex(where: { $0.item?.file.name == name }) else { return nil }
    return c.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PanelItemCell
  }
  func waitPreview() {
    guard let file = c.selectedItem?.file, !file.isFolder else { return }
    wait("preview of \(file.name)") { spy.content.report.url?.path == file.path && spy.content.report.kind != .loading }
  }
  func snapshot(_ title: String) {
    guard let shots else { return }
    pump(0.05)
    c.finishMotion()
    c.root.layoutSubtreeIfNeeded()
    waitPreview()
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
      let canvas = NSImage(size: NSSize(width: size.width + margin * 2, height: size.height + margin * 2), flipped: false) { rect in
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
        (dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 0.9) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 0.9)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return true
      }
      let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.size.width * 2), pixelsHigh: Int(canvas.size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
      out.size = canvas.size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
      NSAppearance(named: look)!.performAsCurrentDrawingAppearance { canvas.draw(in: NSRect(origin: .zero, size: canvas.size)) }
      NSGraphicsContext.restoreGraphicsState()
      let file = (shots as NSString).appendingPathComponent("\(title)-\(suffix).png")
      try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
    }
    panel.appearance = NSAppearance(named: .aqua)
    print("   wrote \(title)-light.png and \(title)-dark.png")
  }

  // Home: chips on the new downloads once Jev has answered, in the background.
  wait("Just Arrived") { c.items(in: "Just Arrived").count == 3 }
  wait("verdicts") { ["Invoice 1121.pdf", "IMG_4821.HEIC", "meeting-notes.txt"].allSatisfy { name in coordinator.verdict(for: downloads + "/" + name) != nil } }
  wait("subtitles name the sender") { c.items(in: "Just Arrived").first { $0.file.name == "Invoice 1121.pdf" }?.subtitle == "Downloads · harborprint.co" }
  check(true, "the invoice's row says where it came from")
  pump(0.05)
  check(cell("Invoice 1121.pdf")?.filingChip == FilingChip(text: "⇥ invoices", confident: true), "the invoice's row has an accent “⇥ invoices” chip")
  check(cell("IMG_4821.HEIC")?.filingChip == FilingChip(text: "refs?", confident: false), "the photo's row has a gray “refs?” chip")
  check(cell("meeting-notes.txt")?.filingChip == nil, "Finger stays quiet about the notes")
  check(cell("Print notes.txt")?.filingChip == nil, "and about files that aren't new")

  // The Likely bar, above the photo.
  select("IMG_4821.HEIC")
  waitPreview()
  check(spy.content.accessory === filing.bar, "the photo's preview has the Jev bar")
  check(
    filing.bar.content?.name == "refs" && filing.bar.content?.parent == "Fold Studies" && filing.bar.content?.tier == .likely,
    "refs in Fold Studies, Likely", filing.bar.content.map { "\($0)" } ?? "nil")
  check(filing.bar.label == "Suggested by Jev · Likely" && filing.bar.buttons.map(\.1) == ["Choose Folder…"], "Likely offers Choose Folder…")
  check(
    filing.bar.content?.why == "3 other HEIC files are here, and Fold Studies is what you’re working on.",
    "its why comes from what Finger saw", filing.bar.content?.why ?? "nil")
  check(c.footer.hints.map(\.keys) == ["↩", "Space", "→", "⌥M"], "Likely files hint ⌥M Move but not ⇥ File", c.footer.hints.map(\.keys))
  snapshot("filing-home")

  // The Confident bar, above the invoice.
  select("Invoice 1121.pdf")
  waitPreview()
  check(spy.content.accessory === filing.bar && filing.bar.content?.tier == .confident, "the invoice's preview has a Confident bar")
  check(filing.bar.buttons.map(\.1) == ["Other…", "File to invoices"], "with Other… and File to invoices")
  check(filing.bar.content?.why == "Invoices 1119 and 1120 from billing.harborprint.co are filed here.", "and why", filing.bar.content?.why ?? "nil")
  check(abs((filing.bar.content?.probability ?? 0) - 0.91) < 0.001 && filing.bar.label == "Suggested by Jev · Confident", "91%, Confident")
  check(c.footer.hints.map(\.keys) == ["↩", "⇥", "Space", "→", "⌥M"], "the footer offers ⇥ File", c.footer.hints.map(\.keys))
  snapshot("filing-invoice")
  select("meeting-notes.txt")
  waitPreview()
  check(spy.content.accessory == nil, "no bar for an Unsure download")
  select("Print notes.txt")
  waitPreview()
  check(spy.content.accessory == nil, "or for older files")

  // ⇥ on Likely: the move list, with Jev's folder selected.
  select("IMG_4821.HEIC")
  let beforeMove = c.selectedPath
  key(tab, "\t")
  check(filing.isMoving && c.chips.pill == "Move IMG_4821.HEIC to", "⇥ on a Likely download opens “Move IMG_4821.HEIC to”")
  wait("folders listed") { filing.move?.loading == false }
  check(c.sectionTitles == ["Suggested by Jev", "Other Folders"], "Jev's folders first, then the others", c.sectionTitles)
  if case .header(let section) = c.rows[0] { check(section.aside == "Likely", "the Jev section says Likely") }
  let suggested = c.items(in: "Suggested by Jev")
  check(suggested.map(\.file.name) == ["refs", "Desktop", "Documents"], "in Jev's order", suggested.map(\.file.name))
  check(suggested.map { Int(($0.probability ?? 0) * 100 + 0.5) } == [58, 24, 18], "with their percentages")
  check(c.selectedItem?.file.name == "refs", "refs is selected", c.selectedItem?.file.name ?? "nil")
  let others = c.items(in: "Other Folders").map(\.file.path)
  let firstOutside = others.firstIndex { !$0.hasPrefix(studies) } ?? others.count
  check(firstOutside >= 3 && others.prefix(firstOutside).allSatisfy { $0.hasPrefix(studies) }, "then the project's folders", others.prefix(6))
  check(others.first == studies && others.dropFirst().first == studies + "/delivery", "the project reads top-down", others.prefix(3))
  check(others.dropFirst(firstOutside).first == root, "then Home", others.dropFirst(firstOutside).prefix(3))
  let homeCell = c.rowIndex(of: root).flatMap { c.table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? PanelItemCell }
  check(homeCell?.name == "Home", "the home folder reads as Home, never its folder name", homeCell?.name ?? "nil")
  check(!others.contains(downloads) && !others.contains(studies + "/refs"), "never where it is, or a folder twice")
  check(cell("refs")?.probability.map { Int($0 * 100 + 0.5) } == 58 && cell("refs")?.folder == false, "rows draw Jev's percentage, without a chevron")
  check(c.footer.hints.map(\.label) == ["Move", "Cancel"], "↩ Move, esc Cancel", c.footer.hints.map(\.label))
  snapshot("filing-move")
  // Typing filters; Esc goes back.
  type("doc")
  wait("filtered") { c.query == "doc" }
  check(c.items(in: "Suggested by Jev").map(\.file.name) == ["Documents"], "typing filters Jev's folders", c.itemNames)
  check(c.itemNames.allSatisfy { PanelMatch.rank("doc", in: $0) > 0 }, "and the others", c.itemNames)
  check(c.selectedItem?.file.name == "Documents", "selecting the first match")
  type("zzz")
  check(c.rows.isEmpty && c.emptyTitle.stringValue == "No folder matches “doczzz”", "a filter with no folders says so", c.emptyTitle.stringValue)
  key(esc, "\u{1b}")
  check(!filing.isMoving && c.chips.pill == nil && c.query.isEmpty && c.selectedPath == beforeMove, "Esc cancels back to where you were")
  check(FileManager.default.fileExists(atPath: downloads + "/IMG_4821.HEIC"), "and nothing moved")

  // ⇥ on Unsure: the move list, quiet about Jev.
  select("meeting-notes.txt")
  key(tab, "\t")
  wait("unsure list") { filing.isMoving && filing.move?.loading == false }
  check(c.sectionTitles == ["Your Usual Folders"], "no Jev section when Jev is unsure", c.sectionTitles)
  if case .header(let section) = c.rows[0] { check(section.aside == "Jev unsure", "it says Jev is unsure", section.aside) }
  check(c.selectedRow == c.firstItemRow, "the first folder is selected")
  key(esc, "\u{1b}")

  // ⇥ on Confident files it at once, through the core; ⌘Z puts it back.
  let invoice = downloads + "/Invoice 1121.pdf"
  let filed = studies + "/invoices/Invoice 1121.pdf"
  let asked = jev.requests.count
  select("Invoice 1121.pdf")
  var mark = settled
  key(tab, "\t")
  wait("filed") { settled > mark }
  check(!FileManager.default.fileExists(atPath: invoice) && FileManager.default.fileExists(atPath: filed), "⇥ moved the invoice into invoices")
  check(filing.toast.isShowing && filing.toast.message == "Moved Invoice 1121.pdf to invoices" && filing.toast.action == "Undo", "a toast says so, with Undo", filing.toast.message)
  wait("Just Arrived updates") { !c.items(in: "Just Arrived").contains { $0.file.name == "Invoice 1121.pdf" } }
  check(filing.canUndo, "the move has a receipt")
  check(log.pairs.first?.signal == "You moved Invoice 1121.pdf to invoices" && log.pairs.first?.sent == FilingLog.staysHere, "the log notes the move, which stays here")
  check(coordinator.memory.entries.first.map { $0.name == "Invoice 1121.pdf" && $0.host == "billing.harborprint.co" && $0.folder == studies + "/invoices" } == true, "Finger remembers where it filed it")
  check(coordinator.preferences.stringArray(forKey: "recentDestinations")?.first == studies + "/invoices", "and the window's Move sees it as a recent destination")
  mark = settled
  key(6, "z", .command)
  wait("undone") { settled > mark }
  check(FileManager.default.fileExists(atPath: invoice) && !FileManager.default.fileExists(atPath: filed), "⌘Z put it back in Downloads")
  check(filing.toast.message == "Moved Invoice 1121.pdf back to Downloads" && filing.toast.action == nil, "the toast says so", filing.toast.message)
  wait("back in Just Arrived with its chip") { coordinator.verdict(for: invoice) != nil && c.items(in: "Just Arrived").contains { $0.file.name == "Invoice 1121.pdf" } }
  check(jev.requests.count == asked, "the cached verdict came back without asking Jev again", jev.requests.count - asked)
  check(!filing.canUndo, "nothing left to undo")

  // The bar's File to invoices, then the toast's Undo.
  select("Invoice 1121.pdf")
  waitPreview()
  mark = settled
  filing.bar.press(.file)
  wait("filed from the bar") { settled > mark }
  check(FileManager.default.fileExists(atPath: filed), "File to invoices moved it")
  mark = settled
  filing.toast.performAction()
  wait("undone from the toast") { settled > mark }
  check(FileManager.default.fileExists(atPath: invoice) && !FileManager.default.fileExists(atPath: filed), "the toast's Undo put it back")

  // ⌥M on any file: filter, ↩ moves, ⌘Z undoes.
  wait("Recents") { c.items(in: "Recents").contains { $0.file.name == "Print notes.txt" } }
  select("Print notes.txt")
  let notes = studies + "/exports/Print notes.txt"
  key(46, "µ", .option)
  wait("move list for Print notes") { filing.isMoving && filing.move?.loading == false }
  check(c.chips.pill == "Move Print notes.txt to" && c.field.placeholder == "Folder", "⌥M opens the move list for any file")
  check(c.sectionTitles == ["Your Usual Folders"] && !c.itemNames.contains("exports"), "a file Jev hasn't seen gets the usual folders, not its own", c.sectionTitles)
  type("deliv")
  wait("delivery") { c.selectedItem?.file.name == "delivery" }
  mark = settled
  key(ret, "\r")
  wait("moved to delivery") { settled > mark }
  check(FileManager.default.fileExists(atPath: studies + "/delivery/Print notes.txt") && !FileManager.default.fileExists(atPath: notes), "↩ moved it into delivery")
  check(!filing.isMoving && c.query.isEmpty, "the panel is back on Home")
  let stale = [PanelSection(title: "Recents", items: [PanelItem(file: PanelFile(path: notes, isFolder: false), origin: .home)])]
  check(
    filing.adjust(stale).first?.items.first.map { $0.file.path == studies + "/delivery/Print notes.txt" && $0.subtitle == "Studio › Fold Studies › delivery" } == true,
    "a stale Recents or search row follows the file to its new place")
  mark = settled
  key(6, "z", .command)
  wait("undo delivery") { settled > mark }
  check(FileManager.default.fileExists(atPath: notes), "⌘Z put it back in exports")

  // Never overwrite: a name already there is the core's collision, and Keep Both is a choice.
  let existing = root + "/Documents/meeting-notes.txt"
  try! Data("Someone else's notes.\n".utf8).write(to: URL(fileURLWithPath: existing))
  select("meeting-notes.txt")
  key(46, "µ", .option)
  wait("list for notes") { filing.isMoving && filing.move?.loading == false }
  type("Documents")
  wait("Documents") { c.selectedItem?.file.path == root + "/Documents" }
  mark = settled
  key(ret, "\r")
  wait("collision") { settled > mark }
  check(filing.toast.message == "Documents already has “meeting-notes.txt”" && filing.toast.action == "Keep Both", "a collision offers Keep Both", filing.toast.message)
  check(
    (try? String(contentsOfFile: existing, encoding: .utf8)) == "Someone else's notes.\n"
      && FileManager.default.fileExists(atPath: downloads + "/meeting-notes.txt"),
    "nothing was overwritten or moved")
  mark = settled
  filing.toast.performAction()
  wait("kept both") { settled > mark }
  check(
    FileManager.default.fileExists(atPath: root + "/Documents/meeting-notes 2.txt")
      && (try? String(contentsOfFile: existing, encoding: .utf8)) == "Someone else's notes.\n",
    "Keep Both gave the incoming file a new name")
  check(filing.toast.message == "Moved meeting-notes 2.txt to Documents", "and said so", filing.toast.message)
  mark = settled
  key(6, "z", .command)
  wait("undo keep both") { settled > mark }
  check(FileManager.default.fileExists(atPath: downloads + "/meeting-notes.txt"), "⌘Z brought it back under its own name")

  // ⌥M is for files; on a folder it says so.
  c.enter(root + "/Studio")
  wait("in Studio") { c.folder == root + "/Studio" && !c.rows.isEmpty }
  select("Fold Studies")
  key(46, "µ", .option)
  check(!filing.isMoving && filing.toast.message == "Select a file to move", "⌥M on a folder asks for a file", filing.toast.message)
  key(esc, "\u{1b}")
  wait("back on Home") { c.folder == nil }
  filing.toast.dismiss()

  // Without a key: no chips or bar, and the move list ranks folders locally.
  try! coordinator.credentials.remove()
  pump(0.1)
  c.rebuild(.keep)
  check(cell("Invoice 1121.pdf")?.filingChip == nil && cell("IMG_4821.HEIC")?.filingChip == nil, "without a key there are no chips")
  select("Invoice 1121.pdf")
  waitPreview()
  check(spy.content.accessory == nil, "or a bar")
  check(!c.footer.hints.contains { $0.keys == "⇥" }, "or ⇥ File")
  key(tab, "\t")
  wait("local list") { filing.isMoving && filing.move?.loading == false }
  check(c.sectionTitles == ["Your Usual Folders"], "⇥ opens the move list", c.sectionTitles)
  if case .header(let section) = c.rows[0] { check(section.aside == "Jev off", "which says Jev is off", section.aside) }
  check(c.itemNames.first == "invoices", "with the local favorite first", c.itemNames.prefix(4))
  check(FileManager.default.fileExists(atPath: invoice), "⇥ never files without Jev")
  key(esc, "\u{1b}")
  check(jev.requests.allSatisfy { $0.url?.host == "api.typesafe.ai" }, "every request went to the fake transport")
  coordinator.stop()
  c.hide()
  check(opened.isEmpty, "filing never opened a file")
}

