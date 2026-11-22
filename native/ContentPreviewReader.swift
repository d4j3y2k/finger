import AppKit
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Everything ContentPreview shows is read here, off the main thread. Each read
// checks its ticket between steps so a newer selection can abandon it.

struct ContentFacts {
  var rows: [(String, String)] = []
}

struct ContentText {
  enum Style { case prose, markdown, code }
  let style: Style
  let text: NSTextStorage
  /// UTF-16 offsets where each numbered line starts, for the gutter.
  let lineStarts: [Int]
  let lines: Int
  let partial: Bool
  let matches: [NSRange]
}

struct ContentImage {
  let image: NSImage
  let pixels: (Int, Int)?
  let dimensions: String?
  let facts: ContentFacts
}

struct ContentArchive {
  struct Row {
    let depth: Int
    let name: String
    let directory: Bool
    let detail: String
    let type: UTType?
  }
  let rows: [Row]
  let files: Int
  let more: Int
  let facts: ContentFacts
}

struct ContentSheet {
  let rows: [[String]]
  let columns: Int
  let totalRows: Int
  let partial: Bool
  let matches: [(row: Int, column: Int)]
}

enum ContentBody {
  case text(ContentText)
  case pdf(PDFDocument, matches: [PDFSelection])
  case image(ContentImage)
  case archive(ContentArchive)
  case sheet(ContentSheet)
  case quickLook
  case message(String)
}

struct ContentLoad {
  let url: URL
  let kind: String
  let bytes: Int?
  let extra: String?
  let body: ContentBody
  /// The file's own icon, which can differ from its type's.
  let icon: NSImage?
}

enum ContentPreviewReader {
  static let textLimit = 512 * 1_024
  static let lineLimit = 10_000

  static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
  static let proseExtensions: Set<String> = ["txt", "text", "me", "nfo", "readme"]
  static let sheetExtensions: Set<String> = ["csv", "tsv", "tab"]
  /// Rich formats that are text underneath but read better in Quick Look.
  private static let richText: Set<String> = ["rtf", "rtfd", "webarchive", "pages", "doc", "docx"]

  /// What the header can say before anything is read.
  static func kind(of url: URL) -> String {
    if url.hasDirectoryPath { return "Folder" }
    let ext = url.pathExtension.lowercased()
    if let known = kindNames[ext] { return known }
    let name = url.lastPathComponent.lowercased()
    if ["makefile", "dockerfile", "license", "readme", "changelog"].contains(name) {
      return name == "makefile" ? "Makefile" : name == "dockerfile" ? "Dockerfile" : "Plain Text"
    }
    if let type = UTType(filenameExtension: ext), !type.isDynamic,
      let description = type.localizedDescription, !description.isEmpty
    {
      return description.prefix(1).uppercased() + description.dropFirst()
    }
    return ext.isEmpty ? "Document" : ext.uppercased() + " File"
  }
  private static let kindNames: [String: String] = [
    "swift": "Swift Source", "rs": "Rust Source", "js": "JavaScript", "mjs": "JavaScript",
    "cjs": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
    "py": "Python Script", "sh": "Shell Script", "bash": "Shell Script", "zsh": "Shell Script",
    "fish": "Shell Script", "command": "Shell Script", "toml": "TOML", "json": "JSON",
    "jsonl": "JSON Lines", "yaml": "YAML", "yml": "YAML", "c": "C Source", "h": "C Header",
    "m": "Objective-C Source", "mm": "Objective-C++ Source", "cpp": "C++ Source",
    "cc": "C++ Source", "hpp": "C++ Header", "go": "Go Source", "md": "Markdown",
    "markdown": "Markdown", "txt": "Plain Text", "text": "Plain Text", "log": "Log File",
    "pdf": "PDF Document", "zip": "ZIP Archive", "png": "PNG Image", "jpg": "JPEG Image",
    "jpeg": "JPEG Image", "heic": "HEIC Image", "heif": "HEIF Image", "gif": "GIF Image",
    "svg": "SVG Image", "tif": "TIFF Image", "tiff": "TIFF Image", "webp": "WebP Image",
    "avif": "AVIF Image", "bmp": "BMP Image", "psd": "Photoshop Document", "csv": "CSV Document",
    "tsv": "TSV Document", "html": "HTML Document", "xml": "XML Document", "css": "CSS",
    "rtf": "Rich Text Document", "numbers": "Numbers Spreadsheet", "pages": "Pages Document",
    "key": "Keynote Presentation", "xlsx": "Excel Workbook", "docx": "Word Document",
    "pptx": "PowerPoint Presentation", "plist": "Property List", "lock": "Lockfile",
  ]

