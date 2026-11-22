import AppKit

// Colors and text styles for ContentPreview. Every color is dynamic, so text
// built off the main thread follows the view's appearance when it draws.
enum ContentInk {
  static func pair(_ light: UInt32, _ dark: UInt32, _ lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat = 1)
    -> NSColor
  {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(rgb: dark).withAlphaComponent(darkAlpha)
        : NSColor(rgb: light).withAlphaComponent(lightAlpha)
    }
  }
  // Xcode's default theme, light and dark.
  static let keyword = pair(0x9B2393, 0xFC5FA3)
  static let string = pair(0xC41A16, 0xFC6A5D)
  static let number = pair(0x1C00CF, 0xD0BF69)
  static let comment = pair(0x5D6C79, 0x7F8C98)
  static let type = pair(0x3900A0, 0xD0A8FF)
  static let call = pair(0x326D74, 0x67B7A4)
  static let attribute = pair(0x643820, 0xFD8F3F)
  static let editor = pair(0xFFFFFF, 0x16161A, 0.72, 0.62)
  static let desk = pair(0x000000, 0x000000, 0.05, 0.28)
  static let fill = pair(0x000000, 0xFFFFFF, 0.045, 0.06)
  static let fill2 = pair(0x000000, 0xFFFFFF, 0.08, 0.10)
  static let card = pair(0x000000, 0xFFFFFF, 0.14, 0.12)
  // The find highlight stays yellow with dark ink in both appearances.
  static let found = NSColor.findHighlightColor
  static let foundInk = NSColor(rgb: 0x1D1D1F)
}

enum CodeLanguage: Equatable {
  case swift, rust, javascript, typescript, python, shell, toml, json, yaml, c, objc, cpp, go
  case markup, slashGeneric, hashGeneric

  static func forFile(_ url: URL) -> CodeLanguage? {
    let name = url.lastPathComponent.lowercased()
    switch name {
    case "makefile", "gnumakefile", "dockerfile", "containerfile", "podfile", "gemfile", "brewfile",
      "procfile", "vagrantfile", "rakefile", "justfile":
      return .hashGeneric
    case ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv", ".env",
      ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig":
      return .shell
    case "cargo.lock", "pipfile", "poetry.lock":
      return .toml
    default: break
    }
    return forExtension(url.pathExtension.lowercased())
  }

  static func forExtension(_ ext: String) -> CodeLanguage? {
    switch ext {
    case "swift": return .swift
    case "rs": return .rust
    case "js", "mjs", "cjs", "jsx": return .javascript
    case "ts", "tsx", "mts", "cts": return .typescript
    case "py", "pyw", "pyi": return .python
    case "sh", "bash", "zsh", "fish", "ksh", "command", "env": return .shell
    case "toml", "ini", "cfg", "conf", "properties", "lock": return .toml
    case "json", "jsonc", "json5", "jsonl", "ndjson", "geojson", "webmanifest": return .json
    case "yaml", "yml": return .yaml
    case "c", "h": return .c
    case "m": return .objc
    case "mm": return .objc
    case "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "metal": return .cpp
    case "go": return .go
    case "html", "htm", "xhtml", "xml", "plist", "xib", "storyboard", "xsd", "xsl", "rss", "atom",
      "vue", "svelte":
      return .markup
    case "java", "kt", "kts", "scala", "cs", "php", "css", "scss", "less", "dart", "zig", "proto",
      "gradle", "groovy", "graphql", "gql", "sql", "hlsl", "glsl", "wgsl", "sol", "v", "d":
      return .slashGeneric
    case "rb", "pl", "pm", "r", "cmake", "tf", "hcl", "nix", "ex", "exs", "jl", "tcl", "awk",
      "mk", "gitignore", "dockerignore", "diff", "patch", "log":
      return .hashGeneric
    default: return nil
    }
  }

  /// A Markdown fence's info string, such as ```swift.
  static func forFence(_ info: String) -> CodeLanguage? {
    let word = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first
      .map { $0.lowercased() } ?? ""
    switch word {
    case "": return nil
    case "rust": return .rust
    case "javascript", "node": return .javascript
    case "typescript": return .typescript
    case "python", "python3": return .python
    case "shell", "console", "shellsession", "terminal", "bash", "zsh", "sh": return .shell
    case "objective-c", "objectivec", "objc": return .objc
    case "c++", "cpp": return .cpp
    case "golang": return .go
    case "yml": return .yaml
    default: return forExtension(word)
    }
  }

  /// `#!/usr/bin/env python3` and friends, for files without an extension.
  static func forShebang(_ text: String) -> CodeLanguage? {
    guard text.hasPrefix("#!") else { return nil }
    let line = text.prefix { $0 != "\n" }
    if line.contains("python") { return .python }
    if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
    if line.contains("swift") { return .swift }
    if line.contains("ruby") || line.contains("perl") { return .hashGeneric }
    return .shell
  }

