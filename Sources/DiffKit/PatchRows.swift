import SwiftUI

// MARK: - A file on a host's page

/// One file's diff for a host that lays a whole pull request out as one page: the built model,
/// the unchanged lines around its hunks, and which of them the reader revealed. The host keeps
/// one per file for as long as the page shows it; the rows (`PatchRows`) come and go with the
/// page's laziness, and this does not.
@Observable
public final class PatchFile {
    public let file: FileChange
    public let hidesWhitespaceChanges: Bool
    private(set) var model: PatchModel? { didSet { version += 1 } }
    private(set) var expansion: PatchExpansion? { didSet { version += 1 } }
    private(set) var revealed: [Int: GapReveal] = [:] { didSet { version += 1 } }
    /// The text was asked for and has arrived, or failed: from here a reserved unchanged-line
    /// row that found nothing to show is kept as blank space.
    private(set) var expansionSettled = false { didSet { version += 1 } }
    /// Bumped by every change the rows show, so `items` is worked out once per change rather
    /// than once per redraw of the page.
    private var version = 0
    @ObservationIgnored private var itemsCache: (version: Int, layout: PatchLayout, reserves: Bool, items: [PatchRows.Item])?
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var fetching: Task<Void, Never>?
    /// Rows of this file on screen. The text is fetched while there are any, and a fetch still
    /// waiting when the last one goes is cancelled: a file only flicked past fetches nothing.
    @ObservationIgnored private var rowsOnScreen = 0

    public init(file: FileChange, hidesWhitespaceChanges: Bool = false) {
        self.file = file
        self.hidesWhitespaceChanges = hidesWhitespaceChanges
        // Built before: start from it, so the first frame has the rows, at their final height.
        model = PatchCache.shared.model(for: file, hidesWhitespaceChanges: hidesWhitespaceChanges)
    }

    /// The patch as the rows show it, whitespace-only edits gone when hidden. nil until built,
    /// and for a file with no text diff.
    public var parsed: ParsedDiff? {
        if case .diff(let parsed)? = model?.content { return parsed }
        return nil
    }

    /// The rows, top to bottom, for a host that lays every file's rows into one `ForEach` of its
    /// own (draw each with `PatchRow`). `reservesGaps`: the host gives `.patchFileText`, so room
    /// for the unchanged lines is held before the text arrives. Observed: a host reading it is
    /// redrawn when the rows change.
    public func items(layout: PatchLayout, reservesGaps: Bool) -> [PatchRows.Item] {
        if let cache = itemsCache, cache.version == version, cache.layout == layout, cache.reserves == reservesGaps {
            return cache.items
        }
        let made = PatchRows.items(model: model, expansion: expansion, revealed: revealed,
                                   settled: expansionSettled, layout: layout, reservesGaps: reservesGaps)
        itemsCache = (version, layout, reservesGaps, made)
        return made
    }

    /// The page's id for the row that shows `lineID`: in split view a row holds two lines.
    public func itemID(forLine lineID: Int, layout: PatchLayout) -> String? {
        let local = layout == .split ? model?.splitRowID[lineID] : PatchScrollTarget.rowID(lineID)
        return local.map { PatchRows.itemID(file.path, $0) }
    }

    @MainActor func rowAppeared(text: ((FileChange) async -> String?)?) {
        rowsOnScreen += 1
        build()
        if let text { requestExpansion(text) }
    }

    @MainActor func rowDisappeared() {
        rowsOnScreen = max(0, rowsOnScreen - 1)
        guard rowsOnScreen == 0, !expansionSettled else { return }
        fetching?.cancel()
        fetching = nil
    }

    /// Builds the model if it is not built, and returns once it is: for a host that must know
    /// the rows — to land on a change — before they have come on screen.
    @MainActor public func built() async {
        build()
        let task = building
        await task?.value
    }

