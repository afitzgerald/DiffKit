import SwiftUI

/// One file's diff, unified, with line numbers, syntax colouring and word-level emphasis on
/// paired edits. It knows nothing about where the diff came from: no comments, no review
/// state, no toolbar. The host owns the chrome.
///
/// Code does not scale with Dynamic Type: the alignment is what makes a diff legible, so the
/// host passes `codeSize` instead.
///
/// Hooks are environment modifiers, so they reach every `PatchView` below them:
/// `.patchTheme(_:)` for colours, `.onPatchLineTap { line in … }` to act on a tapped row, and
/// `.patchSelection(_:)` to tint rows. Rows are identified by `DiffLine.id`, which is stable
/// for a given patch: it is the id `DiffParser.parse(file.patch)` assigns.
public struct PatchView: View {
    let file: FileChange
    let codeSize: Double
    let wrap: Bool

    /// Built off the main actor: word emphasis is Myers per paired line and can take real time
    /// on a long minified one (see `DiffParser.maxInlineTokens`).
    @State private var model: PatchModel?

    public init(file: FileChange, codeSize: Double = 12, wrap: Bool = false) {
        self.file = file
        self.codeSize = codeSize
        self.wrap = wrap
    }

    public var body: some View {
        Group {
            // The file check keeps a stale model from flashing the previous file's diff.
            if let model, model.file == file {
                switch model.content {
                case .diff(let parsed): diff(parsed, model: model)
                case .binary:
                    placeholder("Binary file", "doc.zipper", "This file is binary, so there is no text diff.")
                case .noPatch:
                    placeholder("No diff to show", "doc.questionmark",
                                "The patch was not sent, usually because the file is too large.")
                case .empty:
                    placeholder("No content changes", "doc",
                                "Only the file's name, mode or existence changed.")
                }
            } else {
                ProgressView()
            }
        }
        // Fill the offered space in every state, not just the diff: otherwise the spinner and
        // placeholders shrink the view to their own size, and anything the host overlays or
        // aligns to it (a floating file stepper) jumps around as the state changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) {
            let file = file
            model = await Task.detached(priority: .userInitiated) { PatchModel(file: file) }.value
        }
    }

    @ViewBuilder
    private func diff(_ parsed: ParsedDiff, model: PatchModel) -> some View {
        // Horizontal scroll wrapping the vertical one, so a long line scrolls the whole
        // column rather than each row separately — rows sliding independently is what makes
        // a per-row ScrollView unreadable.
        let content = LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(parsed.hunks) { hunk in
                Section {
                    ForEach(hunk.lines) { line in
                        PatchLineRow(line: line, language: model.language,
                                     startState: model.highlightStates[line.id] ?? HighlightState(),
                                     emphasis: model.emphasis[line.id] ?? [],
                                     size: codeSize, wrap: wrap)
                    }
                } header: {
                    PatchHunkHeader(hunk: hunk, size: codeSize)
                }
            }
            if parsed.isTruncated {
                Label("This diff was cut short after \(DiffParser.maxLines) lines.", systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }

        if wrap {
            ScrollView(.vertical) { content }
        } else {
            // An explicit width, not `minWidth`: rows carry `.frame(maxWidth: .infinity)` so the
            // +/- tint spans the full line, and inside a horizontal ScrollView that resolves to
            // whatever width is *proposed* — the screen's, with minWidth — which clamps every row
            // to the screen and leaves nothing to scroll. Proposing the widest line instead makes
            // the tint and the scrollable extent the same number.
            //
            // The minHeight is for iOS, which centres a two-axis ScrollView's content when it is
            // shorter than the screen, so a three-line diff floated mid-page. macOS does not.
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    content.frame(width: max(geo.size.width, width(of: parsed)), alignment: .leading)
                        .frame(minHeight: geo.size.height, alignment: .top)
                }
            }
        }
    }

    /// Width of the longest line, measured in characters rather than laid out: the code is
    /// monospaced, so a character count times the advance is exact enough to scroll to.
    /// A wide glyph (CJK, an emoji in a comment) is under-counted and its line clips at the
    /// right edge; measure the real string if that ever matters.
    private func width(of parsed: ParsedDiff) -> CGFloat {
        let chars = parsed.hunks.flatMap(\.lines).map(\.text.count).max() ?? 0
        let advance = codeSize * 0.6
        let gutter = max(28, codeSize * 2.6)
        // gutter + spacing + marker + spacing + trailing padding, then the code itself with slack.
        return gutter + 20 + advance + Double(chars + 2) * advance
    }

    private func placeholder(_ title: String, _ symbol: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}