  var keywords: Set<String> {
    switch self {
    case .swift: return CodeLanguage.swiftWords
    case .rust: return CodeLanguage.rustWords
    case .javascript: return CodeLanguage.jsWords
    case .typescript: return CodeLanguage.jsWords.union(CodeLanguage.tsWords)
    case .python: return CodeLanguage.pythonWords
    case .shell: return CodeLanguage.shellWords
    case .toml: return ["true", "false"]
    case .json: return ["true", "false", "null"]
    case .yaml: return ["true", "false", "null", "yes", "no", "on", "off"]
    case .c: return CodeLanguage.cWords
    case .objc: return CodeLanguage.cWords.union(CodeLanguage.objcWords)
    case .cpp: return CodeLanguage.cWords.union(CodeLanguage.cppWords)
    case .go: return CodeLanguage.goWords
    case .markup: return []
    case .slashGeneric, .hashGeneric: return CodeLanguage.genericWords
    }
  }
  /// Data formats color keys, not types or calls.
  var isData: Bool { self == .json || self == .yaml || self == .toml }
  var hashComments: Bool {
    [.python, .shell, .toml, .yaml, .hashGeneric].contains(self)
  }
  var slashComments: Bool {
    [.swift, .rust, .javascript, .typescript, .c, .objc, .cpp, .go, .slashGeneric, .json].contains(
      self)
  }