    /// Builds the model off the main actor, once.
    @MainActor private func build() {
        guard model == nil, building == nil else { return }
        let file = file, hides = hidesWhitespaceChanges
        building = Task {
            let built = await Task.detached(priority: .userInitiated) {
                PatchModel(file: file, hidesWhitespaceChanges: hides)
            }.value
            model = built
            PatchCache.shared.store(built)
            // Rows were waiting on the model; ask for the text now they can use it.
            building = nil
        }
    }

    /// Fetches the new side's text for the unchanged lines around the hunks. The host's `text`
    /// can wait before fetching; cancelled meanwhile, it returns nil and nothing is fetched.
    @MainActor private func requestExpansion(_ text: @escaping (FileChange) async -> String?) {
        guard !expansionSettled, fetching == nil, let model else { return }
        guard PatchExpansion.expandable(model) != nil else {
            expansionSettled = true
            return
        }
        let file = file
        fetching = Task {
            let fetched = await text(file)
            guard !Task.isCancelled else { return }
            let expanded: PatchExpansion?
            if let fetched {
                expanded = await Task.detached(priority: .userInitiated) {
                    PatchExpansion(model: model, text: fetched)
                }.value
            } else {
                expanded = nil
            }
            expansion = expanded
            expansionSettled = true
            fetching = nil
        }
    }

    @MainActor func reveal(gap index: Int, edge: VerticalEdge?) {
        guard let lines = expansion?.gaps[index] else { return }
        revealed[index, default: GapReveal()].reveal(edge, of: lines.count)
    }
}

// MARK: - Its rows

/// A `PatchFile`'s rows as items of the host's own lazy stack, not a view of their own: only the
/// rows on screen are built and laid out, however long the page. Put it straight inside the
/// host's `LazyVStack` (directly, or as one of several views a `ForEach` element gives):
///
///     ScrollViewReader { proxy in
///         ScrollView {
///             LazyVStack(alignment: .leading, spacing: 0) {
///                 ForEach(files) { file in
///                     MyFileHeader(file).id(PatchRows.itemID(file.path, "header"))
///                     PatchRows(patchFiles[file.path], codeSize: 12)
///                 }
///             }
///             .scrollTargetLayout()   // or `.patchPagePosition` reports nothing
///         }
///         .patchPagePosition(position) { path in /* the file at the top changed */ }
///     }
///
/// A host listing every file's rows in one `ForEach` of its own uses `PatchFile.items` and draws
/// each with `PatchRow` instead: a lazy stack places one flat list more cheaply than a list of
/// per-file lists.
///
/// Every row's id is `PatchRows.itemID(path, …)`, so `proxy.scrollTo` reaches any of them;
/// `PatchFile.itemID(forLine:layout:)` names the row for a line. The hooks work as they do on
/// `PatchView` — set the row-keyed ones (`.patchSelection`, `.patchCurrentChange`, `.patchFind`'s
/// `current`) on each file's `PatchRows`, since line ids restart in every file. Scrolling is the
/// host's: `.patchScrollTarget` does nothing here.
///
/// Unwrapped, long lines need the page to scroll sideways: put the stack in a two-axis
/// `ScrollView` and give it a width of at least `PatchRows.width(of:…)` for each file. Give
/// `.patchViewportWidth(_:)` the visible width, so what hangs under a line stays readable
/// without scrolling sideways.
public struct PatchRows: View {
    let patch: PatchFile
    let codeSize: Double
    let wrap: Bool
    let highlightsSyntax: Bool

    @Environment(\.patchLayout) private var layout
    @Environment(\.patchFileText) private var fileText

    public init(_ patch: PatchFile, codeSize: Double = 12, wrap: Bool = false, highlightsSyntax: Bool = true) {
        self.patch = patch
        self.codeSize = codeSize
        self.wrap = wrap
        self.highlightsSyntax = highlightsSyntax
    }

    /// A row's id on the page: its file's path, then its own.
    public static func itemID(_ path: String, _ local: String) -> String { "\(path)\n\(local)" }

