import Foundation

/// Text search inside a diff. Pure, so it can be checked without a view.
///
/// Two entry points because the two jobs have different budgets: `ranges` runs against the
/// lines a diff view has already parsed and must return exact character offsets to highlight,
/// while `count(inPatch:)` runs against *every other file's* raw patch on each keystroke and
/// only needs a number, so it never parses.
public enum DiffFind {
    /// One highlighted occurrence. `rowID` is the view's row to scroll to; `lineID` and
    /// `range` identify the characters inside that row's line.
    public struct Match: Equatable, Sendable {
        public let rowID: String
        public let lineID: Int
        public let range: Range<Int>

        public init(rowID: String, lineID: Int, range: Range<Int>) {
            self.rowID = rowID
            self.lineID = lineID
            self.range = range
        }
    }

    /// Case-insensitive, literal, non-overlapping occurrences as character offsets.
    public static func ranges(in text: String, query: String) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let found = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex) {
            out.append(text.distance(from: text.startIndex, to: found.lowerBound)
                       ..< text.distance(from: text.startIndex, to: found.upperBound))
            from = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return out
    }

    /// Occurrences in the *content* of a unified patch, for files that are not on screen.
    ///
    /// Counts the raw patch rather than the rendered rows, so it can disagree with
    /// what a file shows once opened — hidden whitespace-only changes are the case that bites.
    /// Navigation always re-derives matches from the rendered rows, so a disagreement costs a
    /// wrong total, never a wrong jump. Parse the patch here if the total ever has to be exact.
    public static func count(inPatch patch: String, query: String) -> Int {
        guard !query.isEmpty, !patch.isEmpty else { return 0 }
        var total = 0
        // Everything before the first `@@` is preamble, which is where a `---`/`+++` file
        // header would live. The usual inputs have none (GitHub's `patch`, `unifiedPatch` and
        // `files(fromGitDiff:)` all start at the first hunk), but skipping it costs one Bool and
        // is the only way to tell a header from a content line that begins with `-- `.
        var inHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { inHunk = true; continue }
            guard inHunk, let marker = line.first,
                  marker == "+" || marker == "-" || marker == " " else { continue }
            total += ranges(in: String(line.dropFirst()), query: query).count
        }
        return total
    }

    @_spi(Testing) public static func demo() {
        assert(ranges(in: "let x = 1", query: "") == [])
        assert(ranges(in: "", query: "x") == [])
        assert(ranges(in: "let x = x", query: "x") == [4..<5, 8..<9])
        assert(ranges(in: "Foo foo FOO", query: "foo") == [0..<3, 4..<7, 8..<11])
        assert(ranges(in: "abc", query: "z") == [])
        // Non-overlapping: "aaaa" holds two "aa", not three.
        assert(ranges(in: "aaaa", query: "aa") == [0..<2, 2..<4])

        // The usual shape: no `diff --git` preamble, first line is a hunk.
        let patch = """
        @@ -1,3 +1,3 @@ func foo()
         let foo = 1
        -var foo = 2
        +var foo = 3
        \\ No newline at end of file
        """
        // Three content lines carry "foo"; the @@ heading's own `func foo()` does not count.
        assert(count(inPatch: patch, query: "foo") == 3)
        assert(count(inPatch: patch, query: "") == 0)

        // A patch that quotes a patch — a changelog, a .patch fixture — is content, not
        // headers, and every one of these lines is searchable.
        let quoted = """
        @@ -1,4 +1,4 @@
        +--- a/old.txt
        +++- b/new.txt
         -- see the patch above
        """
        assert(count(inPatch: quoted, query: "old.txt") == 1)
        assert(count(inPatch: quoted, query: "new.txt") == 1)
        assert(count(inPatch: quoted, query: "see the patch") == 1)

        // Preamble is skipped when a patch does carry one.
        let withHeaders = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,1 +1,1 @@
        +let foo = 1
        """
        assert(count(inPatch: withHeaders, query: "foo") == 1)
    }
}