// MARK: - Model

/// Everything `PatchView` derives from a `FileChange`, with no SwiftUI in it.
struct PatchModel: Sendable {
    enum Content: Sendable {
        case diff(ParsedDiff), binary, noPatch, empty
    }

    let file: FileChange
    let content: Content
    let language: CodeLanguage
    /// Character ranges to emphasise, keyed by `DiffLine.id`.
    let emphasis: [Int: [Range<Int>]]
    /// The highlighter state each row starts in, for rows that do not start clean.
    let highlightStates: [Int: HighlightState]

    init(file: FileChange) {
        self.file = file
        if file.isBinary {
            content = .binary
        } else if let patch = file.patch {
            let parsed = DiffParser.parse(patch)
            content = parsed.isEmpty ? .empty : .diff(parsed)
        } else {
            content = .noPatch
        }
        guard case .diff(let parsed) = content else {
            language = .plaintext; emphasis = [:]; highlightStates = [:]
            return
        }
        // A shebang only counts on line 1, so it is only consulted when the hunk shows it.
        let firstLine = parsed.hunks.first?.lines.first { $0.newLine == 1 && $0.kind != .deletion }?.text
        language = CodeLanguage.detect(path: file.path, firstLine: firstLine)
        emphasis = Self.emphasis(for: parsed)
        highlightStates = Self.highlightStates(for: parsed, language: language)
    }

    /// Walks each hunk once per side, so a block comment or multi-line string that opens on
    /// one row still colours the rows after it. Deletions continue the old file's state,
    /// additions the new file's, and context lines are in both. Each hunk starts clean: what
    /// precedes it is not in the patch, so a comment opened above a hunk is still missed.
    static func highlightStates(for parsed: ParsedDiff, language: CodeLanguage) -> [Int: HighlightState] {
        guard language != .plaintext else { return [:] }
        var out: [Int: HighlightState] = [:]
        for hunk in parsed.hunks {
            var old = HighlightState(), new = HighlightState()
            for line in hunk.lines {
                let start: HighlightState
                switch line.kind {
                case .deletion:
                    start = old
                    _ = SyntaxHighlighter.tokenize(line.text, language: language, state: &old)
                case .addition:
                    start = new
                    _ = SyntaxHighlighter.tokenize(line.text, language: language, state: &new)
                case .context:
                    start = new
                    _ = SyntaxHighlighter.tokenize(line.text, language: language, state: &old)
                    _ = SyntaxHighlighter.tokenize(line.text, language: language, state: &new)
                case .noNewline, .meta:
                    continue
                }
                if !start.isClean { out[line.id] = start }
            }
        }
        return out
    }

    /// `hunk.header` up to its closing `@@`, i.e. git's own numbers. `Hunk.rangeHeader`
    /// rebuilds them from the parsed starts, which moves an empty side from git's `+0,0` to `+1,0`.
    static func rangeText(_ hunk: Hunk) -> String {
        // The closing run matches the opening one: `@@` normally, `@@@` in a combined diff.
        let run = hunk.header.prefix { $0 == "@" }
        let rest = hunk.header.dropFirst(run.count)
        guard run.count >= 2, let close = rest.range(of: String(run)) else { return hunk.rangeHeader }
        return String(hunk.header[..<close.upperBound])
    }

    /// Word-level emphasis for each deletion/addition pair, paired the way the split view pairs
    /// them. A line with no partner has nothing to be compared against and gets none.
    static func emphasis(for parsed: ParsedDiff) -> [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for hunk in parsed.hunks {
            for row in DiffParser.pair(hunk) {
                guard let old = row.left, let new = row.right,
                      old.kind == .deletion, new.kind == .addition else { continue }
                let ranges = DiffParser.inlineRanges(old: old.text, new: new.text)
                if !ranges.old.isEmpty { out[old.id] = ranges.old }
                if !ranges.new.isEmpty { out[new.id] = ranges.new }
            }
        }
        return out
    }
}

// MARK: - Hooks

/// The colours `PatchView` draws with. Every default comes from `DiffTheme` and
/// `HighlightTheme.system`; override the ones you need and pass the result to `.patchTheme(_:)`.
public struct PatchTheme {
    public var added: Color
    public var removed: Color
    public var addedBG: Color
    public var removedBG: Color
    /// Behind the words that changed inside a paired edit.
    public var addedEmphasis: Color
    public var removedEmphasis: Color
    /// Over rows named in `.patchSelection(_:)`.
    public var selection: Color
    public var syntax: HighlightTheme

