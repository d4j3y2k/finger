import Foundation

// Jev filing for new downloads: what Finger knows about where a file belongs,
// how sure it is, and how the panel words it. Nothing here touches the network.

/// How sure Jev is about a download's top folder, and so how much the panel does.
enum FilingTier: String, Equatable {
  /// 85% or more: one key files it.
  case confident
  /// 50–85%: Finger suggests, you choose.
  case likely
  /// Below that: Finger stays quiet.
  case unsure

  static let confidentFrom = 0.85
  static let likelyFrom = 0.5

  init(_ probability: Double) {
    if probability >= FilingTier.confidentFrom {
      self = .confident
    } else if probability >= FilingTier.likelyFrom {
      self = .likely
    } else {
      self = .unsure
    }
  }

  var name: String {
    switch self {
    case .confident: return "Confident"
    case .likely: return "Likely"
    case .unsure: return "Unsure"
    }
  }
}

/// A file as Jev saw it. A changed size or modification time asks again.
struct FilingKey: Hashable {
  let path: String
  let size: Int64
  let modified: TimeInterval

  /// One stat. Nil when the file is gone.
  static func of(_ path: String) -> FilingKey? {
    var info = stat()
    guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
    let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return FilingKey(path: path, size: Int64(info.st_size), modified: modified)
  }
}

/// What Finger saw on this Mac that ties a file to a folder. It decides which
/// folders Jev hears about and words the "why"; none of it is sent.
struct FilingEvidence: Equatable {
  /// Names of earlier files from the same website that are in this folder.
  var sameHost: [String] = []
  /// Names of files Finger itself filed here, from the same website or with a similar name.
  var filedBefore: [String] = []
  /// Names of files here whose names start like this one's.
  var similarNames: [String] = []
  /// How many files here share this file's extension.
  var sameKind = 0
  /// The recently used project that holds this folder, and when you last used it.
  var project: String?
  var projectUsed: Date?
  /// A folder you moved things to recently.
  var recentDestination = false

  var isEmpty: Bool { self == FilingEvidence() }
}

struct FilingCandidate: Equatable {
  let folder: String
  var evidence: FilingEvidence
  var score: Double
}

/// One folder Jev ranked, with its probability.
struct FilingRanked: Equatable {
  let folder: String
  let probability: Double
}

/// Where Jev thinks a download belongs, and Finger's own short reason.
struct FilingVerdict: Equatable {
  /// Jev's folders, most probable first.
  let ranked: [FilingRanked]
  /// Built from local evidence for the top folder, never from Jev.
  let why: String?

  var top: FilingRanked? { ranked.first }
  var tier: FilingTier { top.map { FilingTier($0.probability) } ?? .unsure }

  /// The row's chip: "⇥ invoices" when confident, "refs?" when likely, none otherwise.
  func chip(home: String) -> FilingChip? {
    guard let top else { return nil }
    let name = FilingText.folderName(top.folder, home: home)
    switch tier {
    case .confident: return FilingChip(text: "⇥ " + name, confident: true)
    case .likely: return FilingChip(text: name + "?", confident: false)
    case .unsure: return nil
    }
  }

  /// What ⇥ does on this file.
  var tabAction: FilingTabAction {
    switch tier {
    case .confident: return .file(to: top!.folder)
    case .likely: return .choose(preselect: top?.folder)
    case .unsure: return .choose(preselect: nil)
    }
  }
}

struct FilingChip: Equatable {
  let text: String
  /// Accent tint when confident, gray when likely.
  let confident: Bool
}

enum FilingTabAction: Equatable {
  /// Confident: file it now.
  case file(to: String)
  /// Likely or unsure: open the move list, with Jev's folder selected when likely.
  case choose(preselect: String?)

  static func of(_ verdict: FilingVerdict?) -> FilingTabAction {
    verdict?.tabAction ?? .choose(preselect: nil)
  }
}

/// How filing words folders, sources and reasons.
enum FilingText {
  static func folderName(_ folder: String, home: String) -> String {
    if folder == home { return "Home" }
    if folder == "/" { return FileManager.default.displayName(atPath: "/") }
    return (folder as NSString).lastPathComponent
  }

  /// The parent's name, for the bar: "Fold Studies", or "Home".
  static func parentName(_ folder: String, home: String) -> String {
    folderName((folder as NSString).deletingLastPathComponent, home: home)
  }

  /// "harborprint.co" from "billing.harborprint.co", for a row's subtitle.
  static func shortHost(_ host: String) -> String {
    let labels = host.split(separator: ".")
    guard labels.count > 2 else { return host }
    // "co.uk", "com.au": keep three labels.
    let second = labels[labels.count - 2]
    let keep = labels.last!.count == 2 && second.count <= 3 ? 3 : 2
    return labels.suffix(keep).joined(separator: ".")
  }

