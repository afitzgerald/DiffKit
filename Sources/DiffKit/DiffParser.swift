import Foundation

// MARK: - Model

/// One rendered row of a unified diff. `oldLine`/`newLine` are 1-based and nil on the side
/// where the row does not exist, which is exactly what the gutter needs.
public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case context, addition, deletion, noNewline, meta
    }

    public var id: Int
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    /// Diff marker already stripped.
    public var text: String

    /// Spelling used by the diff views.
    public var oldLineNumber: Int? { oldLine }
    public var newLineNumber: Int? { newLine }

    public init(id: Int, kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public struct Hunk: Identifiable, Hashable, Sendable {
    public var id: Int { lines.first?.id ?? oldStart &* 1_000_003 &+ newStart }
    /// The verbatim `@@ … @@` line, section heading included.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Trailing section heading after the closing `@@`, nil when the provider emitted none.
    public var sectionHeading: String?
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                sectionHeading: String?, lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }
}

extension Hunk {
    /// Just the `@@ -a,b +c,d @@` part, section heading stripped.
    public var rangeHeader: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

/// The view layer spells it `DiffHunk`.
public typealias DiffHunk = Hunk

public struct ParsedDiff: Hashable, Sendable {
    public var hunks: [Hunk]
    /// True when the patch exceeded `DiffParser.maxLines` and parsing stopped early.
    public var isTruncated: Bool

    public init(hunks: [Hunk], isTruncated: Bool) {
        self.hunks = hunks
        self.isTruncated = isTruncated
    }

    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    public var isEmpty: Bool { hunks.isEmpty }
}

// MARK: - Parser

/// Unified-diff parser. Deliberately hand-rolled: the format is a dozen rules and the only
/// hard part — keeping both line counters honest — is not something a library would do for us.
public enum DiffParser {

    /// Rendering ceiling. Past this a diff is unreadable anyway and SwiftUI list performance
    /// falls off a cliff; `PatchView` shows a "cut short" note instead.
    public static let maxLines = 20_000

    /// Word-diff ceiling for intra-line refinement. Beyond it we highlight the whole changed
    /// span instead. This is a latency guard, not a memory one: `CollectionDifference` is Myers,
    /// so d — not n·m — drives the cost, and memory stays flat (measured ~1MB at this cap, where
    /// the LCS table it replaced allocated 16MB). Time still degrades quadratically once nothing
    /// matches, which is the minified-JS case: measured 0.07s at 2k tokens, 6.4s at 20k. It runs
    /// off the main actor behind a spinner (see `PatchModel.emphasis`), so this buys headroom
    /// rather than frames. Raise it if whole-line emphasis on long lines becomes the annoyance.
    public static let maxInlineTokens = 2_000

    public static func parse(_ patch: String) -> ParsedDiff {
        var hunks: [Hunk] = []
        var truncated = false
        var nextID = 0

        var header = ""
        var heading: String?
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var oldNo = 0, newNo = 0
        var lines: [DiffLine] = []
        var inHunk = false

        func flush() {
            guard inHunk else { return }
            hunks.append(Hunk(header: header, oldStart: oldStart, oldCount: oldCount,
                              newStart: newStart, newCount: newCount,
                              sectionHeading: heading, lines: lines))
            lines = []
            inHunk = false
        }

        // Swift treats CRLF as one Character, so splitting on `isNewline` handles CRLF, LF
        // and lone-CR patches without a normalising copy of the whole patch.
        var rawLines = patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A newline-terminated patch leaves one empty trailing element, which would otherwise
        // render as a numbered blank context line.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }

        for rawLine in rawLines {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                flush()
                guard let h = parseHunkHeader(line) else { continue }
                header = line
                (oldStart, oldCount, newStart, newCount, heading) = h
                oldNo = oldStart
                newNo = newStart
                inHunk = true
                continue
            }

            guard inHunk else { continue }   // file headers between hunks: nothing to render

            if nextID >= maxLines {
                truncated = true
                break
            }

            let marker = line.first
            let body = line.isEmpty ? "" : String(line.dropFirst())

            switch marker {
            case "+":
                lines.append(DiffLine(id: nextID, kind: .addition, oldLine: nil, newLine: newNo, text: body))
                newNo += 1
            case "-":
                lines.append(DiffLine(id: nextID, kind: .deletion, oldLine: oldNo, newLine: nil, text: body))
                oldNo += 1
            case "\\":
                // "\ No newline at end of file" — belongs to the previous line, consumes no number.
                lines.append(DiffLine(id: nextID, kind: .noNewline, oldLine: nil, newLine: nil,
                                      text: body.trimmingCharacters(in: .whitespaces)))
            case " ", nil:
                // A bare empty line is an empty context line; some forges strip the marker.
                lines.append(DiffLine(id: nextID, kind: .context, oldLine: oldNo, newLine: newNo, text: body))
                oldNo += 1
                newNo += 1
            default:
                // "diff --git", "index …", "--- a/x", "+++ b/x" handled above by the +/- cases
                // for the last two; anything else inside a hunk is a provider annotation.
                lines.append(DiffLine(id: nextID, kind: .meta, oldLine: nil, newLine: nil, text: line))
            }
            nextID += 1
        }
        flush()
        return ParsedDiff(hunks: hunks, isTruncated: truncated)
    }