    /// The file an `itemID` belongs to.
    /// Split at the last newline: a row's own id never has one, and git allows them in a path.
    public static func path(ofItem id: String) -> String {
        id.lastIndex(of: "\n").map { String(id[..<$0]) } ?? id
    }

    public var body: some View {
        let path = patch.file.path
        ForEach(patch.items(layout: layout, reservesGaps: fileText != nil), id: \.id) { item in
            PatchRow(item, of: patch, codeSize: codeSize, wrap: wrap, highlightsSyntax: highlightsSyntax)
                .id(Self.itemID(path, item.id))
        }
    }

    // MARK: Items

    /// One row of a file: what `PatchFile.items` lists and `PatchRow` draws.
    public enum Item {
        case loading
        case placeholder(title: String, symbol: String, detail: String)
        case hunkHeader(Hunk)
        case line(DiffLine)
        case pair(SplitRow)
        /// Unchanged lines left to reveal before hunk `index`. `live` false: reserved before the
        /// text arrives, inert, with the count the headers give (0 when they give none).
        case gapRow(index: Int, hidden: Int, edges: [VerticalEdge], live: Bool)
        /// A reserved row that found nothing to show, kept as blank space so nothing moves.
        case gapSpace(index: Int)
        case truncated

        /// Unique within its file; `PatchRows.itemID(path, id)` makes it unique on a page.
        public var id: String {
            switch self {
            case .loading: "loading"
            case .placeholder: "placeholder"
            case .hunkHeader(let hunk): "hunk-\(hunk.id)"
            case .line(let line): PatchScrollTarget.rowID(line.id)
            case .pair(let pair): pair.id
            case .gapRow(let index, _, _, _), .gapSpace(let index): "gap-\(index)"
            case .truncated: "truncated"
            }
        }
    }

    /// The rows, top to bottom. Pure, so the self-check covers it.
    static func items(model: PatchModel?, expansion: PatchExpansion?, revealed: [Int: GapReveal],
                      settled: Bool, layout: PatchLayout, reservesGaps: Bool) -> [Item] {
        guard let model else { return [.loading] }
        switch model.content {
        case .binary:
            return [.placeholder(title: "Binary file", symbol: "doc.zipper",
                                 detail: "This file is binary, so there is no text diff.")]
        case .noPatch:
            return [.placeholder(title: "No diff to show", symbol: "doc.questionmark",
                                 detail: "The patch was not sent, usually because the file is too large.")]
        case .empty:
            return [.placeholder(title: "No content changes", symbol: "doc",
                                 detail: "Only the file's name, mode or existence changed.")]
        case .whitespaceOnly:
            return [.placeholder(title: "Only whitespace changed", symbol: "text.alignleft",
                                 detail: "Every change in this file is whitespace, which is hidden.")]
        case .diff(let parsed):
            let current = expansion.flatMap {
                $0.file == model.file && $0.hidesWhitespaceChanges == model.hidesWhitespaceChanges ? $0 : nil
            }
            let reserves = reservesGaps && PatchExpansion.expandable(model) != nil
            var out: [Item] = []
            func unchanged(_ line: DiffLine) -> Item {
                layout == .split ? .pair(SplitRow(left: line, right: line)) : .line(line)
            }
            func gap(_ index: Int) {
                // Above the first hunk only upwards makes sense, below the last only downwards.
                let edges: [VerticalEdge] = (index > 0 ? [.top] : []) + (index < parsed.hunks.count ? [.bottom] : [])
                if let lines = current?.gaps[index], !lines.isEmpty {
                    let shown = revealed[index] ?? GapReveal()
                    let hidden = shown.hidden(of: lines.count)
                    out += lines.prefix(shown.top).map(unchanged)
                    if hidden > 0 { out.append(.gapRow(index: index, hidden: hidden, edges: edges, live: true)) }
                    out += lines.suffix(shown.bottom).map(unchanged)
                } else if reserves, index == parsed.hunks.count || (PatchView.knownGap(index, in: parsed) ?? 0) > 0 {
                    // Held from the first draw, so the text arriving moves nothing: inert until
                    // then, and blank space if it brought nothing to show.
                    out.append(settled ? .gapSpace(index: index)
                               : .gapRow(index: index, hidden: PatchView.knownGap(index, in: parsed) ?? 0,
                                         edges: edges, live: false))
                }
            }
            for (index, hunk) in parsed.hunks.enumerated() {
                gap(index)
                out.append(.hunkHeader(hunk))
                if layout == .split {
                    out += model.splitRows[index].map(Item.pair)
                } else {
                    out += hunk.lines.map(Item.line)
                }
            }
            gap(parsed.hunks.count)
            if parsed.isTruncated { out.append(.truncated) }
            return out
        }
    }

