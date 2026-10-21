import SwiftUI

/// One file's diff, unified, with line numbers, syntax colouring and word-level emphasis on
/// paired edits. It knows nothing about where the diff came from: no comments, no review
/// state, no toolbar. The host owns the chrome.
///
/// Code does not scale with Dynamic Type: the alignment is what makes a diff legible, so the
/// host passes `codeSize` instead.
///
/// Hooks are environment modifiers, so they reach every `PatchView` below them:
/// `.patchTheme(_:)` for colours, `.onPatchLineTap { line in … }` to act on a tapped row,
/// `.patchSelection(_:)` to tint rows, `.patchLineAccessory { line in … }` to draw something at
/// the end of a row, and `.patchScrollTarget(_:)` to bring a row into view. Rows are identified
/// by `DiffLine.id`, which is stable for a given patch: it is the id `DiffParser.parse(file.patch)`
/// assigns.
public struct PatchView: View {
    let file: FileChange
    let codeSize: Double
    let wrap: Bool
    let highlightsSyntax: Bool
    let hidesWhitespaceChanges: Bool

    /// Built off the main actor: word emphasis is Myers per paired line and can take real time
    /// on a long minified one (see `DiffParser.maxInlineTokens`).
    @State private var model: PatchModel?
    @Environment(\.patchScrollTarget) private var scrollTarget
    @Environment(\.patchLineAccessory) private var accessory
    @Environment(\.patchLineHover) private var hover
    @Environment(\.patchLayout) private var layout
    @Environment(\.patchLineNumbers) private var lineNumbers
    @Environment(\.patchLineAttachment) private var attachment
    /// The visible width, which attachments are held to: in an unwrapped diff the column is as
    /// wide as the longest line, and a thread laid across it ran off screen to the right.
    @State private var viewportWidth: CGFloat = 0
    @Environment(\.patchFileText) private var fileText
    /// The last target scrolled to, so `.onAppear` does not take the reader back to a row they
    /// had long since left when this view is shown again.
    @State private var lastTarget: PatchScrollTarget?
    /// The unchanged lines around the hunks, once the host's text has arrived and matched.
    @State private var expansion: PatchExpansion?
    /// How much of each gap is showing, keyed by its index in `PatchExpansion.gaps`.
    @State private var revealed: [Int: GapReveal] = [:]
    /// Kept so that flipping hidden whitespace does not fetch the file again.
    @State private var loadedText: (file: FileChange, text: String)?

    public init(file: FileChange, codeSize: Double = 12, wrap: Bool = false) {
        self.init(file: file, codeSize: codeSize, wrap: wrap,
                  highlightsSyntax: true, hidesWhitespaceChanges: false)
    }

    /// `highlightsSyntax: false` draws the code as plain text; the word emphasis stays.
    /// `hidesWhitespaceChanges` drops every edit that differs only in whitespace
    /// (`DiffParser.hidingWhitespaceChanges`).
    ///
    /// A second initialiser rather than two more defaults on the first, so the original
    /// `init(file:codeSize:wrap:)` stays exactly as it was.
    public init(file: FileChange, codeSize: Double = 12, wrap: Bool = false,
                highlightsSyntax: Bool, hidesWhitespaceChanges: Bool = false) {
        self.file = file
        self.codeSize = codeSize
        self.wrap = wrap
        self.highlightsSyntax = highlightsSyntax
        self.hidesWhitespaceChanges = hidesWhitespaceChanges
        // Built before: start from it, so the first frame has the rows, at their final height.
        if let cached = PatchCache.shared.model(for: file, hidesWhitespaceChanges: hidesWhitespaceChanges) {
            _model = State(initialValue: cached)
        }
    }

    public init(file: FileChange, codeSize: Double = 12, wrap: Bool = false,
                hidesWhitespaceChanges: Bool) {
        self.init(file: file, codeSize: codeSize, wrap: wrap,
                  highlightsSyntax: true, hidesWhitespaceChanges: hidesWhitespaceChanges)
    }

