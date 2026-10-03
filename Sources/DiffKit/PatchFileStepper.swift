import SwiftUI

/// Previous/next file, as a small capsule meant to float over a `PatchView`'s corner:
///
///     PatchView(file: file)
///         .overlay(alignment: .bottomLeading) { PatchFileStepper(files: files, selection: $selected).padding(12) }
///         .onPatchFilesEnd { dismiss() }
///
/// It steps through `files` in the order given, so pass them in the order your list draws them
/// (`FileTree.fileOrder(for:)` for a tree). ⌘[ and ⌘] step too.
///
/// On the last file, "next" is disabled unless the host set `.onPatchFilesEnd`; with it, the
/// button becomes a checkmark that calls the hook, e.g. to close the diff.
///
/// Pass `viewed:` for a review loop: "next" then marks the current file viewed and goes to the
/// next file not in the set, wrapping, and the end is when no other file is left unviewed.
/// "Previous" still goes to the file before, viewed or not — the one you just read is viewed by
/// definition, and skipping it would make going back to it impossible.
public struct PatchFileStepper: View {
    let files: [FileChange]
    @Binding var selection: FileChange.ID?
    let viewed: Binding<Set<FileChange.ID>>?
    @Environment(\.patchFilesEnd) private var onEnd

    public init(files: [FileChange], selection: Binding<FileChange.ID?>) {
        self.files = files
        self._selection = selection
        self.viewed = nil
    }

    public init(files: [FileChange], selection: Binding<FileChange.ID?>,
                viewed: Binding<Set<FileChange.ID>>) {
        self.files = files
        self._selection = selection
        self.viewed = viewed
    }

    public var body: some View {
        let i = files.firstIndex { $0.id == selection } ?? 0
        let next = Self.nextIndex(after: i, in: files.map(\.id), viewed: viewed?.wrappedValue)
        let pill = HStack(spacing: 0) {
            step("chevron.up", "[", "Previous file (⌘[)", enabled: i > 0) { selection = files[i - 1].id }
            Text("\(i + 1) of \(files.count)").font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary).fixedSize()
            if next == nil, onEnd != nil {
                step("checkmark", "]", "Done (⌘])", enabled: !files.isEmpty) { advance(from: i, to: nil) }
            } else {
                step("chevron.down", "]", "Next file (⌘])", enabled: next != nil) { advance(from: i, to: next) }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)

        if #available(iOS 26, macOS 26, *) {
            pill.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            pill.background(.regularMaterial, in: Capsule()).shadow(radius: 3, y: 1)
        }
    }

    private func step(_ symbol: String, _ key: KeyEquivalent, _ help: String, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 44pt: the minimum comfortable touch target on iOS.
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .disabled(!enabled)
        .keyboardShortcut(key, modifiers: .command)
        .help(help)
    }

    /// Marks the file being left as read, then goes to `next`, or past the end.
    private func advance(from i: Int, to next: Int?) {
        if files.indices.contains(i) { viewed?.wrappedValue.insert(files[i].id) }
        if let next { selection = files[next].id } else { onEnd?() }
    }

    /// Where "next" goes from `i`: the following file, or with `viewed` the first unviewed file
    /// after `i`, wrapping. `nil` is the end.
    static func nextIndex(after i: Int, in ids: [FileChange.ID], viewed: Set<FileChange.ID>?) -> Int? {
        guard let viewed else { return i + 1 < ids.count ? i + 1 : nil }
        guard ids.indices.contains(i) else { return ids.firstIndex { !viewed.contains($0) } }
        return ids[(i + 1)...].firstIndex { !viewed.contains($0) }
            ?? ids[..<i].firstIndex { !viewed.contains($0) }
    }

    @_spi(Testing) public static func demo() {
        let ids = ["a", "b", "c", "d"]
        // Without `viewed`: plain order, and the last file is the end.
        assert(nextIndex(after: 0, in: ids, viewed: nil) == 1)
        assert(nextIndex(after: 3, in: ids, viewed: nil) == nil)
        // With it: skips what's been read…
        assert(nextIndex(after: 0, in: ids, viewed: ["b"]) == 2)
        // …wraps to an unviewed file before this one…
        assert(nextIndex(after: 2, in: ids, viewed: ["b", "d"]) == 0)
        // …ignores the current file, which "next" is about to mark…
        assert(nextIndex(after: 1, in: ids, viewed: ["a", "c", "d"]) == nil)
        // …and ends when everything is read, wherever you are.
        assert(nextIndex(after: 0, in: ids, viewed: Set(ids)) == nil)
        // No files: nothing to step to, and slicing past the end would trap.
        assert(nextIndex(after: 0, in: [], viewed: []) == nil)
    }
}

private struct PatchFilesEndKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    var patchFilesEnd: (() -> Void)? {
        get { self[PatchFilesEndKey.self] }
        set { self[PatchFilesEndKey.self] = newValue }
    }
}

extension View {
    /// Called when "next" is pressed with nowhere left to go — the last file, or with `viewed:`
    /// no unviewed file left — e.g. to close the diff. Without it, "next" is disabled there.
    public func onPatchFilesEnd(perform action: @escaping () -> Void) -> some View {
        environment(\.patchFilesEnd, action)
    }
}
