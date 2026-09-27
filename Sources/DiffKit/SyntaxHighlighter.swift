import Foundation
import SwiftUI

// We deliberately ship no highlighting dependency: HighlightSwift uses the #Preview macro and
// will not build outside Xcode, and booting a JavaScriptCore runtime to colour a diff is absurd.

// MARK: - Languages

public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, objc, c, cpp, javascript, typescript, python, ruby, go, rust, java, kotlin
    case php, csharp, shell, sql, html, css, json, yaml, toml, markdown, dockerfile, plaintext

    public var displayName: String {
        switch self {
        case .objc: return "Objective-C"
        case .cpp: return "C++"
        case .csharp: return "C#"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        default: return rawValue.capitalized
        }
    }

    /// Extension first, then well-known bare filenames.
    /// `firstLine` is the file's line 1, when the caller can supply it. It is consulted only
    /// after the path has failed, which is exactly the case it exists for: `bin/deploy` and
    /// friends carry their language in a shebang and nowhere else.
    public static func detect(path: String, firstLine: String? = nil) -> CodeLanguage {
        let file = String(path.split(separator: "/").last ?? "")
        let lower = file.lowercased()

        if let named = byFilename[lower] { return named }
        // Dockerfile.dev, Dockerfile.ci — the variant suffix is a tag, not an extension.
        if lower.hasPrefix("dockerfile.") { return .dockerfile }
        // Dotfiles like .zshrc / .bash_profile have no extension worth reading.
        if lower.hasPrefix(".") && !lower.dropFirst().contains(".") {
            return byFilename[String(lower.dropFirst())] ?? .shell
        }
        if let ext = lower.split(separator: ".").last, lower.contains("."),
           let known = byExtension[String(ext)] {
            return known
        }
        return firstLine.flatMap(byShebang) ?? .plaintext
    }

    /// Reduces `#!/usr/bin/env -S python3 -u` and `#!/usr/local/bin/python3.11` alike to the
    /// interpreter name. Walks the words because `env` and its flags sit in front of the real one.
    static func byShebang(_ line: String) -> CodeLanguage? {
        guard line.hasPrefix("#!") else { return nil }
        for word in line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let name = String(word.split(separator: "/").last ?? "").lowercased()
            if name == "env" || name.hasPrefix("-") { continue }
            // Trailing version digits are noise: python3, python3.11, ruby2.7 are all the language.
            if let lang = byInterpreter[String(name.prefix { $0.isLetter })] { return lang }
        }
        return nil
    }

    private static let byInterpreter: [String: CodeLanguage] = [
        "sh": .shell, "bash": .shell, "zsh": .shell, "dash": .shell, "ksh": .shell, "fish": .shell,
        "python": .python,
        "ruby": .ruby,
        "node": .javascript, "deno": .typescript, "bun": .typescript,
        "php": .php,
        "swift": .swift,
    ]

    private static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "m": .objc, "mm": .objc,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript,
        "py": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "php": .php,
        "cs": .csharp,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ksh": .shell,
        "sql": .sql,
        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html,
        "xml": .html, "plist": .html, "svg": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "json": .json, "jsonc": .json, "json5": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
    ]

    private static let byFilename: [String: CodeLanguage] = [
        "dockerfile": .dockerfile, "containerfile": .dockerfile,
        "makefile": .shell, "gnumakefile": .shell,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby, "brewfile": .ruby,
        "vagrantfile": .ruby, "berksfile": .ruby, "guardfile": .ruby, "capfile": .ruby,
        "thorfile": .ruby, "appfile": .ruby, "matchfile": .ruby, "deliverfile": .ruby,
        "env": .shell, "env.example": .shell, "env.sample": .shell,
        "package.swift": .swift,
        "zshrc": .shell, "bashrc": .shell, "bash_profile": .shell, "zprofile": .shell,
        "profile": .shell, "zshenv": .shell, "inputrc": .shell, "envrc": .shell,
        "gitconfig": .toml, "gitignore": .shell, "gitattributes": .shell,
        "cargo.toml": .toml, "cargo.lock": .toml, "pyproject.toml": .toml,
        "go.mod": .go, "go.sum": .go,
        "readme": .markdown, "license": .plaintext,
    ]
}

