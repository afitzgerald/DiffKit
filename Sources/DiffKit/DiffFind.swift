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

    /// Every occurrence in the rows `PatchView` draws for `file`, in reading order — the list a
    /// host steps through and passes back as `.patchFind(_:current:)`'s `current`. Pass the
    /// same `hidesWhitespaceChanges` as the view, or the list names rows it is not showing.
    /// `rowID` is `PatchView`'s own row id; scroll with `PatchScrollTarget(lineID:)`.
    public static func matches(in file: FileChange, query: String,
                               hidesWhitespaceChanges: Bool = false) -> [Match] {
        guard !query.isEmpty,
              case .diff(let parsed) = PatchModel.content(of: file, hidesWhitespaceChanges: hidesWhitespaceChanges)
        else { return [] }
        return parsed.hunks.flatMap(\.lines).flatMap { line -> [Match] in
            // The markers are not code, and `PatchView` does not tint them.
            guard line.kind != .meta, line.kind != .noNewline else { return [] }
            return ranges(in: line.text, query: query).map {
                Match(rowID: PatchScrollTarget.rowID(line.id), lineID: line.id, range: $0)
            }
        }
    }

    /// How many matches the whole change holds, and how many come before the file at `current`,
    /// so a counter can read "12 of 40" across files rather than restarting in each. `files` is
    /// in the order the host lists them; `localCount` is the open file's rendered matches, which
    /// stand in for its raw count. Every other file is counted with `count(inPatch:)`.
    ///
    /// Async and cancellable, because it reads every patch and runs per keystroke: call it from
    /// the task the query drives, and a superseded scan returns nil rather than a half-count.
    public static func totals(in files: [FileChange], query: String, current: String,
                              localCount: Int) async -> (before: Int, total: Int)? {
        var before = 0, total = 0, passed = false
        for file in files {
            if Task.isCancelled { return nil }
            if file.path == current {
                passed = true
                total += localCount
                continue
            }
            let count = count(inPatch: file.patch ?? "", query: query)
            total += count
            if !passed { before += count }
        }
        return (before, total)
    }

    /// The nearest file after (`delta` 1) or before (-1) `current` whose patch holds `query`,
    /// wrapping around and never `current` itself — where stepping past a file's last match
    /// goes. nil when no other file has one.
    public static func nextFile(in files: [FileChange], from current: String, delta: Int,
                                query: String) -> FileChange? {
        guard !query.isEmpty, let here = files.firstIndex(where: { $0.path == current }) else { return nil }
        let n = files.count
        return (1..<max(n, 1)).lazy
            .map { files[((here + $0 * delta) % n + n) % n] }
            .first { count(inPatch: $0.patch ?? "", query: query) > 0 }
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

        // `matches` searches the rows the view draws: whitespace hiding drops the re-indented
        // pair but keeps the real edit beside it, and the `\ No newline` marker is not code.
        func file(_ path: String, _ patch: String?) -> FileChange {
            FileChange(path: path, status: .modified, additions: 0, deletions: 0, patch: patch)
        }
        let shown = file("a.swift", "@@ -1,4 +1,4 @@\n foo\n-  foo()\n+    foo()\n-a\n+b\n\\ No newline foo")
        let all = matches(in: shown, query: "FOO")
        assert(all.map(\.range) == [0..<3, 2..<5, 4..<7], "\(all)")
        assert(all[0].rowID == PatchScrollTarget.rowID(all[0].lineID))
        assert(Set(all.map(\.lineID)).count == 3, "one per row, in order")
        assert(matches(in: shown, query: "foo", hidesWhitespaceChanges: true).count == 1)
        assert(matches(in: shown, query: "").isEmpty)
        assert(matches(in: file("b.png", nil), query: "foo").isEmpty)

        let files = [file("a", "@@ -1 +1 @@\n+x x"), file("b", "@@ -1 +1 @@\n+y"),
                     file("c", "@@ -1 +1 @@\n+x"), file("d", nil)]
        assert(nextFile(in: files, from: "a", delta: 1, query: "x")?.path == "c")
        assert(nextFile(in: files, from: "c", delta: 1, query: "x")?.path == "a", "wraps")
        assert(nextFile(in: files, from: "a", delta: -1, query: "x")?.path == "c", "wraps backwards")
        assert(nextFile(in: files, from: "b", delta: -1, query: "x")?.path == "a")
        assert(nextFile(in: files, from: "a", delta: 1, query: "y")?.path == "b")
        assert(nextFile(in: files, from: "b", delta: 1, query: "y") == nil, "never the file itself")
        assert(nextFile(in: [files[0]], from: "a", delta: 1, query: "x") == nil)
        assert(nextFile(in: files, from: "zz", delta: 1, query: "x") == nil)

        // Totals are synchronous inside: check them by blocking on the task.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var got: (before: Int, total: Int)?
        Task {
            // The open file counts what it renders (5 here), not its raw 2, and nothing precedes it.
            got = await totals(in: files, query: "x", current: "a", localCount: 5)
            done.signal()
        }
        done.wait()
        assert(got?.before == 0 && got?.total == 6, "\(String(describing: got))")
    }
}
