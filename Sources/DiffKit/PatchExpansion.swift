import SwiftUI

/// The unchanged lines a patch leaves out, read from the new file's full text, so `PatchView`
/// can reveal them around the hunks. Unchanged lines are the same on both sides, so the new
/// text alone gives them, and each hunk header gives the offset to their old numbers.
struct PatchExpansion: Sendable {
    let file: FileChange
    let hidesWhitespaceChanges: Bool
    /// `gaps[i]` is the run before hunk `i`, and the last one is the run after the last hunk;
    /// any can be empty. Context lines with both numbers, and id `-newLine`, so they never
    /// collide with the patch's own ids, which start at 0.
    let gaps: [[DiffLine]]
    /// The highlighter state each gap line starts in, from one walk down the whole new file.
    let highlightStates: [Int: HighlightState]
    /// The longest gap line, in characters, so an unwrapped diff is wide enough to show it.
    let longestLine: Int

    /// nil when there is nothing to expand, or when the text does not hold the patch's lines
    /// where its headers put them: the file changed since the diff was taken, and revealing
    /// from it would show the wrong lines.
    init?(model: PatchModel, text: String) {
        guard let parsed = Self.expandable(model) else { return nil }
        let lines = Self.lines(of: text)
        guard let gaps = Self.gaps(between: parsed.hunks, in: lines) else { return nil }
        file = model.file
        hidesWhitespaceChanges = model.hidesWhitespaceChanges
        self.gaps = gaps
        longestLine = gaps.joined().map(\.text.count).max() ?? 0

        var states: [Int: HighlightState] = [:]
        if model.language != .plaintext {
            let inGap = Set(gaps.joined().map(\.id))
            var state = HighlightState()
            for (index, line) in lines.enumerated() {
                if !state.isClean, inGap.contains(-(index + 1)) { states[-(index + 1)] = state }
                _ = SyntaxHighlighter.tokenize(line, language: model.language, state: &state)
            }
        }
        highlightStates = states
    }

    /// The diff to expand around, or nil when the file has no gaps to fill: a new or deleted
    /// file is one hunk covering the whole file, and a cut-short diff's last hunk is partial.
    static func expandable(_ model: PatchModel) -> ParsedDiff? {
        guard model.file.status != .added, model.file.status != .removed,
              case .diff(let parsed) = model.content, !parsed.isTruncated else { return nil }
        return parsed
    }

    /// Split the way `DiffParser.parse` splits a patch, so a CRLF file compares equal.
    static func lines(of text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map(String.init)
    }

    /// The unchanged runs before, between and after `hunks`, numbered on both sides. nil unless
    /// every context and added line sits at its new number in `lines`, in hunk order.
    static func gaps(between hunks: [Hunk], in lines: [String]) -> [[DiffLine]]? {
        guard !hunks.isEmpty else { return nil }
        func run(_ numbers: Range<Int>, offset: Int) -> [DiffLine] {
            numbers.map { DiffLine(id: -$0, kind: .context, oldLine: $0 + offset, newLine: $0, text: lines[$0 - 1]) }
        }
        var gaps: [[DiffLine]] = []
        // The first new line no hunk has covered yet, and old minus new for an unchanged line there.
        var next = 1, offset = 0
        for hunk in hunks {
            // Starts are the parsed ones, so an empty side's range is empty rather than one short.
            guard hunk.newStart >= next, hunk.newStart + hunk.newCount - 1 <= lines.count else { return nil }
            for line in hunk.lines where line.kind == .context || line.kind == .addition {
                guard let n = line.newLine, (1...lines.count).contains(n), lines[n - 1] == line.text else { return nil }
            }
            gaps.append(run(next..<hunk.newStart, offset: hunk.oldStart - hunk.newStart))
            next = hunk.newStart + hunk.newCount
            offset = hunk.oldStart + hunk.oldCount - next
        }
        gaps.append(run(next..<(lines.count + 1), offset: offset))
        return gaps
    }
}

/// How much of one gap is showing: lines revealed from its top (continuing down from the hunk
/// above) and from its bottom (continuing up from the hunk below).
struct GapReveal: Equatable {
    static let step = 20
    var top = 0
    var bottom = 0

    func hidden(of count: Int) -> Int { max(0, count - top - bottom) }

    /// `step` more lines from that edge, or every hidden line for `nil`.
    mutating func reveal(_ edge: VerticalEdge?, of count: Int) {
        let hidden = hidden(of: count)
        switch edge {
        case .top: top += min(Self.step, hidden)
        case .bottom: bottom += min(Self.step, hidden)
        case nil: top += hidden
        }
    }
}

// MARK: - Self check