public enum TokenKind: Hashable, Sendable {
    case keyword, type, string, number, comment, attribute, function, plain
}

/// Carried across lines. Highlighting runs one line at a time (a diff renders lines, not files),
/// so block comments and multi-line strings can only survive if the caller threads this through —
/// that is the entire reason `tokenize` takes it `inout`.
public struct HighlightState: Hashable, Sendable {
    /// > 0 while inside a block comment. An Int, not a Bool, because Swift nests them.
    public var blockCommentDepth: Int = 0
    /// Closing delimiter of the multi-line string we are inside; empty when not in one.
    public var stringTerminator: String = ""
    /// Multi-line raw strings ignore backslash escapes.
    public var stringEscapes: Bool = true

    public init() {}
    public var isClean: Bool { blockCommentDepth == 0 && stringTerminator.isEmpty }
}

// MARK: - Theme

public struct HighlightTheme: Hashable {
    public var keyword: Color
    public var type: Color
    public var string: Color
    public var number: Color
    public var comment: Color
    public var attribute: Color
    public var function: Color
    public var plain: Color

    public init(keyword: Color, type: Color, string: Color, number: Color,
                comment: Color, attribute: Color, function: Color, plain: Color) {
        self.keyword = keyword
        self.type = type
        self.string = string
        self.number = number
        self.comment = comment
        self.attribute = attribute
        self.function = function
        self.plain = plain
    }

    /// System palette only — every colour here is dynamic, so it stays legible in both appearances.
    public static let system = HighlightTheme(
        keyword: .pink, type: .teal, string: .red, number: .indigo,
        comment: .green, attribute: .purple, function: .blue, plain: .primary)

    public func color(for kind: TokenKind) -> Color {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .attribute: return attribute
        case .function: return function
        case .plain: return plain
        }
    }
}

// MARK: - Highlighter

public enum SyntaxHighlighter {

    /// Past this a "line" is minified output or embedded data; scanning it per keystroke of
    /// scroll is not worth it. Upgrade path: highlight the visible prefix only.
    public static let maxLineLength = 2_000
    /// Whole-file ceiling. Callers ask before highlighting anything.
    public static let maxFileLines = 20_000

    public static func shouldHighlight(fileLineCount: Int) -> Bool { fileLineCount <= maxFileLines }

    // MARK: Public entry points

    public static func tokenize(_ line: String, language: CodeLanguage,
                                state: inout HighlightState) -> [(Range<String.Index>, TokenKind)] {
        guard language != .plaintext, line.count <= maxLineLength else { return [] }

        let key = "\(language.rawValue)\u{1}\(state.blockCommentDepth)\u{1}\(state.stringTerminator)\u{1}\(state.stringEscapes ? 1 : 0)\u{1}\(line)" as NSString
        let result: TokenBox
        if let hit = cache.object(forKey: key) {
            result = hit
        } else {
            var working = state
            let spans = scan(Array(line), spec: spec(for: language), state: &working)
            result = TokenBox(spans: spans, endState: working)
            cache.setObject(result, forKey: key)
        }
        state = result.endState

        var out: [(Range<String.Index>, TokenKind)] = []
        out.reserveCapacity(result.spans.count)
        var index = line.startIndex
        var offset = 0
        for span in result.spans {
            index = line.index(index, offsetBy: span.start - offset)
            let upper = line.index(index, offsetBy: span.length)
            out.append((index..<upper, span.kind))
            offset = span.start
        }
        return out
    }