  private static let swiftWords: Set<String> = Set(
    """
    associatedtype class deinit enum extension fileprivate func import init inout internal let open
    operator private precedencegroup protocol public rethrows static struct subscript typealias var
    break case catch continue default defer do else fallthrough for guard if in repeat return throw
    switch where while Any as await false is nil self Self super throws true try async some any
    final lazy weak unowned override mutating nonmutating convenience required dynamic indirect
    optional get set willSet didSet actor nonisolated isolated consume borrowing consuming package
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let rustWords: Set<String> = Set(
    """
    as async await break const continue crate dyn else enum extern false fn for if impl in let loop
    match mod move mut pub ref return self Self static struct super trait true type unsafe use where
    while yield union macro_rules
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let jsWords: Set<String> = Set(
    """
    async await break case catch class const continue debugger default delete do else export extends
    false finally for from function get if import in instanceof let new null of return set static
    super switch this throw true try typeof undefined var void while with yield
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let tsWords: Set<String> = Set(
    """
    abstract as declare enum implements interface keyof namespace private protected public readonly
    type any boolean number string never unknown satisfies infer is
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let pythonWords: Set<String> = Set(
    """
    and as assert async await break class continue def del elif else except False finally for from
    global if import in is lambda None nonlocal not or pass raise return True try while with yield
    match case self cls
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let shellWords: Set<String> = Set(
    """
    if then else elif fi for while until do done case esac in function return export local set unset
    readonly declare shift exit source alias trap break continue select time echo cd eval exec test
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let cWords: Set<String> = Set(
    """
    auto break case char const continue default do double else enum extern float for goto if inline
    int long register restrict return short signed sizeof static struct switch typedef union unsigned
    void volatile while _Bool bool true false NULL
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let objcWords: Set<String> = Set(
    """
    self super nil Nil YES NO id instancetype nullable nonnull _Nullable _Nonnull __block __weak
    __strong in out inout oneway interface implementation end property protocol class selector
    synthesize dynamic autoreleasepool optional required try catch finally throw import
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let cppWords: Set<String> = Set(
    """
    class namespace template typename public private protected virtual override final new delete
    this nullptr using operator friend explicit constexpr consteval noexcept static_cast
    dynamic_cast const_cast reinterpret_cast try catch throw decltype mutable concept requires co_await
    co_return co_yield auto
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let goWords: Set<String> = Set(
    """
    break case chan const continue default defer else fallthrough for func go goto if import interface
    map package range return select struct switch type var true false nil iota
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let genericWords: Set<String> = Set(
    """
    if else elif for foreach while do return break continue switch case default class struct enum
    interface func fun function fn def var val let const import package from export public private
    protected static final new this self super true false null nil None True False try catch finally
    throw throws raise end begin module require include in is not and or then unless until yield
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}

// MARK: - Highlighting

/// One pass over UTF-16 code units, in the spirit of the mockup's regular
/// expression: comments, strings, numbers, words, attributes, then anything else.
struct SyntaxHighlighter {
  enum Token { case keyword, string, number, comment, type, call, attribute }
  let language: CodeLanguage

  func tokens(_ text: String, cancelled: () -> Bool = { false }) -> [(NSRange, Token)] {
    let u = Array(text.utf16)
    if language == .markup { return markupTokens(u) }
    var out: [(NSRange, Token)] = []
    out.reserveCapacity(u.count / 6)
    let words = language.keywords
    let n = u.count
    var i = 0
    var lineStart = true  // only whitespace since the last newline
    func add(_ start: Int, _ end: Int, _ token: Token) {
      if end > start { out.append((NSRange(location: start, length: end - start), token)) }
    }
    func at(_ k: Int) -> UInt16 { k < n ? u[k] : 0 }
    func toLineEnd(_ k: Int) -> Int {
      var e = k
      while e < n, u[e] != 10 { e += 1 }
      return e
    }
    func nextNonSpace(_ k: Int) -> UInt16 {
      var e = k
      while e < n, u[e] == 32 || u[e] == 9 { e += 1 }
      return at(e)
    }
    /// Scans a quoted string starting at the quote, returning the index after it.
    func scanString(_ k: Int, quote: UInt16, escapes: Bool, multiline: Bool) -> Int {
      var e = k + 1
      while e < n {
        let c = u[e]
        if escapes && c == 92 { e += 2; continue }
        if c == quote { return e + 1 }
        if c == 10 && !multiline { return e }
        e += 1
      }
      return n
    }
    func scanTriple(_ k: Int, _ q: UInt16) -> Int {
      var e = k + 3
      while e < n {
        if u[e] == 92 { e += 2; continue }
        if u[e] == q && at(e + 1) == q && at(e + 2) == q { return e + 3 }
        e += 1
      }
      return n
    }
    func stringEnd(_ k: Int, _ q: UInt16) -> Int? {
      switch language {
      case .python, .toml:
        if (q == 34 || q == 39) && at(k + 1) == q && at(k + 2) == q { return scanTriple(k, q) }
        if q == 96 { return nil }
        return scanString(k, quote: q, escapes: !(language == .toml && q == 39), multiline: false)
      case .swift:
        if q == 34 && at(k + 1) == 34 && at(k + 2) == 34 { return scanTriple(k, 34) }
        return q == 34 ? scanString(k, quote: 34, escapes: true, multiline: false) : nil
      case .rust:
        if q == 34 { return scanString(k, quote: 34, escapes: true, multiline: true) }
        if q == 39 {
          // 'x' or '\n' is a character; 'a without a close is a lifetime.
          if at(k + 1) == 92 {
            var e = k + 2
            while e < n, e < k + 12, u[e] != 39, u[e] != 10 { e += 1 }
            return at(e) == 39 ? e + 1 : nil
          }
          if at(k + 2) == 39 && at(k + 1) != 10 { return k + 3 }
          // Astral characters are two code units.
          if at(k + 3) == 39 && at(k + 1) >= 0xD800 && at(k + 1) < 0xDC00 { return k + 4 }
          return nil
        }
        return nil
      case .javascript, .typescript:
        return scanString(k, quote: q, escapes: true, multiline: q == 96)
      case .go:
        if q == 96 { return scanString(k, quote: 96, escapes: false, multiline: true) }
        return scanString(k, quote: q, escapes: true, multiline: false)
      case .shell:
        if q == 39 { return scanString(k, quote: 39, escapes: false, multiline: true) }
        if q == 96 { return nil }
        return scanString(k, quote: 34, escapes: true, multiline: true)
      case .json:
        return q == 34 ? scanString(k, quote: 34, escapes: true, multiline: false) : nil
      case .yaml:
        if q == 96 { return nil }
        // An apostrophe inside a plain word is not a quote.
        if q == 39 && k > 0 && isIdent(u[k - 1]) { return nil }
        return scanString(k, quote: q, escapes: q == 34, multiline: false)
      case .c, .objc, .cpp:
        return q == 96 ? nil : scanString(k, quote: q, escapes: true, multiline: false)
      case .slashGeneric, .hashGeneric:
        if q == 39 && k > 0 && isIdent(u[k - 1]) { return nil }
        return scanString(k, quote: q, escapes: true, multiline: q == 96)
      case .markup:
        return nil
      }
    }
    var checks = 0
    while i < n {
      checks += 1
      if checks & 0xFFFF == 0, cancelled() { return [] }
      let c = u[i]
      if c == 10 {
        lineStart = true
        i += 1
        continue
      }
      if c == 32 || c == 9 || c == 13 {
        i += 1
        continue
      }
      let wasLineStart = lineStart
      lineStart = false
      let prev = i > 0 ? u[i - 1] : 10
      let prevSpace = prev == 32 || prev == 9 || prev == 10 || prev == 13
      // Comments
      if language.slashComments && c == 47 {
        if at(i + 1) == 47 {
          let e = toLineEnd(i)
          add(i, e, .comment)
          i = e
          continue
        }
        if at(i + 1) == 42 {
          let nests = language == .swift || language == .rust
          var depth = 1
          var e = i + 2
          while e < n, depth > 0 {
            if u[e] == 42 && at(e + 1) == 47 {
              depth -= 1
              e += 2
            } else if nests && u[e] == 47 && at(e + 1) == 42 {
              depth += 1
              e += 2
            } else {
              e += 1
            }
          }
          add(i, e, .comment)
          i = e
          continue
        }
      }
      if language.hashComments && c == 35 {
        // `$#` and `a#b` are not comments in shell or YAML.
        let strict = language == .shell || language == .yaml
        if !strict || prevSpace {
          let e = toLineEnd(i)
          add(i, e, .comment)
          i = e
          continue
        }
      }
      // Preprocessor, Swift directives and Rust attributes
      if c == 35 {
        if language == .rust && (at(i + 1) == 91 || (at(i + 1) == 33 && at(i + 2) == 91)) {
          var depth = 0
          var e = i + 1
          while e < n, u[e] != 10 {
            if u[e] == 91 { depth += 1 }
            if u[e] == 93 {
              depth -= 1
              if depth == 0 { e += 1; break }
            }
            e += 1
          }
          add(i, e, .attribute)
          i = e
          continue
        }
        if [.c, .objc, .cpp].contains(language) && wasLineStart {
          var e = i + 1
          while e < n, u[e] == 32 { e += 1 }
          while e < n, isIdent(u[e]) { e += 1 }
          add(i, e, .attribute)
          // #include <stdio.h>
          let after = e
          var k = after
          while k < n, u[k] == 32 { k += 1 }
          if at(k) == 60 {
            var close = k + 1
            while close < n, u[close] != 62, u[close] != 10 { close += 1 }
            if at(close) == 62 { add(k, close + 1, .string) }
            i = close < n ? close + 1 : n
          } else {
            i = after
          }
          continue
        }
        if language == .swift && isIdentStart(at(i + 1)) {
          var e = i + 1
          while e < n, isIdent(u[e]) { e += 1 }
          add(i, e, .attribute)
          i = e
          continue
        }
      }
      // @attributes, decorators and Objective-C @keywords
      if c == 64 {
        if language == .objc && at(i + 1) == 34 {
          let e = scanString(i + 1, quote: 34, escapes: true, multiline: false)
          add(i, e, .string)
          i = e
          continue
        }
        if isIdentStart(at(i + 1)) && !language.isData && language != .shell {
          var e = i + 1
          while e < n, isIdent(u[e]) { e += 1 }
          let word = String(utf16CodeUnits: Array(u[(i + 1)..<e]), count: e - i - 1)
          add(i, e, language == .objc && words.contains(word) ? .keyword : .attribute)
          i = e
          continue
        }
      }
      // Shell variables
      if language == .shell && c == 36 {
        var e = i + 1
        if at(e) == 123 {
          while e < n, u[e] != 125, u[e] != 10 { e += 1 }
          if at(e) == 125 { e += 1 }
        } else if isIdent(at(e)) {
          while e < n, isIdent(u[e]) { e += 1 }
        } else if [64, 42, 35, 63, 33, 36].contains(at(e)) {
          e += 1
        }
        if e > i + 1 {
          add(i, e, .attribute)
          i = e
          continue
        }
      }
      // TOML tables
      if language == .toml && c == 91 && wasLineStart {
        let e = toLineEnd(i)
        var close = i
        while close < e, u[close] != 93 { close += 1 }
        if close < e {
          close += 1
          if at(close) == 93 { close += 1 }
          add(i, close, .type)
          i = close
          continue
        }
      }
      // Strings
      if c == 34 || c == 39 || c == 96 {
        if let e = stringEnd(i, c) {
          var token = Token.string
          if language.isData && (language == .json || wasLineStart || prevIsListDash(u, i)) {
            let next = nextNonSpace(e)
            if next == 58 || (language == .toml && next == 61) { token = .call }
          }
          add(i, e, token)
          i = e
          continue
        }
        if language == .rust && c == 39 {
          // A lifetime, such as 'a or '_.
          var e = i + 1
          while e < n, isIdent(u[e]) { e += 1 }
          i = max(e, i + 1)
          continue
        }
      }
      // Numbers
      if isDigit(c) && !isIdent(prev) {
        var e = i + 1
        let hex = c == 48 && (at(i + 1) == 120 || at(i + 1) == 88)
        while e < n {
          let d = u[e]
          if isIdent(d) {
            e += 1
          } else if d == 46 && isDigit(at(e + 1)) && !(language == .yaml) {
            e += 1
          } else if (d == 43 || d == 45) && !hex && (u[e - 1] == 101 || u[e - 1] == 69) {
            e += 1
          } else {
            break
          }
        }
        add(i, e, .number)
        i = e
        continue
      }
      // Words
      if isIdentStart(c) {
        var e = i + 1
        while e < n, isIdent(u[e]) { e += 1 }
        let next = at(e)
        // Python's f"…", Rust's r"…" and r#"…"#
        if (next == 34 || next == 39) && e - i <= 2 {
          let prefix = String(utf16CodeUnits: Array(u[i..<e]), count: e - i).lowercased()
          if language == .python && ["f", "r", "b", "u", "rb", "br", "fr", "rf"].contains(prefix),
            let end = stringEnd(e, next)
          {
            add(i, end, .string)
            i = end
            continue
          }
          if language == .rust && (prefix == "r" || prefix == "b" || prefix == "br") && next == 34 {
            let end = scanString(e, quote: 34, escapes: prefix == "b", multiline: true)
            add(i, end, .string)
            i = end
            continue
          }
        }
        if language == .rust && e - i == 1 && u[i] == 114 && next == 35 && at(e + 1) == 34 {
          var hashes = 0
          var k = e
          while at(k) == 35 { hashes += 1; k += 1 }
          var end = k + 1
          search: while end < n {
            if u[end] == 34 {
              var h = 0
              while h < hashes && at(end + 1 + h) == 35 { h += 1 }
              if h == hashes { end += 1 + hashes; break search }
            }
            end += 1
          }
          add(i, min(end, n), .string)
          i = min(end, n)
          continue
        }
        let word = String(utf16CodeUnits: Array(u[i..<e]), count: e - i)
        if words.contains(word) {
          // A keyword used as a key, such as `type:` in YAML, stays a key.
          if language.isData && wasLineStart && (next == 58 || next == 61) {
            add(i, e, .call)
          } else {
            add(i, e, .keyword)
          }
        } else if language.isData {
          if (wasLineStart || prevIsListDash(u, i) || prevIsDotKey(u, i)) {
            let after = nextNonSpace(e)
            if (language == .yaml && after == 58) || (language == .toml && (after == 61 || after == 46)) {
              var end = e
              // Dotted and dashed keys
              while end < n, isIdent(u[end]) || u[end] == 45 || u[end] == 46 { end += 1 }
              add(i, end, .call)
              i = end
              continue
            }
          }
        } else if language == .rust && next == 33 && at(e + 1) != 61 {
          add(i, e + 1, .attribute)
          i = e + 1
          continue
        } else if language != .shell && isUpper(u[i]) {
          add(i, e, .type)
        } else if language != .shell && nextNonSpace(e) == 40 {
          add(i, e, .call)
        }
        i = e
        continue
      }
      i += 1
    }
    return out
  }

  /// HTML and XML: comments, tag names, attribute names and values.
  private func markupTokens(_ u: [UInt16]) -> [(NSRange, Token)] {
    var out: [(NSRange, Token)] = []
    let n = u.count
    var i = 0
    func at(_ k: Int) -> UInt16 { k < n ? u[k] : 0 }
    func add(_ s: Int, _ e: Int, _ t: Token) {
      if e > s { out.append((NSRange(location: s, length: e - s), t)) }
    }
    while i < n {
      if u[i] == 60 {
        // <!-- comment -->
        if at(i + 1) == 33 && at(i + 2) == 45 && at(i + 3) == 45 {
          var e = i + 4
          while e < n, !(u[e] == 45 && at(e + 1) == 45 && at(e + 2) == 62) { e += 1 }
          e = min(n, e + 3)
          add(i, e, .comment)
          i = e
          continue
        }
        var e = i + 1
        if at(e) == 47 || at(e) == 63 || at(e) == 33 { e += 1 }
        let nameStart = e
        while e < n, isIdent(u[e]) || u[e] == 58 || u[e] == 45 || u[e] == 46 { e += 1 }
        guard e > nameStart else {
          i += 1
          continue
        }
        add(nameStart, e, .keyword)
        // Attributes until the tag closes.
        while e < n, u[e] != 62 {
          let c = u[e]
          if c == 34 || c == 39 {
            var k = e + 1
            while k < n, u[k] != c { k += 1 }
            k = min(n, k + 1)
            add(e, k, .string)
            e = k
          } else if isIdentStart(c) {
            var k = e + 1
            while k < n, isIdent(u[k]) || u[k] == 58 || u[k] == 45 || u[k] == 46 { k += 1 }
            add(e, k, .attribute)
            e = k
          } else {
            e += 1
          }
        }
        i = e + 1
        continue
      }
      if u[i] == 38 {
        // &amp; and friends
        var e = i + 1
        while e < n, e < i + 10, isIdent(u[e]) || u[e] == 35 { e += 1 }
        if at(e) == 59 {
          add(i, e + 1, .number)
          i = e + 1
          continue
        }
      }
      i += 1
    }
    return out
  }

  /// Builds the colored code text with the editor's paragraph style.
  static func attributed(
    _ text: String, language: CodeLanguage?, font: NSFont, cancelled: () -> Bool = { false }
  ) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: codeParagraph(font),
      ])
    guard let language else { return result }
    let semibold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
    result.beginEditing()
    for (range, token) in SyntaxHighlighter(language: language).tokens(text, cancelled: cancelled) {
      switch token {
      case .keyword:
        result.addAttributes([.foregroundColor: ContentInk.keyword, .font: semibold], range: range)
      case .string: result.addAttribute(.foregroundColor, value: ContentInk.string, range: range)
      case .number: result.addAttribute(.foregroundColor, value: ContentInk.number, range: range)
      case .comment: result.addAttribute(.foregroundColor, value: ContentInk.comment, range: range)
      case .type: result.addAttribute(.foregroundColor, value: ContentInk.type, range: range)
      case .call: result.addAttribute(.foregroundColor, value: ContentInk.call, range: range)
      case .attribute:
        result.addAttribute(.foregroundColor, value: ContentInk.attribute, range: range)
      }
    }
    result.endEditing()
    return result
  }

  /// Wrapped lines hang under their own indentation, one step further in.
  static func hangIndents(_ text: NSMutableAttributedString, font: NSFont) {
    let base = codeParagraph(font)
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    var styles: [Int: NSParagraphStyle] = [:]
    let ns = text.string as NSString
    let length = ns.length
    var start = 0
    while start < length {
      var columns = 0
      var k = start
      while k < length {
        let c = ns.character(at: k)
        if c == 32 { columns += 1 } else if c == 9 { columns += 4 - columns % 4 } else { break }
        k += 1
      }
      var end = k
      while end < length, ns.character(at: end) != 10 { end += 1 }
      if end < length { end += 1 }
      let indent = min(columns, 40) + 4
      let style =
        styles[indent]
        ?? {
          let p = base.mutableCopy() as! NSMutableParagraphStyle
          p.headIndent = CGFloat(indent) * space
          styles[indent] = p
          return p
        }()
      text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: end - start))
      start = end
    }
  }

  static func codeParagraph(_ font: NSFont) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    // 1.6 line height, as in the mockup.
    let natural = ceil(font.ascender - font.descender + font.leading)
    style.lineSpacing = max(0, round(font.pointSize * 1.6 - natural))
    style.lineBreakMode = .byWordWrapping
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    style.tabStops = []
    style.defaultTabInterval = space * 4
    return style
  }
}

@inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
@inline(__always) private func isIdentStart(_ c: UInt16) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (c >= 0xC0 && c < 0xD800)
}
@inline(__always) private func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
/// `- key: value` in YAML lists.
private func prevIsListDash(_ u: [UInt16], _ i: Int) -> Bool {
  var k = i - 1
  while k >= 0, u[k] == 32 { k -= 1 }
  guard k >= 0, u[k] == 45 else { return false }
  k -= 1
  while k >= 0, u[k] == 32 || u[k] == 9 { k -= 1 }
  return k < 0 || u[k] == 10
}
/// The second part of a dotted TOML key, such as `b` in `a.b = 1`.
private func prevIsDotKey(_ u: [UInt16], _ i: Int) -> Bool { i > 0 && u[i - 1] == 46 }

// MARK: - Markdown

/// Just enough Markdown for notes and READMEs: headings, paragraphs, lists,
/// quotes, emphasis, inline code, links and fenced blocks.
enum MarkdownRenderer {
  static func render(_ source: String, cancelled: () -> Bool = { false }) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    let body = NSFont.systemFont(ofSize: 13)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var lines = source.components(separatedBy: "\n").map {
      $0.hasSuffix("\r") ? String($0.dropLast()) : $0
    }
    var paragraph: [String] = []
    var fence: (marker: String, language: CodeLanguage?, lines: [String])?
    var lastWasList = false

    func style(
      before: CGFloat = 0, after: CGFloat = 10, indent: CGFloat = 0, head: CGFloat? = nil,
      spacing: CGFloat = 4.5
    ) -> NSMutableParagraphStyle {
      let p = NSMutableParagraphStyle()
      p.paragraphSpacingBefore = before
      p.paragraphSpacing = after
      p.firstLineHeadIndent = indent
      p.headIndent = head ?? indent
      p.lineSpacing = spacing
      p.lineBreakMode = .byWordWrapping
      return p
    }
    func newline() {
      if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
    }
    func flushParagraph() {
      guard !paragraph.isEmpty else { return }
      newline()
      // Two trailing spaces or a backslash end a line inside a paragraph.
      var text = ""
      for (index, line) in paragraph.enumerated() {
        let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("\\") { trimmed.removeLast() }
        text += trimmed
        if index < paragraph.count - 1 { text += hard ? "\u{2028}" : " " }
      }
      out.append(inline(text, font: body, paragraph: style()))
      paragraph = []
      lastWasList = false
    }
    func flushFence() {
      guard let f = fence else { return }
      newline()
      let block = MarkdownCodeBlock()
      // Lines inside the block sit close; the space comes after the last one.
      let inner = style(after: 0, spacing: round(12 * 1.5) - 15)
      inner.textBlocks = [block]
      let last = inner.mutableCopy() as! NSMutableParagraphStyle
      last.paragraphSpacing = 10
      let code = f.lines.joined(separator: "\n")
      let text = SyntaxHighlighter.attributed(code, language: f.language, font: codeFont)
      // An empty block still needs one line to draw.
      if text.length == 0 {
        text.append(NSAttributedString(string: " ", attributes: [.font: codeFont]))
      }
      let whole = NSRange(location: 0, length: text.length)
      text.addAttribute(.paragraphStyle, value: inner, range: whole)
      let ns = text.string as NSString
      text.addAttribute(
        .paragraphStyle, value: last, range: ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0)))
      out.append(text)
      fence = nil
      lastWasList = false
    }

    func heading(_ level: Int, _ text: String) {
      newline()
      let size: CGFloat = level == 1 ? 20 : level == 2 ? 15 : 13
      let font = NSFont.systemFont(ofSize: size, weight: .semibold)
      let before: CGFloat = out.length == 0 ? 0 : level == 1 ? 14 : level == 2 ? 12 : 8
      let p = style(before: before, after: level == 1 ? 8 : level == 2 ? 6 : 4, spacing: 2)
      if level == 1 { p.lineHeightMultiple = 1.05 }
      let title = inline(text, font: font, paragraph: p)
      if level == 1 {
        title.addAttribute(.kern, value: -0.2, range: NSRange(location: 0, length: title.length))
      }
      out.append(title)
      lastWasList = false
    }

    // YAML front matter shows as a block, not as a heading and rules.
    if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
      fence = ("---", .yaml, Array(lines[1..<close]))
      flushFence()
      lines.removeSubrange(0...close)
    }

    var index = 0
    while index < lines.count {
      if index & 1023 == 0, cancelled() { return NSMutableAttributedString() }
      let line = lines[index]
      index += 1
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var f = fence {
        if trimmed.hasPrefix(f.marker) && trimmed.allSatisfy({ String($0) == String(f.marker.first!) }) {
          flushFence()
        } else {
          f.lines.append(line)
          fence = f
        }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flushParagraph()
        let marker = String(trimmed.prefix { $0 == trimmed.first })
        let info = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        fence = (marker, CodeLanguage.forFence(info), [])
        continue
      }
      if trimmed.isEmpty {
        flushParagraph()
        continue
      }
      // Setext headings: a paragraph line underlined with === or ---.
      if !paragraph.isEmpty, paragraph.count == 1, !trimmed.isEmpty,
        trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2)
      {
        let text = paragraph[0].trimmingCharacters(in: .whitespaces)
        paragraph = []
        heading(trimmed.first == "=" ? 1 : 2, text)
        continue
      }
      if let level = headingLevel(trimmed) {
        flushParagraph()
        var text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        heading(level, text.trimmingCharacters(in: .whitespaces))
        continue
      }
      if isRule(trimmed) {
        flushParagraph()
        newline()
        let block = MarkdownRule()
        let p = style(before: 4, after: 14, spacing: 0)
        p.textBlocks = [block]
        out.append(
          NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: p]))
        lastWasList = false
        continue
      }
      if let item = listItem(line) {
        flushParagraph()
        newline()
        let indent = 18 * CGFloat(item.level)
        let marker = item.marker
        let markerWidth = (marker as NSString).size(withAttributes: [.font: body]).width
        let p = style(after: 3, indent: indent + max(0, 12 - markerWidth), head: indent + 18)
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
        if !lastWasList { p.paragraphSpacingBefore = 0 }
        let text = NSMutableAttributedString(
          string: marker + "\t",
          attributes: [
            .font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
          ])
        // Continuation lines belong to the item.
        var content = item.text
        while index < lines.count {
          let next = lines[index]
          let t = next.trimmingCharacters(in: .whitespaces)
          if t.isEmpty || listItem(next) != nil || headingLevel(t) != nil || t.hasPrefix("```")
            || t.hasPrefix(">") || isRule(t)
          {
            break
          }
          guard next.first == " " || next.first == "\t" else { break }
          content += " " + t
          index += 1
        }
        text.append(inline(content, font: body, paragraph: p))
        out.append(text)
        lastWasList = true
        // Space after the last item of a list.
        let following = index < lines.count ? lines[index] : ""
        if listItem(following) == nil { p.paragraphSpacing = 10 }
        continue
      }
      if trimmed.hasPrefix(">") {
        flushParagraph()
        var quote: [String] = []
        var k = index - 1
        while k < lines.count {
          let t = lines[k].trimmingCharacters(in: .whitespaces)
          guard t.hasPrefix(">") else { break }
          quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
          k += 1
        }
        index = k
        newline()
        let block = MarkdownQuote()
        let p = style(after: 10)
        p.textBlocks = [block]
        let text = inline(
          quote.joined(separator: " "), font: body, paragraph: p, color: .secondaryLabelColor)
        out.append(text)
        lastWasList = false
        continue
      }
      // Tables keep their rows as written, in the code font.
      if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
        flushParagraph()
        var rows: [String] = []
        var k = index - 1
        while k < lines.count {
          let t = lines[k].trimmingCharacters(in: .whitespaces)
          guard t.hasPrefix("|") else { break }
          rows.append(t)
          k += 1
        }
        index = k
        fence = ("```", nil, rows)
        flushFence()
        continue
      }
      paragraph.append(line)
    }
    if fence != nil { flushFence() }
    flushParagraph()
    return out
  }

  private static func headingLevel(_ t: String) -> Int? {
    var level = 0
    for c in t {
      if c == "#" { level += 1 } else { break }
    }
    guard (1...6).contains(level) else { return nil }
    let rest = t.dropFirst(level)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return min(level, 3)
  }
  private static func isRule(_ t: String) -> Bool {
    let chars = t.filter { $0 != " " }
    guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
    return chars.allSatisfy { $0 == first }
  }
  private static func listItem(_ line: String) -> (level: Int, marker: String, text: String)? {
    var spaces = 0
    var rest = Substring(line)
    while let c = rest.first, c == " " || c == "\t" {
      spaces += c == "\t" ? 4 : 1
      rest = rest.dropFirst()
    }
    let level = min(spaces / 2, 6)
    if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " {
      var text = String(rest.dropFirst(2))
      var marker = level % 2 == 0 ? "•" : "◦"
      if text.hasPrefix("[ ] ") {
        marker = "☐"
        text = String(text.dropFirst(4))
      } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
        marker = "☑"
        text = String(text.dropFirst(4))
      }
      return (level, marker, text)
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    if !digits.isEmpty, digits.count <= 9 {
      let after = rest.dropFirst(digits.count)
      if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
        return (level, digits + ".", String(after.dropFirst(2)))
      }
    }
    return nil
  }

  /// Bold, italics, inline code, links and images within one block.
  static func inline(
    _ text: String, font: NSFont, paragraph: NSParagraphStyle, color: NSColor = .labelColor
  ) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ]
    let chars = Array(text)
    var plain = ""
    var bold = false
    var italic = false
    var i = 0
    func currentFont() -> NSFont {
      var f = font
      if bold {
        f = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
      }
      if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
      return f
    }
    func flush() {
      guard !plain.isEmpty else { return }
      var attrs = base
      attrs[.font] = currentFont()
      out.append(NSAttributedString(string: plain, attributes: attrs))
      plain = ""
    }
    func find(_ s: [Character], from: Int) -> Int? {
      guard !s.isEmpty, from < chars.count else { return nil }
      var k = from
      while k + s.count <= chars.count {
        if Array(chars[k..<(k + s.count)]) == s { return k }
        k += 1
      }
      return nil
    }
    while i < chars.count {
      let c = chars[i]
      if c == "\\", i + 1 < chars.count, "\\`*_[]()#+-.!<>".contains(chars[i + 1]) {
        plain.append(chars[i + 1])
        i += 2
        continue
      }
      if c == "`" {
        var ticks = 0
        while i + ticks < chars.count, chars[i + ticks] == "`" { ticks += 1 }
        if let close = find(Array(repeating: "`", count: ticks), from: i + ticks) {
          flush()
          let code = String(chars[(i + ticks)..<close]).trimmingCharacters(in: .whitespaces)
          var attrs = base
          attrs[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
          attrs[.backgroundColor] = ContentInk.fill2
          // Thin spaces give the code a little room inside its background.
          out.append(NSAttributedString(string: "\u{2009}" + code + "\u{2009}", attributes: attrs))
          i = close + ticks
          continue
        }
      }
      if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] == c {
        let opening = !bold
        let nextChar = i + 2 < chars.count ? chars[i + 2] : " "
        if !opening || (!nextChar.isWhitespace && find([c, c], from: i + 2) != nil) {
          flush()
          bold.toggle()
          i += 2
          continue
        }
      }
      if c == "*" || (c == "_" && (i == 0 || !chars[i - 1].isLetter)) || (c == "_" && italic) {
        let nextChar = i + 1 < chars.count ? chars[i + 1] : " "
        if italic || (!nextChar.isWhitespace && find([c], from: i + 1) != nil) {
          flush()
          italic.toggle()
          i += 1
          continue
        }
      }
      if c == "!" || c == "[" {
        let start = c == "!" ? i + 1 : i
        if start < chars.count, chars[start] == "[", let close = find(["]"], from: start + 1),
          close + 1 < chars.count, chars[close + 1] == "(", let end = find([")"], from: close + 2)
        {
          flush()
          let label = String(chars[(start + 1)..<close])
          let image = c == "!"
          var attrs = base
          attrs[.foregroundColor] = image ? NSColor.secondaryLabelColor : NSColor.linkColor
          attrs[.font] = currentFont()
          out.append(
            NSAttributedString(string: image ? "[\(label)]" : label, attributes: attrs))
          i = end + 1
          continue
        }
      }
      if c == "<", let close = find([">"], from: i + 1), close - i < 200 {
        let inner = String(chars[(i + 1)..<close])
        if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
          flush()
          var attrs = base
          attrs[.foregroundColor] = NSColor.linkColor
          out.append(NSAttributedString(string: inner, attributes: attrs))
          i = close + 1
          continue
        }
      }
      plain.append(c)
      i += 1
    }
    flush()
    return out
  }
}

/// A fenced block: a rounded fill behind the code, the width of the text.
final class MarkdownCodeBlock: NSTextBlock {
  override init() {
    super.init()
    setValue(100, type: .percentageValueType, for: .width)
    setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
    setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
    setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
    setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange,
    layoutManager: NSLayoutManager
  ) {
    ContentInk.fill.setFill()
    NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
  }
}

/// A block quote: a bar on the leading edge.
final class MarkdownQuote: NSTextBlock {
  override init() {
    super.init()
    setValue(100, type: .percentageValueType, for: .width)
    setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange,
    layoutManager: NSLayoutManager
  ) {
    NSColor.tertiaryLabelColor.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: frameRect.minX, y: frameRect.minY + 1, width: 3, height: frameRect.height - 2),
      xRadius: 1.5, yRadius: 1.5
    ).fill()
  }
}

/// A thematic break.
final class MarkdownRule: NSTextBlock {
  override init() {
    super.init()
    setValue(100, type: .percentageValueType, for: .width)
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange,
    layoutManager: NSLayoutManager
  ) {
    NSColor.separatorColor.setFill()
    NSRect(x: frameRect.minX, y: frameRect.midY, width: frameRect.width, height: 1).fill()
  }
}
