import SwiftUI
import ImageIO

/// Before-and-after previews for files whose patch is not the thing to read: an image, which
/// has no patch at all, and markdown, which reads better rendered.
///
/// Neither fetches anything. A patch carries hunks, not whole files, so both sides have to be
/// read in full at their revisions; the host does that and hands the results in, `nil` for a
/// side that is not there. What a missing side means follows from `file.status`: an added
/// file has no "before", a removed one no "after", and anything else missing failed to load.
///
/// Side by side when there is room for two readable panes, one above the other when there is
/// not — a phone in portrait.

// MARK: - Image

public struct PatchImagePreview: View {
    let file: FileChange
    let before: Data?
    let after: Data?
    let baseRef: String
    let headRef: String

    /// `baseRef` and `headRef` label the panes ("main", "feature/x"); they are not fetched.
    public init(file: FileChange, before: Data?, after: Data?, baseRef: String, headRef: String) {
        self.file = file
        self.before = before
        self.after = after
        self.baseRef = baseRef
        self.headRef = headRef
    }

    /// Formats a forge reports as binary and a reviewer can still look at. SVG is absent on
    /// purpose: it is text, arrives with a real patch, and diffs as code.
    public static func isImage(path: String) -> Bool {
        guard path.contains("."), let ext = path.split(separator: ".").last else { return false }
        return imageExtensions.contains(ext.lowercased())
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "tif", "heic", "avif",
    ]

    @Environment(\.patchTheme) private var theme

    public var body: some View {
        PreviewPanes(minPaneWidth: 240) {
            pane(.before, data: before)
        } after: {
            pane(.after, data: after)
        }
    }

    private func pane(_ side: PreviewSide, data: Data?) -> some View {
        PreviewPane(side: side, ref: side == .before ? baseRef : headRef, tint: tint(side)) {
            if let decoded = data.flatMap(Self.decode) {
                VStack(spacing: 8) {
                    Image(decorative: decoded, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .background(Checkerboard())
                        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.25)))
                    Text(Self.caption(width: decoded.width, height: decoded.height,
                                      bytes: data?.count ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                // Only a real image takes the room: stacked on a phone, an added file's empty
                // "before" took half the screen to say "Not in main".
                .frame(maxHeight: .infinity)
            } else {
                // Bytes that are there but do not decode read the same as a failed fetch.
                PreviewAbsent(side.missing(file: file, ref: side == .before ? baseRef : headRef))
            }
        }
    }

    private func tint(_ side: PreviewSide) -> Color { side == .before ? theme.removed : theme.added }

    /// ImageIO rather than NSImage/UIImage: one path for both platforms, and a `CGImage` is in
    /// pixels, so a 2x asset reports its real width instead of half of it in points.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    static func caption(width: Int, height: Int, bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard width > 0, height > 0 else { return size }
        return "\(width) × \(height) · \(size)"
    }
}

// MARK: - Markdown

public struct PatchMarkdownPreview<Rendered: View>: View {
    let file: FileChange
    let before: String?
    let after: String?
    let baseRef: String
    let headRef: String
    let render: (String) -> Rendered

    /// `render` draws one side's whole document. DiffKit has no markdown renderer of its own:
    /// the host already has one for comments and descriptions, and a preview drawn by a second,
    /// different renderer would not look like the rest of the app.
    public init(file: FileChange, before: String?, after: String?, baseRef: String, headRef: String,
                @ViewBuilder render: @escaping (String) -> Rendered) {
        self.file = file
        self.before = before
        self.after = after
        self.baseRef = baseRef
        self.headRef = headRef
        self.render = render
    }

    @Environment(\.patchTheme) private var theme

    /// One scroll view around both panes, so side by side they scroll together with no
    /// position syncing. They are not line-aligned: rendered markdown has no lines to align on.
    public var body: some View {
        ScrollView {
            PreviewPanes(minPaneWidth: 280) {
                pane(.before, text: before)
            } after: {
                pane(.after, text: after)
            }
        }
    }

    private func pane(_ side: PreviewSide, text: String?) -> some View {
        let ref = side == .before ? baseRef : headRef
        return PreviewPane(side: side, ref: ref, tint: side == .before ? theme.removed : theme.added) {
            Group {
                if let text, !text.isEmpty {
                    render(text)
                } else {
                    PreviewAbsent(side.missing(file: file, ref: ref))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

// MARK: - Shared pieces

enum PreviewSide {
    case before, after

    /// What an empty side means, from the file's status.
    func missing(file: FileChange, ref: String) -> String {
        switch self {
        case .before: return file.status == .added ? "Not in \(ref)" : "Couldn't load"
        case .after: return file.status == .removed ? "Deleted in this change" : "Couldn't load"
        }
    }
}

/// Two panes side by side if each gets `minPaneWidth`, else stacked.
private struct PreviewPanes<Before: View, After: View>: View {
    let minPaneWidth: CGFloat
    @ViewBuilder let before: Before
    @ViewBuilder let after: After

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                before.frame(minWidth: minPaneWidth)
                Divider()
                after.frame(minWidth: minPaneWidth)
            }
            VStack(spacing: 0) {
                before
                Divider()
                after
            }
        }
    }
}

private struct PreviewPane<Content: View>: View {
    let side: PreviewSide
    let ref: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(side == .before ? "Before" : "After").font(.caption.weight(.semibold))
                Text(ref)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PreviewAbsent: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// The usual transparency backdrop, so an image with an alpha channel reads as transparent
/// rather than as whatever the background happens to be.
private struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            // Every dark square in one Path and one fill: a pane holds thousands of squares,
            // and that many fill calls per resize frame is visible as lag.
            var dark = Path()
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    dark.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square,
                                        width: square, height: square))
                }
            }
            context.fill(dark, with: .color(Color(white: 0.87)))
        }
    }
}

// MARK: - Self check

extension PatchImagePreview {
    @_spi(Testing) public static func demo() {
        assert(isImage(path: "docs/screenshot.PNG"))
        assert(isImage(path: "a/b/icon.jpeg"))
        assert(!isImage(path: "src/logo.svg"), "SVG is text with a real patch")
        assert(!isImage(path: "README.md"))
        assert(!isImage(path: "Makefile"), "no extension at all")
        assert(!isImage(path: "png"), "a bare word that happens to match an extension")

        assert(caption(width: 0, height: 0, bytes: 2048) == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file),
               "unknown dimensions: size alone")
        assert(caption(width: 640, height: 480, bytes: 2048).hasPrefix("640 × 480 · "))

        // A 1×1 PNG decodes in pixels; bytes that are not an image do not decode at all.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        assert(decode(png)?.width == 1)
        assert(decode(Data("not an image".utf8)) == nil)

        func file(_ status: FileChangeStatus) -> FileChange {
            FileChange(path: "a.png", status: status, additions: 0, deletions: 0, patch: nil, isBinary: true)
        }
        assert(PreviewSide.before.missing(file: file(.added), ref: "main") == "Not in main")
        assert(PreviewSide.before.missing(file: file(.modified), ref: "main") == "Couldn't load")
        assert(PreviewSide.after.missing(file: file(.removed), ref: "x") == "Deleted in this change")
        assert(PreviewSide.after.missing(file: file(.modified), ref: "x") == "Couldn't load")

    }
}