    public static func attributed(_ line: String, language: CodeLanguage,
                                  state: inout HighlightState,
                                  theme: HighlightTheme = .system) -> AttributedString {
        let tokens = tokenize(line, language: language, state: &state)
        guard !tokens.isEmpty else {
            var plain = AttributedString(line)
            plain.foregroundColor = theme.plain
            return plain
        }
        var out = AttributedString()
        var cursor = line.startIndex
        for (range, kind) in tokens {
            if cursor < range.lowerBound {
                var gap = AttributedString(String(line[cursor..<range.lowerBound]))
                gap.foregroundColor = theme.plain
                out.append(gap)
            }
            var piece = AttributedString(String(line[range]))
            piece.foregroundColor = theme.color(for: kind)
            out.append(piece)
            cursor = range.upperBound
        }
        if cursor < line.endIndex {
            var tail = AttributedString(String(line[cursor...]))
            tail.foregroundColor = theme.plain
            out.append(tail)
        }
        return out
    }

    // MARK: Memoisation

    struct Span: Sendable { var start: Int; var length: Int; var kind: TokenKind }

    final class TokenBox {
        let spans: [Span]
        let endState: HighlightState
        init(spans: [Span], endState: HighlightState) {
            self.spans = spans
            self.endState = endState
        }
    }

    /// Diff views re-tokenise the same lines on every scroll and every re-render. NSCache is
    /// thread-safe and evicts under memory pressure, which is all we need.
    private static let cache: NSCache<NSString, TokenBox> = {
        let c = NSCache<NSString, TokenBox>()
        c.countLimit = 8_000
        return c
    }()

    public static func clearCache() { cache.removeAllObjects() }

    // MARK: Scanner