  /// The words of a name, lowercased, without its extension.
  static func words(_ name: String) -> [String] {
    (name as NSString).deletingPathExtension
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  /// The leading word that names what the file is: "invoice" in "Invoice 1121.pdf".
  /// Camera and app defaults such as IMG or Screenshot don't say what a file is.
  static func stem(_ name: String) -> String? {
    guard let word = words(name).first(where: { $0.count >= 3 && $0.allSatisfy(\.isLetter) }),
      !genericStems.contains(word)
    else { return nil }
    return word
  }

  static let genericStems: Set<String> = [
    "img", "dsc", "dscn", "dscf", "pxl", "mvimg", "photo", "image", "screenshot", "screen", "scan",
    "untitled", "document", "file", "download", "export", "copy", "new", "video", "movie", "recording",
  ]

  /// "Invoices 1119 and 1120", "Invoice 1120", or "3 earlier files".
  static func describe(_ names: [String], like name: String) -> (text: String, plural: Bool) {
    let unique = Array(NSOrderedSet(array: names).array as? [String] ?? names)
    let plural = unique.count != 1
    if let stem = stem(name) {
      // Every earlier name starts with the same word and carries a number.
      let numbers = unique.compactMap { other -> String? in
        let parts = words(other)
        guard parts.first == stem else { return nil }
        return parts.dropFirst().first { $0.allSatisfy(\.isNumber) }
      }
      if numbers.count == unique.count, !numbers.isEmpty {
        let title = stemTitle(unique[0], stem)
        let sorted = numbers.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sorted.count == 1 { return (title + " " + sorted[0], false) }
        let head = plural ? pluralize(title) : title
        return (head + " " + list(sorted), true)
      }
    }
    if unique.count == 1 { return (unique[0], false) }
    return ("\(unique.count) earlier files", true)
  }

  /// The stem as the earlier file spelled it: "Invoice".
  private static func stemTitle(_ name: String, _ stem: String) -> String {
    let base = (name as NSString).deletingPathExtension
    if let range = base.range(of: stem, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) {
      return String(base[range])
    }
    return stem.prefix(1).uppercased() + stem.dropFirst()
  }

  static func pluralize(_ word: String) -> String {
    let lower = word.lowercased()
    if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("ch") || lower.hasSuffix("sh") {
      return word + "es"
    }
    if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
      return word.dropLast() + "ies"
    }
    return word + "s"
  }

  /// "1119 and 1120", "1117, 1118 and 1119", "1116, 1117 and 3 more".
  static func list(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    case 2...3: return items.dropLast().joined(separator: ", ") + " and " + items.last!
    default: return items.prefix(2).joined(separator: ", ") + " and \(items.count - 2) more"
    }
  }

  /// A short local reason for the top folder, built from what Finger saw here.
  /// "Invoices 1119 and 1120 from billing.harborprint.co are filed here."
  static func why(file name: String, host: String?, evidence e: FilingEvidence, now: Date = Date()) -> String? {
    var lead: String?
    // A strong reason stands alone; a weak one says what you are working on too.
    var strong = true
    if let host, !e.sameHost.isEmpty {
      let d = describe(e.sameHost, like: name)
      lead = "\(d.text) from \(host) \(d.plural ? "are" : "is") filed here"
    } else if !e.filedBefore.isEmpty {
      let d = describe(e.filedBefore, like: name)
      lead = "You filed \(d.text) here with Finger"
    } else if !e.similarNames.isEmpty {
      let d = describe(e.similarNames, like: name)
      lead = "\(d.text) \(d.plural ? "are" : "is") here"
    } else if e.sameKind > 0 {
      strong = false
      let ext = (name as NSString).pathExtension.uppercased()
      let kind = ext.isEmpty ? "file" : ext + " file"
      lead = e.sameKind == 1 ? "Another \(kind) is here" : "\(e.sameKind) other \(kind)s are here"
    } else if e.recentDestination {
      strong = false
      lead = "You moved files here recently"
    } else {
      strong = false
    }
    var project: String?
    if !strong, let name = e.project, let used = e.projectUsed, now.timeIntervalSince(used) < 3 * 86_400 {
      project = "\(name) is what you’re working on"
    }
    switch (lead, project) {
    case (let lead?, let project?): return lead + ", and " + project + "."
    case (let lead?, nil): return lead + "."
    case (nil, let project?): return project.prefix(1).uppercased() + project.dropFirst() + "."
    default: return nil
    }
  }
}

/// What Finger noticed while filing and what, if anything, it sent to Jev,
/// as rows of "signal → what was sent". The "What Finger knows" popover lists
/// them. The API key and full paths are never recorded here.
struct FilingLogRow: Equatable {
  let signal: String
  let sent: String
  let at: Date
}

final class FilingLog {
  static let shared = FilingLog()
  /// Posted on the main thread when rows change.
  static let changed = Notification.Name("FilingLog.changed")
  static let staysHere = "Stays on this Mac"

  private(set) var rows: [FilingLogRow] = []
  let limit: Int

  init(limit: Int = 40) { self.limit = limit }

  /// Newest first.
  func add(_ signal: String, sent: String, at: Date = Date()) {
    rows.insert(FilingLogRow(signal: signal, sent: sent, at: at), at: 0)
    if rows.count > limit { rows.removeLast(rows.count - limit) }
    NotificationCenter.default.post(name: FilingLog.changed, object: self)
  }

  /// The rows to show: signal and what was sent.
  var pairs: [(signal: String, sent: String)] { rows.map { ($0.signal, $0.sent) } }

  func clear() {
    rows.removeAll()
    NotificationCenter.default.post(name: FilingLog.changed, object: self)
  }
}