extension PatchView {
    /// The gaps `PatchView` reveals, their numbering on both sides, and the check that refuses
    /// a text the patch does not match.
    @_spi(Testing) public static func expansionDemo() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        // An edit at line 5, a line deleted after 11 and one inserted at 20.
        let patch = """
            @@ -4,3 +4,3 @@
             line 4
            -old 5
            +line 5
             line 6
            @@ -11,3 +11,2 @@
             line 11
            -gone
             line 12
            @@ -20,2 +19,3 @@
             line 19
            +line 20
             line 21
            """
        func model(_ patch: String?, status: FileChangeStatus = .modified, hides: Bool = false) -> PatchModel {
            PatchModel(file: FileChange(path: "a.swift", status: status, additions: 0, deletions: 0, patch: patch),
                       hidesWhitespaceChanges: hides)
        }
        guard let e = PatchExpansion(model: model(patch), text: text) else { return assert(false, "a matching text expands") }
        assert(e.gaps.map(\.count) == [3, 4, 6, 9], "\(e.gaps.map(\.count))")
        assert(e.gaps[0].map(\.newLine) == [1, 2, 3] && e.gaps[0].map(\.oldLine) == [1, 2, 3])
        // Between hunks 1 and 2 nothing has shifted; after the deletion, old runs one ahead.
        assert(e.gaps[1].first?.newLine == 7 && e.gaps[1].first?.oldLine == 7)
        assert(e.gaps[2].first?.newLine == 13 && e.gaps[2].first?.oldLine == 14, "\(e.gaps[2][0])")
        assert(e.gaps[2].last?.newLine == 18 && e.gaps[2].last?.oldLine == 19)
        // After the addition the two sides are level again.
        assert(e.gaps[3].first?.newLine == 22 && e.gaps[3].first?.oldLine == 22, "\(e.gaps[3][0])")
        assert(e.gaps[3].last?.newLine == 30 && e.gaps[3].last?.text == "line 30")
        assert(e.gaps.joined().allSatisfy { $0.kind == .context && $0.id == -$0.newLine! })
        assert(e.longestLine == "line 30".count)
        assert(PatchExpansion(model: model(patch), text: text.replacingOccurrences(of: "\n", with: "\r\n")) != nil,
               "CRLF splits the way the patch does")

        // The file changed after the diff: a context line moved, an added line differs, or the
        // file is shorter than the last hunk. No gaps rather than wrong ones.
        let edited = "inserted\n" + text
        assert(PatchExpansion(model: model(patch), text: edited) == nil, "context no longer at its number")
        assert(PatchExpansion(model: model(patch), text: text.replacingOccurrences(of: "line 20\n", with: "line 20!\n")) == nil)
        assert(PatchExpansion(model: model(patch), text: "line 1\n") == nil)

        // Empty sides use the parsed starts: a pure deletion after line 4, a pure insertion after 9.
        let thin = DiffParser.parse("@@ -5,2 +4,0 @@\n-a\n-b\n@@ -12,0 +11,1 @@\n+line 11").hunks
        let lines = (1...12).map { "line \($0)" }
        let tg = PatchExpansion.gaps(between: thin, in: lines)
        assert(tg?.map(\.count) == [4, 6, 1], "\(String(describing: tg?.map(\.count)))")
        assert(tg?[1].first.map { [$0.oldLine, $0.newLine] } == [7, 5], "two deleted lines put old two ahead")
        assert(tg?[2].first.map { [$0.oldLine, $0.newLine] } == [13, 12], "the insertion takes one back")
        assert(PatchExpansion.gaps(between: Array(thin.reversed()), in: lines) == nil, "hunks out of order")

        // New, deleted, binary and cut-short files have nothing to expand.
        assert(PatchExpansion(model: model("@@ -0,0 +1,1 @@\n+line 1", status: .added), text: text) == nil)
        assert(PatchExpansion(model: model("@@ -1,1 +0,0 @@\n-line 1", status: .removed), text: "") == nil)
        assert(PatchExpansion(model: model(nil), text: text) == nil)
        let huge = "@@ -1,\(DiffParser.maxLines + 1) +1,\(DiffParser.maxLines + 1) @@\n"
            + String(repeating: " x\n", count: DiffParser.maxLines + 1)
        assert(PatchExpansion(model: model(huge), text: text) == nil)

        // Hiding whitespace drops a hunk; its lines come back as part of a wider gap.
        let ws = patch + "\n@@ -25,1 +25,1 @@\n-  line 25\n+line 25"
        guard let h = PatchExpansion(model: model(ws, hides: true), text: text) else { return assert(false) }
        assert(h.gaps.count == 4 && h.gaps[3].count == 9, "\(h.gaps.map(\.count))")

        // A block comment opened above a gap still colours the gap.
        let commented = PatchExpansion(model: model("@@ -3,1 +3,1 @@\n-x\n+y"), text: "/* a\nb\ny\nc */\nd\n")
        assert(commented?.highlightStates[-2]?.blockCommentDepth == 1)
        assert(commented?.highlightStates[-4]?.blockCommentDepth == 1)
        assert(commented?.highlightStates[-1] == nil && commented?.highlightStates[-5] == nil)

        // Revealing: 20 at a time from either edge, never past the gap, or all at once.
        var r = GapReveal()
        r.reveal(.top, of: 50)
        r.reveal(.bottom, of: 50)
        assert(r == GapReveal(top: 20, bottom: 20) && r.hidden(of: 50) == 10)
        r.reveal(.top, of: 50)
        assert(r.top == 30 && r.hidden(of: 50) == 0)
        var all = GapReveal(top: 0, bottom: 3)
        all.reveal(nil, of: 50)
        assert(all.hidden(of: 50) == 0)
    }
}