  static func read(_ url: URL, match: String?, ticket: FileReadTicket) -> ContentLoad? {
    var kind = kind(of: url)
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    func load(_ body: ContentBody, bytes: Int? = nil, extra: String? = nil) -> ContentLoad {
      ContentLoad(url: url, kind: kind, bytes: bytes, extra: extra, body: body, icon: icon)
    }
    // Follow a link for the content; the header keeps the link's own name.
    let target = url.resolvingSymlinksInPath()
    var info = stat()
    guard stat(target.path, &info) == 0 else {
      return load(.message("This file can’t be read."))
    }
    let bytes = Int(info.st_size)
    if info.st_mode & S_IFMT == S_IFDIR {
      kind = "Folder"
      return load(.quickLook)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      return load(.message("Contents are unavailable for this type of item."))
    }
    // Never materialize a cloud placeholder just because it was selected.
    if info.st_flags & UInt32(SF_DATALESS) != 0 {
      return load(.message("Download this file to preview its contents."), bytes: bytes)
    }
    if bytes == 0 { return load(.message("This file is empty."), bytes: 0) }
    if ticket.cancelled { return nil }

    let ext = url.pathExtension.lowercased()
    let type = UTType(filenameExtension: ext)
    let needle = match.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap {
      $0.isEmpty ? nil : $0
    }

    if type?.conforms(to: .pdf) == true {
      return readPDF(target, needle: needle, ticket: ticket).map {
        load($0.body, bytes: bytes, extra: $0.extra)
      }
    }
    if ext == "zip" {
      guard let archive = ZipIndex.read(target, ticket: ticket) else {
        return ticket.cancelled ? nil : load(.quickLook, bytes: bytes)
      }
      let index = ContentArchive(
        rows: archive.rows, files: archive.files, more: archive.more,
        facts: fileFacts(url, info: info))
      return load(.archive(index), bytes: bytes, extra: plural(archive.files, "file"))
    }
    let language = CodeLanguage.forFile(url)
    if language == nil, type?.conforms(to: .image) == true || ext == "svg" {
      if let image = readImage(target, url: url, info: info, ticket: ticket) {
        return load(.image(image), bytes: bytes, extra: image.dimensions)
      }
      return ticket.cancelled ? nil : load(.quickLook, bytes: bytes)
    }
    if richText.contains(ext) { return load(.quickLook, bytes: bytes) }

    let markdown = markdownExtensions.contains(ext)
    let sheet = sheetExtensions.contains(ext)
    let texty =
      markdown || sheet || language != nil || proseExtensions.contains(ext) || ext.isEmpty
      || type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
      || type == nil || type?.isDynamic == true
    guard texty else { return load(.quickLook, bytes: bytes) }
    guard
      let sample = try? PreviewReader.readText(target, limit: textLimit, maxLines: lineLimit)
    else {
      // Binary data behind a text-like name, or an encoding we don't read.
      return ticket.cancelled ? nil : load(.quickLook, bytes: bytes)
    }
    if ticket.cancelled { return nil }
    var text = sample.text
    if sample.partial, let cut = text.lastIndex(of: "\n") {
      // Don't end on half a line.
      text = String(text[...cut])
    }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    if sheet, let grid = readSheet(text, tabs: ext != "csv", partial: sample.partial, needle: needle)
    {
      return load(.sheet(grid), bytes: bytes, extra: plural(grid.totalRows, "row", more: sample.partial))
    }
    let style: ContentText.Style
    var codeLanguage = language
    if markdown {
      style = .markdown
    } else if ext == "log" {
      // Logs read best as plain columns; coloring every number is noise.
      style = .code
      codeLanguage = nil
    } else if let language {
      style = .code
      codeLanguage = language
    } else if let shebang = CodeLanguage.forShebang(text) {
      style = .code
      codeLanguage = shebang
    } else {
      style = .prose
    }
    guard let content = buildText(
        text, style: style, language: codeLanguage, partial: sample.partial, needle: needle,
        ticket: ticket)
    else { return nil }
    return load(
      .text(content), bytes: bytes, extra: plural(content.lines, "line", more: content.partial))
  }

