# DiffKit

**Early alpha.** Built for one person's own daily use, not yet hardened for anyone else's. Expect
rough edges, missing features (see [Notes](#notes)), and breaking changes between releases
without notice.

A Swift package for git diffs. It parses unified diffs, splits raw `git diff` output into
files, and renders one file with `PatchView`. It uses SwiftUI only, has no dependencies, and
targets macOS 14 and iOS 18.

```swift
.package(url: "https://github.com/afitzgerald/DiffKit.git", from: "0.1.0")
```

## API

Parsing and search:

- `DiffParser`: `parse(_:) -> ParsedDiff`, `pair(_:)` (split-view rows),
  `inlineRanges(deleted:added:)` and `inlineRanges(old:new:)` (word-level changes),
  `unifiedPatch(from:to:)`, `isWhitespaceOnly(_:against:)`
- `ParsedDiff`, `Hunk` (alias `DiffHunk`), `DiffLine`
- `FileTree` (`fileOrder(for:)`, `firstPath(of:)`, `tree(of:)`, `Node`): directory-first file order
- `DiffFind`: case-insensitive search in parsed lines or in a raw patch
- `CodeLanguage`, `SyntaxHighlighter`, `HighlightState`, `HighlightTheme`, `TokenKind`: a small
  built-in highlighter for about 25 languages
- `FileChange`, `FileChangeStatus`
- `DiffAnchor` and `DiffSide`: where a review comment hangs, a line number *and* the side it
  counts in. `DiffLine.commentAnchor` (the one a new comment composes on) and
  `DiffLine.threadAnchors` (every one a thread can hang on), `DiffAnchor.next(after:in:)` for
  stepping through them.
- `FileTree.likelyConflicts(in:baseChanged:)`: the changed paths the base branch has also
  touched, matched on either name of a rename.

Git and rendering:

- `DiffTheme.added / .removed / .addedBG / .removedBG`: the default diff colours.
- `DiffParser.files(fromGitDiff: String) -> [FileChange]` splits raw multi-file `git diff`
  output on its section headers. Each `patch` is the body from the first `@@` on, with no
  header. That is what GitHub sends, so `parse` takes it unchanged.
  - Statuses: `added` (new file mode), `removed` (deleted file mode), `renamed` / `copied`
    (with `previousPath`), and `modified` for everything else.
  - Type changes: a file that becomes a symlink, or the reverse, is one `changed` entry.
    GitHub reports it that way. git prints a delete and an add under the same path, which
    would give two entries with the same `id`.
  - Binary files (`Binary files … differ` or `GIT binary patch`): `isBinary = true`, `patch = nil`.
  - Sections with no hunks (mode-only change, 100% rename, empty new file): `patch = ""`.
  - Paths: paths with spaces (git's trailing tab on `---`/`+++` is stripped), C-quoted paths
    (`"a/x\ty"`, `"a/na\303\257ve.txt"`), `diff.mnemonicPrefix` (`i/`, `w/`) and `--no-prefix`.
  - Combined diffs (`diff --cc`, which `git show` prints for a merge commit and `git diff`
    prints for a file mid-conflict) come back as the result against the first parent, as an
    ordinary unified patch.
  - Colour output: the escapes are stripped. It also handles CRLF content (the `\r` is
    kept) and `\ No newline at end of file`.
  - Additions and deletions are counted from the patch body.
- `PatchView(file:codeSize:wrap:)`: a unified diff with a line-number gutter, syntax
  highlighting that carries block comments and multi-line strings from row to row, and
  word-level emphasis on paired edits. Hunk headers stay pinned while you scroll. It shows
  placeholders for binary, missing (`patch == nil`) and empty patches, and a note when the
  diff is cut off at `DiffParser.maxLines`. Parsing, emphasis and highlighter state are
  computed off the main actor. The code text is selectable.
- Hooks for `PatchView`. They are environment modifiers, so they apply to every
  `PatchView` inside the view they're set on:
  - `.patchTheme(PatchTheme(...))`: every colour, including emphasis, selection and the
    syntax `HighlightTheme`. The defaults are `DiffTheme`.
  - `.onPatchLineTap { line in … }`: called with the `DiffLine` of a tapped row.
  - `.patchSelection(Set<Int>)`: tints the rows with those `DiffLine.id`s. The host owns
    the selection. The ids are the ones `DiffParser.parse(file.patch)` assigns, and they
    are stable for a given patch.
- `PatchFileStepper(files:selection:)`: an optional previous/next capsule (Liquid Glass on
  iOS/macOS 26+) to overlay on a `PatchView`, e.g. `.overlay(alignment: .bottomLeading)`.
  It steps `files` in the order given, so pass your list's order. ⌘[ and ⌘] step too.
  - `.onPatchFilesEnd { … }`: on the last file, "next" becomes a checkmark that calls this,
    e.g. to close the diff. Without it, "next" is disabled there.

## Self-check

The checks are `assert`-based `demo()` functions in each file with logic. There's no
XCTest or Testing, so it builds under CommandLineTools. They and `DiffKitSelfTest.run()` are
`@_spi(Testing)`, so they aren't part of the public API. A normal `import DiffKit`
can't see them. `@_spi(Testing) import DiffKit` can.

```sh
swift run diffkit-selfcheck          # prints "DiffKit self-check passed"
```

`-O` compiles asserts out, so in a release build (`-c release`) it exits 1 instead of
passing without checking anything.

To build with CommandLineTools when Xcode is the selected developer dir, set both
variables. Otherwise SwiftPM uses Xcode's toolchain and SDK and ignores `SDKROOT`:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift run diffkit-selfcheck
```

Under CommandLineTools, `ld` prints three `search path … not found` warnings. SwiftPM adds
those paths itself (an empty package prints the same three). The compiler gives no
warnings, and CI builds with `-warnings-as-errors`.

## Preview harness

`diffkit-preview` is a local app for looking at `PatchView`. It shows a file list and the
selected file's diff, with controls for code size, wrapping and a high-contrast theme.
Tapping a row toggles its selection, which exercises the hooks. With no arguments it loads a
built-in sample: real `git diff` output that covers every placeholder and edge case above.

```sh
swift run diffkit-preview                          # the built-in sample
git diff | swift run diffkit-preview -             # whatever git prints
swift run diffkit-preview some.diff                # a saved diff
swift run diffkit-preview --snapshot out --light   # out/<n>-<file>.png per file, then quit
scripts/preview-macos.sh                           # same arguments, with the current macOS look
scripts/preview-ios.sh                             # the same app in the booted iOS Simulator
DEVICE="iPhone 18 Pro" SCREENSHOT=ios.png scripts/preview-ios.sh
```

The harness is an executable target, not a product, so nothing that depends on DiffKit
builds it. The iOS script needs Xcode, because CommandLineTools has no iOS SDK. `swift run`
stamps the binary with the deployment target (macOS 14) as its SDK version, so macOS 26 and
later show it with the pre-Liquid Glass look; the macOS script links with the installed SDK's
version instead. `--snapshot` can't capture glass, so check glass by eye.

## CI

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request. It
builds with warnings as errors, runs the self-check, checks that a release self-check
refuses to run, and builds the library and the harness for the iOS Simulator. It also
uploads light and dark harness snapshots as an artifact.

## Notes

- Unified view only. There's no split view, although `DiffParser.pair(_:)` gives you the rows for one.
- `PatchView` shows a deleted file's diff straight away. If you want a "tap to load"
  step for deletions, the host adds it.
- `\ No newline at end of file` markers are drawn as plain text.
- Hunk headers show git's own numbers (`+0,0`). `Hunk.rangeHeader` rebuilds them from the
  parsed starts, which turns an empty side into `+1,0`.
- Syntax state starts clean at each hunk, so a comment opened above a hunk's first line is
  still coloured as code. The patch doesn't contain what comes before the hunk.
- The line-number gutter has one column: the new file's number, falling back to the old.
- The `files(fromGitDiff:)` check is `DiffParser.gitDiffDemo()` rather than `demo()`,
  because `DiffParser.demo()` checks the parser.

## Releases

Tags are `major.minor.patch`. Most releases are point releases (`0.2.1`): fixes and internal
changes that leave the public API and layout alone. Bump the minor (`0.3.0`) when public API
is added or changed, or a view lays out differently. Depend on it with
`.upToNextMinor(from:)` to pick up point releases without a pin bump.

## License

MIT. See [LICENSE](LICENSE).
