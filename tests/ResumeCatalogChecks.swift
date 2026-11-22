import Foundation

@main
struct ResumeCatalogChecks {
  static func main() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
      "finger-resume-\(UUID())", isDirectory: true)
    let project = temp.appendingPathComponent("Fold Studies", isDirectory: true)
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temp) }
    let fixture = URL(fileURLWithPath: "assets/Demo/Fold Studies", isDirectory: true)
    try manager.copyItem(at: fixture, to: project)
    // In memory: the checks leave nothing in ~/Library/Preferences.
    let defaults = FingerMemoryPreferences()
    let history = ResumeHistory(defaults: defaults)
    func scan(_ history: ResumeHistory) throws -> ResumeCatalog {
      try ResumeCatalog.scan(project: project.path, history: history)
    }

    // Check the initial Fold Studies experience with metadata that can be
    // reproduced across checkouts (git does not preserve original file times).
    let start = Date().addingTimeInterval(-300)
    let source = project.appendingPathComponent("exports/Overlap 01.svg")
    let export = project.appendingPathComponent("exports/Overlap 01.png")
    try manager.setAttributes([.modificationDate: start], ofItemAtPath: source.path)
    try manager.setAttributes(
      [.modificationDate: start.addingTimeInterval(1)], ofItemAtPath: export.path)
    let first = try scan(history)
    precondition(first.groups.count == 4)
    let hero = first.groups[0]
    precondition(hero.primary.url == export && hero.related.map(\.url) == [source])
    precondition(hero.reason == "Export is newer than its source" && !hero.changed)
    precondition(first.matching("svg overlap 01").map(\.primary.url) == [source])
    precondition(first.matching("exports-old").count == 2)
    precondition(first.matching("absent").isEmpty)
    precondition(first.matching("", limit: 1).count == 1)

    let visit = Date()
    history.markVisit(project: project.path, at: visit)
    try manager.setAttributes(
      [.modificationDate: visit.addingTimeInterval(1)], ofItemAtPath: export.path)
    let afterVisit = ResumeHistory(defaults: defaults)
    let changed = try scan(afterVisit)
    precondition(changed.groups.filter(\.changed).count == 1)
    precondition(changed.groups[0].reason == "Export updated since your last visit")
    let refresh = try scan(history)
    precondition(!refresh.groups[0].changed, "Refresh must retain the original baseline")

    let note = first.matching("print notes")[0].primary
    history.recordUse([note])
    let next = ResumeHistory(defaults: defaults)
    next.markVisit(project: project.path, at: visit.addingTimeInterval(2))
    let revisited = try scan(ResumeHistory(defaults: defaults))
    precondition(
      revisited.groups[0].primary == note && revisited.groups[0].reason == "Recently used in Finger"
    )
    let other = temp.appendingPathComponent("Unrelated project", isDirectory: true)
    try manager.createDirectory(at: other, withIntermediateDirectories: true)
    try Data().write(to: other.appendingPathComponent("Outside.png"))
    try manager.createSymbolicLink(
      at: project.appendingPathComponent("linked"), withDestinationURL: other)
    let scoped = try ResumeCatalog.scan(
      project: project.path,
      recentFolders: [other.path, project.appendingPathComponent("linked").path],
      history: next)
    precondition(scoped.matching("Outside").isEmpty)

    let sources = project.appendingPathComponent("sources", isDirectory: true)
    try manager.createDirectory(at: sources, withIntermediateDirectories: true)
    try manager.moveItem(at: source, to: sources.appendingPathComponent(source.lastPathComponent))
    let split = try scan(afterVisit)
    precondition(split.matching("sources svg")[0].primary.name == source.lastPathComponent)
    let exports = split.matching("01.png")[0]
    precondition(exports.related.first?.url.deletingLastPathComponent() == sources)
    try Data().write(to: sources.appendingPathComponent(export.lastPathComponent))
    let duplicate = try scan(afterVisit)
    precondition(
      duplicate.groups.first { $0.primary.url == export }?.related.isEmpty == true,
      "An ambiguous duplicate export must not claim a source from another folder")
    do {
      _ = try ResumeCatalog.scan(project: project.path, history: history, cancelled: { true })
      preconditionFailure("Cancelled scan completed")
    } catch is CancellationError {}
    print(
      "Fold Studies resume catalog, visit history, filename narrowing, pairing and project boundaries passed"
    )
  }
}