  static func plural(_ n: Int, _ word: String, more: Bool = false) -> String {
    "\(n.formatted())\(more ? "+" : "") \(word)\(n == 1 && !more ? "" : "s")"
  }

  // MARK: Text

  static func buildText(
    _ text: String, style: ContentText.Style, language: CodeLanguage?, partial: Bool,
    needle: String?, ticket: FileReadTicket
  ) -> ContentText? {
    // TextKit takes seconds to wrap one enormous line, such as a minified
    // bundle, so very long lines are cut short for display.
    let (text, shortened) = shortenLongLines(text, limit: lineCharacterLimit)
    let ns = text as NSString
    var starts: [Int] = [0]
    starts.reserveCapacity(ns.length / 24)
    var units = Array(text.utf16)
    for (i, c) in units.enumerated() where c == 10 && i + 1 < units.count { starts.append(i + 1) }
    units = []
    let lines = text.isEmpty ? 0 : starts.count
    if ticket.cancelled { return nil }
    let cancelled = { ticket.cancelled }
    let body: NSMutableAttributedString
    switch style {
    case .code:
      let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
      body = SyntaxHighlighter.attributed(text, language: language, font: font, cancelled: cancelled)
      SyntaxHighlighter.hangIndents(body, font: font)
    case .markdown:
      body = MarkdownRenderer.render(text, cancelled: cancelled)
    case .prose:
      body = prose(text)
    }
    if ticket.cancelled { return nil }
    preferTextGlyphs(body)
    let matches = needle.map { highlight(body, $0) } ?? []
    var notes: [String] = []
    if partial { notes.append("Showing the first \(lines.formatted()) lines") }
    if shortened > 0 {
      notes.append(
        "\(plural(shortened, "line")) cut at \(lineCharacterLimit.formatted()) characters")
    }
    if !notes.isEmpty {
      let note = NSMutableParagraphStyle()
      note.paragraphSpacingBefore = 12
      let prefix = body.length > 0 && !(body.string.hasSuffix("\n")) ? "\n" : ""
      body.append(
        NSAttributedString(
          string: prefix + notes.joined(separator: " · "),
          attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: note,
          ]))
    }
    return ContentText(
      style: style, text: NSTextStorage(attributedString: body), lineStarts: style == .code ? starts : [], lines: lines,
      partial: partial, matches: matches)
  }

  /// Characters such as ↩ have a text form and an emoji form. When the font
  /// in use has no glyph for one, fallback picks Apple Color Emoji, so ⌘↩ in
  /// code shows a color button. Give those characters a text font that has
  /// the glyph instead, unless the text asks for emoji with U+FE0F.
  static func preferTextGlyphs(_ text: NSMutableAttributedString) {
    func has(_ font: NSFont, _ scalar: Unicode.Scalar) -> Bool {
      var units = Array(String(scalar).utf16)
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }
    var chosen: [String: NSFont] = [:]
    var offset = 0
    var scalars = text.string.unicodeScalars.makeIterator()
    var current = scalars.next()
    text.beginEditing()
    while let scalar = current {
      let next = scalars.next()
      let length = scalar.utf16.count
      if scalar.value >= 0xA9, scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation,
        next?.value != 0xFE0F,
        let font = text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont,
        !has(font, scalar)
      {
        let key = "\(font.fontName) \(font.pointSize) \(scalar.value)"
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let candidates = [
          NSFont.systemFont(ofSize: font.pointSize, weight: bold ? .semibold : .regular),
          NSFont(name: "AppleSymbols", size: font.pointSize),
        ]
        if let replacement = chosen[key] ?? candidates.compactMap({ $0 }).first(where: { has($0, scalar) }) {
          chosen[key] = replacement
          text.addAttribute(.font, value: replacement, range: NSRange(location: offset, length: length))
        }
      }
      offset += length
      current = next
    }
    text.endEditing()
  }

  static let lineCharacterLimit = 3_000

  static func shortenLongLines(_ text: String, limit: Int) -> (String, Int) {
    var run = 0
    var long = false
    for c in text.utf16 {
      if c == 10 {
        run = 0
      } else {
        run += 1
        if run > limit {
          long = true
          break
        }
      }
    }
    guard long else { return (text, 0) }
    var cut = 0
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
      guard line.utf16.count > limit else { return line }
      cut += 1
      return line.prefix(limit) + " …"
    }
    return (lines.joined(separator: "\n"), cut)
  }

  /// Readable text: the system font, wrapped, with short gaps between paragraphs.
  private static func prose(_ text: String) -> NSMutableAttributedString {
    let font = NSFont.systemFont(ofSize: 13)
    let style = NSMutableParagraphStyle()
    style.lineSpacing = round(13 * 1.55 - (font.ascender - font.descender + font.leading))
    style.lineBreakMode = .byWordWrapping
    let blank = NSMutableParagraphStyle()
    blank.minimumLineHeight = 6
    blank.maximumLineHeight = 6
    let result = NSMutableAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    // Blank lines separate paragraphs by a short gap, not a full line.
    let ns = text as NSString
    var location = 0
    while location < ns.length {
      let line = ns.lineRange(for: NSRange(location: location, length: 0))
      let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
      if content.isEmpty && line.location > 0 {
        result.addAttribute(.paragraphStyle, value: blank, range: line)
      }
      location = NSMaxRange(line)
      if line.length == 0 { break }
    }
    return result
  }

  /// Marks every hit in the yellow find highlight. A phrase that never appears
  /// whole falls back to its words, as content search may have matched them
  /// apart, but only when every word is in the text shown.
  static func highlight(_ text: NSMutableAttributedString, _ needle: String) -> [NSRange] {
    var ranges = find(needle, in: text.string)
    if ranges.isEmpty {
      let words = needle.split(whereSeparator: \.isWhitespace).map(String.init).filter {
        $0.count >= 2
      }
      if words.count > 1 {
        let hits = words.map { find($0, in: text.string) }
        if hits.allSatisfy({ !$0.isEmpty }) {
          ranges = hits.flatMap { $0 }.sorted { $0.location < $1.location }
        }
      }
    }
    for range in ranges {
      text.addAttributes(
        [.backgroundColor: ContentInk.found, .foregroundColor: ContentInk.foundInk], range: range)
    }
    return ranges
  }

  static func find(_ needle: String, in haystack: String, limit: Int = 5_000) -> [NSRange] {
    let ns = haystack as NSString
    var ranges: [NSRange] = []
    var search = NSRange(location: 0, length: ns.length)
    while ranges.count < limit {
      let hit = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
      if hit.location == NSNotFound || hit.length == 0 { break }
      ranges.append(hit)
      search = NSRange(location: NSMaxRange(hit), length: ns.length - NSMaxRange(hit))
    }
    return ranges
  }

  // MARK: PDF

  private static func readPDF(_ url: URL, needle: String?, ticket: FileReadTicket) -> (
    body: ContentBody, extra: String?
  )? {
    guard let document = PDFDocument(url: url) else {
      return (.message("This PDF can’t be opened."), nil)
    }
    if document.isLocked {
      return (.message("This PDF requires a password."), nil)
    }
    let pages = document.pageCount
    if ticket.cancelled { return nil }
    var matches: [PDFSelection] = []
    if let needle {
      let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
      matches = document.findString(needle, withOptions: options)
      if matches.isEmpty {
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init).filter {
          $0.count >= 2
        }
        if words.count > 1 {
          let hits = words.map { document.findString($0, withOptions: options) }
          if hits.allSatisfy({ !$0.isEmpty }) { matches = hits.flatMap { $0 } }
        }
      }
      for selection in matches { selection.color = ContentInk.found }
    }
    if ticket.cancelled { return nil }
    return (.pdf(document, matches: matches), plural(pages, "page"))
  }

  // MARK: Images

  private static func readImage(_ target: URL, url: URL, info: stat, ticket: FileReadTicket)
    -> ContentImage?
  {
    let ext = url.pathExtension.lowercased()
    var facts = ContentFacts()
    if ext == "svg" {
      // ImageIO doesn't draw SVG. NSImage does, as a vector.
      guard let image = NSImage(contentsOf: target), image.isValid else { return nil }
      var dimensions: String?
      if let sample = try? PreviewReader.readText(target), let box = SVGViewport.read(sample.text) {
        dimensions = box.contains(where: \.isLetter) ? box : box + " pt"
      } else if image.size.width > 0 {
        dimensions = "\(Int(image.size.width)) × \(Int(image.size.height)) pt"
      }
      if let dimensions { facts.rows.append(("Dimensions", dimensions)) }
      facts.rows += fileFacts(url, info: info).rows
      return ContentImage(image: image, pixels: nil, dimensions: dimensions, facts: facts)
    }
    guard
      let source = CGImageSourceCreateWithURL(
        target as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    var pixels: (Int, Int)?
    if let w = properties[kCGImagePropertyPixelWidth] as? Int,
      let h = properties[kCGImagePropertyPixelHeight] as? Int
    {
      let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
      pixels = (5...8).contains(orientation) ? (h, w) : (w, h)
    }
    if ticket.cancelled { return nil }
    // Enough pixels for a Retina pane at Quick Look size.
    guard let raster = PreviewReader.raster(target, pixels: 1_600) else { return nil }
    if ticket.cancelled { return nil }
    let image = NSImage(cgImage: raster, size: NSSize(width: raster.width, height: raster.height))
    let dimensions = pixels.map { "\($0.0) × \($0.1)" }
    if let dimensions { facts.rows.append(("Dimensions", dimensions)) }
    if let camera = camera(properties) {
      facts.rows.append(("Camera", camera))
    } else if let profile = properties[kCGImagePropertyProfileName] as? String, !profile.isEmpty {
      facts.rows.append(("Color", profile))
    }
    facts.rows += fileFacts(url, info: info).rows
    return ContentImage(image: image, pixels: pixels, dimensions: dimensions, facts: facts)
  }

  private static func camera(_ properties: [CFString: Any]) -> String? {
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
    guard var model = (tiff[kCGImagePropertyTIFFModel] as? String)?
      .trimmingCharacters(in: .whitespaces), !model.isEmpty
    else { return nil }
    if let make, !make.isEmpty, !model.lowercased().hasPrefix(make.lowercased()),
      make.lowercased() != "apple"
    {
      model = make.prefix(1).uppercased() + make.dropFirst().lowercased() + " " + model
    }
    if let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, focal > 0 {
      return "\(model), \(focal) mm"
    }
    return model
  }

  // MARK: File facts

  /// Where, Modified and From, as Quick Look would tell you.
  static func fileFacts(_ url: URL, info: stat) -> ContentFacts {
    var facts = ContentFacts()
    facts.rows.append(("Where", place(url.deletingLastPathComponent())))
    let modified = Date(
      timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
        + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    facts.rows.append(("Modified", relative(modified)))
    if let from = origin(url) { facts.rows.append(("From", from)) }
    return facts
  }

  /// A folder as a person names it: "Downloads", or "Finances › 2026".
  static func place(_ folder: URL) -> String {
    let path = folder.standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    if path == home { return "Home" }
    if path == "/" { return FileManager.default.displayName(atPath: "/") }
    var names: [String] = []
    var current = URL(fileURLWithPath: path)
    while names.count < 2 && current.path != "/" && current.path != home {
      names.insert(FileManager.default.displayName(atPath: current.path), at: 0)
      current.deleteLastPathComponent()
    }
    return names.joined(separator: " › ")
  }

  static func relative(_ date: Date, now: Date = Date()) -> String {
    let age = now.timeIntervalSince(date)
    if age >= 0 && age < 60 { return "Just now" }
    if age >= 0 && age < 7 * 86_400 {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      return formatter.localizedString(for: date, relativeTo: now)
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  /// The sites in kMDItemWhereFroms, and the app that downloaded the file.
  static func origin(_ url: URL) -> String? {
    var parts: [String] = []
    if let data = xattr(url, "com.apple.metadata:kMDItemWhereFroms"),
      let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    {
      for entry in list {
        let host = URL(string: entry)?.host ?? (entry.contains("@") ? entry : nil)
        if let host, !host.isEmpty {
          let short = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
          if !parts.contains(short) { parts.append(short) }
        }
      }
      parts = Array(parts.prefix(2))
    }
    if let data = xattr(url, "com.apple.quarantine"),
      let value = String(data: data, encoding: .utf8)
    {
      let fields = value.split(separator: ";", omittingEmptySubsequences: false)
      if fields.count > 2, !fields[2].isEmpty, !parts.contains(String(fields[2])) {
        parts.append(String(fields[2]))
      }
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  private static func xattr(_ url: URL, _ name: String) -> Data? {
    url.withUnsafeFileSystemRepresentation { path -> Data? in
      guard let path else { return nil }
      let size = getxattr(path, name, nil, 0, 0, 0)
      guard size > 0, size < 1 << 20 else { return nil }
      var data = Data(count: size)
      let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
      return read == size ? data : nil
    }
  }

  // MARK: Spreadsheets

  private static func readSheet(_ text: String, tabs: Bool, partial: Bool, needle: String?)
    -> ContentSheet?
  {
    let separator: Character = tabs ? "\t" : (text.prefix(4_096).contains(";")
      && !text.prefix(4_096).contains(",") ? ";" : ",")
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var total = 0
    var iterator = text.makeIterator()
    var pending: Character?
    func endRow() {
      row.append(field)
      field = ""
      if !(row.count == 1 && row[0].isEmpty) {
        total += 1
        if rows.count < 500 { rows.append(Array(row.prefix(40))) }
      }
      row = []
    }
    while let c = pending ?? iterator.next() {
      pending = nil
      if quoted {
        if c == "\"" {
          if let next = iterator.next() {
            if next == "\"" { field.append("\"") } else {
              quoted = false
              pending = next
            }
          } else {
            quoted = false
          }
        } else {
          field.append(c)
        }
        continue
      }
      switch c {
      case "\"" where field.isEmpty: quoted = true
      case separator:
        row.append(field)
        field = ""
      case "\n", "\r\n": endRow()
      case "\r": endRow()
      default: field.append(c)
      }
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    let columns = rows.map(\.count).max() ?? 0
    // A file with a single column is better read as text.
    guard columns >= 2, !rows.isEmpty else { return nil }
    var matches: [(Int, Int)] = []
    if let needle {
      for (r, cells) in rows.enumerated() {
        for (c, cell) in cells.enumerated()
        where cell.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
          matches.append((r, c))
        }
      }
    }
    return ContentSheet(
      rows: rows, columns: columns, totalRows: total, partial: partial || total > rows.count,
      matches: matches)
  }
}

// MARK: - Zip

/// Reads a zip's central directory to list what is inside. Nothing is extracted.
enum ZipIndex {
  struct Listing {
    let rows: [ContentArchive.Row]
    let files: Int
    let more: Int
  }
  private final class Node {
    let name: String
    var directory: Bool
    var size: UInt64 = 0
    var children: [String: Node] = [:]
    var order: [String] = []
    init(_ name: String, directory: Bool) {
      self.name = name
      self.directory = directory
    }
    func child(_ name: String, directory: Bool) -> Node {
      if let existing = children[name] {
        if directory { existing.directory = true }
        return existing
      }
      let node = Node(name, directory: directory)
      children[name] = node
      order.append(name)
      return node
    }
  }

  static let rowLimit = 2_000
  static let maxDepth = 48

  static func read(_ url: URL, ticket: FileReadTicket) -> Listing? {
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let size = UInt64(info.st_size)
    guard size >= 22 else { return nil }
    func readAt(_ offset: UInt64, _ count: Int) -> [UInt8]? {
      guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
      var buffer = [UInt8](repeating: 0, count: count)
      var done = 0
      while done < count {
        let got = buffer.withUnsafeMutableBytes {
          pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
        }
        if got <= 0 { return nil }
        done += got
      }
      return buffer
    }
    // The end of central directory record is in the last 64 KB + 22 bytes.
    let tailLength = Int(min(size, 65_557))
    guard let tail = readAt(size - UInt64(tailLength), tailLength) else { return nil }
    var eocd = -1
    var k = tail.count - 22
    while k >= 0 {
      if tail[k] == 0x50 && tail[k + 1] == 0x4B && tail[k + 2] == 0x05 && tail[k + 3] == 0x06 {
        eocd = k
        break
      }
      k -= 1
    }
    guard eocd >= 0 else { return nil }
    var entries = UInt64(le16(tail, eocd + 10))
    var directorySize = UInt64(le32(tail, eocd + 12))
    var directoryOffset = UInt64(le32(tail, eocd + 16))
    let eocdOffset = size - UInt64(tailLength) + UInt64(eocd)
    if entries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
      eocd >= 20, le32(tail, eocd - 20) == 0x0706_4B50
    {
      let recordOffset = le64(tail, eocd - 20 + 8)
      if let record = readAt(recordOffset, 56), le32(record, 0) == 0x0606_4B50 {
        entries = le64(record, 32)
        directorySize = le64(record, 40)
        directoryOffset = le64(record, 48)
      }
    }
    guard directoryOffset <= eocdOffset, directorySize <= 64 << 20,
      let directory = readAt(directoryOffset, Int(directorySize))
    else { return nil }
    let root = Node("", directory: true)
    var files = 0
    var p = 0
    var seen: UInt64 = 0
    while p + 46 <= directory.count, le32(directory, p) == 0x0201_4B50, seen < entries {
      if seen & 1023 == 0, ticket.cancelled { return nil }
      seen += 1
      let flags = le16(directory, p + 8)
      var uncompressed = UInt64(le32(directory, p + 24))
      let nameLength = Int(le16(directory, p + 28))
      let extraLength = Int(le16(directory, p + 30))
      let commentLength = Int(le16(directory, p + 32))
      let nameStart = p + 46
      guard nameStart + nameLength + extraLength <= directory.count else { break }
      let nameBytes = Array(directory[nameStart..<(nameStart + nameLength)])
      if uncompressed == 0xFFFF_FFFF {
        // The ZIP64 extra field holds the real size.
        var e = nameStart + nameLength
        let end = e + extraLength
        while e + 4 <= end {
          let id = le16(directory, e)
          let length = Int(le16(directory, e + 2))
          if id == 1, e + 4 + 8 <= end {
            uncompressed = le64(directory, e + 4)
            break
          }
          e += 4 + length
        }
      }
      p = nameStart + nameLength + extraLength + commentLength
      let name =
        flags & 0x800 != 0
        ? String(decoding: nameBytes, as: UTF8.self)
        : String(bytes: nameBytes, encoding: .utf8)
          ?? String(
            bytes: nameBytes,
            encoding: String.Encoding(
              rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))
          ?? String(decoding: nameBytes, as: UTF8.self)
      let isDirectory = name.hasSuffix("/")
      var parts = name.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
      // The tree is walked recursively, so a hostile path can't nest without end.
      if parts.count > maxDepth {
        parts = Array(parts.prefix(maxDepth - 1)) + [parts.dropFirst(maxDepth - 1).joined(separator: "/")]
      }
      guard let last = parts.last else { continue }
      // Finder's resource forks and folder settings are not content.
      if parts.first == "__MACOSX" || last == ".DS_Store" { continue }
      var node = root
      for part in parts.dropLast() { node = node.child(part, directory: true) }
      let leaf = node.child(last, directory: isDirectory)
      if !isDirectory {
        leaf.size = uncompressed
        files += 1
      }
    }
    var rows: [ContentArchive.Row] = []
    var more = 0
    func sorted(_ node: Node) -> [Node] {
      node.order.compactMap { node.children[$0] }.sorted {
        if $0.directory != $1.directory { return $0.directory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    }
    func count(_ node: Node) -> Int { node.children.values.reduce(0) { $0 + 1 + count($1) } }
    func walk(_ node: Node, depth: Int) {
      for child in sorted(node) {
        guard rows.count < rowLimit else {
          more += 1 + count(child)
          continue
        }
        let ext = (child.name as NSString).pathExtension
        rows.append(
          ContentArchive.Row(
            depth: depth, name: child.name, directory: child.directory,
            detail: child.directory
              ? ContentPreviewReader.plural(child.children.count, "item")
              : ByteCountFormatter.string(fromByteCount: Int64(clamping: child.size), countStyle: .file),
            type: child.directory ? .folder : UTType(filenameExtension: ext)))
        if child.directory { walk(child, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return Listing(rows: rows, files: files, more: more)
  }

  private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
    guard i + 2 <= b.count, i >= 0 else { return 0 }
    return UInt16(b[i]) | UInt16(b[i + 1]) << 8
  }
  private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    guard i + 4 <= b.count, i >= 0 else { return 0 }
    return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
  }
  private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
  }
}