    public init(added: Color = DiffTheme.added, removed: Color = DiffTheme.removed,
                addedBG: Color = DiffTheme.addedBG, removedBG: Color = DiffTheme.removedBG,
                addedEmphasis: Color = DiffTheme.added.opacity(0.3),
                removedEmphasis: Color = DiffTheme.removed.opacity(0.3),
                selection: Color = Color.accentColor.opacity(0.18),
                syntax: HighlightTheme = .system) {
        self.added = added
        self.removed = removed
        self.addedBG = addedBG
        self.removedBG = removedBG
        self.addedEmphasis = addedEmphasis
        self.removedEmphasis = removedEmphasis
        self.selection = selection
        self.syntax = syntax
    }
}

private struct PatchThemeKey: EnvironmentKey { static let defaultValue = PatchTheme() }
private struct PatchLineTapKey: EnvironmentKey { static let defaultValue: ((DiffLine) -> Void)? = nil }
private struct PatchSelectionKey: EnvironmentKey { static let defaultValue: Set<Int> = [] }

extension EnvironmentValues {
    var patchTheme: PatchTheme {
        get { self[PatchThemeKey.self] }
        set { self[PatchThemeKey.self] = newValue }
    }
    var patchLineTap: ((DiffLine) -> Void)? {
        get { self[PatchLineTapKey.self] }
        set { self[PatchLineTapKey.self] = newValue }
    }
    var patchSelection: Set<Int> {
        get { self[PatchSelectionKey.self] }
        set { self[PatchSelectionKey.self] = newValue }
    }
}

extension View {
    /// Colours for every `PatchView` inside this view.
    public func patchTheme(_ theme: PatchTheme) -> some View {
        environment(\.patchTheme, theme)
    }

    /// Called with the row's line when a diff row is tapped or clicked. Hunk headers and
    /// placeholders are not tappable.
    public func onPatchLineTap(perform action: @escaping (DiffLine) -> Void) -> some View {
        environment(\.patchLineTap, action)
    }

    /// Tints the rows whose `DiffLine.id` is in `lineIDs`, e.g. a selected range or a
    /// commented line. The host owns the selection; `PatchView` only draws it.
    public func patchSelection(_ lineIDs: Set<Int>) -> some View {
        environment(\.patchSelection, lineIDs)
    }
}

// MARK: - Rows

