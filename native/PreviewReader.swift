import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// MARK: - Reading bounded previews

struct PreviewEntry {
  let url: URL
  let name: String
  let directory: Bool
  var bytes: Int?
  var isMedia: Bool {
    !directory && PreviewReader.mediaExtensions.contains(url.pathExtension.lowercased())
  }
}
struct PreviewFolder {
  let rows: [PreviewEntry]
  let media: [PreviewEntry]
  let total: Int
  let linkTarget: String?
}
struct PreviewFile {
  let url: URL
  let typeName: String
  let bytes: Int?
  let modified: Date?
  var dimensions: (Int, Int)?
  var pages: Int?
  var artboard: String?
  var text: String?
  var textIsPrefix = false
  var message: String?
  var isBundle = false
  var version: String?
  var isLink = false
}
enum PreviewModel {
  case folder(PreviewFolder)
  case file(PreviewFile)
  case multiple(Int, Int?, [PreviewEntry], [PreviewEntry])
  case error(String)
}
enum PreviewReader {
  static let mediaExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp", "webp", "svg", "pdf",
    "psd", "mov", "mp4", "m4v",
  ]
  private static let plainExtensions: Set<String> = [
    "rs", "py", "js", "jsx", "ts", "tsx", "css", "scss", "html", "md", "markdown", "rst", "toml",
    "yaml", "yml", "json", "jsonl", "xml", "ini", "conf", "cfg", "env", "sh", "zsh", "bash", "fish",
    "c", "h", "cpp", "hpp", "swift", "java", "kt", "go", "rb", "php", "sql", "tex", "log", "txt",
    "csv", "tsv", "gitignore", "lock",
  ]
  private static let fileKeys: Set<URLResourceKey> = [
    .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
    .contentModificationDateKey, .contentTypeKey, .isPackageKey,
    .ubiquitousItemDownloadingStatusKey,
  ]

  static func read(
    _ urls: [URL], total: Int, hidden: Bool, order: FileOrder, ticket: FileReadTicket,
    engine: Engine?
  ) -> PreviewModel? {
    if total > 1 {
      var rows: [PreviewEntry] = []
      var bytes: Int? = total == urls.count && total <= 128 ? 0 : nil
      for (index, url) in urls.prefix(128).enumerated() {
        if ticket.cancelled { return nil }
        if bytes == nil && index >= 32 { break }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
        if index < 32 {
          rows.append(
            PreviewEntry(
              url: url, name: pName(url), directory: v?.isDirectory == true, bytes: v?.fileSize))
        }
        if let total = bytes, v?.isRegularFile == true, let size = v?.fileSize,
          total <= Int.max - size
        {
          bytes = total + size
        } else {
          bytes = nil
        }
      }
      return .multiple(total, bytes, rows, Array(rows.filter(\.isMedia).prefix(3)))
    }
    guard let url = urls.first else { return nil }
    do {
      let v = try url.resourceValues(forKeys: fileKeys)
      if v.isSymbolicLink == true {
        var targetIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &targetIsDirectory),
          targetIsDirectory.boolValue
        {
          let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
          return try readFolder(
            url, hidden: hidden, order: order, engine: engine, ticket: ticket, linkTarget: target)
        }
      }
      if v.isDirectory == true && v.isSymbolicLink != true {
        if v.isPackage == true {
          var file = PreviewFile(
            url: url, typeName: v.contentType?.localizedDescription ?? "Bundle",
            bytes: nil, modified: v.contentModificationDate)
          file.isBundle = ["app", "bundle", "framework", "appex", "plugin", "kext", "prefpane"]
            .contains(url.pathExtension.lowercased())
          if file.isBundle {
            file.version =
              Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
              as? String
          }
          return .file(file)
        }
        return try readFolder(url, hidden: hidden, order: order, engine: engine, ticket: ticket)
      }
      let ext = url.pathExtension.lowercased()
      let type = v.contentType ?? UTType(filenameExtension: ext)
      let kind =
        v.isSymbolicLink == true
        ? "Symbolic link"
        : type?.localizedDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " file")
      var file = PreviewFile(
        url: url, typeName: kind, bytes: v.fileSize, modified: v.contentModificationDate)
      if v.isSymbolicLink == true {
        file.isLink = true
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        file.message = "Points to \(target)"
      } else if v.isRegularFile != true {
        file.message = "Contents are unavailable for this type of item."
      } else if v.ubiquitousItemDownloadingStatus == .notDownloaded {
        file.message = "Download this file to preview its contents."
      } else if v.fileSize == 0 {
        file.message = "This file is empty."
      } else if ext == "svg" {
        if let prefix = try? readText(url) { file.artboard = SVGViewport.read(prefix.text) }
      } else if type?.conforms(to: .pdf) == true {
        if let pdf = CGPDFDocument(url as CFURL) {
          if pdf.isEncrypted && !pdf.isUnlocked {
            file.message = "This PDF requires a password."
          } else {
            file.pages = pdf.numberOfPages
          }
        }
      } else if type?.conforms(to: .image) == true {
        file.dimensions = imageDimensions(url)
      } else if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
        || plainExtensions.contains(ext) || ext.isEmpty
      {
        // Read only a finite prefix, even if a file changes under us.
        if let preview = try readText(url) {
          file.text = preview.text
          file.textIsPrefix = preview.partial
        }
      }
      return .file(file)
    } catch { return .error(error.localizedDescription) }
  }

  private static func readFolder(
    _ url: URL, hidden: Bool, order: FileOrder, engine: Engine?, ticket: FileReadTicket,
    linkTarget: String? = nil
  ) throws -> PreviewModel {
    struct Reply: Decodable {
      let ok: Bool
      let entries: [Entry]?
      let media: [Entry]?
      let total: Int?
      let error: String?
    }
    guard let engine else { return .error("The folder reader is unavailable.") }
    let data = try engine.folderPreview(url.path, showHidden: hidden, order: order, ticket: ticket)
    let reply = try JSONDecoder().decode(Reply.self, from: data)
    guard reply.ok, let entries = reply.entries, let media = reply.media, let total = reply.total
    else {
      return .error(reply.error ?? "Couldn’t read this folder.")
    }
    func item(_ entry: Entry) -> PreviewEntry {
      PreviewEntry(
        url: entry.url, name: entry.name, directory: entry.isDirectory,
        bytes: entry.size.flatMap(Int.init(exactly:)))
    }
    return .folder(
      PreviewFolder(
        rows: entries.map(item), media: media.map(item), total: total, linkTarget: linkTarget))
  }

  /// Defaults suit the inspector. ContentPreview reads up to 512 KB and 10,000 lines.
  static func readText(_ url: URL, limit: Int = 12_288, maxLines: Int = 160) throws -> (
    text: String, partial: Bool
  )? {
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var attributes = stat()
    guard fstat(fd, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG else { return nil }
    var buffer = [UInt8](repeating: 0, count: limit + 1)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var bytes = Array(buffer.prefix(min(count, limit)))
    // A newline-only file can otherwise produce a native text surface
    // hundreds of thousands of points tall from a small byte prefix.
    func bounded(_ text: String) -> (text: String, partial: Bool) {
      var lines = 0
      for index in text.indices where text[index].isNewline {
        lines += 1
        if lines == maxLines, text.index(after: index) < text.endIndex {
          return (String(text[...index]), true)
        }
      }
      return (text, count > limit)
    }
    if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
      if let text = String(data: Data(bytes), encoding: .utf16) { return bounded(text) }
      // The byte limit can cut a surrogate pair between its two code units.
      if count > limit, let text = String(data: Data(bytes.dropLast(2)), encoding: .utf16) {
        return bounded(text)
      }
      return nil
    }
    guard !bytes.contains(0) else { return nil }
    // A bounded read may split a UTF-8 scalar at the end.
    for _ in 0..<4 {
      if let text = String(bytes: bytes, encoding: .utf8) { return bounded(text) }
      if count <= limit || bytes.isEmpty { break }
      bytes.removeLast()
    }
    return nil
  }

  static func raster(_ url: URL, pixels: Int) -> CGImage? {
    let ext = url.pathExtension.lowercased()
    guard ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .image) == true else {
      return nil
    }
    guard
      let src = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
  }

  private static func imageDimensions(_ url: URL) -> (Int, Int)? {
    guard
      let src = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = info[kCGImagePropertyPixelWidth] as? Int,
      let h = info[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = info[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? (h, w) : (w, h)
  }
}

// Parse only the root element of the bounded SVG text sample. A viewBox
// remains meaningful for vector sources whose width and height are relative.
final class SVGViewport: NSObject, XMLParserDelegate {
  private var result: String?
  static func read(_ prefix: String) -> String? {
    let delegate = SVGViewport()
    let parser = XMLParser(data: Data(prefix.utf8))
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.result
  }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    defer { parser.abortParsing() }
    guard elementName.split(separator: ":").last == "svg" else { return }
    if let width = attributes["width"], let height = attributes["height"],
      !width.contains("%"), !height.contains("%"), width.count <= 24, height.count <= 24
    {
      result = width + " × " + height
    } else if let box = attributes["viewBox"] {
      let parts = box.split { $0.isWhitespace || $0 == "," }
      if parts.count == 4, parts.allSatisfy({ Double($0)?.isFinite == true && $0.count <= 24 }) {
        result = String(parts[2]) + " × " + String(parts[3])
      }
    }
  }
}

final class PreviewBitmap {
  let image: NSImage
  let mayHaveTransparency: Bool
  init(_ nsImage: NSImage) {
    image = nsImage
    mayHaveTransparency = false
  }
  init(_ cg: CGImage) {
    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    mayHaveTransparency = [.alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast]
      .contains(cg.alphaInfo)
  }
}

enum WorktablePreview {
  case image(CGImage), text(String), thumbnail

  static func read(_ file: Entry) -> WorktablePreview {
    if let image = PreviewReader.raster(file.url, pixels: 960) { return .image(image) }
    let type = UTType(filenameExtension: file.ext)
    if (type?.conforms(to: .text) == true || ["md", "log", "json", "yaml", "toml"].contains(file.ext)),
      let sample = try? PreviewReader.readText(file.url), !sample.text.isEmpty
    {
      return .text(String(sample.text.prefix(700)))
    }
    return .thumbnail
  }
}
