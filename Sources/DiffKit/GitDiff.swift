import Foundation

// MARK: - Raw `git diff` output

extension DiffParser {

    /// Splits raw multi-file `git diff` output into one `FileChange` per `diff --git` section.
    ///
    /// Each `patch` is the section's body from its first `@@` on, header stripped — the shape
    /// GitHub sends — so `parse` takes it unchanged. A binary file has `isBinary` set and a nil
    /// patch; a section with no hunks at all (mode change, pure rename, empty new file) has an
    /// empty patch. Anything before the first `diff --git` (a `git show` commit header) is ignored.
    ///
    /// Also accepted: colour output (the escapes are stripped), `diff.mnemonicPrefix` and
    /// `--no-prefix` paths, and combined diffs (`diff --cc`, what `git diff` prints for a file
    /// with merge conflicts and `git show` prints for a merge), which come back as the result
    /// against the first parent. A file that changed type (file ↔ symlink) is one `.changed`
    /// entry, as GitHub reports it, rather than git's delete-then-add pair under one path.
    public static func files(fromGitDiff diff: String) -> [FileChange] {
        // Only coloured output has a line that *starts* with an escape: every uncoloured line
        // opens with a header word or a diff marker, so content escapes are never touched.
        var diff = diff
        if diff.hasPrefix("\u{1B}[") || diff.contains("\n\u{1B}[") {
            diff = diff.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        // Split on "\n" alone, not `isNewline`: a CRLF file's "\r" is content and has to survive
        // into the patch, and Swift would otherwise read "\r\n" as a single separator.
        var sections: [[String]] = []
        for line in diff.components(separatedBy: "\n") {
            if sectionStarts.contains(where: line.hasPrefix) {
                sections.append([line])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(line)
            }
        }
        // The output's own final newline leaves one empty element on the last section.
        if sections.last?.last == "", let last = sections.indices.last { sections[last].removeLast() }

        var out: [FileChange] = []
        for file in sections.map(fileChange(from:)) {
            if let previous = out.last, previous.path == file.path,
               previous.status == .removed, file.status == .added {
                out[out.count - 1] = FileChange(
                    path: file.path, status: .changed,
                    additions: previous.additions + file.additions,
                    deletions: previous.deletions + file.deletions,
                    patch: previous.patch.flatMap { old in file.patch.map { [old, $0].joined(separator: "\n") } },
                    isBinary: previous.isBinary || file.isBinary)
            } else {
                out.append(file)
            }
        }
        return out
    }

    private static let sectionStarts = ["diff --git ", "diff --cc ", "diff --combined "]

    private static func fileChange(from lines: [String]) -> FileChange {
        let bodyStart = lines.firstIndex { $0.hasPrefix("@@") } ?? lines.count
        let head = lines[0].hasSuffix("\r") ? String(lines[0].dropLast()) : lines[0]
        let fromGitLine: (old: String, new: String, oldPrefix: String, newPrefix: String)?
        let combined = !head.hasPrefix("diff --git ")
        if combined {
            // `diff --cc <path>`: one unprefixed path, and ---/+++ keep git's default prefixes.
            let rest = Substring(head.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst())
            let path = rest.hasPrefix("\"") ? (unquote(rest)?.value ?? "") : String(rest)
            fromGitLine = (path, path, "a/", "b/")
        } else {
            fromGitLine = gitLinePaths(String(head.dropFirst("diff --git ".count)))
        }

        var status = FileChangeStatus.modified
        var isBinary = false
        // `rename from` / `copy from` are unprefixed and authoritative; `---`/`+++` come next;
        // the `diff --git` line is the fallback, and the only source for a hunk-less section.
        var renamedFrom: String?, renamedTo: String?, minus: String?, plus: String?
        for raw in lines[1..<bodyStart] {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("new file mode ") {
                status = .added
            } else if line.hasPrefix("deleted file mode ") {
                status = .removed
            } else if let path = value(line, after: "rename from ") {
                status = .renamed; renamedFrom = path
            } else if let path = value(line, after: "rename to ") {
                status = .renamed; renamedTo = path
            } else if let path = value(line, after: "copy from ") {
                status = .copied; renamedFrom = path
            } else if let path = value(line, after: "copy to ") {
                status = .copied; renamedTo = path
            } else if line.hasPrefix("--- ") {
                minus = headerPath(line.dropFirst(4), prefix: fromGitLine?.oldPrefix ?? "a/")
            } else if line.hasPrefix("+++ ") {
                plus = headerPath(line.dropFirst(4), prefix: fromGitLine?.newPrefix ?? "b/")
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
            }
        }

        let oldPath = renamedFrom ?? minus ?? fromGitLine?.old ?? ""
        let newPath = renamedTo ?? plus ?? fromGitLine?.new ?? oldPath
        let body = combined ? ArraySlice(firstParent(of: lines[bodyStart...])) : lines[bodyStart...]
        return FileChange(
            path: status == .removed ? oldPath : newPath,
            previousPath: status == .renamed || status == .copied ? oldPath : nil,
            status: status,
            additions: body.filter { $0.hasPrefix("+") }.count,
            deletions: body.filter { $0.hasPrefix("-") }.count,
            patch: isBinary ? nil : body.joined(separator: "\n"),
            isBinary: isBinary)
    }

    /// The path after a `rename from ` style key, unquoted.
    private static func value(_ line: String, after key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
        return rest.hasPrefix("\"") ? unquote(rest)?.value : String(rest)
    }

    /// `--- a/x`, `+++ "b/na\303\257ve"`, `--- /dev/null`. Git appends a tab when the name holds
    /// a space, so everything from a tab on is dropped. nil for /dev/null.
    private static func headerPath(_ field: Substring, prefix: String) -> String? {
        let name: String
        if field.hasPrefix("\"") {
            guard let q = unquote(field) else { return nil }
            name = q.value
        } else {
            name = String(field.prefix { $0 != "\t" })
        }
        if name == "/dev/null" { return nil }
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// Both paths from `a/<old> b/<new>`, plus the prefixes in use: `a/`/`b/` by default,
    /// `i/`, `w/`, `c/`, `o/` under `diff.mnemonicPrefix`, none under `--no-prefix`.
    ///
    /// Unquoted names can themselves contain " b/", so the line is ambiguous in general; when
    /// both sides are the same path (the only case where no other header names them) the
    /// halves are equal length, which settles it — and comparing them shows the prefixes too.
    private static func gitLinePaths(_ rest: String)
        -> (old: String, new: String, oldPrefix: String, newPrefix: String)? {
        /// The prefixes that make `a` and `b` the same path, if any do.
        func samePath(_ a: String, _ b: String) -> (String, String)? {
            if a == b { return ("", "") }
            let pa = a.prefix(2), pb = b.prefix(2)
            guard pa.count == 2, pb.count == 2, pa.last == "/", pb.last == "/",
                  a.dropFirst(2) == b.dropFirst(2) else { return nil }
            return (String(pa), String(pb))
        }
        var a: String, b: String
        if rest.hasPrefix("\"") {
            guard let q = unquote(Substring(rest)), q.rest.hasPrefix(" ") else { return nil }
            let tail = q.rest.dropFirst()
            a = q.value
            b = tail.hasPrefix("\"") ? (unquote(tail)?.value ?? "") : String(tail)
        } else if rest.hasSuffix("\""), let split = rest.range(of: " \"", options: .backwards) {
            a = String(rest[..<split.lowerBound])
            b = unquote(rest[rest.index(after: split.lowerBound)...])?.value ?? ""
        } else {
            let chars = Array(rest), half = (chars.count - 1) / 2
            if chars.count % 2 == 1, chars[half] == " ",
               samePath(String(chars[..<half]), String(chars[(half + 1)...])) != nil {
                a = String(chars[..<half]); b = String(chars[(half + 1)...])
            } else if let split = rest.range(of: " b/") {
                a = String(rest[..<split.lowerBound]); b = String(rest[rest.index(after: split.lowerBound)...])
            } else {
                return nil
            }
        }
        // A rename's two names differ, so assume the defaults; `rename from/to` names it anyway.
        let (pa, pb) = samePath(a, b)
            ?? (a.hasPrefix("a/") ? "a/" : "", b.hasPrefix("b/") ? "b/" : "")
        return (String(a.dropFirst(pa.count)), String(b.dropFirst(pb.count)), pa, pb)
    }

    /// Projects a combined diff's body onto its first parent, giving an ordinary unified diff
    /// of the result against "ours". Each line carries one marker column per parent; column 1
    /// alone says how the line relates to parent 1, except that a line some *other* parent
    /// removed (a `-` elsewhere) is in neither parent 1 nor the result, so it is dropped.
    private static func firstParent(of body: ArraySlice<String>) -> [String] {
        var out: [String] = []
        var parents = 0
        for line in body {
            if line.hasPrefix("@@") {
                // `@@@ -1,3 -1,3 +1,7 @@@ heading`: one `-` range per parent, then the result's.
                let run = line.prefix { $0 == "@" }
                parents = run.count - 1
                let inner = line.dropFirst(run.count)
                guard let close = inner.range(of: String(run)) else { parents = 0; continue }
                let fields = inner[..<close.lowerBound].split(separator: " ")
                guard let old = fields.first(where: { $0.hasPrefix("-") }),
                      let new = fields.first(where: { $0.hasPrefix("+") }) else { parents = 0; continue }
                let heading = inner[close.upperBound...].trimmingCharacters(in: .whitespaces)
                out.append("@@ \(old) \(new) @@" + (heading.isEmpty ? "" : " \(heading)"))
                continue
            }
            guard parents > 0 else { continue }
            if line.hasPrefix("\\") { out.append(line); continue }
            let markers = line.prefix(parents), text = line.dropFirst(parents)
            switch markers.first {
            case "-": out.append("-" + text)
            case "+": out.append("+" + text)
            default: if !markers.contains("-") { out.append(" " + text) }
            }
        }
        return out
    }

    /// Git's C-style quoting: `"na\303\257ve.txt"`, with escapes for `\" \\ \t \n` and octal
    /// bytes for anything outside printable ASCII. Returns the decoded value and what follows
    /// the closing quote.
    private static func unquote(_ s: Substring) -> (value: String, rest: Substring)? {
        let u = s.utf8
        guard u.first == UInt8(ascii: "\"") else { return nil }
        let escapes: [UInt8: UInt8] = [
            UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "t"): 9, UInt8(ascii: "n"): 10,
            UInt8(ascii: "v"): 11, UInt8(ascii: "f"): 12, UInt8(ascii: "r"): 13,
        ]
        let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
        var bytes: [UInt8] = []
        var i = u.index(after: u.startIndex)
        while i < u.endIndex {
            let c = u[i]
            if c == UInt8(ascii: "\"") {
                return (String(decoding: bytes, as: UTF8.self), s[u.index(after: i)...])
            }
            guard c == UInt8(ascii: "\\") else { bytes.append(c); i = u.index(after: i); continue }
            i = u.index(after: i)
            guard i < u.endIndex else { return nil }
            if octal.contains(u[i]) {
                var v = 0, digits = 0
                while digits < 3, i < u.endIndex, octal.contains(u[i]) {
                    v = v * 8 + Int(u[i] - UInt8(ascii: "0")); i = u.index(after: i); digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: v))
            } else {
                bytes.append(escapes[u[i]] ?? u[i]); i = u.index(after: i)
            }
        }
        return nil
    }
}