    private static func scan(_ chars: [Character], spec: LanguageSpec,
                             state: inout HighlightState) -> [Span] {
        var out: [Span] = []
        let n = chars.count
        var i = 0

        func matches(_ s: [Character], at index: Int) -> Bool {
            guard !s.isEmpty, index + s.count <= n else { return false }
            for (k, c) in s.enumerated() where chars[index + k] != c { return false }
            return true
        }

        // Continuation of a block comment opened on an earlier line.
        if state.blockCommentDepth > 0, let block = spec.blockComment {
            let open = Array(block.open), close = Array(block.close)
            while i < n {
                if matches(close, at: i) {
                    i += close.count
                    state.blockCommentDepth -= 1
                    if state.blockCommentDepth == 0 { break }
                } else if spec.nestedBlockComments, matches(open, at: i) {
                    i += open.count
                    state.blockCommentDepth += 1
                } else {
                    i += 1
                }
            }
            out.append(Span(start: 0, length: i, kind: .comment))
        }

        // Continuation of a multi-line string.
        if !state.stringTerminator.isEmpty {
            let term = Array(state.stringTerminator)
            let start = i
            var closed = false
            while i < n {
                if state.stringEscapes, chars[i] == "\\" { i += 2; continue }
                if matches(term, at: i) { i += term.count; closed = true; break }
                i += 1
            }
            if i > n { i = n }
            out.append(Span(start: start, length: i - start, kind: .string))
            if closed { state.stringTerminator = ""; state.stringEscapes = true }
        }

        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            // Line comment — checked before everything else so `#` and `//` win over operators.
            if spec.lineComments.contains(where: { matches(Array($0), at: i) }) {
                out.append(Span(start: i, length: n - i, kind: .comment))
                i = n
                break
            }

            // Block comment.
            if let block = spec.blockComment, matches(Array(block.open), at: i) {
                let open = Array(block.open), close = Array(block.close)
                let start = i
                i += open.count
                state.blockCommentDepth = 1
                while i < n {
                    if matches(close, at: i) {
                        i += close.count
                        state.blockCommentDepth -= 1
                        if state.blockCommentDepth == 0 { break }
                    } else if spec.nestedBlockComments, matches(open, at: i) {
                        i += open.count
                        state.blockCommentDepth += 1
                    } else {
                        i += 1
                    }
                }
                out.append(Span(start: start, length: min(i, n) - start, kind: .comment))
                continue
            }

            // Swift-style raw strings: any run of '#' then a quote; the same hashes close it.
            if spec.hashRawStrings, c == "#" {
                var hashes = 0
                while i + hashes < n, chars[i + hashes] == "#" { hashes += 1 }
                let after = i + hashes
                if after < n, chars[after] == "\"" {
                    let hashSuffix = String(repeating: "#", count: hashes)
                    let isTriple = after + 2 < n && chars[after + 1] == "\"" && chars[after + 2] == "\""
                    let opener = isTriple ? 3 : 1
                    let term = (isTriple ? "\"\"\"" : "\"") + hashSuffix
                    i = consumeString(chars, from: i, openLength: hashes + opener, terminator: term,
                                      escapes: false, multiline: isTriple, out: &out, state: &state,
                                      matches: matches)
                    continue
                }
            }

            // Multi-line string openers (""" ''' and JS template literals) before single quotes.
            if let ml = spec.multilineDelimiters.first(where: { matches(Array($0), at: i) }) {
                i = consumeString(chars, from: i, openLength: ml.count, terminator: ml,
                                  escapes: spec.escapesInStrings, multiline: true,
                                  out: &out, state: &state, matches: matches)
                continue
            }

            // Identifiers, and the r"" / f"" / b"" string prefixes that look like one.
            if c.isLetter || spec.identifierExtras.contains(c) {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || spec.identifierExtras.contains(chars[j]) {
                    j += 1
                }
                let word = String(chars[i..<j])
                if j < n, spec.stringPrefixes.contains(word.lowercased()) {
                    if let ml = spec.multilineDelimiters.first(where: { matches(Array($0), at: j) }) {
                        i = consumeString(chars, from: i, openLength: word.count + ml.count,
                                          terminator: ml, escapes: false, multiline: true,
                                          out: &out, state: &state, matches: matches)
                        continue
                    }
                    if spec.stringDelimiters.contains(chars[j]) {
                        i = consumeString(chars, from: i, openLength: word.count + 1,
                                          terminator: String(chars[j]), escapes: false,
                                          multiline: false, out: &out, state: &state, matches: matches)
                        continue
                    }
                }
                out.append(Span(start: i, length: j - i, kind: classify(word, spec: spec, chars: chars, after: j, n: n)))
                i = j
                continue
            }

            // Strings.
            if spec.stringDelimiters.contains(c) {
                i = consumeString(chars, from: i, openLength: 1, terminator: String(c),
                                  escapes: spec.escapesInStrings, multiline: false,
                                  out: &out, state: &state, matches: matches)
                continue
            }

            // Numbers, including 0x/0b/0o forms and underscore separators.
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber) {
                var j = i
                while j < n {
                    let d = chars[j]
                    // isNumber must be included: the branch is entered on c.isNumber, and
                    // characters like ½, ², ①, ٣ are numbers but neither hex digits nor letters.
                    // Without it the scan makes no progress and the outer loop spins forever.
                    if d.isNumber || d.isHexDigit || d.isLetter || d == "_" || d == "." {
                        // an exponent sign is part of the literal, a following '-' otherwise is not
                        if (d == "e" || d == "E" || d == "p" || d == "P"), j + 1 < n,
                           chars[j + 1] == "+" || chars[j + 1] == "-" {
                            j += 2
                            continue
                        }
                        j += 1
                    } else {
                        break
                    }
                }
                out.append(Span(start: i, length: j - i, kind: .number))
                i = j
                continue
            }