    /// `@@ -12,7 +12,9 @@ func thing() {` → counts default to 1 when omitted, per POSIX.
    static func parseHunkHeader(_ line: String) -> (Int, Int, Int, Int, String?)? {
        // strip leading "@@" run (combined diffs use "@@@"), then split at the closing run
        var rest = Substring(line)
        while rest.first == "@" { rest = rest.dropFirst() }
        guard let close = rest.range(of: "@@") else { return nil }
        let ranges = rest[rest.startIndex..<close.lowerBound]
        var heading = String(rest[close.upperBound...])
        while heading.first == "@" { heading = String(heading.dropFirst()) }
        heading = heading.trimmingCharacters(in: .whitespaces)

        var old: (Int, Int)?
        var new: (Int, Int)?
        for field in ranges.split(separator: " ") {
            guard let sign = field.first, sign == "-" || sign == "+" else { continue }
            let numbers = field.dropFirst().split(separator: ",")
            guard let start = Int(numbers.first ?? "") else { continue }
            let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
            if sign == "-" { old = (start, count) } else { new = (start, count) }
        }
        guard let o = old, let n = new else { return nil }
        // A zero-length side starts *after* the given line (git emits "-0,0" for a new file).
        return (o.1 == 0 ? o.0 + 1 : o.0, o.1, n.1 == 0 ? n.0 + 1 : n.0, n.1,
                heading.isEmpty ? nil : heading)
    }

    // MARK: - Split view

