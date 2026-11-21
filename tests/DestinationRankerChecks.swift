import Foundation

// swiftc native/FolderReferences.swift native/DestinationRanker.swift tests/DestinationRankerChecks.swift -o /tmp/finger-ranker-check
// /tmp/finger-ranker-check
@main
struct DestinationRankerChecks {
  static func main() throws {
    try checkFolderReferences()
    let root = URL(fileURLWithPath: "/disposable/private-client/Fold Studies", isDirectory: true)
    let exports = root.appendingPathComponent("exports", isDirectory: true)
    let old = root.appendingPathComponent("exports-old", isDirectory: true)
    let delivery = root.appendingPathComponent("delivery", isDirectory: true)
    let pictures = root.appendingPathComponent("Pictures", isDirectory: true)
    let sources = ["Overlap 01.png", "Overlap 01.svg"].map { exports.appendingPathComponent($0) }

    let locations = DestinationRanker.ranked(
      sources: sources, candidates: [old, delivery, exports, old])
    precondition(
      locations == [delivery, old, exports],
      "Archive, duplicate, or source-folder ordering regressed")
    let recent = DestinationRanker.ranked(
      sources: sources, candidates: [pictures, delivery], recent: [delivery])
    precondition(
      recent.first == delivery, "Previous transfer destination should influence the local order")
    let previousProject = root.deletingLastPathComponent().appendingPathComponent(
      "Fold Studies Previous", isDirectory: true)
    let previousDelivery = previousProject.appendingPathComponent("delivery", isDirectory: true)
    let previousExports = previousProject.appendingPathComponent("exports", isDirectory: true)
    let groups = DestinationRanker.jevCandidates(
      [delivery, root, previousDelivery, old, previousExports], project: root)
    precondition(
      groups.ranked == [delivery, old]
        && groups.remaining == [root, previousDelivery, previousExports])
    let scoped = DestinationRanker.ranked(
      sources: sources,
      candidates: [previousDelivery, previousExports, old, pictures, delivery, exports],
      recent: [previousExports, previousDelivery, delivery], project: root)
    precondition(
      scoped == [delivery, pictures, old, previousExports, previousDelivery, exports],
      "Current-project folders must outrank similarly named external destinations")
    let twoProjects =
      Array(repeating: sources[0], count: 32) + [
        previousExports.appendingPathComponent("proof.png")
      ]
    let mixed = DestinationRanker.ranked(
      sources: twoProjects, candidates: [delivery, previousDelivery],
      recent: [previousDelivery], project: root)
    precondition(
      mixed.first == previousDelivery,
      "A mixed-project collection must retain its recent destinations")

    let candidates = [old, delivery, pictures]
    let req = try DestinationRanker.jevRequest(
      sources: sources, candidates: candidates, key: "test-value")
    precondition(
      req.url?.absoluteString == "https://api.typesafe.ai/v1/systemone" && req.httpMethod == "POST")
    precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-value")
    let data = try required(req.httpBody)
    let body = try required(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let state = try required(body["state"] as? [String: Any])
    let names = try required(state["selectedNames"] as? [String])
    let destinations = try required(state["destinations"] as? [[String: String]])
    precondition(names == sources.map(\.lastPathComponent))
    precondition(destinations.compactMap { $0["folder"] } == candidates.map(\.lastPathComponent))
    let encoded = String(decoding: data, as: UTF8.self)
    precondition(
      !encoded.contains("private-client") && !encoded.contains("test-value"),
      "Only display names belong in state")
    let questions = try required(body["questions"] as? [String: [String: Any]])
    precondition(questions["destination"]?["type"] as? String == "choice")

    let good = Data(
      #"{"answers":{"destination":{"type":"choice","choice":"d1","probabilities":{"d0":0.01,"d1":0.75,"d2":0.24}}}}"#
        .utf8)
    let sorted = try DestinationRanker.applyJevReply(good, to: candidates)
    precondition(sorted == [delivery, pictures, old])
    let tied = Data(
      #"{"answers":{"destination":{"type":"choice","choice":"d0","probabilities":{"d0":0.45,"d1":0.45,"d2":0.10}}}}"#
        .utf8)
    let stable = try DestinationRanker.applyJevReply(tied, to: candidates)
    precondition(stable == candidates)
    for invalid in [
      #"{"answers":{"destination":{"type":"choice","choice":"outside","probabilities":{"outside":1.0}}}}"#,
      #"{"answers":{"destination":{"type":"choice","choice":"d0","probabilities":{"d0":1.2,"d1":-0.2,"d2":0.0}}}}"#,
      #"{"answers":{"destination":{"type":"choice","choice":"d0","probabilities":{"d0":0.99,"d1":0.98,"d2":0.97}}}}"#,
    ] {
      if (try? DestinationRanker.applyJevReply(Data(invalid.utf8), to: candidates)) != nil {
        fatalError("A malformed or out-of-scope destination ranking was accepted")
      }
    }
    print("Destination checks passed for local ranking, request scope and simulated Jev replies.")
  }

  private struct MissingFixtureField: Error {}
  private static func checkFolderReferences() throws {
    let name = "finger-folder-reference-" + UUID().uuidString
    let physical = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
    let short = URL(fileURLWithPath: "/tmp/" + name, isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: physical, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: physical) }
    let exports = short.appendingPathComponent("exports", isDirectory: true)
    let same = physical.appendingPathComponent("exports", isDirectory: true)
    let different = physical.appendingPathComponent("another/exports", isDirectory: true)
    let link = physical.appendingPathComponent("My linked exports", isDirectory: true)
    precondition(exports.path.hasPrefix("/tmp/") && same.path.hasPrefix("/private/tmp/"))
    for folder in [same, different] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try fm.createSymbolicLink(at: link, withDestinationURL: same)
    precondition(fm.fileExists(atPath: exports.path) && fm.fileExists(atPath: link.path))

    let saved = [exports.path, same.path, link.path, different.path]
    precondition(
      FolderReferences.unique(saved, limit: 3) == [exports.path, link.path, different.path])
    precondition(FolderReferences.unique([same.path] + saved, limit: 2) == [same.path, link.path])
    precondition(FolderReferences.unique(saved, limit: 0).isEmpty)
    for alias in ["tmp", "var", "etc"] {
      precondition(
        FolderReferences.key("/" + alias + "/") == FolderReferences.key("/private/" + alias))
      precondition(
        FolderReferences.key("/" + alias + "-old/exports")
          != FolderReferences.key("/private/" + alias + "-old/exports"))
    }

    let source = short.appendingPathComponent("proof.svg", isDirectory: false)
    let options = DestinationRanker.ranked(
      sources: [source], candidates: [exports, same, different, link],
      recent: [same], project: physical)
    precondition(options.first?.path == exports.path && options.count == 3)
    precondition(options.contains(link) && options.contains(different))
    let sourceFolderLast = DestinationRanker.ranked(
      sources: [exports.appendingPathComponent("one.png"), same.appendingPathComponent("two.svg")],
      candidates: [same, different, exports], recent: [exports], project: physical)
    precondition(sourceFolderLast == [different, same])
    let jev = DestinationRanker.jevCandidates([exports, same, different, link], project: short)
    precondition(
      jev.ranked.map(\.path) == [exports.path, different.path, link.path] && jev.remaining.isEmpty)
    precondition(
      DestinationRanker.jevCandidates([exports, same], project: nil).ranked == [exports])
    print(
      "Recent folders and destination ranking coalesced macOS system spellings while preserving the newest path, distinct same-named folders and a real user-created symlink."
    )
  }
  private static func required<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingFixtureField() }
    return value
  }
}