    public var body: some View {
        Group {
            // The file check keeps a stale model from flashing the previous file's diff.
            if let model, model.file == file, model.hidesWhitespaceChanges == hidesWhitespaceChanges {
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
                case .whitespaceOnly:
                    placeholder("Only whitespace changed", "text.alignleft",
                                "Every change in this file is whitespace, which is hidden.")
                }
            } else {
                ProgressView()
            }
        }
        // Fill the offered space in every state, not just the diff: otherwise the spinner and
        // placeholders shrink the view to their own size, and anything the host overlays or
        // aligns to it (a floating file stepper) jumps around as the state changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: ModelKey(file: file, hidesWhitespaceChanges: hidesWhitespaceChanges)) {
            let file = file, hides = hidesWhitespaceChanges
            let built: PatchModel
            if let model, model.file == file, model.hidesWhitespaceChanges == hides {
                // Shown again, which restarts this task: what was built, and the unchanged lines
                // the reader revealed, still stand.
                guard expansion == nil else { return }
                built = model
            } else {
                built = await Task.detached(priority: .userInitiated) {
                    PatchModel(file: file, hidesWhitespaceChanges: hides)
                }.value
                model = built
                expansion = nil
                revealed = [:]
                PatchCache.shared.store(built)
            }
            guard PatchExpansion.expandable(built) != nil, let text = await text(of: file),
                  !Task.isCancelled else { return }
            let expanded = await Task.detached(priority: .userInitiated) {
                PatchExpansion(model: built, text: text)
            }.value
            if !Task.isCancelled { expansion = expanded }
        }
    }

    /// The host's full new text for `file`, from `.patchFileText`, fetched once per file.
    private func text(of file: FileChange) async -> String? {
        guard let fileText else { return nil }
        if let loadedText, loadedText.file == file { return loadedText.text }
        let text = await fileText(file)
        if let text { loadedText = (file, text) }
        return text
    }

    /// The expansion for what is on screen now, never a previous file's.
    private var currentExpansion: PatchExpansion? {
        guard let expansion, expansion.file == file,
              expansion.hidesWhitespaceChanges == hidesWhitespaceChanges else { return nil }
        return expansion
    }

    @ViewBuilder
    private func diff(_ parsed: ParsedDiff, model: PatchModel) -> some View {
        // Horizontal scroll wrapping the vertical one, so a long line scrolls the whole
        // column rather than each row separately — rows sliding independently is what makes
        // a per-row ScrollView unreadable.
        let content = LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            rows(parsed, model: model)
        }

        ScrollViewReader { proxy in
            // Leading, not centre: the rows are as wide as the longest line, and `.center`
            // scrolled sideways to the middle of it, gutter off screen.
            let scroll = { (target: PatchScrollTarget?) in
                guard let target, target != lastTarget else { return }
                lastTarget = target
                // In split view a row holds two lines, so the line names its row.
                let id = layout == .split ? model.splitRowID[target.lineID] : PatchScrollTarget.rowID(target.lineID)
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.5)) }
            }
            scroller(content, parsed)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                .onChange(of: scrollTarget) { _, target in scroll(target) }
                // A target set while the model was still building — a host that opens a file
                // at a find match — arrives before these rows exist, and onChange never sees it.
                .onAppear { scroll(scrollTarget) }
        }
    }

    /// The hunks, the unchanged lines between them, and the truncation note.
    @ViewBuilder
    private func rows(_ parsed: ParsedDiff, model: PatchModel) -> some View {
        ForEach(Array(parsed.hunks.enumerated()), id: \.element.id) { index, hunk in
            gap(index, model: model, parsed: parsed)
            Section {
                if layout == .split {
                    ForEach(model.splitRows[index]) { pair in
                        pairRow(pair, model: model, parsed: parsed)
                    }
                } else {
                    ForEach(hunk.lines) { line in
                        unifiedRow(line, model: model)
                    }
                }
            } header: {
                PatchHunkHeader(hunk: hunk, size: codeSize)
            }
        }
        gap(parsed.hunks.count, model: model, parsed: parsed)
        if parsed.isTruncated {
            Label("This diff was cut short after \(DiffParser.maxLines) lines.", systemImage: "scissors")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    @ViewBuilder
    private func scroller(_ content: some View, _ parsed: ParsedDiff) -> some View {
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
                    // Split is two columns of the widest line, so the same scroll moves both.
                    content.frame(width: max(geo.size.width, width(of: parsed) * (layout == .split ? 2 : 1)),
                                  alignment: .leading)
                        .frame(minHeight: geo.size.height, alignment: .top)
                }
            }
        }
    }

    private func unifiedRow(_ line: DiffLine, model: PatchModel) -> some View {
        withAttachments(line.threadAnchors) {
            row(line, model: model, gutter: lineNumbers == .both ? .both : .unified)
        }
            // A string id of its own: `Hunk.id` is its first line's id, so
            // scrolling to the bare number could land on the section instead.
            .id(PatchScrollTarget.rowID(line.id))
    }

    private func pairRow(_ pair: SplitRow, model: PatchModel, parsed: ParsedDiff) -> some View {
        withAttachments([pair.left, pair.right].compactMap { $0 }.threadAnchors) {
            splitRow(pair, model: model, halfWidth: wrap ? nil : width(of: parsed))
        }
        .id(pair.id)
    }

    /// The unchanged lines before hunk `index` (after the last one, at `hunks.count`): what has
    /// been revealed from each end, and between them a row that reveals more. Nothing without
    /// an expansion, so a host that supplies no text sees the diff exactly as before.
    @ViewBuilder
    private func gap(_ index: Int, model: PatchModel, parsed: ParsedDiff) -> some View {
        if let lines = currentExpansion?.gaps[index], !lines.isEmpty {
            let shown = revealed[index] ?? GapReveal()
            let hidden = shown.hidden(of: lines.count)
            ForEach(lines.prefix(shown.top)) { gapLine($0, model: model, parsed: parsed) }
            if hidden > 0 {
                // Above the first hunk only upwards makes sense, below the last only downwards.
                PatchGapRow(hidden: hidden, size: codeSize,
                            edges: (index > 0 ? [.top] : []) + (index < parsed.hunks.count ? [.bottom] : [])) { edge in
                    revealed[index, default: GapReveal()].reveal(edge, of: lines.count)
                }
            }
            ForEach(lines.suffix(shown.bottom)) { gapLine($0, model: model, parsed: parsed) }
        }
    }

    /// The unchanged lines before hunk `index`, from the hunk headers alone. None after the last
    /// hunk: how long the file runs on is not in the patch.
    static func knownGap(_ index: Int, in parsed: ParsedDiff) -> Int? {
        let hunks = parsed.hunks
        guard hunks.indices.contains(index) else { return nil }
        let end = index == 0 ? 1 : hunks[index - 1].newStart + hunks[index - 1].newCount
        return hunks[index].newStart - end
    }

    @ViewBuilder
    private func gapLine(_ line: DiffLine, model: PatchModel, parsed: ParsedDiff) -> some View {
        if layout == .split {
            pairRow(SplitRow(left: line, right: line), model: model, parsed: parsed)
        } else {
            unifiedRow(line, model: model)
        }
    }

    /// Width of the longest line, measured in characters rather than laid out: the code is
    /// monospaced, so a character count times the advance is exact enough to scroll to.
    /// A wide glyph (CJK, an emoji in a comment) is under-counted and its line clips at the
    /// right edge; measure the real string if that ever matters.
    private func width(of parsed: ParsedDiff) -> CGFloat {
        let chars = max(parsed.hunks.flatMap(\.lines).map(\.text.count).max() ?? 0,
                        currentExpansion?.longestLine ?? 0)
        let advance = codeSize * 0.6
        // Two number columns only in a unified diff: each split half numbers its own side.
        let columns: CGFloat = lineNumbers == .both && layout == .unified ? 2 : 1
        let gutter = max(28, codeSize * 2.6) * columns
        // gutter + spacing + marker + spacing + trailing padding, then the code itself with slack.
        return gutter + 20 + advance + Double(chars + 2) * advance
    }

    private func row(_ line: DiffLine, model: PatchModel, gutter: PatchLineRow.Gutter) -> PatchLineRow {
        PatchLineRow(line: line, language: highlightsSyntax ? model.language : .plaintext,
                     startState: model.highlightStates[line.id] ?? currentExpansion?.highlightStates[line.id]
                         ?? HighlightState(),
                     emphasis: model.emphasis[line.id] ?? [],
                     size: codeSize, wrap: wrap, gutter: gutter)
    }

    /// A row with the host's attachments under it, one per anchor, full width. Without the
    /// hook it is the row alone, so a diff that attaches nothing lays out exactly as before.
    @ViewBuilder
    private func withAttachments(_ anchors: [DiffAnchor], @ViewBuilder row: () -> some View) -> some View {
        if let attachment, !anchors.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                row()
                ForEach(anchors, id: \.self) { anchor in
                    attachment(anchor)
                        .frame(maxWidth: wrap || viewportWidth == 0 ? .infinity : viewportWidth,
                               alignment: .leading)
                }
            }
        } else {
            row()
        }
    }

    /// Old on the left, new on the right, each half numbered by its own side and unmarked —
    /// the colour says which is which. `halfWidth` is nil when wrapping, and the halves split
    /// the width evenly instead.
    private func splitRow(_ pair: SplitRow, model: PatchModel, halfWidth: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitHalf(pair.left, model: model, gutter: .old, halfWidth: halfWidth)
            Divider()
            splitHalf(pair.right, model: model, gutter: .new, halfWidth: halfWidth)
        }
        // Both halves as tall as the taller, so a wrapped line on one side does not leave a
        // short tint or filler beside it.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func splitHalf(_ line: DiffLine?, model: PatchModel, gutter: PatchLineRow.Gutter,
                           halfWidth: CGFloat?) -> some View {
        Group {
            if let line {
                row(line, model: model, gutter: gutter)
                    .environment(\.patchLineAccessory,
                                 PatchLineRow.ownsLineChrome(line, gutter: gutter) ? accessory : nil)
                    .environment(\.patchLineHover,
                                 PatchLineRow.ownsLineChrome(line, gutter: gutter) ? hover : nil)
            } else {
                // Opposite an unpaired insertion or deletion: a fill, never a blank hole.
                Color.secondary.opacity(0.07)
            }
        }
        .frame(minWidth: halfWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ title: String, _ symbol: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}

// MARK: - Model

/// Models already built, with their unchanged lines and what of them was revealed, so a
/// `PatchView` made again draws its rows on its first frame. A host's lazy page discards views
/// it has scrolled past and makes them again within a fraction of a second; rebuilt from
/// nothing, a file went spinner, rows, unchanged lines — three heights, each moving everything
/// below it. Bounded: the most recently built `capacity` files.
final class PatchCache: @unchecked Sendable {
    static let shared = PatchCache()
    static let capacity = 48

    private let lock = NSLock()
    private var entries: [String: PatchModel] = [:]
    private var order: [String] = []

    private static func key(_ path: String, _ hides: Bool) -> String { "\(hides ? 1 : 0)\(path)" }

    /// The model for exactly this file — a push that changed its patch misses. Only the model:
    /// it depends on the patch alone, where the unchanged lines around it depend on which
    /// revision the host read, which nothing here knows — the same patch in two repositories,
    /// or on a branch whose base moved, would show the other's lines.
    func model(for file: FileChange, hidesWhitespaceChanges: Bool) -> PatchModel? {
        lock.withLock {
            guard let model = entries[Self.key(file.path, hidesWhitespaceChanges)], model.file == file else { return nil }
            return model
        }
    }

    /// Kept as the most recently built: a store moves its file to the back of the queue.
    func store(_ model: PatchModel) {
        lock.withLock {
            let key = Self.key(model.file.path, model.hidesWhitespaceChanges)
            if entries.updateValue(model, forKey: key) != nil { order.removeAll { $0 == key } }
            order.append(key)
            while order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }
    }
}

/// What a `PatchModel` is built from, as the view's task identity: a new file or a flipped
/// whitespace setting rebuilds it.
struct ModelKey: Hashable {
    let file: FileChange
    let hidesWhitespaceChanges: Bool
}

/// Everything `PatchView` derives from a `FileChange`, with no SwiftUI in it.
struct PatchModel: Sendable {
    enum Content: Sendable {
        /// `whitespaceOnly`: there was a diff, and hiding whitespace changes left nothing of it.
        case diff(ParsedDiff), binary, noPatch, empty, whitespaceOnly
    }

    let file: FileChange
    let hidesWhitespaceChanges: Bool
    let content: Content
    let language: CodeLanguage
    /// Character ranges to emphasise, keyed by `DiffLine.id`.
    let emphasis: [Int: [Range<Int>]]
    /// The highlighter state each row starts in, for rows that do not start clean.
    let highlightStates: [Int: HighlightState]
    /// Split view's rows, one array per hunk in `parsed.hunks` order, and the row each line
    /// sits in — a row holds two lines, so a scroll to a line goes through this.
    let splitRows: [[SplitRow]]
    let splitRowID: [Int: String]

    init(file: FileChange, hidesWhitespaceChanges: Bool = false) {
        self.file = file
        self.hidesWhitespaceChanges = hidesWhitespaceChanges
        content = Self.content(of: file, hidesWhitespaceChanges: hidesWhitespaceChanges)
        guard case .diff(let parsed) = content else {
            language = .plaintext; emphasis = [:]; highlightStates = [:]; splitRows = []; splitRowID = [:]
            return
        }
        // A shebang only counts on line 1, so it is only consulted when the hunk shows it.
        let firstLine = parsed.hunks.first?.lines.first { $0.newLine == 1 && $0.kind != .deletion }?.text
        language = CodeLanguage.detect(path: file.path, firstLine: firstLine)
        emphasis = Self.emphasis(for: parsed)
        highlightStates = Self.highlightStates(for: parsed, language: language)
        splitRows = parsed.hunks.map { hunk in DiffParser.pair(hunk).map { SplitRow(left: $0.left, right: $0.right) } }
        var ids: [Int: String] = [:]
        for row in splitRows.joined() {
            if let l = row.left { ids[l.id] = row.id }
            if let r = row.right { ids[r.id] = row.id }
        }
        splitRowID = ids
    }

    /// What the view shows for a file, without the emphasis and highlighter work — all that
    /// `DiffFind.matches(in:query:hidesWhitespaceChanges:)` needs to search the same rows.
    static func content(of file: FileChange, hidesWhitespaceChanges: Bool) -> Content {
        if file.isBinary { return .binary }
        guard let patch = file.patch else { return .noPatch }
        let parsed = DiffParser.parse(patch)
        if parsed.isEmpty { return .empty }
        guard hidesWhitespaceChanges else { return .diff(parsed) }
        var visible = parsed
        visible.hunks = parsed.hunks.map { hunk in
            var hunk = hunk
            hunk.lines = DiffParser.hidingWhitespaceChanges(hunk)
            return hunk
        }
        // Context alone is not a change: a hunk left with nothing added or removed goes.
        visible.hunks.removeAll { !$0.lines.contains { $0.kind == .addition || $0.kind == .deletion } }
        return visible.hunks.isEmpty ? .whitespaceOnly : .diff(visible)
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

/// One split-view row: the old side's line and the new side's, either missing opposite an
/// unpaired change. A context line is both.
public struct SplitRow: Identifiable, Sendable {
    let left: DiffLine?
    let right: DiffLine?
    /// Named for its first line, which `pair` guarantees exists.
    public var id: String { "patch-pair-\((left ?? right)?.id ?? -1)" }
}

// MARK: - Hooks

/// The line numbers a unified diff shows. Set with `.patchLineNumbers(_:)`.
public enum PatchLineNumbers: Sendable {
    /// One column, the new file's number falling back to the old: on a phone the numbers are
    /// orientation, not something you read.
    case one
    /// The old file's number and the new file's, side by side.
    case both
}

/// What `.onPatchLineTap` listens on. Set with `.patchLineTapTarget(_:)`.
public enum PatchLineTapTarget: Sendable {
    /// The whole row: a phone's finger needs the room, and a 28-point gutter is a sliver.
    case row
    /// The line number only, so a click in the code still places a text selection rather
    /// than acting on the line — what a pointer wants.
    case gutter
}

/// How `PatchView` lays a diff out. Set with `.patchLayout(_:)`; unified by default.
public enum PatchLayout: Sendable {
    /// One column, deletions above their additions.
    case unified
    /// Old on the left, new on the right, changes paired across.
    case split
}

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
    /// Behind every occurrence of the `.patchFind(_:current:)` query, and the current one.
    /// Properties rather than `init` parameters, so the initialiser stays the 0.3.0 symbol.
    public var findMatch = Color.yellow.opacity(0.35)
    /// Opaque, with its own text colour: syntax colours on a strong tint (a red keyword on
    /// orange) blur into a smudge, and the current match stops reading as the current one.
    public var findCurrent = Color.yellow
    public var findCurrentText = Color.black
    /// The bar down the leading edge of the rows named in `.patchCurrentChange(_:)`.
    public var currentChange = Color.accentColor
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

/// A request to bring a row into view. Each one is new — `PatchScrollTarget(lineID: 7)` twice
/// scrolls twice — so a host can jump back to the same row, e.g. a file with one comment.
public struct PatchScrollTarget: Equatable, Sendable {
    public let lineID: Int
    private let token = UUID()

    public init(lineID: Int) { self.lineID = lineID }

    static func rowID(_ lineID: Int) -> String { "patch-line-\(lineID)" }
}

private struct PatchThemeKey: EnvironmentKey { static let defaultValue = PatchTheme() }
private struct PatchLineTapKey: EnvironmentKey { static let defaultValue: ((DiffLine) -> Void)? = nil }
private struct PatchSelectionKey: EnvironmentKey { static let defaultValue: Set<Int> = [] }
private struct PatchCurrentChangeKey: EnvironmentKey { static let defaultValue: Set<Int> = [] }
private struct PatchLineAccessoryKey: EnvironmentKey { static let defaultValue: ((DiffLine) -> AnyView)? = nil }
private struct PatchScrollTargetKey: EnvironmentKey { static let defaultValue: PatchScrollTarget? = nil }
private struct PatchFindKey: EnvironmentKey { static let defaultValue = PatchFind() }
private struct PatchLayoutKey: EnvironmentKey { static let defaultValue = PatchLayout.unified }
private struct PatchLineAttachmentKey: EnvironmentKey { static let defaultValue: ((DiffAnchor) -> AnyView)? = nil }
private struct PatchLineNumbersKey: EnvironmentKey { static let defaultValue = PatchLineNumbers.one }
private struct PatchLineHoverKey: EnvironmentKey { static let defaultValue: ((DiffLine) -> AnyView)? = nil }
private struct PatchLineTapTargetKey: EnvironmentKey { static let defaultValue = PatchLineTapTarget.row }
private struct PatchFileTextKey: EnvironmentKey { static let defaultValue: ((FileChange) async -> String?)? = nil }

/// What `.patchFind(_:current:)` set: the query to tint and the occurrence to tint harder.
struct PatchFind: Equatable {
    var query = ""
    var current: DiffFind.Match?
}

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
    var patchCurrentChange: Set<Int> {
        get { self[PatchCurrentChangeKey.self] }
        set { self[PatchCurrentChangeKey.self] = newValue }
    }
    var patchLineAccessory: ((DiffLine) -> AnyView)? {
        get { self[PatchLineAccessoryKey.self] }
        set { self[PatchLineAccessoryKey.self] = newValue }
    }
    var patchScrollTarget: PatchScrollTarget? {
        get { self[PatchScrollTargetKey.self] }
        set { self[PatchScrollTargetKey.self] = newValue }
    }
    var patchLineAttachment: ((DiffAnchor) -> AnyView)? {
        get { self[PatchLineAttachmentKey.self] }
        set { self[PatchLineAttachmentKey.self] = newValue }
    }
    var patchLineNumbers: PatchLineNumbers {
        get { self[PatchLineNumbersKey.self] }
        set { self[PatchLineNumbersKey.self] = newValue }
    }
    var patchLineHover: ((DiffLine) -> AnyView)? {
        get { self[PatchLineHoverKey.self] }
        set { self[PatchLineHoverKey.self] = newValue }
    }
    var patchLineTapTarget: PatchLineTapTarget {
        get { self[PatchLineTapTargetKey.self] }
        set { self[PatchLineTapTargetKey.self] = newValue }
    }
    var patchLayout: PatchLayout {
        get { self[PatchLayoutKey.self] }
        set { self[PatchLayoutKey.self] = newValue }
    }
    var patchFind: PatchFind {
        get { self[PatchFindKey.self] }
        set { self[PatchFindKey.self] = newValue }
    }
    var patchFileText: ((FileChange) async -> String?)? {
        get { self[PatchFileTextKey.self] }
        set { self[PatchFileTextKey.self] = newValue }
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

    /// Marks the rows whose `DiffLine.id` is in `lineIDs` as the change a host is stepping
    /// through, with a bar down their leading edge (`PatchTheme.currentChange`). A bar rather
    /// than a tint, so it reads over the added/removed backgrounds and alongside a selection.
    /// The host owns the stepping; scroll to the change with `.patchScrollTarget(_:)`.
    public func patchCurrentChange(_ lineIDs: Set<Int>) -> some View {
        environment(\.patchCurrentChange, lineIDs)
    }

    /// Drawn at the end of every diff row — a comment count, a marker for something the host
    /// has queued. Return `EmptyView()` for rows that carry nothing. It is kept to its natural
    /// size. Wrapped, it sits after the code and never takes width from it. Unwrapped, it is
    /// overlaid at the visible right edge, over the code of a line that runs past it, so give
    /// it a background if it must read over text.
    public func patchLineAccessory<Accessory: View>(
        @ViewBuilder _ accessory: @escaping (DiffLine) -> Accessory
    ) -> some View {
        environment(\.patchLineAccessory, { AnyView(accessory($0)) })
    }

    /// Scrolls the row with this `DiffLine.id` into view, vertically centred and scrolled all
    /// the way left, each time a new target is set. `nil` does nothing.
    public func patchScrollTarget(_ target: PatchScrollTarget?) -> some View {
        environment(\.patchScrollTarget, target)
    }

    /// Drawn under a row, full width, once for each place a review thread can hang on it —
    /// `DiffLine.threadAnchors`, and in split view both halves', each once. For the threads on
    /// a line and a composer opened on it. Return `EmptyView()` for anchors with nothing; a
    /// row with nothing attached keeps its height. In an unwrapped diff an attachment is held
    /// to the visible width and pinned left, so it reads without scrolling sideways.
    public func patchLineAttachment<Attachment: View>(
        @ViewBuilder _ attachment: @escaping (DiffAnchor) -> Attachment
    ) -> some View {
        environment(\.patchLineAttachment, { AnyView(attachment($0)) })
    }

    /// The line-number columns of a unified diff: `.one` (the default) or `.both`, old and new.
    /// Split view always numbers each half by its own side.
    public func patchLineNumbers(_ numbers: PatchLineNumbers) -> some View {
        environment(\.patchLineNumbers, numbers)
    }

    /// Overlaid at the visible right edge of a row while the pointer is over it — a + that starts a
    /// comment, say. Pointer only: nothing hovers on a touch screen, so a phone never shows it.
    /// In split view it is drawn once per line, on the half where `commentAnchor` composes.
    public func patchLineHover<Hover: View>(@ViewBuilder _ hover: @escaping (DiffLine) -> Hover) -> some View {
        environment(\.patchLineHover, { AnyView(hover($0)) })
    }

    /// Where `.onPatchLineTap` listens: the whole row (the default) or the line number alone.
    public func patchLineTapTarget(_ target: PatchLineTapTarget) -> some View {
        environment(\.patchLineTapTarget, target)
    }

    /// Lays every `PatchView` inside this view out unified (the default) or split. Split pairs
    /// each deletion with the addition that replaced it, in order, and needs the width: a host
    /// on a phone should not offer it. Every other hook works the same in both.
    public func patchLayout(_ layout: PatchLayout) -> some View {
        environment(\.patchLayout, layout)
    }

    /// Tints every case-insensitive occurrence of `query` in the code, and `current` — one of
    /// `DiffFind.matches(in:query:hidesWhitespaceChanges:)` — more strongly. The host owns the
    /// query and steps through the matches; scroll to one with `.patchScrollTarget(_:)`. An
    /// empty query tints nothing.
    public func patchFind(_ query: String, current: DiffFind.Match? = nil) -> some View {
        environment(\.patchFind, PatchFind(query: query, current: current))
    }

    /// The file's full text on the diff's new side, so the reader can reveal the unchanged lines
    /// between hunks, and above the first and below the last. Called once per file `PatchView`
    /// shows, never for a new, deleted or binary file; return nil when there is no text. The
    /// revealed lines are context rows with both numbers and id `-newLine`, outside
    /// `DiffFind.matches`. A text that does not hold the patch's lines at its headers' numbers
    /// (the file changed since the diff was taken) offers no expansion at all.
    public func patchFileText(_ text: @escaping (FileChange) async -> String?) -> some View {
        environment(\.patchFileText, text)
    }

}

// MARK: - Rows

struct PatchHunkHeader: View {
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

/// Between hunks: how many unchanged lines are hidden, and buttons to reveal them. `edges` are
/// the ends of the gap a step can reveal from: `.top` continues down from the hunk above,
/// `.bottom` up from the hunk below. A gap of one step or less only offers all of it.
struct PatchGapRow: View {
    let hidden: Int
    let size: Double
    let edges: [VerticalEdge]
    let reveal: (VerticalEdge?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if hidden > GapReveal.step {
                ForEach(edges, id: \.self) { edge in
                    Button { reveal(edge) } label: {
                        Image(systemName: edge == .top ? "arrow.down" : "arrow.up")
                    }
                    .help(edge == .top ? "Show \(GapReveal.step) more lines below" : "Show \(GapReveal.step) more lines above")
                    .accessibilityLabel(edge == .top ? "Show \(GapReveal.step) more lines below"
                                                     : "Show \(GapReveal.step) more lines above")
                }
            }
            Button { reveal(nil) } label: {
                // No count yet: the lines after the last hunk, before the file's text is in.
                Label(hidden == 0 ? "Show unchanged lines"
                      : hidden == 1 ? "Show 1 unchanged line" : "Show \(hidden) unchanged lines",
                      systemImage: "arrow.up.and.down")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: size - 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
    }
}

struct PatchLineRow: View {
    let line: DiffLine
    let language: CodeLanguage
    let startState: HighlightState
    let emphasis: [Range<Int>]
    let size: Double
    let wrap: Bool
    let gutter: Gutter

    /// Which line number the gutter shows: unified shows the new file's, falling back to the
    /// old, and no more — on a phone the numbers are orientation, not something you read.
    /// Each split half shows its own side's, with no marker beside it.
    /// `.both` is unified with the old number and the new side by side, for a desktop reader
    /// who does read them.
    enum Gutter { case unified, both, old, new }

    @Environment(\.patchTheme) private var theme
    @Environment(\.patchLineTap) private var onTap
    @Environment(\.patchSelection) private var selection
    @Environment(\.patchCurrentChange) private var currentChange
    @Environment(\.patchLineAccessory) private var accessory
    @Environment(\.patchFind) private var find
    @Environment(\.patchLineTapTarget) private var tapTarget
    @Environment(\.patchLineHover) private var hover
    @State private var hovering = false

    var body: some View {
        if let onTap, tapTarget == .row {
            // Only with a handler: an idle tap gesture would still compete with scrolling
            // and with text selection.
            row.contentShape(Rectangle()).onTapGesture { onTap(line) }
        } else {
            row
        }
    }

    /// The hover view, and the accessory of an unwrapped row, overlaid at the *visible* right
    /// edge. An unwrapped row is as wide as the file's longest line, so its own trailing edge
    /// is off screen whenever that line is wider than the view — which is where the + and the
    /// thread count used to be drawn. `inset` changes only on a sideways scroll.
    ///
    /// The pointer is tracked outside the overlay, so moving onto the + keeps the row hovered.
    /// Inside it, the + took the pointer from the row: exit, the + went, entry, the + came
    /// back — a + that blinked under the pointer. Tracked only when there is a hover view: an
    /// idle `onHover` on every row of a long diff is a tracking area each, for nothing.
    private struct TrailingChrome: ViewModifier {
        let accessory: AnyView?
        /// Built only for the row under the pointer. Built for every row on every render, it
        /// made each row depend on whatever the host's hover view reads — and a host whose +
        /// waits out a scroll re-rendered every row of the page as each scroll began and ended.
        let hover: (() -> AnyView)?
        @Binding var hovering: Bool
        @State private var inset: CGFloat = 0

        func body(content: Content) -> some View {
            if accessory == nil && hover == nil {
                content
            } else if hover != nil {
                pinned(content).onHover { hovering = $0 }
            } else {
                pinned(content)
            }
        }

        private func pinned(_ content: Content) -> some View {
            content
                .overlay(alignment: .trailing) {
                    HStack(spacing: 4) {
                        accessory?.fixedSize()
                        if hovering, let hover { hover() }
                    }
                    .padding(.trailing, 6 + inset)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    PatchLineRow.overhang(width: proxy.size.width,
                                          visibleMaxX: proxy.bounds(of: .scrollView)?.maxX)
                } action: { inset = $0 }
        }
    }

    /// How far a row runs past the scroll view's visible right edge, in the row's own
    /// coordinates. Zero when the edge is beyond the row or there is no scroll view.
    static func overhang(width: CGFloat, visibleMaxX: CGFloat?) -> CGFloat {
        max(0, width - (visibleMaxX ?? width))
    }

    /// A split context row is the same line on both halves; its accessory and hover view — a
    /// comment count, a + — are drawn once, on the right, where `commentAnchor` puts a new
    /// comment.
    static func ownsLineChrome(_ line: DiffLine, gutter: Gutter) -> Bool {
        !(gutter == .old && line.kind != .deletion)
    }

    private func numberText(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: size - 2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: max(28, size * 2.6), alignment: .trailing)
    }

    @ViewBuilder
    private var gutterView: some View {
        let number = Group {
            if gutter == .both {
                HStack(spacing: 4) {
                    numberText(line.oldLineNumber)
                    numberText(line.newLineNumber)
                }
            } else {
                numberText(gutterNumber)
            }
        }
        if let onTap, tapTarget == .gutter {
            number.contentShape(Rectangle()).onTapGesture { onTap(line) }
        } else {
            number
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 6) {
            gutterView

            // fixedSize, or the widest row in the file loses its marker: the HStack hands the
            // leftover width to its flexible children, and on the row that fills the whole
            // scrollable width there is none left, so the +/- is squeezed to nothing.
            if gutter == .unified || gutter == .both {
                Text(marker)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(markerColor)
                    .fixedSize()
            }

            // Only the code is selectable, so a copy never drags along gutters or markers.
            Text(highlighted)
                .font(.system(size: size, design: .monospaced))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: wrap)
                .textSelection(.enabled)

            // Wrapped, the code fills the visible width and this lands at its right edge.
            // Unwrapped it would land after the line's end, so `TrailingChrome` draws it.
            if wrap, let accessory { accessory(line).fixedSize() }
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        // maxHeight before the tint: in a split row the half beside a wrapped line is stretched
        // to its height, and a tint applied first stopped at this line's own height. In a
        // single column nothing proposes a height, so a row stays its natural size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay { if selection.contains(line.id) { theme.selection.allowsHitTesting(false) } }
        .overlay(alignment: .leading) {
            if currentChange.contains(line.id) {
                theme.currentChange.frame(width: 3).allowsHitTesting(false)
            }
        }
        .modifier(TrailingChrome(accessory: wrap ? nil : accessory?(line),
                                 hover: hover.map { build in { build(line) } },
                                 hovering: $hovering))
    }

    /// The one number a single column shows; `.both` draws its own pair.
    private var gutterNumber: Int? {
        switch gutter {
        case .unified, .both: return line.newLineNumber ?? line.oldLineNumber
        case .old: return line.oldLineNumber
        case .new: return line.newLineNumber
        }
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
        func paint(_ range: Range<Int>, _ color: Color, text foreground: Color? = nil) {
            guard range.upperBound <= count else { return }
            let lower = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            let upper = text.characters.index(lower, offsetBy: range.count)
            text[lower..<upper].backgroundColor = color
            if let foreground { text[lower..<upper].foregroundColor = foreground }
        }
        for range in emphasis { paint(range, tint) }
        // After the emphasis, so a match inside a changed word still shows as a match. Searched
        // per visible row rather than looked up: the rows are lazy, and one line is cheap.
        for range in DiffFind.ranges(in: line.text, query: find.query) {
            let isCurrent = find.current?.lineID == line.id && find.current?.range == range
            paint(range, isCurrent ? theme.findCurrent : theme.findMatch,
                  text: isCurrent ? theme.findCurrentText : nil)
        }
        return text
    }
}

// MARK: - Self check

extension PatchView {
    /// Checks the part of the view that is logic: which placeholder a file gets and which
    /// characters are emphasised. Rendering itself is not checked.
    @_spi(Testing) public static func demo() {
        // A rebuilt view starts from the cache: the same file hits, a changed patch or the other
        // whitespace setting misses, and the oldest goes once it is full.
        let cache = PatchCache()
        let cached = FileChange(path: "c.swift", status: .modified, additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b")
        cache.store(PatchModel(file: cached))
        assert(cache.model(for: cached, hidesWhitespaceChanges: false) != nil)
        var pushed = cached
        pushed.patch = "@@ -1 +1 @@\n-a\n+c"
        assert(cache.model(for: pushed, hidesWhitespaceChanges: false) == nil, "a changed patch misses")
        assert(cache.model(for: cached, hidesWhitespaceChanges: true) == nil)
        // Stored again, a file goes to the back of the queue: built most recently, kept longest.
        for i in 0..<PatchCache.capacity - 1 {
            cache.store(PatchModel(file: FileChange(path: "f\(i)", status: .modified, additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+x")))
        }
        cache.store(PatchModel(file: cached))
        cache.store(PatchModel(file: FileChange(path: "one-more", status: .modified, additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+x")))
        assert(cache.model(for: cached, hidesWhitespaceChanges: false) != nil, "re-stored, not the oldest")
        for i in 0..<PatchCache.capacity {
            cache.store(PatchModel(file: FileChange(path: "g\(i)", status: .modified, additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+x")))
        }
        assert(cache.model(for: cached, hidesWhitespaceChanges: false) == nil, "the oldest goes")
        // The unchanged lines a stacked file reserves before its text arrives: from the headers,
        // above the first hunk and between hunks, and nothing after the last.
        let twoHunks = DiffParser.parse("@@ -1,3 +5,3 @@\n a\n-b\n+c\n d\n@@ -10,2 +20,2 @@\n-e\n+f\n g")
        assert(knownGap(0, in: twoHunks) == 4, "\(String(describing: knownGap(0, in: twoHunks)))")
        assert(knownGap(1, in: twoHunks) == 12, "\(String(describing: knownGap(1, in: twoHunks)))")
        assert(knownGap(2, in: twoHunks) == nil)
        assert(knownGap(0, in: DiffParser.parse("@@ -1,2 +1,2 @@\n-a\n+b\n c")) == 0)
        func content(_ f: FileChange) -> String {
            switch PatchModel(file: f).content {
            case .diff(let p): return p.isTruncated ? "truncated" : "diff"
            case .binary: return "binary"
            case .noPatch: return "noPatch"
            case .empty: return "empty"
            case .whitespaceOnly: return "whitespaceOnly"
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

        // Hiding whitespace drops a pair that differs only in indentation, both halves, and
        // keeps a real edit beside it; a file whose every edit is whitespace says so.
        let mixed = file("@@ -1,3 +1,3 @@\n keep\n-  indented\n-let a = 1\n+    indented\n+let a = 2")
        guard case .diff(let shown) = PatchModel(file: mixed, hidesWhitespaceChanges: true).content else {
            return assert(false, "a real edit survives hiding whitespace")
        }
        assert(shown.hunks[0].lines.map(\.text) == ["keep", "let a = 1", "let a = 2"],
               "\(shown.hunks[0].lines.map(\.text))")
        guard case .diff(let all) = PatchModel(file: mixed).content else { return assert(false) }
        assert(all.hunks[0].lines.count == 5, "shown in full when not hiding")
        assert(content(file("@@ -1 +1 @@\n-  a\n+a")) == "diff")
        let reindented = PatchModel(file: file("@@ -1,2 +1,2 @@\n ctx\n-  a\n+a"), hidesWhitespaceChanges: true)
        if case .whitespaceOnly = reindented.content {} else {
            assert(false, "only whitespace changed, so nothing is left to show")
        }

        // Split rows pair each deletion with its replacement and pad the longer side; every
        // line, including a context line that sits on both sides, maps to the row it is in.
        let split = PatchModel(file: file("@@ -1,3 +1,4 @@\n ctx\n-old\n+new\n+more\n tail"))
        guard case .diff(let sp) = split.content else { return assert(false) }
        let sl = sp.hunks[0].lines
        let rows = split.splitRows[0]
        assert(rows.map { [$0.left?.text, $0.right?.text] }
               == [["ctx", "ctx"], ["old", "new"], [nil, "more"], ["tail", "tail"]], "\(rows)")
        assert(Set(rows.map(\.id)).count == rows.count, "row ids are unique")
        assert(split.splitRowID[sl[1].id] == rows[1].id && split.splitRowID[sl[2].id] == rows[1].id,
               "both halves of a pair scroll to the same row")
        assert(split.splitRowID[sl[3].id] == rows[2].id, "an unpaired addition has its own row")
        assert(sl.allSatisfy { split.splitRowID[$0.id] != nil }, "every line is in some row")
        assert(split.splitRows.count == sp.hunks.count, "one array per hunk")
        assert(PatchModel(file: file(nil)).splitRows.isEmpty)
        // Rows with nothing on the right — deletions with no replacement — still get ids of
        // their own: named for the right side alone, they would all collide.
        let shrunk = PatchModel(file: file("@@ -1,3 +1,1 @@\n-a\n-b\n-c\n+d")).splitRows[0]
        assert(shrunk.count == 3 && Set(shrunk.map(\.id)).count == 3, "\(shrunk.map(\.id))")

        // A split context row's accessory is drawn on the right half only; a deletion's on the
        // left, where it is the only line; unified always.
        let ctx = DiffLine(id: 0, kind: .context, oldLine: 1, newLine: 1, text: "x")
        let del = DiffLine(id: 1, kind: .deletion, oldLine: 2, newLine: nil, text: "y")
        assert(!PatchLineRow.ownsLineChrome(ctx, gutter: .old), "accessory and hover drawn once, not on both halves")
        assert(PatchLineRow.ownsLineChrome(ctx, gutter: .new))
        assert(PatchLineRow.ownsLineChrome(del, gutter: .old))
        assert(PatchLineRow.ownsLineChrome(ctx, gutter: .unified))

        // A 2000-point row in a 400-point view: the chrome sits 1600 in from the row's end, so
        // on screen. Scrolled 300 right, 1300. A row narrower than the view needs no inset.
        assert(PatchLineRow.overhang(width: 2000, visibleMaxX: 400) == 1600, "chrome drawn past the visible edge")
        assert(PatchLineRow.overhang(width: 2000, visibleMaxX: 700) == 1300)
        assert(PatchLineRow.overhang(width: 300, visibleMaxX: 400) == 0)
        assert(PatchLineRow.overhang(width: 300, visibleMaxX: nil) == 0)

        // Asking for the same row twice is two requests, so the second still scrolls.
        assert(PatchScrollTarget(lineID: 7) != PatchScrollTarget(lineID: 7))
        assert(PatchScrollTarget.rowID(7) == "patch-line-7")
    }
}