    /// Align a hunk into left/right rows. Within each contiguous change block deletions pair
    /// against additions in order and the shorter side is padded with nils.
    public static func pair(_ hunk: Hunk) -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(left: DiffLine?, right: DiffLine?)] = []
        var i = 0
        let lines = hunk.lines
        while i < lines.count {
            switch lines[i].kind {
            case .addition, .deletion:
                var dels: [DiffLine] = []
                var adds: [DiffLine] = []
                // git puts "\ No newline at end of file" *between* a deletion and its
                // replacement addition; it must not split the change block.
                var markers: [DiffLine] = []
                loop: while i < lines.count {
                    switch lines[i].kind {
                    case .deletion: dels.append(lines[i])
                    case .addition: adds.append(lines[i])
                    case .noNewline: markers.append(lines[i])
                    default: break loop
                    }
                    i += 1
                }
                for k in 0..<max(dels.count, adds.count) {
                    rows.append((left: k < dels.count ? dels[k] : nil,
                                 right: k < adds.count ? adds[k] : nil))
                }
                for m in markers { rows.append((left: m, right: m)) }
            default:
                rows.append((left: lines[i], right: lines[i]))
                i += 1
            }
        }
        return rows
    }

    // MARK: - Synthesising a patch

    /// Builds a unified patch from the two whole files, for the case where the forge sent
    /// none. GitHub's REST file list omits `patch` above a per-file size, so an ordinary text
    /// file can arrive with real line counts and nothing to render; fetching both revisions
    /// and diffing them here is the only way to show it.
    ///
    /// The header carries no `diff --git` preamble because `parse` does not want one.
    public static func unifiedPatch(from old: String, to new: String, context: Int = 3) -> String {
        let oldLines = splitLines(old), newLines = splitLines(new)
        guard oldLines != newLines else { return "" }

        let diff = newLines.difference(from: oldLines)
        var removals: [Int: String] = [:], insertions: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, element, _): removals[offset] = element
            case let .insert(offset, element, _): insertions[offset] = element
            }
        }

        // Walk both files in step: a removal is keyed by its old index, an insertion by its
        // new one, and anything neither touches is context present in both.
        var ops: [(kind: Character, text: String, oldNo: Int, newNo: Int)] = []
        var o = 0, n = 0
        while o < oldLines.count || n < newLines.count {
            if let text = removals[o] {
                ops.append(("-", text, o + 1, n)); o += 1
            } else if let text = insertions[n] {
                ops.append(("+", text, o, n + 1)); n += 1
            } else {
                ops.append((" ", oldLines[o], o + 1, n + 1)); o += 1; n += 1
            }
        }

        // Group changes whose context windows would touch into one hunk, then print each
        // group with `context` lines either side.
        let changed = ops.indices.filter { ops[$0].kind != " " }
        var groups: [[Int]] = []
        for i in changed {
            if var last = groups.last, let previous = last.last, i - previous <= context * 2 {
                last.append(i)
                groups[groups.count - 1] = last
            } else {
                groups.append([i])
            }
        }

        var patch = ""
        for group in groups {
            let from = max(0, group[0] - context)
            let through = min(ops.count - 1, group[group.count - 1] + context)
            let slice = ops[from...through]
            let oldCount = slice.filter { $0.kind != "+" }.count
            let newCount = slice.filter { $0.kind != "-" }.count
            let oldStart = slice.first(where: { $0.kind != "+" })?.oldNo ?? 0
            let newStart = slice.first(where: { $0.kind != "-" })?.newNo ?? 0
            patch += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for op in slice { patch += "\(op.kind)\(op.text)\n" }
        }
        return patch
    }

    /// Drops one trailing newline so a file ending in "\n" does not gain a phantom empty
    /// final line that shows up as a change against one that does not.
    private static func splitLines(_ text: String) -> [String] {
        var body = Substring(text)
        if body.hasSuffix("\n") { body = body.dropLast() }
        if body.isEmpty { return [] }
        return String(body).components(separatedBy: "\n")
    }

    // MARK: - Intra-line refinement

    /// Character ranges that actually differ between a paired deletion and addition.
    /// Common prefix/suffix are trimmed first so a one-token edit highlights one token.
    public static func inlineRanges(deleted: String, added: String)
        -> (del: [Range<String.Index>], add: [Range<String.Index>]) {
        let d = Array(deleted), a = Array(added)
        if d == a { return ([], []) }

        var prefix = 0
        while prefix < d.count, prefix < a.count, d[prefix] == a[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < d.count - prefix, suffix < a.count - prefix,
              d[d.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }

        let dMid = Array(d[prefix..<(d.count - suffix)])
        let aMid = Array(a[prefix..<(a.count - suffix)])
        if dMid.isEmpty && aMid.isEmpty { return ([], []) }
        if dMid.isEmpty { return ([], [range(in: added, from: prefix, length: aMid.count)]) }
        if aMid.isEmpty { return ([range(in: deleted, from: prefix, length: dMid.count)], []) }

        let dTokens = tokenSpans(dMid)
        let aTokens = tokenSpans(aMid)
        guard dTokens.count <= maxInlineTokens, aTokens.count <= maxInlineTokens else {
            return ([range(in: deleted, from: prefix, length: dMid.count)],
                    [range(in: added, from: prefix, length: aMid.count)])
        }

        let (dMatched, aMatched) = matchedTokens(dMid, dTokens, aMid, aTokens)
        return (spans(dTokens, matched: dMatched, base: prefix, in: deleted),
                spans(aTokens, matched: aMatched, base: prefix, in: added))
    }

    /// Character-offset flavour of `inlineRanges(deleted:added:)`, for callers that key
    /// emphasis by position rather than by index into a specific String instance.
    public static func inlineRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let (d, a) = inlineRanges(deleted: old, added: new)
        func offsets(_ ranges: [Range<String.Index>], in s: String) -> [Range<Int>] {
            ranges.map { s.distance(from: s.startIndex, to: $0.lowerBound)
                ..< s.distance(from: s.startIndex, to: $0.upperBound) }
        }
        return (offsets(d, in: old), offsets(a, in: new))
    }

    /// True when the two lines differ only in whitespace — drives the hide-whitespace preference.
    public static func isWhitespaceOnly(_ line: DiffLine, against other: DiffLine) -> Bool {
        guard line.text != other.text else { return true }
        return strip(line.text) == strip(other.text)
    }

    private static func strip(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.map(Character.init))
    }

    // MARK: - Token helpers

    /// Split into word runs, whitespace runs and single punctuation characters. Returns
    /// (offset, length) spans into `chars`.
    private static func tokenSpans(_ chars: [Character]) -> [(offset: Int, length: Int)] {
        var out: [(offset: Int, length: Int)] = []
        var i = 0
        func classOf(_ c: Character) -> Int {
            if c.isLetter || c.isNumber || c == "_" { return 0 }
            if c.isWhitespace { return 1 }
            return 2
        }
        while i < chars.count {
            let cls = classOf(chars[i])
            if cls == 2 { out.append((i, 1)); i += 1; continue }
            var j = i + 1
            while j < chars.count, classOf(chars[j]) == cls { j += 1 }
            out.append((i, j - i))
            i = j
        }
        return out
    }

    /// Which tokens survive unchanged between the two lines. `CollectionDifference` is Myers,
    /// so a small edit inside a long line costs far less than the O(n·m) LCS table this replaced.
    private static func matchedTokens(_ d: [Character], _ dt: [(offset: Int, length: Int)],
                                      _ a: [Character], _ at: [(offset: Int, length: Int)])
        -> ([Bool], [Bool]) {
        func strings(_ chars: [Character], _ tokens: [(offset: Int, length: Int)]) -> [String] {
            tokens.map { String(chars[$0.offset..<($0.offset + $0.length)]) }
        }
        var dMatched = [Bool](repeating: true, count: dt.count)
        var aMatched = [Bool](repeating: true, count: at.count)
        // Removal offsets index the original collection, insertion offsets the final one.
        for change in strings(a, at).difference(from: strings(d, dt)) {
            switch change {
            case .remove(let offset, _, _): dMatched[offset] = false
            case .insert(let offset, _, _): aMatched[offset] = false
            }
        }
        return (dMatched, aMatched)
    }

    /// Merge runs of unmatched tokens into character ranges of the original string.
    private static func spans(_ tokens: [(offset: Int, length: Int)], matched: [Bool],
                              base: Int, in string: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var run: (start: Int, end: Int)?
        for (k, token) in tokens.enumerated() {
            if matched[k] {
                if let r = run { out.append(range(in: string, from: base + r.start, length: r.end - r.start)) }
                run = nil
            } else if var r = run {
                r.end = token.offset + token.length
                run = r
            } else {
                run = (token.offset, token.offset + token.length)
            }
        }
        if let r = run { out.append(range(in: string, from: base + r.start, length: r.end - r.start)) }
        return out
    }

    private static func range(in string: String, from offset: Int, length: Int) -> Range<String.Index> {
        let lower = string.index(string.startIndex, offsetBy: offset)
        let upper = string.index(lower, offsetBy: length)
        return lower..<upper
    }
}