// MARK: - Self check

extension DiffParser {
    /// `files(fromGitDiff:)` against real `git diff --cached` output (captured from a scratch
    /// repo, not hand-written), covering every header shape git emits for a working tree.
    /// Named apart from `demo()` because `DiffParser.demo()` checks the parser itself.
    @_spi(Testing) public static func gitDiffDemo() {
        let raw = #"""
        diff --git a/added.go b/added.go
        new file mode 100644
        index 0000000..5786b13
        --- /dev/null
        +++ b/added.go
        @@ -0,0 +1,2 @@
        +brand
        +new
        diff --git a/blob.bin b/blob.bin
        new file mode 100644
        index 0000000..0f49c4a
        Binary files /dev/null and b/blob.bin differ
        diff --git a/moved.txt b/dir/moved.txt
        similarity index 100%
        rename from moved.txt
        rename to dir/moved.txt
        diff --git a/doomed.rb b/doomed.rb
        deleted file mode 100644
        index 6eeb8d8..0000000
        --- a/doomed.rb
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -gone
        -forever
        diff --git a/empty.txt b/empty.txt
        new file mode 100644
        index 0000000..e69de29
        diff --git a/main.swift b/main.swift
        index e031777..7e09756 100644
        --- a/main.swift
        +++ b/main.swift
        @@ -1,4 +1,4 @@
        -one
        +ONE
         two
         three
         four
        @@ -9,4 +9,5 @@ eight
         nine
         ten
         eleven
        -twelve
        +TWELVE
        +thirteen
        diff --git a/my file.txt b/my file.txt
        index 587be6b..206b378 100644
        --- a/my file.txt\#t
        +++ b/my file.txt\#t
        @@ -1 +1,2 @@
         x
        +z
        diff --git "a/na\303\257ve.txt" "b/na\303\257ve.txt"
        index 975fbec..1a78173 100644
        --- "a/na\303\257ve.txt"
        +++ "b/na\303\257ve.txt"
        @@ -1 +1 @@
        -y
        +y2
        diff --git a/old name.txt b/new name.txt
        similarity index 80%
        rename from old name.txt
        rename to new name.txt
        index 600d48a..cdafba1 100644
        --- a/old name.txt\#t
        +++ b/new name.txt\#t
        @@ -1,5 +1,5 @@
         alpha
         beta
        -gamma
        +GAMMA
         delta
         epsilon
        diff --git a/nonl.txt b/nonl.txt
        index eeed123..418f7b6 100644
        --- a/nonl.txt
        +++ b/nonl.txt
        @@ -1 +1,2 @@
        -tail
        \ No newline at end of file
        +tail
        +more
        \ No newline at end of file
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/main.swift b/copy.swift
        similarity index 92%
        copy from main.swift
        copy to copy.swift
        index 7e09756..4c75c7b 100644
        --- a/main.swift
        +++ b/copy.swift
        @@ -11,3 +11,4 @@ ten
         eleven
         TWELVE
         thirteen
        +extra

        """#

        // Everything a view keys off, one tuple per file, in output order.
        func summary(_ f: FileChange) -> String {
            "\(f.path)|\(f.previousPath ?? "-")|\(f.status.rawValue)|+\(f.additions)-\(f.deletions)|"
                + (f.isBinary ? "bin" : f.patch.map { $0.isEmpty ? "empty" : "patch" } ?? "nil")
        }
        let all = files(fromGitDiff: raw)
        let expected = [
            "added.go|-|added|+2-0|patch",
            "blob.bin|-|added|+0-0|bin",
            "dir/moved.txt|moved.txt|renamed|+0-0|empty",
            "doomed.rb|-|removed|+0-2|patch",
            "empty.txt|-|added|+0-0|empty",
            "main.swift|-|modified|+3-2|patch",
            "my file.txt|-|modified|+1-0|patch",
            "naïve.txt|-|modified|+1-1|patch",
            "new name.txt|old name.txt|renamed|+1-1|patch",
            "nonl.txt|-|modified|+2-1|patch",
            "run.sh|-|modified|+0-0|empty",
            "copy.swift|main.swift|copied|+1-0|patch",
        ]
        assert(all.map(summary) == expected, "\(all.map(summary))")
        assert(all[1].patch == nil, "binary has no patch")

        // The patch is the body only, starting at the hunk, exactly as GitHub sends it.
        let main = all[5]
        assert(main.patch?.hasPrefix("@@ -1,4 +1,4 @@\n-one\n+ONE") == true, main.patch ?? "nil")
        assert(main.patch?.hasSuffix("+thirteen") == true, "no trailing newline, no next header")
        let parsed = parse(main.patch ?? "")
        assert(parsed.hunks.count == 2 && parsed.hunks[1].sectionHeading == "eight")
        assert(parsed.hunks[1].lines.last?.newLine == 13)

        // "\ No newline" survives into the patch and parses as the marker kind.
        let nonl = parse(all[9].patch ?? "")
        assert(nonl.hunks[0].lines.map(\.kind) == [.deletion, .noNewline, .addition, .addition, .noNewline])

        // A deleted file parses with old-side numbers only.
        assert(parse(all[3].patch ?? "").hunks[0].lines.allSatisfy { $0.oldLine != nil && $0.newLine == nil })

        // The last section keeps its body even though the output ended with a newline.
        assert(all[11].patch?.hasSuffix("+extra") == true, all[11].patch ?? "nil")

        // CRLF content: the "\r" stays in the patch, headers still resolve.
        let crlf = files(fromGitDiff: raw.replacingOccurrences(of: "\n", with: "\r\n"))
        assert(crlf.map(summary) == expected, "\(crlf.map(summary))")
        assert(crlf[5].patch?.contains("+ONE\r\n") == true)
        assert(parse(crlf[5].patch ?? "").hunks.map(\.lines.count) == parse(main.patch ?? "").hunks.map(\.lines.count))

        // Leading `git show` commit header is skipped; empty input is no files.
        let shown = files(fromGitDiff: "commit abc\nAuthor: x\n\n    msg\n\n" + raw)
        assert(shown.count == expected.count)
        assert(files(fromGitDiff: "").isEmpty)
        assert(files(fromGitDiff: "not a diff\n").isEmpty)

        // Only the `diff --git` line names a hunk-less file; spaces and " b/" inside the name
        // must not split it early.
        let spaced = files(fromGitDiff: "diff --git a/x b/y.sh b/x b/y.sh\nold mode 100644\nnew mode 100755\n")
        assert(spaced.first?.path == "x b/y.sh", spaced.first?.path ?? "nil")
        // One side quoted, the other not.
        let mixed = files(fromGitDiff: "diff --git a/plain \"b/tab\\there\"\nsimilarity index 100%\n")
        assert(mixed.first?.path == "tab\there", mixed.first?.path ?? "nil")

        // A deleted binary is named by its old path.
        let goneBin = files(fromGitDiff: """
            diff --git a/logo.png b/logo.png
            deleted file mode 100644
            index 0f49c4a..0000000
            Binary files a/logo.png and /dev/null differ
            """)
        assert(goneBin.map(summary) == ["logo.png|-|removed|+0-0|bin"], "\(goneBin.map(summary))")

        // The rest are real output too, from a scratch repo with a conflicting merge.
        let plain = """
            diff --git a/f.txt b/f.txt
            index bd9d3b5..6d54d93 100644
            --- a/f.txt
            +++ b/f.txt
            @@ -1,3 +1,4 @@
             a
             BOTH
             c
            +d
            """
        let plainFiles = files(fromGitDiff: plain)
        assert(plainFiles.map(summary) == ["f.txt|-|modified|+1-0|patch"])

        // `git -c color.ui=always diff`: same files, same patch, once the escapes are gone.
        let colour = "\u{1B}[1mdiff --git a/f.txt b/f.txt\u{1B}[m\n\u{1B}[1mindex bd9d3b5..6d54d93 100644\u{1B}[m\n"
            + "\u{1B}[1m--- a/f.txt\u{1B}[m\n\u{1B}[1m+++ b/f.txt\u{1B}[m\n\u{1B}[36m@@ -1,3 +1,4 @@\u{1B}[m\n"
            + " a\u{1B}[m\n BOTH\u{1B}[m\n c\u{1B}[m\n\u{1B}[32m+\u{1B}[m\u{1B}[32md\u{1B}[m\n"
        assert(files(fromGitDiff: colour) == plainFiles, "\(files(fromGitDiff: colour))")
        // An uncoloured diff keeps an escape that is part of the content.
        let escaped = files(fromGitDiff: "diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -0,0 +1 @@\n+\u{1B}[31mred\n")
        assert(escaped.first?.patch?.hasSuffix("+\u{1B}[31mred") == true)

        // `diff.mnemonicPrefix` (i/ w/) and `--no-prefix` name the same file.
        let mnemonic = plain.replacingOccurrences(of: "a/f.txt", with: "i/f.txt")
            .replacingOccurrences(of: "b/f.txt", with: "w/f.txt")
        assert(files(fromGitDiff: mnemonic) == plainFiles, "\(files(fromGitDiff: mnemonic).map(summary))")
        let noPrefix = plain.replacingOccurrences(of: "a/f.txt", with: "f.txt")
            .replacingOccurrences(of: "b/f.txt", with: "f.txt")
        assert(files(fromGitDiff: noPrefix) == plainFiles, "\(files(fromGitDiff: noPrefix).map(summary))")
        // Without a prefix, a directory that happens to be called `a` is not one.
        assert(files(fromGitDiff: "diff --git a/x a/x\nold mode 100644\nnew mode 100755\n").first?.path == "a/x")

        // `git diff` during a conflicted merge: the result against ours (HEAD).
        let conflict = files(fromGitDiff: """
            diff --cc f.txt
            index af70335,f794161..0000000
            --- a/f.txt
            +++ b/f.txt
            @@@ -1,3 -1,3 +1,7 @@@
              a
            ++<<<<<<< HEAD
             +MAIN
            ++=======
            + SIDE
            ++>>>>>>> side
              c
            """)
        assert(conflict.map(summary) == ["f.txt|-|modified|+4-0|patch"], "\(conflict.map(summary))")
        assert(conflict[0].patch == """
            @@ -1,3 +1,7 @@
             a
            +<<<<<<< HEAD
             MAIN
            +=======
            +SIDE
            +>>>>>>> side
             c
            """, conflict[0].patch ?? "nil")
        let conflictHunk = parse(conflict[0].patch ?? "").hunks[0]
        assert(conflictHunk.lines.last?.oldLine == 3 && conflictHunk.lines.last?.newLine == 7)

        // `git show` of the resolved merge: a line only the other parent had is not ours, and
        // it is not in the result, so it is dropped rather than shown as context.
        let merge = files(fromGitDiff: """
            diff --cc f.txt
            index af70335,f794161..bd9d3b5
            --- a/f.txt
            +++ b/f.txt
            @@@ -1,3 -1,3 +1,3 @@@
              a
            - MAIN
             -SIDE
            ++BOTH
              c
            diff --cc g.txt
            index f4573cb,b27d9ce..db55786
            --- a/g.txt
            +++ b/g.txt
            @@@ -1,2 -1,2 +1,3 @@@
             +main-g
              keep
            + side-g
            """)
        assert(merge.map(summary) == ["f.txt|-|modified|+1-1|patch", "g.txt|-|modified|+1-0|patch"],
               "\(merge.map(summary))")
        assert(merge[0].patch == "@@ -1,3 +1,3 @@\n a\n-MAIN\n+BOTH\n c", merge[0].patch ?? "nil")
        assert(merge[1].patch == "@@ -1,2 +1,3 @@\n main-g\n keep\n+side-g", merge[1].patch ?? "nil")

        // A file replaced by a symlink: git prints a delete and an add under one path, which
        // would be two entries with the same `id`.
        let typeChange = files(fromGitDiff: #"""
            diff --git a/g.txt b/g.txt
            deleted file mode 100644
            index db55786..0000000
            --- a/g.txt
            +++ /dev/null
            @@ -1,3 +0,0 @@
            -main-g
            -keep
            -side-g
            diff --git a/g.txt b/g.txt
            new file mode 120000
            index 0000000..7f66e4f
            --- /dev/null
            +++ b/g.txt
            @@ -0,0 +1 @@
            +f.txt
            \ No newline at end of file
            """#)
        assert(typeChange.map(summary) == ["g.txt|-|changed|+1-3|patch"], "\(typeChange.map(summary))")
        assert(parse(typeChange[0].patch ?? "").hunks.map(\.header) == ["@@ -1,3 +0,0 @@", "@@ -0,0 +1 @@"])
    }
}
