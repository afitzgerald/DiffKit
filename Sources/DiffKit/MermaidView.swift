import SwiftUI
import WebKit

/// A ```` ```mermaid ```` block, drawn by the bundled mermaid.js in a web view: nothing native
/// draws Mermaid. One small web view per diagram rather than the whole document in one, so the
/// text around it stays native and looks like the rest of the host.
///
/// Falls back to the source as a code block when the diagram does not parse, or when the host
/// app did not ship DiffKit's resource bundle (`DiffKit_DiffKit.bundle`).
struct MermaidView: View {
    let source: String

    @Environment(\.colorScheme) private var scheme
    /// The SVG's natural size, once drawn.
    @State private var size: CGSize?
    @State private var failed = false

    var body: some View {
        if failed || Mermaid.page == nil {
            MarkdownCode(text: source)
        } else {
            MermaidWebView(source: source, dark: scheme == .dark) { result in
                switch result {
                case .some(let drawn): size = drawn
                case .none: failed = true
                }
            }
            // Scales down to the pane, never up past its natural size. The 4:1 is only the
            // placeholder while mermaid.js draws.
            .aspectRatio(size.map { $0.width / $0.height } ?? 4, contentMode: .fit)
            .frame(maxWidth: size?.width ?? .infinity)
            .accessibilityLabel("Diagram")
        }
    }
}

enum Mermaid {
    /// `mermaid.html` in DiffKit's resource bundle. Looked up by hand rather than through
    /// `Bundle.module`, which traps when the bundle is missing — and a host that assembles its
    /// .app by hand has to copy the bundle in itself.
    static let page: URL? = {
        for case let place? in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let bundle = Bundle(url: place.appendingPathComponent("DiffKit_DiffKit.bundle")),
               let page = bundle.url(forResource: "mermaid", withExtension: "html") {
                return page
            }
        }
        return nil
    }()
}

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable
#else
private typealias PlatformRepresentable = UIViewRepresentable
#endif

private struct MermaidWebView: PlatformRepresentable {
    let source: String
    let dark: Bool
    /// The natural size once drawn, nil when mermaid.js could not draw it.
    let onDraw: (CGSize?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    #endif

    private func make(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = InertWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        #endif
        if let page = Mermaid.page {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    private func update(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.onDraw = onDraw
        coordinator.wanted = .init(source: source, dark: dark)
        coordinator.drawIfReady(view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Request: Equatable {
            var source: String
            var dark: Bool
        }

        var wanted: Request?
        var onDraw: (CGSize?) -> Void = { _ in }
        private var drawn: Request?
        private var loaded = false

        /// Draws once the page has loaded, and again only when the source or the colour scheme
        /// changes: SwiftUI calls `update` on every layout pass.
        func drawIfReady(_ view: WKWebView) {
            guard loaded, let wanted, wanted != drawn else { return }
            drawn = wanted
            // Arguments, not string building: the source is anyone's text.
            view.callAsyncJavaScript("return await draw(source, dark)",
                                     arguments: ["source": wanted.source, "dark": wanted.dark],
                                     in: nil, in: .page) { [weak self] result in
                guard let self, self.drawn == wanted else { return }
                if case .success(let value) = result, let pair = value as? [NSNumber], pair.count == 2,
                   pair[0].doubleValue > 0, pair[1].doubleValue > 0 {
                    self.onDraw(CGSize(width: pair[0].doubleValue, height: pair[1].doubleValue))
                } else {
                    self.onDraw(nil)
                }
            }
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            drawIfReady(view)
        }

        /// The bundled page loads once; nothing else navigates, link or redirect.
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url == Mermaid.page ? .allow : .cancel
        }
    }
}

/// Takes no events, so a scroll or click over a diagram reaches the document around it.
private final class InertWebView: WKWebView {
    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}