            // Attributes / annotations: @objc, #[derive(…)], [Serializable].
            if spec.attributeLeaders.contains(c), i + 1 < n {
                let next = chars[i + 1]
                // Rust puts the bracket after the leader (#[…]); C# the leader *is* the bracket.
                if next == "[" || c == "[" {
                    var j = c == "[" ? i + 1 : i + 2
                    var depth = 1
                    while j < n, depth > 0 {
                        if chars[j] == "[" { depth += 1 }
                        if chars[j] == "]" { depth -= 1 }
                        j += 1
                    }
                    out.append(Span(start: i, length: j - i, kind: .attribute))
                    i = j
                    continue
                }
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                    out.append(Span(start: i, length: j - i, kind: .attribute))
                    i = j
                    continue
                }
            }

            i += 1
        }
        return out
    }

    /// Emits one string span and, when a multi-line opener is left unterminated, parks the
    /// closing delimiter in the carried state.
    private static func consumeString(_ chars: [Character], from start: Int, openLength: Int,
                                      terminator: String, escapes: Bool, multiline: Bool,
                                      out: inout [Span], state: inout HighlightState,
                                      matches: ([Character], Int) -> Bool) -> Int {
        let n = chars.count
        let term = Array(terminator)
        var i = start + openLength
        var closed = false
        while i < n {
            if escapes, chars[i] == "\\" { i += 2; continue }
            if matches(term, i) { i += term.count; closed = true; break }
            i += 1
        }
        if i > n { i = n }
        out.append(Span(start: start, length: i - start, kind: .string))
        if !closed && multiline {
            state.stringTerminator = terminator
            state.stringEscapes = escapes
        }
        return i
    }

    private static func classify(_ word: String, spec: LanguageSpec,
                                 chars: [Character], after: Int, n: Int) -> TokenKind {
        if spec.keywords.contains(word) { return .keyword }
        if spec.types.contains(word) { return .type }
        // cheap heuristics: identifier( is a call, Capitalized is a type
        var k = after
        while k < n, chars[k] == " " { k += 1 }
        if k < n, chars[k] == "(" { return .function }
        if let first = word.first, first.isUppercase, word.count > 1 { return .type }
        return .plain
    }

    // MARK: Language table

    struct LanguageSpec {
        var keywords: Set<String> = []
        var types: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var nestedBlockComments = false
        var stringDelimiters: Set<Character> = ["\"", "'"]
        /// Checked before `stringDelimiters`, longest first.
        var multilineDelimiters: [String] = []
        var escapesInStrings = true
        var attributeLeaders: Set<Character> = []
        var identifierExtras: Set<Character> = ["_"]
        /// Lowercased prefixes that turn the following quote into a string: r"", f"", b"".
        var stringPrefixes: Set<String> = []
        var hashRawStrings = false
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.split(separator: " ").map(String.init))
    }

    private static func spec(for language: CodeLanguage) -> LanguageSpec {
        specLock.lock()
        defer { specLock.unlock() }
        if let cached = specCache[language] { return cached }
        let built = build(language)
        specCache[language] = built
        return built
    }

    private static let specLock = NSLock()
    private nonisolated(unsafe) static var specCache: [CodeLanguage: LanguageSpec] = [:]

    private static func build(_ language: CodeLanguage) -> LanguageSpec {
        var s = LanguageSpec()
        switch language {
        case .swift:
            s.keywords = words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var actor async await break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any catch false is nil super self Self throws true try some any nonisolated isolated consuming borrowing each package didSet willSet get set mutating nonmutating indirect lazy final required convenience override dynamic weak unowned optional infix prefix postfix")
            s.types = words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Array Dictionary Set Optional Result Data Date URL Void Never AnyObject")
            s.lineComments = ["///", "//"]
            s.blockComment = ("/*", "*/")
            s.nestedBlockComments = true
            s.multilineDelimiters = ["\"\"\""]
            s.stringDelimiters = ["\""]
            s.attributeLeaders = ["@"]
            s.identifierExtras = ["_", "$"]
            s.hashRawStrings = true
        case .objc:
            s.keywords = words("@interface @implementation @property @end @synthesize @dynamic @selector @protocol @class if else for while do switch case default break continue return goto typedef struct union enum static const extern inline sizeof void nil YES NO self super id BOOL instancetype nonatomic atomic strong weak copy assign readonly readwrite")
            s.types = words("NSString NSArray NSDictionary NSMutableArray NSMutableDictionary NSNumber NSObject NSError NSData NSDate CGRect CGFloat CGPoint CGSize int char float double long short unsigned signed")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.attributeLeaders = ["@"]
        case .c, .cpp:
            var kw = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL"
            if language == .cpp {
                kw += " class public private protected virtual override final template typename namespace using new delete this nullptr operator friend explicit constexpr consteval noexcept decltype static_cast dynamic_cast const_cast reinterpret_cast try catch throw mutable concept requires co_await co_return co_yield"
            }
            s.keywords = words(kw)
            s.types = words("size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t std string vector map set wchar_t")
            s.lineComments = ["//", "#"]   // '#' covers preprocessor lines closely enough
            s.blockComment = ("/*", "*/")
        case .javascript, .typescript:
            var kw = "await async break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch this throw try typeof var void while with yield null true false undefined get set from as"
            if language == .typescript {
                kw += " interface type enum implements declare namespace public private protected readonly abstract override satisfies keyof infer is asserts"
            }
            s.keywords = words(kw)
            s.types = words("string number boolean any unknown never object symbol bigint Promise Array Record Partial Map Set Object JSON Math Date RegExp Error")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.multilineDelimiters = ["`"]
            s.attributeLeaders = ["@"]
            s.identifierExtras = ["_", "$"]
        case .python:
            s.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda None nonlocal not or pass raise return try while with yield True False match case self cls")
            s.types = words("int float str bool list dict set tuple bytes object Exception ValueError TypeError KeyError Optional List Dict Any Union")
            s.lineComments = ["#"]
            s.multilineDelimiters = ["\"\"\"", "'''"]
            s.stringPrefixes = ["r", "f", "b", "u", "rb", "br", "fr", "rf"]
            s.attributeLeaders = ["@"]
        case .ruby:
            s.keywords = words("alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield attr_accessor attr_reader attr_writer require require_relative include extend lambda proc puts raise new")
            s.lineComments = ["#"]
            s.attributeLeaders = ["@", "$"]
            s.identifierExtras = ["_", "?", "!"]
        case .go:
            s.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota make new len cap append copy delete panic recover")
            s.types = words("string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr byte rune float32 float64 complex64 complex128 bool error any")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.multilineDelimiters = ["`"]
            s.stringDelimiters = ["\"", "'"]
        case .rust:
            s.keywords = words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while union macro_rules")
            s.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc HashMap HashSet")
            s.lineComments = ["///", "//!", "//"]
            s.blockComment = ("/*", "*/")
            s.nestedBlockComments = true
            s.stringDelimiters = ["\"", "'"]
            s.attributeLeaders = ["#"]
            s.stringPrefixes = ["r", "b", "br"]
        case .java:
            s.keywords = words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try var void volatile while true false null record sealed permits yield")
            s.types = words("boolean byte char double float int long short String Object Integer Double Boolean List Map Set Optional Stream Exception")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.attributeLeaders = ["@"]
        case .kotlin:
            s.keywords = words("as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum external false final finally for fun get if import in infix init inline interface internal is lateinit noinline null object open operator out override package private protected public reified return sealed set super suspend this throw true try typealias typeof val var vararg when where while it")
            s.types = words("Int Long Double Float Boolean String Char Any Unit Nothing List Map Set MutableList MutableMap Array")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.nestedBlockComments = true
            s.multilineDelimiters = ["\"\"\""]
            s.attributeLeaders = ["@"]
        case .php:
            s.keywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null")
            s.lineComments = ["//", "#"]
            s.blockComment = ("/*", "*/")
            s.attributeLeaders = ["$"]
        case .csharp:
            s.keywords = words("abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern false finally fixed for foreach get goto if implicit in interface internal is lock namespace new null operator out override params partial private protected public readonly record ref return sealed set sizeof stackalloc static struct switch this throw true try typeof unchecked unsafe using var virtual void volatile when where while yield nameof")
            s.types = words("bool byte char decimal double float int long object sbyte short string uint ulong ushort dynamic Task List Dictionary IEnumerable Exception")
            s.lineComments = ["///", "//"]
            s.blockComment = ("/*", "*/")
            s.attributeLeaders = ["["]
        case .shell:
            s.keywords = words("if then else elif fi for while until do done case esac function select in return break continue local export readonly declare typeset source alias unalias set unset shift trap exit eval exec echo printf cd test")
            s.lineComments = ["#"]
            s.attributeLeaders = ["$"]
            s.identifierExtras = ["_", "-"]
        case .sql:
            s.keywords = words("SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX VIEW JOIN LEFT RIGHT INNER OUTER FULL ON GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE CASE WHEN THEN ELSE END PRIMARY KEY FOREIGN REFERENCES CONSTRAINT DEFAULT UNIQUE CASCADE RETURNING WITH select from where insert into values update set delete create table alter drop index view join left right inner outer full on group by order having limit offset union all distinct as and or not null is in exists between like case when then else end with returning")
            s.types = words("INT INTEGER BIGINT SMALLINT TEXT VARCHAR CHAR BOOLEAN DATE TIMESTAMP TIMESTAMPTZ NUMERIC DECIMAL REAL JSON JSONB UUID SERIAL")
            s.lineComments = ["--"]
            s.blockComment = ("/*", "*/")
        case .html:
            s.keywords = words("html head body div span a p ul ol li table tr td th form input button script style link meta title img section header footer nav main article aside template slot")
            s.lineComments = []
            s.blockComment = ("<!--", "-->")
            s.identifierExtras = ["_", "-", ":"]
        case .css:
            s.keywords = words("important media supports keyframes import charset font-face root and not only from to")
            s.lineComments = ["//"]   // scss/less
            s.blockComment = ("/*", "*/")
            s.attributeLeaders = ["@"]
            s.identifierExtras = ["_", "-"]
        case .json:
            s.keywords = words("true false null")
            s.stringDelimiters = ["\""]
        case .yaml:
            s.keywords = words("true false null yes no on off ~")
            s.lineComments = ["#"]
            s.identifierExtras = ["_", "-"]
        case .toml:
            s.keywords = words("true false")
            s.lineComments = ["#"]
            s.multilineDelimiters = ["\"\"\"", "'''"]
            s.identifierExtras = ["_", "-"]
        case .markdown:
            s.lineComments = []
            s.stringDelimiters = ["`"]
            s.escapesInStrings = false
        case .dockerfile:
            s.keywords = words("FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS from run cmd label expose env add copy entrypoint volume user workdir arg as")
            s.lineComments = ["#"]
            s.attributeLeaders = ["$"]
        case .plaintext:
            break
        }
        // longest delimiter first so ''' beats ' and """ beats "
        s.multilineDelimiters.sort { $0.count > $1.count }
        s.lineComments.sort { $0.count > $1.count }
        return s
    }
}