    // MARK: Measures
}

// MARK: - One row

/// One of a `PatchFile`'s rows, for a host whose own `ForEach` lists every file's rows
/// (`PatchFile.items`) rather than nesting a `PatchRows` per file: one flat list is cheaper for
/// a lazy stack to place than a list of lists. Give it the id `PatchRows.itemID(path, item.id)`.
/// The hooks work as on `PatchRows`.
public struct PatchRow: View {
    let item: PatchRows.Item
    let patch: PatchFile
    let codeSize: Double
    let wrap: Bool
    let highlightsSyntax: Bool

    @Environment(\.patchLineNumbers) private var lineNumbers
    @Environment(\.patchLineAccessory) private var accessory
    @Environment(\.patchLineHover) private var hover
    @Environment(\.patchLineAttachment) private var attachment
    @Environment(\.patchFileText) private var fileText
    @Environment(\.patchViewportWidth) private var viewportWidth

    public init(_ item: PatchRows.Item, of patch: PatchFile, codeSize: Double = 12, wrap: Bool = false,
                highlightsSyntax: Bool = true) {
        self.item = item
        self.patch = patch
        self.codeSize = codeSize
        self.wrap = wrap
        self.highlightsSyntax = highlightsSyntax
    }

    public var body: some View {
        row(item)
            .onAppear { patch.rowAppeared(text: fileText) }
            .onDisappear { patch.rowDisappeared() }
    }

