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
// Tap a row to toggle its selection, which exercises `.onPatchLineTap` and `.patchSelection`.

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
    @State private var customTheme = false
    @State private var selectedLines: Set<Int> = []
    @State private var lastTap = "Tap a row to select it"

    private var file: FileChange? { files.first { $0.id == selected } }

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
            if let file {
                PatchView(file: file, codeSize: codeSize, wrap: wrap)
                    .id(file.id)
                    .patchTheme(customTheme ? Self.contrast : PatchTheme())
                    .patchSelection(selectedLines)
                    .patchLayout(split ? .split : .unified)
                    .patchLineTapTarget(gutterTaps ? .gutter : .row)
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
                        Text(lastTap).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            Toggle("Custom theme", isOn: $customTheme)
        }
        .onChange(of: selected) { selectedLines = [] }
        .task {
            selected = files.first?.id
            #if os(macOS)
            if let snapshotDir { await snapshot(into: snapshotDir) }
            #endif
        }
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

    #if os(macOS)
    /// Renders each file in turn from the live window, so it goes through the same layout,
    /// `.task` loading and scroll views as a person would see.
    private func snapshot(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            selectedLines = Set(DiffParser.parse(code.patch ?? "").hunks.first?.lines.dropFirst(2).prefix(3).map(\.id) ?? [])
            await capture(dir.appendingPathComponent("hooks.png"))
            // And split, with the same selection, so the hooks are seen working in both layouts.
            // Wrapped: unwrapped, each half is as wide as the longest line, and this file's
            // longest pushes the right half off screen.
            split = true
            wrap = true
            await capture(dir.appendingPathComponent("split.png"))
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
