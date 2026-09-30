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
public struct PatchFileStepper: View {
    let files: [FileChange]
    @Binding var selection: FileChange.ID?
    @Environment(\.patchFilesEnd) private var onEnd

    public init(files: [FileChange], selection: Binding<FileChange.ID?>) {
        self.files = files
        self._selection = selection
    }

    public var body: some View {
        let i = files.firstIndex { $0.id == selection } ?? 0
        let atEnd = i >= files.count - 1
        let pill = HStack(spacing: 0) {
            step("chevron.up", "[", "Previous file (⌘[)", enabled: i > 0) { selection = files[i - 1].id }
            Text("\(i + 1) of \(files.count)").font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary).fixedSize()
            if atEnd, let onEnd {
                step("checkmark", "]", "Done (⌘])", enabled: true, action: onEnd)
            } else {
                step("chevron.down", "]", "Next file (⌘])", enabled: !atEnd) { selection = files[i + 1].id }
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
}

private struct PatchFilesEndKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    var patchFilesEnd: (() -> Void)? {
        get { self[PatchFilesEndKey.self] }
        set { self[PatchFilesEndKey.self] = newValue }
    }
}

extension View {
    /// Called when "next" is pressed on the last file of a `PatchFileStepper` inside this view,
    /// e.g. to close the diff. Without it, "next" is disabled on the last file.
    public func onPatchFilesEnd(perform action: @escaping () -> Void) -> some View {
        environment(\.patchFilesEnd, action)
    }
}