// MARK: - Self check

extension DiffParser {
    /// Runnable sanity check over a real two-hunk patch. Called from `DiffKitSelfTest` and
    /// cheap enough to run in a debug build.
    @_spi(Testing) public static func demo() {
        let patch = """
        @@ -1,5 +1,6 @@ struct Thing {
         import Foundation
        -let a = 1
        +let a = 2
        +let b = 3
         // tail
         end
        @@ -20,3 +21,2 @@
         keep
        -drop me
        -drop me too
        +replaced
        \\ No newline at end of file
        """

        let parsed = parse(patch.replacingOccurrences(of: "\n", with: "\r\n"))
        assert(!parsed.isTruncated)
        assert(parsed.hunks.count == 2, "expected 2 hunks, got \(parsed.hunks.count)")

        let h1 = parsed.hunks[0]
        assert(h1.oldStart == 1 && h1.oldCount == 5 && h1.newStart == 1 && h1.newCount == 6)
        assert(h1.sectionHeading == "struct Thing {", "heading was \(h1.sectionHeading ?? "nil")")
        assert(h1.lines.count == 6)
        assert(h1.lines[0].oldLine == 1 && h1.lines[0].newLine == 1)
        assert(h1.lines[1].kind == .deletion && h1.lines[1].oldLine == 2 && h1.lines[1].newLine == nil)
        assert(h1.lines[2].kind == .addition && h1.lines[2].newLine == 2 && h1.lines[2].oldLine == nil)
        assert(h1.lines[3].kind == .addition && h1.lines[3].newLine == 3)
        // context after a 1-for-2 replacement: old advanced once, new advanced twice
        assert(h1.lines[4].oldLine == 3 && h1.lines[4].newLine == 4, "\(String(describing: h1.lines[4]))")
        assert(h1.lines[5].oldLine == 4 && h1.lines[5].newLine == 5)

        let h2 = parsed.hunks[1]
        assert(h2.oldStart == 20 && h2.newStart == 21)
        assert(h2.sectionHeading == nil)
        assert(h2.rangeHeader == "@@ -20,3 +21,2 @@", h2.rangeHeader)
        assert(h2.lines.last?.kind == .noNewline)
        assert(h2.lines.last?.oldLine == nil && h2.lines.last?.newLine == nil)
        assert(h2.lines[1].oldLine == 21 && h2.lines[2].oldLine == 22)
        assert(h2.lines[3].newLine == 22)

        let rows1 = pair(h1)
        assert(rows1.count == 5, "expected 5 split rows, got \(rows1.count)")
        assert(rows1[0].left?.id == rows1[0].right?.id)               // context pairs with itself
        assert(rows1[1].left?.text == "let a = 1" && rows1[1].right?.text == "let a = 2")
        assert(rows1[2].left == nil && rows1[2].right?.text == "let b = 3")

        let rows2 = pair(h2)
        assert(rows2[1].left?.text == "drop me" && rows2[1].right?.text == "replaced")
        assert(rows2[2].left?.text == "drop me too" && rows2[2].right == nil)

        // Newline-terminated patch: no phantom context row. "\ No newline" between a deletion
        // and its replacement must not split the change block.
        let nn = parse("@@ -1,1 +1,1 @@\n-old line\n\\ No newline at end of file\n+new line\n")
        assert(nn.hunks.count == 1)
        assert(nn.hunks[0].lines.count == 3, "phantom row: \(nn.hunks[0].lines.count)")
        let nnRows = pair(nn.hunks[0])
        assert(nnRows.count == 2, "expected 2 split rows, got \(nnRows.count)")
        assert(nnRows[0].left?.text == "old line" && nnRows[0].right?.text == "new line")
        assert(nnRows[1].left?.kind == .noNewline)

        let del = "let a = 1", add = "let a = 2"
        let refined = inlineRanges(deleted: del, added: add)
        assert(refined.del.count == 1 && refined.add.count == 1)
        assert(String(del[refined.del[0]]) == "1", "got \(String(del[refined.del[0]]))")
        assert(String(add[refined.add[0]]) == "2")

        let widened = inlineRanges(deleted: "value(x)", added: "value(x, y)")
        assert(widened.del.isEmpty)
        assert(String("value(x, y)"[widened.add[0]]) == ", y")

        // Two separate edits in one line: both sides must report both spans, not one wide one.
        let scattered = inlineRanges(deleted: "foo(a, b)", added: "bar(a, c)")
        assert(scattered.del.map { String("foo(a, b)"[$0]) } == ["foo", "b"], "\(scattered.del)")
        assert(scattered.add.map { String("bar(a, c)"[$0]) } == ["bar", "c"], "\(scattered.add)")

        assert(inlineRanges(deleted: "same", added: "same") == ([], []))
        let offsets = inlineRanges(old: del, new: add)
        assert(offsets.old == [8..<9] && offsets.new == [8..<9], "\(offsets)")

        // MARK: synthesised patches

        let base = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let head = base.replacingOccurrences(of: "line 6", with: "line six")
        let synth = unifiedPatch(from: base, to: head)
        let sp = parse(synth)
        assert(sp.hunks.count == 1, "one edit, one hunk: \(sp.hunks.count)")
        assert(sp.hunks[0].rangeHeader == "@@ -3,7 +3,7 @@", sp.hunks[0].rangeHeader)
        assert(sp.hunks[0].lines.contains { $0.kind == .deletion && $0.text == "line 6" })
        assert(sp.hunks[0].lines.contains { $0.kind == .addition && $0.text == "line six" })
        assert(sp.hunks[0].lines.first?.oldLine == 3, "context must start three lines back")

        // Two edits far apart are two hunks; the same two edits close together are one.
        let far = unifiedPatch(from: base,
                               to: base.replacingOccurrences(of: "line 2", with: "two")
                                       .replacingOccurrences(of: "line 11", with: "eleven"))
        assert(parse(far).hunks.count == 2, "\(parse(far).hunks.count)")
        let near = unifiedPatch(from: base,
                                to: base.replacingOccurrences(of: "line 2", with: "two")
                                        .replacingOccurrences(of: "line 5", with: "five"))
        assert(parse(near).hunks.count == 1, "overlapping context must merge into one hunk")

        assert(unifiedPatch(from: base, to: base).isEmpty, "no change, no patch")
        assert(unifiedPatch(from: "a\n", to: "a") .isEmpty,
               "a missing trailing newline is not twelve changed lines")
        let added = unifiedPatch(from: "", to: "only\n")
        assert(added == "@@ -0,0 +1,1 @@\n+only\n", added)

                let ws1 = DiffLine(id: 0, kind: .deletion, oldLine: 1, newLine: nil, text: "  a  =  1")
        let ws2 = DiffLine(id: 1, kind: .addition, oldLine: nil, newLine: 1, text: "a = 1")
        assert(isWhitespaceOnly(ws1, against: ws2))
        assert(!isWhitespaceOnly(ws1, against: DiffLine(id: 2, kind: .addition, oldLine: nil, newLine: 1, text: "a = 2")))
    }
}