private struct PatchHunkHeader: View {
    let hunk: Hunk
    let size: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(PatchModel.rangeText(hunk))
                .font(.system(size: size - 1, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            if let heading = hunk.sectionHeading, !heading.isEmpty {
                Text(heading)
                    .font(.system(size: size - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct PatchLineRow: View {
    let line: DiffLine
    let language: CodeLanguage
    let startState: HighlightState
    let emphasis: [Range<Int>]
    let size: Double
    let wrap: Bool

    @Environment(\.patchTheme) private var theme
    @Environment(\.patchLineTap) private var onTap
    @Environment(\.patchSelection) private var selection

    var body: some View {
        if let onTap {
            // Only with a handler: an idle tap gesture would still compete with scrolling
            // and with text selection.
            row.contentShape(Rectangle()).onTapGesture { onTap(line) }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 6) {
            // One column (the new file's, falling back to the old): on a phone the line
            // numbers are orientation, not something you read.
            Text(gutter)
                .font(.system(size: size - 2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: max(28, size * 2.6), alignment: .trailing)

            // fixedSize, or the widest row in the file loses its marker: the HStack hands the
            // leftover width to its flexible children, and on the row that fills the whole
            // scrollable width there is none left, so the +/- is squeezed to nothing.
            Text(marker)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(markerColor)
                .fixedSize()

            // Only the code is selectable, so a copy never drags along gutters or markers.
            Text(highlighted)
                .font(.system(size: size, design: .monospaced))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: wrap)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay { if selection.contains(line.id) { theme.selection.allowsHitTesting(false) } }
    }

    private var gutter: String {
        if let n = line.newLineNumber { return String(n) }
        if let n = line.oldLineNumber { return String(n) }
        return ""
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        default: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return theme.added
        case .deletion: return theme.removed
        default: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return theme.addedBG
        case .deletion: return theme.removedBG
        default: return .clear
        }
    }

    /// Starts from the state the model carried down the hunk, so a comment continued from the
    /// row above stays a comment.
    private var highlighted: AttributedString {
        guard line.kind != .meta, line.kind != .noNewline else { return AttributedString(line.text) }
        var state = startState
        var text = SyntaxHighlighter.attributed(line.text, language: language, state: &state,
                                                theme: theme.syntax)
        let tint = line.kind == .addition ? theme.addedEmphasis : theme.removedEmphasis
        let count = text.characters.count
        for range in emphasis where range.upperBound <= count {
            let lower = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            let upper = text.characters.index(lower, offsetBy: range.count)
            text[lower..<upper].backgroundColor = tint
        }
        return text
    }
}

// MARK: - Self check

extension PatchView {
    /// Checks the part of the view that is logic: which placeholder a file gets and which
    /// characters are emphasised. Rendering itself is not checked.
    @_spi(Testing) public static func demo() {
        func content(_ f: FileChange) -> String {
            switch PatchModel(file: f).content {
            case .diff(let p): return p.isTruncated ? "truncated" : "diff"
            case .binary: return "binary"
            case .noPatch: return "noPatch"
            case .empty: return "empty"
            }
        }
        func file(_ patch: String?, binary: Bool = false) -> FileChange {
            FileChange(path: "a.swift", status: .modified, additions: 0, deletions: 0,
                       patch: patch, isBinary: binary)
        }
        assert(content(file(nil, binary: true)) == "binary")
        assert(content(file("@@ -1 +1 @@\n-a\n+b", binary: true)) == "binary", "isBinary wins over a patch")
        assert(content(file(nil)) == "noPatch")
        assert(content(file("")) == "empty")
        assert(content(file("index 0000000..e69de29\n")) == "empty", "headers only is still empty")
        assert(content(file("@@ -1 +1 @@\n-a\n+b")) == "diff")
        let huge = "@@ -1,\(DiffParser.maxLines + 1) +1,\(DiffParser.maxLines + 1) @@\n"
            + String(repeating: " x\n", count: DiffParser.maxLines + 1)
        assert(content(file(huge)) == "truncated")

        // Emphasis lands on the changed word of each paired line, keyed by line id.
        let model = PatchModel(file: file("""
            @@ -1,3 +1,3 @@
             let keep = 0
            -let a = 1
            +let a = 2
            -gone entirely
            """))
        let lines = { if case .diff(let p) = model.content { return p.hunks[0].lines }; return [] }()
        assert(lines.count == 4)
        assert(model.emphasis[lines[1].id] == [8..<9], "\(model.emphasis)")
        assert(model.emphasis[lines[2].id] == [8..<9])
        assert(model.emphasis[lines[0].id] == nil, "context is never emphasised")
        assert(model.emphasis[lines[3].id] == nil, "an unpaired deletion has nothing to compare to")

        // A file with nothing to diff builds no emphasis.
        assert(PatchModel(file: file(nil)).emphasis.isEmpty)

        // A block comment opened in context carries into the next rows, per side: the
        // deletion closes it on the old side only, so the addition after it is still inside.
        let commented = PatchModel(file: file("""
            @@ -1,4 +1,4 @@
             /* opens here
            -closes here */ let a = 1
            +still inside
             */ let b = 2
            """))
        let cl = { if case .diff(let p) = commented.content { return p.hunks[0].lines }; return [] }()
        assert(commented.language == .swift)
        assert(commented.highlightStates[cl[0].id] == nil, "first row starts clean")
        assert(commented.highlightStates[cl[1].id]?.blockCommentDepth == 1)
        assert(commented.highlightStates[cl[2].id]?.blockCommentDepth == 1)
        // Context starts from the new side, which is still inside the comment.
        assert(commented.highlightStates[cl[3].id]?.blockCommentDepth == 1)
        // Each hunk starts clean, and plain text carries no state at all.
        assert(PatchModel(file: FileChange(path: "notes.txt", status: .modified, additions: 0, deletions: 0,
                                           patch: "@@ -1 +1 @@\n /* x")).highlightStates.isEmpty)

        // The header shows git's numbers, not the adjusted starts.
        let deleted = DiffParser.parse("@@ -1,3 +0,0 @@ func x\n-a\n-b\n-c")
        assert(PatchModel.rangeText(deleted.hunks[0]) == "@@ -1,3 +0,0 @@", PatchModel.rangeText(deleted.hunks[0]))
        assert(deleted.hunks[0].rangeHeader == "@@ -1,3 +1,0 @@", "rangeHeader rebuilds from the adjusted starts")
        let combined = DiffParser.parse("@@@ -1 -1 +1 @@@\n  a")
        assert(PatchModel.rangeText(combined.hunks[0]) == "@@@ -1 -1 +1 @@@")
    }
}