// MARK: - Self check

extension SyntaxHighlighter {
    @_spi(Testing) public static func demo() {
        // A "//" inside a Swift string literal is not a comment.
        var s1 = HighlightState()
        let line1 = #"let url = "https://example.com" // real comment"#
        let t1 = tokenize(line1, language: .swift, state: &s1)
        assert(s1.isClean)
        let strings = t1.filter { $0.1 == .string }
        assert(strings.count == 1, "expected 1 string, got \(strings.count)")
        assert(String(line1[strings[0].0]) == "\"https://example.com\"")
        let comments = t1.filter { $0.1 == .comment }
        assert(comments.count == 1)
        assert(String(line1[comments[0].0]) == "// real comment")
        assert(t1.contains { $0.1 == .keyword && String(line1[$0.0]) == "let" })

        // A block comment opened on one line keeps the next line commented.
        var s2 = HighlightState()
        let openLine = "let a = 1 /* start of note"
        let t2 = tokenize(openLine, language: .swift, state: &s2)
        assert(s2.blockCommentDepth == 1, "depth \(s2.blockCommentDepth)")
        assert(t2.contains { $0.1 == .number })
        let next = "still inside the note"
        let t3 = tokenize(next, language: .swift, state: &s2)
        assert(t3.count == 1 && t3[0].1 == .comment && String(next[t3[0].0]) == next)
        assert(s2.blockCommentDepth == 1)
        let closeLine = "end of note */ let b = 2"
        let t4 = tokenize(closeLine, language: .swift, state: &s2)
        assert(s2.isClean)
        assert(String(closeLine[t4[0].0]) == "end of note */")
        assert(t4.contains { $0.1 == .keyword && String(closeLine[$0.0]) == "let" })

        // A Python triple-quoted string spans lines.
        var s5 = HighlightState()
        _ = tokenize("doc = \"\"\"first line", language: .python, state: &s5)
        assert(s5.stringTerminator == "\"\"\"", "terminator \(s5.stringTerminator)")
        let mid = "still a string # not a comment"
        let t6 = tokenize(mid, language: .python, state: &s5)
        assert(t6.count == 1 && t6[0].1 == .string)
        _ = tokenize("last\"\"\"", language: .python, state: &s5)
        assert(s5.isClean)

        // Numbers, calls and types.
        var s7 = HighlightState()
        let line7 = "let n = 0xFF_00 + foo(Bar())"
        let t7 = tokenize(line7, language: .swift, state: &s7)
        assert(t7.contains { $0.1 == .number && String(line7[$0.0]) == "0xFF_00" })
        assert(t7.contains { $0.1 == .function && String(line7[$0.0]) == "foo" })
        assert(t7.contains { $0.1 == .function && String(line7[$0.0]) == "Bar" })

        // Language detection.
        assert(CodeLanguage.detect(path: "Sources/App/Main.swift") == .swift)
        assert(CodeLanguage.detect(path: "docker/Dockerfile") == .dockerfile)
        assert(CodeLanguage.detect(path: "Gemfile") == .ruby)
        assert(CodeLanguage.detect(path: "home/.zshrc") == .shell)
        assert(CodeLanguage.detect(path: "web/app.tsx") == .typescript)
        assert(CodeLanguage.detect(path: "NOTES") == .plaintext)
        assert(CodeLanguage.detect(path: "ops/Dockerfile.ci") == .dockerfile)
        assert(CodeLanguage.detect(path: "Vagrantfile") == .ruby)
        // Shebangs: only consulted when the path says nothing, and never over a real extension.
        assert(CodeLanguage.detect(path: "bin/deploy", firstLine: "#!/bin/bash") == .shell)
        assert(CodeLanguage.detect(path: "bin/run", firstLine: "#!/usr/bin/env -S python3 -u") == .python)
        assert(CodeLanguage.detect(path: "bin/x", firstLine: "#!/usr/local/bin/ruby2.7") == .ruby)
        assert(CodeLanguage.detect(path: "app.py", firstLine: "#!/bin/bash") == .python)
        assert(CodeLanguage.detect(path: "bin/x", firstLine: "not a shebang") == .plaintext)
        assert(CodeLanguage.detect(path: "bin/x", firstLine: "#!/bin/unknownthing") == .plaintext)

        // Over-long lines fall back to plain text.
        var s8 = HighlightState()
        assert(tokenize(String(repeating: "a", count: maxLineLength + 1), language: .swift, state: &s8).isEmpty)
    }
}