    @ViewBuilder
    private func row(_ item: PatchRows.Item) -> some View {
        switch item {
        case .loading:
            // About the height the rows will take, so the page's estimate barely moves.
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: PatchRows.estimatedHeight(of: patch.file, codeSize: codeSize), alignment: .top)
        case .placeholder(let title, let symbol, let detail):
            ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        case .hunkHeader(let hunk):
            PatchHunkHeader(hunk: hunk, size: codeSize)
        case .line(let line):
            withAttachments(line.threadAnchors) {
                lineRow(line, gutter: lineNumbers == .both ? .both : .unified)
            }
        case .pair(let pair):
            withAttachments([pair.left, pair.right].compactMap { $0 }.threadAnchors) {
                splitRow(pair)
            }
        case .gapRow(let index, let hidden, let edges, let live):
            PatchGapRow(hidden: hidden, size: codeSize, edges: edges) { edge in
                patch.reveal(gap: index, edge: edge)
            }
            .disabled(!live)
        case .gapSpace(let index):
            PatchGapRow(hidden: 0, size: codeSize, edges: index > 0 ? [.top] : []) { _ in }
                .disabled(true)
                .hidden()
        case .truncated:
            Label("This diff was cut short after \(DiffParser.maxLines) lines.", systemImage: "scissors")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    // The same rows `PatchView` draws, from this file's model; kept in step with its helpers.

    private func lineRow(_ line: DiffLine, gutter: PatchLineRow.Gutter) -> PatchLineRow {
        let model = patch.model
        return PatchLineRow(line: line, language: highlightsSyntax ? model?.language ?? .plaintext : .plaintext,
                            startState: model?.highlightStates[line.id] ?? patch.expansion?.highlightStates[line.id]
                                ?? HighlightState(),
                            emphasis: model?.emphasis[line.id] ?? [],
                            size: codeSize, wrap: wrap, gutter: gutter)
    }

    /// A row with the host's attachments under it, held to the visible width.
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

    /// Old on the left, new on the right, halves of the page's width.
    private func splitRow(_ pair: SplitRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitHalf(pair.left, gutter: .old)
            Divider()
            splitHalf(pair.right, gutter: .new)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func splitHalf(_ line: DiffLine?, gutter: PatchLineRow.Gutter) -> some View {
        Group {
            if let line {
                lineRow(line, gutter: gutter)
                    .environment(\.patchLineAccessory,
                                 PatchLineRow.ownsLineChrome(line, gutter: gutter) ? accessory : nil)
                    .environment(\.patchLineHover,
                                 PatchLineRow.ownsLineChrome(line, gutter: gutter) ? hover : nil)
            } else {
                // Opposite an unpaired insertion or deletion: a fill, never a blank hole.
                Color.secondary.opacity(0.07)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension PatchRows {
    /// About the height a file's rows take before its model exists: one row per patch line.
    public static func estimatedHeight(of file: FileChange, codeSize: Double) -> CGFloat {
        let lines = min(file.patch?.utf8.lazy.filter { $0 == UInt8(ascii: "\n") }.count ?? 0, DiffParser.maxLines)
        return max(60, CGFloat(lines + 1) * codeSize * 1.4)
    }

    /// The width a file's longest patch line needs unwrapped, counted from the patch text rather
    /// than laid out: the code is monospaced. Unchanged lines revealed later can be longer and
    /// clip; a host that minds can widen by `PatchFile` once expanded.
    public static func width(of file: FileChange, codeSize: Double, lineNumbers: PatchLineNumbers,
                             layout: PatchLayout) -> CGFloat {
        var longest = 0, current = 0
        for byte in (file.patch ?? "").utf8 {
            if byte == UInt8(ascii: "\n") {
                longest = max(longest, current)
                current = 0
            } else if byte & 0xC0 != 0x80 {
                current += 1   // one per character, not per UTF-8 byte
            }
        }
        longest = max(longest, current)
        let advance = codeSize * 0.6
        let columns: CGFloat = lineNumbers == .both && layout == .unified ? 2 : 1
        let gutter = max(28, codeSize * 2.6) * columns
        let one = gutter + 20 + advance + Double(longest + 1) * advance
        return layout == .split ? one * 2 : one
    }

    @_spi(Testing) public static func demo() {
        let patch = "@@ -1,3 +5,3 @@\n a\n-b\n+c\n d\n@@ -10,2 +20,2 @@\n-e\n+f\n g"
        let file = FileChange(path: "x.swift", status: .modified, additions: 2, deletions: 2, patch: patch)
        let model = PatchModel(file: file)
        func ids(_ items: [Item]) -> [String] { items.map(\.id) }
        // Unbuilt: one loading row.
        assert(ids(items(model: nil, expansion: nil, revealed: [:], settled: false, layout: .unified,
                         reservesGaps: true)) == ["loading"])
        // Before the text: a reserved row above each hunk the headers count lines before, and
        // after the last; hunk headers and lines in order.
        let waiting = items(model: model, expansion: nil, revealed: [:], settled: false, layout: .unified,
                            reservesGaps: true)
        let lineIDs = DiffParser.parse(patch).hunks.flatMap(\.lines).map { PatchScrollTarget.rowID($0.id) }
        assert(ids(waiting).first == "gap-0" && ids(waiting).last == "gap-2", "\(ids(waiting))")
        assert(ids(waiting).filter { $0.hasPrefix("patch-line-") } == lineIDs)
        if case .gapRow(_, let hidden, _, let live)? = waiting.first { assert(hidden == 4 && !live) } else { assert(false) }
        // Settled with nothing to show: the same places, kept as space, so nothing moves.
        let settled = items(model: model, expansion: nil, revealed: [:], settled: true, layout: .unified,
                            reservesGaps: true)
        assert(ids(settled) == ids(waiting))
        if case .gapSpace? = settled.first {} else { assert(false, "kept as space") }
        // A host with no text reserves nothing.
        assert(!ids(items(model: model, expansion: nil, revealed: [:], settled: false, layout: .unified,
                          reservesGaps: false)).contains { $0.hasPrefix("gap-") })
        // Split: pairs, not lines.
        let split = items(model: model, expansion: nil, revealed: [:], settled: false, layout: .split,
                          reservesGaps: false)
        assert(split.contains { if case .pair = $0 { true } else { false } }
               && !split.contains { if case .line = $0 { true } else { false } })
        // A PatchFile's cached items follow the layout asked for, not the first one asked.
        let cached = FileChange(path: "cache-check.swift", status: .modified, additions: 2, deletions: 2, patch: patch)
        PatchCache.shared.store(PatchModel(file: cached))
        let held = PatchFile(file: cached)
        let unified = ids(held.items(layout: .unified, reservesGaps: false))
        assert(unified == ids(items(model: PatchModel(file: cached), expansion: nil, revealed: [:], settled: false,
                                    layout: .unified, reservesGaps: false)))
        assert(ids(held.items(layout: .split, reservesGaps: false)) != unified, "recomputed for split")
        assert(ids(held.items(layout: .unified, reservesGaps: true)) != unified, "recomputed for reserving")
        // Page ids carry the path, and give it back.
        assert(path(ofItem: itemID("a/b.swift", "patch-line-3")) == "a/b.swift")
        assert(path(ofItem: itemID("odd\nname", "header")) == "odd\nname", "a newline in the path")
        // Width: the longest patch line, counted in characters, doubled for split.
        let wide = FileChange(path: "w", status: .modified, additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+é" + String(repeating: "x", count: 99))
        let w = width(of: wide, codeSize: 10, lineNumbers: .one, layout: .unified)
        // 101 characters ("+", "é" and 99 x), plus one of slack.
        assert(abs(w - (28 + 20 + 6 + Double(102) * 6)) < 0.01, "\(w)")
        assert(width(of: wide, codeSize: 10, lineNumbers: .one, layout: .split) == w * 2)
    }
}

private struct PatchViewportWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var patchViewportWidth: CGFloat {
        get { self[PatchViewportWidthKey.self] }
        set { self[PatchViewportWidthKey.self] = newValue }
    }
}

extension View {
    /// The visible width of a page of `PatchRows`, which what hangs under a line is held to.
    public func patchViewportWidth(_ width: CGFloat) -> some View {
        environment(\.patchViewportWidth, width)
    }
}

// MARK: - The page's place

/// The item at the top of a page of `PatchRows`, as `.scrollPosition` reports it. A class, held
/// by the page and read only by `.patchPagePosition`: the binding is written each time a new row
/// reaches the top, and a page whose body read it would be redrawn whole for every row scrolled
/// past. Set `top` to an item's id to jump there (it is held through the rows above changing
/// height), and to nil before a `scrollTo` of a row, which it would otherwise snap back from.
@Observable
public final class PatchPagePosition {
    public var top: String?
    public init() {}
}

extension View {
    /// Tracks the page's top item in `position`, and calls `fileChanged` with the path of the
    /// file it belongs to when that file changes. Put it on the page's `ScrollView`.
    public func patchPagePosition(_ position: PatchPagePosition,
                                  fileChanged: @escaping (String) -> Void) -> some View {
        modifier(PatchPagePositionTracker(position: position, fileChanged: fileChanged))
    }
}

private struct PatchPagePositionTracker: ViewModifier {
    @Bindable var position: PatchPagePosition
    let fileChanged: (String) -> Void
    @State private var path: String?

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: $position.top, anchor: .topLeading)
            .onChange(of: position.top) { _, id in
                // Past the last file, or let go before a row's scroll: no file to name.
                guard let id, id.contains("\n") else { return }
                let now = PatchRows.path(ofItem: id)
                guard now != path else { return }
                path = now
                fileChanged(now)
            }
    }
}
