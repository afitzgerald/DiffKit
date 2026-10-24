import SwiftUI
import DiffKit
#if os(macOS)
import AppKit
#endif

// A local harness for looking at `PatchView`: a file list and the selected file's diff.
//
//   swift run diffkit-preview                    built-in sample (every placeholder and edge case)
//   git diff | swift run diffkit-preview -       whatever git prints
//   swift run diffkit-preview some.diff          a saved diff
//   swift run diffkit-preview --snapshot DIR     write DIR/<n>-<file>.png for each file, then quit
//   add --light or --dark to override the system appearance
//
// A piped or saved diff reads each file's new text from the current directory, so its unchanged
// lines can be expanded: run it where the diff was taken.
// Tap a row to toggle its selection, which exercises `.onPatchLineTap` and `.patchSelection`.
// Step through changes with ⌥⌘↑ / ⌥⌘↓, which exercises `.patchCurrentChange` and `.patchScrollTarget`.

@main
struct PreviewApp: App {
    init() {
        #if os(macOS)
        // A bare SwiftPM executable starts as a background process with no Dock icon or window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        #endif
    }

    var body: some Scene {
        WindowGroup("DiffKit Preview") {
            PreviewRoot(files: Options.current.files, snapshotDir: Options.current.snapshotDir)
                .preferredColorScheme(Options.current.scheme)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}

struct Options {
    var files: [FileChange]
    var snapshotDir: URL?
    var scheme: ColorScheme?
    /// The new side's full text by path, for `.patchFileText`. nil reads the file from disk.
    var texts: [String: String]?

    static let current: Options = {
        var args = Array(CommandLine.arguments.dropFirst())
        var options = Options(files: [])
        if let i = args.firstIndex(of: "--dark") { options.scheme = .dark; args.remove(at: i) }
        if let i = args.firstIndex(of: "--light") { options.scheme = .light; args.remove(at: i) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            options.snapshotDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            args.removeSubrange(i...(i + 1))
        }
        let text: String
        switch args.first {
        case "-": text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        case let path?: text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        case nil: text = sampleDiff
        }
        options.files = FileTree.fileOrder(for: DiffParser.files(fromGitDiff: text))
        if args.isEmpty {
            // The two placeholders real git output cannot produce.
            options.files.append(FileChange(path: "zz/too-large.json", status: .modified,
                                            additions: 90_000, deletions: 0, patch: nil))
            let lines = DiffParser.maxLines + 50
            options.files.append(FileChange(
                path: "zz/generated.swift", status: .added, additions: lines, deletions: 0,
                patch: "@@ -0,0 +1,\(lines) @@\n" + (1...lines).map { "+let v\($0) = \($0)" }.joined(separator: "\n")))
            // Two hunks far apart in a long file, with its new text, so every gap can expand.
            let body = (1...80).map { "    let v\($0) = \($0)" }
            let old = (["/* Values,", "   one per line. */", "struct Values {"] + body + ["}"]).joined(separator: "\n") + "\n"
            let new = old.replacingOccurrences(of: "v10 = 10", with: "v10 = 100")
                .replacingOccurrences(of: "    let v50 = 50\n", with: "    let v50 = 50\n    let v50b = 51\n")
            options.files.append(FileChange(path: "zz/expandable.swift", status: .modified, additions: 2,
                                            deletions: 1, patch: DiffParser.unifiedPatch(from: old, to: new)))
            options.texts = ["zz/expandable.swift": new]
        }
        return options
    }()
}

struct PreviewRoot: View {
    let files: [FileChange]
    let snapshotDir: URL?

    @State private var selected: FileChange.ID?
    @State private var codeSize = 12.0
    @State private var wrap = false
    @State private var split = false
    @State private var gutterTaps = false
    @State private var bothNumbers = false
    @State private var customTheme = false
    @State private var stacked = false
    /// The file at the top of the stacked page, as its scroll position reports it.
    @State private var visible: FileChange.ID?
    @State private var scrolledTo: FileChange.ID?
    /// One `PatchFile` per file, kept while the page shows them.
    @State private var pool = PatchFilePool()
    @State private var selectedLines: Set<Int> = []
    @State private var lastTap = "Tap a row to select it"
    @State private var changeIndex = 0
    @State private var scrollTarget: PatchScrollTarget?

    private var file: FileChange? { files.first { $0.id == selected } }

    /// The open file's changes: each run of added/removed rows, as a host's "next change" sees them.
    private var changes: [[Int]] { DiffParser.changes(in: DiffParser.parse(file?.patch ?? "").hunks) }

    private func stepChange(_ delta: Int) {
        let changes = changes
        guard !changes.isEmpty else { return }
        changeIndex = min(max(changeIndex + delta, 0), changes.count - 1)
        scrollTarget = PatchScrollTarget(lineID: changes[changeIndex][0])
    }

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selected) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                    Text("\(file.status.rawValue)  +\(file.additions) −\(file.deletions)"
                         + (file.previousPath.map { "  from \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(files.count) files")
        } detail: {
            if stacked {
                stackedFiles
            } else if let file {
                PatchView(file: file, codeSize: codeSize, wrap: wrap)
                    .id(file.id)
                    .patchPinchZoom($codeSize, in: 8...20)
                    .patchTheme(customTheme ? Self.contrast : PatchTheme())
                    .patchSelection(selectedLines)
                    .patchCurrentChange(Set(changes.indices.contains(changeIndex) ? changes[changeIndex] : []))
                    .patchScrollTarget(scrollTarget)
                    .patchLayout(split ? .split : .unified)
                    .patchLineTapTarget(gutterTaps ? .gutter : .row)
                    .patchLineNumbers(bothNumbers ? .both : .one)
                    .patchFileText { file in
                        if let texts = Options.current.texts { return texts[file.path] }
                        return try? String(contentsOfFile: file.path, encoding: .utf8)
                    }
                    // macOS: a + at the end of the row under the pointer, as a host's comment button.
                    .patchLineHover { line in
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            .help("Line \(line.newLine ?? line.oldLine ?? 0)")
                    }
                    // Under each selected line's comment anchor, standing in for a thread.
                    .patchLineAttachment { anchor in
                        if selectedAnchors(in: file).contains(anchor) {
                            Text("Attached under \(anchor.side == .left ? "old" : "new") line \(anchor.line)")
                                .font(.caption)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.1))
                        }
                    }
                    .onPatchLineTap { line in
                        if selectedLines.remove(line.id) == nil { selectedLines.insert(line.id) }
                        lastTap = "Tapped line \(line.newLine ?? line.oldLine ?? 0) (\(line.kind.rawValue)): \(line.text)"
                    }
                    .overlay(alignment: .bottomLeading) {
                        PatchFileStepper(files: files, selection: $selected).padding(12)
                    }
                    // Stands in for the host closing its diff screen: back to "Select a file",
                    // or the file list on iPhone.
                    .onPatchFilesEnd { selected = nil }
                    .safeAreaInset(edge: .bottom) {
                        // The change stepper lives here, not in the toolbar, whose overflow hid it.
                        HStack {
                            Text(lastTap).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Button { stepChange(-1) } label: { Image(systemName: "arrow.up") }
                                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                                .help("Previous change (⌥⌘↑)").disabled(changeIndex == 0)
                            Text(changes.isEmpty ? "No changes" : "Change \(changeIndex + 1) of \(changes.count)")
                                .monospacedDigit().fixedSize()
                            Button { stepChange(1) } label: { Image(systemName: "arrow.down") }
                                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                                .help("Next change (⌥⌘↓)").disabled(changeIndex >= changes.count - 1)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(6).background(.bar)
                    }
                    // Drawn by SwiftUI rather than left to the window, so snapshots include it.
                    .background(.background)
                    .navigationTitle(file.path)
            } else {
                Text("Select a file").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Stepper("Code size \(Int(codeSize))", value: $codeSize, in: 8...20)
            Toggle("Wrap", isOn: $wrap)
            Toggle("Split", isOn: $split)
            Toggle("Gutter taps", isOn: $gutterTaps)
            Toggle("Old and new numbers", isOn: $bothNumbers)
            Toggle("Custom theme", isOn: $customTheme)
            Toggle("Stacked", isOn: $stacked)
        }
        .onChange(of: selected) {
            selectedLines = []
            changeIndex = 0
            // The old file's target, given to the new one, scrolled it to an unrelated row.
            scrollTarget = nil
        }
        .task {
            selected = files.first?.id
            #if os(macOS)
            if let snapshotDir { await snapshot(into: snapshotDir) }
            #endif
        }
    }

    /// Every file on one page, its rows (`PatchRows`) items of one lazy stack. The sidebar selection follows the file whose
    /// header floats at the top, and selecting a file scrolls to it.
    private var stackedFiles: some View {
        GeometryReader { area in
            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            stackedHeader(file).id(PatchRows.itemID(file.path, "header"))
                            // The stepper's hook on the selected file only: rows are numbered per file.
                            PatchRows(pool.file(for: file), codeSize: codeSize, wrap: wrap)
                                .patchCurrentChange(file.id == selected && changes.indices.contains(changeIndex)
                                                    ? Set(changes[changeIndex]) : [])
                        }
                        // Room below the last file, so it can reach the top too.
                        Color.clear.frame(height: area.size.height)
                    }
                    .frame(width: wrap ? area.size.width : pageWidth(area.size.width), alignment: .leading)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $visible, anchor: .topLeading)
                .patchPinchZoom($codeSize, in: 8...20)
                // DIFFKIT_STEP: every scroll offset, timed, to see a step move the page once or bounce.
                .modifier(ScrollTrace())
                .overlay(alignment: .top) {
                    if let file = files.first(where: { $0.id == (selected ?? files.first?.id) }) { stackedHeader(file) }
                }
                // `visible` is a row's id, not updated by a scrollTo; the reader's own scroll is
                // told apart by what it last reported.
                .onChange(of: visible) { _, id in
                    guard let id else { return }
                    let path = PatchRows.path(ofItem: id)
                    guard path != selected else { return }
                    scrolledTo = path
                    selected = path
                }
                .onChange(of: selected) { _, id in
                    guard let id, id != scrolledTo else { return }
                    scrolledTo = nil
                    visible = PatchRows.itemID(id, "header")
                }
                // The page scrolls to a row itself: `PatchRows` has no scroll of its own.
                .onChange(of: scrollTarget) { _, target in
                    guard stacked, let target, let file = files.first(where: { $0.id == selected }),
                          let id = pool.file(for: file).itemID(forLine: target.lineID, layout: split ? .split : .unified)
                    else { return }
                    visible = nil; withAnimation { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.5)) }
                }
            }
            .patchViewportWidth(area.size.width)
        }
        .patchFileText { file in
            if let texts = Options.current.texts { return texts[file.path] }
            return try? String(contentsOfFile: file.path, encoding: .utf8)
        }
        .patchTheme(customTheme ? Self.contrast : PatchTheme())
        .patchLayout(split ? .split : .unified)
        .patchLineNumbers(bothNumbers ? .both : .one)
        .background(.background)
    }

    /// As wide as the widest file needs, unwrapped.
    private func pageWidth(_ visible: CGFloat) -> CGFloat {
        files.map { PatchRows.width(of: $0, codeSize: codeSize, lineNumbers: bothNumbers ? .both : .one,
                                    layout: split ? .split : .unified) }.reduce(visible, max)
    }

    private func stackedHeader(_ file: FileChange) -> some View {
        HStack {
            Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer()
            Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func selectedAnchors(in file: FileChange) -> Set<DiffAnchor> {
        Set(DiffParser.parse(file.patch ?? "").hunks.flatMap(\.lines)
            .filter { selectedLines.contains($0.id) }.compactMap(\.commentAnchor))
    }

    /// A deliberately loud theme, so the toggle shows every colour is actually wired through.
    static let contrast = PatchTheme(added: .blue, removed: .orange,
                                     addedBG: .blue.opacity(0.15), removedBG: .orange.opacity(0.15),
                                     addedEmphasis: .blue.opacity(0.4), removedEmphasis: .orange.opacity(0.4),
                                     selection: .yellow.opacity(0.35))

    /// DIFFKIT_STEP: the file to step through, and every scroll offset logged (`ScrollTrace`).
    static let stepTrace = ProcessInfo.processInfo.environment["DIFFKIT_STEP"]
    static let traceStart = Date()

    #if os(macOS)
    /// Renders each file in turn from the live window, so it goes through the same layout,
    /// `.task` loading and scroll views as a person would see.

    private func snapshot(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let path = Self.stepTrace, let file = files.first(where: { $0.path == path }) {
            stacked = true
            // The page has to be up before a selection can scroll it.
            try? await Task.sleep(for: .seconds(1))
            selected = file.id
            try? await Task.sleep(for: .seconds(2))
            for n in 1...4 {
                print(String(format: "STEP %d at %.3f", n, Date().timeIntervalSince(Self.traceStart)))
                stepChange(1)
                try? await Task.sleep(for: .milliseconds(2500))
            }
            await capture(dir.appendingPathComponent("trace.png"))
            NSApp.terminate(nil)
            return
        }
        for (n, file) in files.enumerated() {
            selected = file.id
            await capture(dir.appendingPathComponent(
                String(format: "%02d-", n) + file.path.replacingOccurrences(of: "/", with: "_") + ".png"))
        }
        // One more with the hooks on: the loud theme, and rows 3–5 of the first code file selected.
        if let code = files.first(where: { $0.path.hasSuffix(".swift") }) {
            selected = code.id
            try? await Task.sleep(for: .milliseconds(100))   // let onChange clear the selection first
            customTheme = true
            bothNumbers = true
            selectedLines = Set(DiffParser.parse(code.patch ?? "").hunks.first?.lines.dropFirst(2).prefix(3).map(\.id) ?? [])
            await capture(dir.appendingPathComponent("hooks.png"))
            // And split, with the same selection, so the hooks are seen working in both layouts.
            // Wrapped: unwrapped, each half is as wide as the longest line, and this file's
            // longest pushes the right half off screen.
            split = true
            wrap = true
            await capture(dir.appendingPathComponent("split.png"))
            split = false
            wrap = false
            customTheme = false
            stacked = true
            selected = files.first?.id
            await capture(dir.appendingPathComponent("stacked.png"))
            selected = files[min(3, files.count - 1)].id
            await capture(dir.appendingPathComponent("stacked-jump.png"))
            // A step to a change well down a file must scroll the page, not just move the bar.
            if let expandable = files.first(where: { $0.path == "zz/expandable.swift" }) {
                selected = expandable.id
                try? await Task.sleep(for: .milliseconds(1500))
                stepChange(1)
                await capture(dir.appendingPathComponent("stacked-step.png"))
                // Wrapped, the rows are not inside a sideways scroll of their own.
                wrap = true
                stepChange(-1)
                try? await Task.sleep(for: .milliseconds(900))
                stepChange(1)
                await capture(dir.appendingPathComponent("stacked-step-wrapped.png"))
            }
        }
        NSApp.terminate(nil)
    }

    private func capture(_ url: URL) async {
        // Long enough for the model to build off the main actor and the list to lay out.
        try? await Task.sleep(for: .milliseconds(900))
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

/// DIFFKIT_STEP's offset log; see `PreviewRoot.snapshot`.
struct ScrollTrace: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *), PreviewRoot.stepTrace != nil {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                print(String(format: "SCROLL %.3f %.1f", Date().timeIntervalSince(PreviewRoot.traceStart), y))
            }
        } else {
            content
        }
    }
}

/// The stacked page's `PatchFile`s, made on first use. A class, so making one inside a body
/// does not count as a state change.
final class PatchFilePool {
    private var files: [String: PatchFile] = [:]

    func file(for file: FileChange) -> PatchFile {
        if let made = files[file.path], made.file == file { return made }
        let made = PatchFile(file: file)
        files[file.path] = made
        return made
    }
}
