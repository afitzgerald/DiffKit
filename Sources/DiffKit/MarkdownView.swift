import SwiftUI

/// Markdown good enough for PR bodies, comments and READMEs: headings, nested lists, task lists,
/// tables, quotes, images, fenced code, ```` ```mermaid ```` diagrams, and the `<details>` blocks
/// review bots wrap their output in. Not a CommonMark renderer and deliberately isn't one — no
/// reference links, no inline HTML beyond stripping the tags. Anything unrecognised falls
/// through as prose, which is why the parse can afford to be this small.
///
/// Images and videos draw with `AsyncImage` and a link by default. A host whose media needs
/// credentials (a private repo's attachments 404 without them) draws its own with
/// `.markdownMedia { media in … }`.
public struct MarkdownView: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    @Environment(\.patchTheme) private var theme
    @Environment(\.markdownMedia) private var media

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    static let codeFont = Font.system(size: 12, design: .monospaced)

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .prose(let s):
            Text(Self.attributed(s))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Self.attributed(s))
                .font(level <= 1 ? .title3.weight(.semibold)
                      : level == 2 ? .headline : .subheadline.weight(.semibold))
                .textSelection(.enabled)
                .padding(.top, 2)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(item)
                        Text(Self.attributed(item.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .table(let header, let rows):
            // Wide tables scroll rather than squeezing every column to unreadable.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    if !header.isEmpty {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                Text(Self.attributed(cell)).font(.callout.weight(.semibold))
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.attributed(cell)).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.attributed(s))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let s):
            MarkdownCode(text: s)
        case .mermaid(let s):
            MermaidView(source: s)
        case .rule:
            Divider()
        case .image(let alt, let url):
            if let media { media.draw(.image(alt: alt, url: url)) } else { DefaultImage(url: url, alt: alt) }
        case .video(let url):
            if let media {
                media.draw(.video(url))
            } else {
                Link(destination: url) { Label("Video", systemImage: "play.rectangle") }.font(.callout)
            }
        case .details(let summary, let body):
            // The body is rendered by another MarkdownView, so a nested <details> folds again.
            DisclosureGroup {
                MarkdownView(body).padding(.top, 6)
            } label: {
                Text(Self.attributed(summary)).font(.callout.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: ListItem) -> some View {
        if let done = item.done {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? theme.added : Color.secondary)
        } else {
            Text(item.marker == Self.bullet ? Self.bullet(at: item.depth) : item.marker)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Parsing

    struct ListItem: Equatable {
        var marker: String
        var text: String
        /// nil for a plain bullet, otherwise the state of a `- [ ]` / `- [x]` checkbox.
        var done: Bool?
        /// Leading whitespace as written; ranked into `depth` once the whole list is known,
        /// because 2-space and 4-space nesting are both common and neither is wrong.
        var indent: Int = 0
        var depth: Int = 0
    }

    enum Block: Equatable {
        case prose(String)
        case heading(Int, String)
        case list([ListItem])
        case table([String], [[String]])
        case quote(String)
        case code(String)
        case mermaid(String)
        case rule
        case image(String, URL)
        case video(URL)
        case details(String, String)
    }

    static let bullet = "•"

    static func bullet(at depth: Int) -> String {
        ["•", "◦", "▪"][min(depth, 2)]
    }

    /// `<details>` comes out first, before the fence split: a bot folds its evidence — code
    /// fences included — inside one, and splitting on ``` first tears the region in half so the
    /// tags never match.
    static func blocks(of source: String) -> [Block] {
        // Bots wrap machine-readable state in HTML comments; rendering them is pure noise.
        // GitHub stores bodies written in the browser with CRLF, and a line left ending in "\r"
        // matches no anchored rule — rules, images and videos all fell through as prose.
        var rest = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        var out: [Block] = []
        while let range = detailsRange(in: rest) {
            out += fenced(String(rest[rest.startIndex..<range.lowerBound]))
            out.append(details(in: String(rest[range])))
            rest = String(rest[range.upperBound...])
        }
        return out + fenced(rest)
    }

    /// Counts opening tags so a `<details>` nested inside one doesn't end the outer block at
    /// the first `</details>`. The inner block stays in the body text and folds again when that
    /// body is rendered. An unbalanced tag returns nil and falls through to prose.
    static func detailsRange(in text: String) -> Range<String.Index>? {
        guard let first = text.range(of: "<details", options: .caseInsensitive) else { return nil }
        var depth = 0
        var cursor = first.lowerBound
        while cursor < text.endIndex {
            let open = text.range(of: "<details", options: .caseInsensitive,
                                  range: cursor..<text.endIndex)
            guard let close = text.range(of: "</details>", options: .caseInsensitive,
                                         range: cursor..<text.endIndex) else { return nil }
            if let open, open.lowerBound < close.lowerBound {
                depth += 1
                cursor = open.upperBound
            } else {
                depth -= 1
                if depth == 0 { return first.lowerBound..<close.upperBound }
                cursor = close.upperBound
            }
        }
        return nil
    }

    private static func details(in region: String) -> Block {
        var body = region.replacingOccurrences(
            of: "(?s)^\\s*<details[^>]*>|</details>\\s*$", with: "",
            options: [.regularExpression, .caseInsensitive])
        var summary = "Details"
        if let s = body.range(of: "(?s)<summary>.*?</summary>",
                              options: [.regularExpression, .caseInsensitive]) {
            summary = stripTags(String(body[s])).trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeSubrange(s)
        }
        return .details(summary.isEmpty ? "Details" : summary,
                        body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fenced(_ text: String) -> [Block] {
        text.components(separatedBy: "```").enumerated().flatMap { index, chunk -> [Block] in
            guard index.isMultiple(of: 2) else {
                // Drop the opening language hint, which is never part of the code.
                var lines = chunk.components(separatedBy: "\n")
                var language = ""
                if let first = lines.first, !first.contains(" "), !first.isEmpty {
                    language = first.lowercased()
                    lines.removeFirst()
                }
                let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if body.isEmpty { return [] }
                return [language == "mermaid" ? .mermaid(body) : .code(body)]
            }
            return lineBlocks(chunk)
        }
    }

    private static func lineBlocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var tableRows: [[String]] = []

        func flush() {
            if !para.isEmpty { out.append(.prose(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !items.isEmpty { out.append(.list(ranked(items))); items = [] }
            if !tableRows.isEmpty { out.append(table(from: tableRows)); tableRows = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }

            if let media = image(in: line) ?? video(in: line) {
                flush()
                out.append(media)
            } else if line.range(of: "^#{1,6} ", options: .regularExpression) != nil {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, stripTags(String(line.dropFirst(level))
                    .trimmingCharacters(in: .whitespaces))))
            } else if line.range(of: "^(?:([-*_])\\1{2,}|<hr\\s*/?>)$",
                                 options: [.regularExpression, .caseInsensitive]) != nil {
                flush()
                out.append(.rule)
            } else if line.hasPrefix("|") {
                tableRows.append(cells(line))
            } else if line.hasPrefix(">") {
                quote.append(stripTags(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if var item = listItem(line) {
                item.indent = indent(of: raw)
                items.append(item)
            } else {
                para.append(stripTags(line))
            }
        }
        flush()
        return out
    }

    /// Nesting is written with two spaces by some people and four by others, so rank the
    /// indents that actually appear rather than dividing by a number one of them will break.
    static func ranked(_ items: [ListItem]) -> [ListItem] {
        let indents = Set(items.map(\.indent)).sorted()
        return items.map { item in
            var copy = item
            copy.depth = indents.firstIndex(of: item.indent) ?? 0
            return copy
        }
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    static func cells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map {
            stripTags($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A `|---|---|` second row is what separates a header from the first body row. Without one
    /// every row is a body row — a pipe table with no header is still a table.
    static func table(from rows: [[String]]) -> Block {
        var rows = rows
        var header: [String] = []
        let isRule: ([String]) -> Bool = { row in
            !row.isEmpty && row.allSatisfy { $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }
        }
        if rows.count > 1, isRule(rows[1]) {
            header = rows[0]
            rows.removeFirst(2)
        }
        return .table(header, rows)
    }

    static func listItem(_ line: String) -> ListItem? {
        var marker: String
        var rest: String
        if line.range(of: "^[-*+] ", options: .regularExpression) != nil {
            marker = bullet
            rest = String(line.dropFirst(2))
        } else if let r = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
            marker = String(line[r]).trimmingCharacters(in: .whitespaces)
            rest = String(line[r.upperBound...])
        } else {
            return nil
        }
        var done: Bool?
        if rest.hasPrefix("[ ] ") { done = false; rest = String(rest.dropFirst(4)) }
        else if rest.lowercased().hasPrefix("[x] ") { done = true; rest = String(rest.dropFirst(4)) }
        return ListItem(marker: marker, text: stripTags(rest), done: done)
    }

    /// `![alt](url)` and the `<img src="…">` GitHub writes when you paste a screenshot.
    static func image(in line: String) -> Block? {
        if line.hasPrefix("!["), let split = line.range(of: "]("), line.hasSuffix(")") {
            let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound])
            let raw = String(line[split.upperBound..<line.index(before: line.endIndex)])
            if let url = URL(string: raw) { return .image(alt, url) }
        }
        if line.hasPrefix("<img"), let raw = attribute("src", in: line), let url = URL(string: raw) {
            return .image(attribute("alt", in: line) ?? "", url)
        }
        return nil
    }

    /// GitHub embeds a pasted video as its bare attachment URL on a line of its own — no markup
    /// at all — and older bodies as a `<video src="…">`.
    static func video(in line: String) -> Block? {
        if line.hasPrefix("<video"), let raw = attribute("src", in: line), let url = URL(string: raw) {
            return .video(url)
        }
        guard line.range(of: "^https://github\\.com/user-attachments/assets/[0-9A-Za-z-]+$",
                         options: .regularExpression) != nil else { return nil }
        return URL(string: line).map(Block.video)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: "\(name)=\"") else { return nil }
        guard let end = tag.range(of: "\"", range: start.upperBound..<tag.endIndex) else { return nil }
        return String(tag[start.upperBound..<end.lowerBound])
    }

    /// Only known tags, so `Array<String>` in a sentence survives. Anchors become markdown
    /// first: stripping `<a href=…>` on its own keeps the text and throws the URL away, and
    /// bots write plenty of raw HTML links. An inline image becomes its alt text — a bot's linked
    /// badge or a counter icon in a summary is otherwise an empty link or nothing at all — and
    /// emphasis becomes markdown, so `<strong>` stays bold.
    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(
            of: "(?is)<a\\s[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            with: "[$2]($1)", options: .regularExpression)
        .replacingOccurrences(
            of: "(?i)<img\\s[^>]*alt=\"([^\"]*)\"[^>]*>", with: "$1", options: .regularExpression)
        .replacingOccurrences(
            of: "(?i)</?(?:strong|b)(?:\\s[^>]*)?>", with: "**", options: .regularExpression)
        .replacingOccurrences(
            of: "(?i)</?(?:em|i)(?:\\s[^>]*)?>", with: "*", options: .regularExpression)
        .replacingOccurrences(of: "(?i)</?code(?:\\s[^>]*)?>", with: "`", options: .regularExpression)
        .replacingOccurrences(
            of: "</?(?:img|br|hr|p|div|span|a|pre|kbd|sub|sup|summary|details|blockquote|u[l]|ol|li|table|thead|tbody|tr|td|th|h[1-6]|picture|source|dl|dd|dt)(?:\\s[^>]*)?/?>",
            with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func attributed(_ s: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        return linkified(parsed)
    }

    /// Makes bare URLs clickable.
    ///
    /// Markdown parsing only links `[text](url)`; a URL sitting on its own in the prose stays
    /// inert text, and plenty of what a host renders (tickets, plain-text comments) is not
    /// written as markdown at all.
    ///
    /// Runs over the *parsed* string rather than the source: markdown parsing moves offsets, so
    /// ranges found in the source would land in the wrong place afterwards. Existing links are
    /// left alone, so an explicit `[label](url)` keeps its label.
    static func linkified(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        let plain = String(result.characters)
        guard !plain.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return result }
        let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
            let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(lower, offsetByCharacters: length)
            guard result[lower..<upper].link == nil else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// An image or video a markdown document embeds, as `.markdownMedia { … }` receives it.
public enum MarkdownMedia: Equatable, Sendable {
    case image(alt: String, url: URL)
    case video(URL)
}

/// `.markdownMedia`'s closure, equal by the modifier that set it. SwiftUI cannot compare a bare
/// closure, so it counted as changed on every environment pass and re-ran every `MarkdownView`
/// body under it, though the host had set it once.
struct MarkdownMediaDrawer: Equatable {
    let id: UUID
    let draw: (MarkdownMedia) -> AnyView

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

private struct MarkdownMediaKey: EnvironmentKey { static let defaultValue: MarkdownMediaDrawer? = nil }

extension EnvironmentValues {
    var markdownMedia: MarkdownMediaDrawer? {
        get { self[MarkdownMediaKey.self] }
        set { self[MarkdownMediaKey.self] = newValue }
    }
}

private struct MarkdownMediaModifier<Media: View>: ViewModifier {
    let draw: (MarkdownMedia) -> Media
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.environment(\.markdownMedia, MarkdownMediaDrawer(id: id) { AnyView(draw($0)) })
    }
}

extension View {
    /// Draws every image and video in the `MarkdownView`s inside this view, e.g. through a
    /// loader that sends credentials. Without it images load with `AsyncImage` and a video is
    /// a link.
    ///
    /// The closure is compared by where it is set, not by what it captures: a capture that
    /// changes redraws media the next time a `MarkdownView` redraws, not straight away.
    public func markdownMedia<Media: View>(@ViewBuilder _ draw: @escaping (MarkdownMedia) -> Media) -> some View {
        modifier(MarkdownMediaModifier(draw: draw))
    }
}

/// A fenced block: monospaced, scrolling sideways rather than wrapping.
struct MarkdownCode: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(MarkdownView.codeFont)
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct DefaultImage: View {
    let url: URL
    let alt: String

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            // Also the failure state: a caption is better than a broken frame.
            Label(alt.isEmpty ? "image" : alt, systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // A screenshot is usually far wider than the pane, and full width makes the text
        // around it unreadable.
        .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(alt)
    }
}

// MARK: - Self check

extension MarkdownView {
    @_spi(Testing) public static func demo() {
        let blocks = Self.blocks(of: """
            <!-- hidden -->
            ## Problem

            The plan step was wrong.

            - [ ] open
            - [x] done
            - plain
              - nested

            | Build | Warnings |
            |---|---|
            | clean | 4 |

            > quoted

            ---

            ![shot](https://example.com/a.png)

            <details>
            <summary>Static analysis</summary>

            ```ruby
            inside
            ```

            </details>
            """)
        assert(blocks.first == .heading(2, "Problem"), "heading, comment stripped")
        assert(blocks.contains(.list([ListItem(marker: bullet, text: "open", done: false),
                                      ListItem(marker: bullet, text: "done", done: true),
                                      ListItem(marker: bullet, text: "plain", done: nil),
                                      ListItem(marker: bullet, text: "nested", done: nil,
                                               indent: 2, depth: 1)])),
               "task boxes, bullets and one level of nesting share a list")
        assert(blocks.contains(.table(["Build", "Warnings"], [["clean", "4"]])),
               "the |---| row separates the header instead of rendering as one")
        assert(blocks.contains(.quote("quoted")) && blocks.contains(.rule))
        assert(blocks.contains { if case .image(let alt, _) = $0 { return alt == "shot" } else { return false } })
        assert(blocks.contains(.details("Static analysis", "```ruby\ninside\n```")),
               "a fenced block inside <details> stays folded rather than tearing the region")

        // Fences: the language hint goes, and only `mermaid` changes what the block is.
        assert(fenced("```swift\nlet x = 1\n```") == [.code("let x = 1")])
        assert(fenced("```\nplain\n```") == [.code("plain")])
        assert(fenced("```mermaid\ngraph TD\n  A --> B\n```") == [.mermaid("graph TD\n  A --> B")])
        assert(fenced("```Mermaid\ngraph TD\n```") == [.mermaid("graph TD")], "the hint is not case-sensitive")
        assert(fenced("```mermaid\n```") == [], "an empty diagram is nothing, as an empty fence is")
        assert(Self.blocks(of: "<details><summary>Flow</summary>\n\n```mermaid\ngraph LR\n```\n</details>")
               == [.details("Flow", "```mermaid\ngraph LR\n```")]
               && Self.blocks(of: "```mermaid\ngraph LR\n```") == [.mermaid("graph LR")],
               "a diagram folded in <details> draws when that body renders")

        // Nesting: the outer block must swallow the inner one whole.
        let nested = Self.blocks(of: """
            <details><summary>Outer</summary>
            before
            <details><summary>Inner</summary>
            deep
            </details>
            after
            </details>
            """)
        assert(nested.count == 1, "one outer block, not two halves")
        guard case .details(let summary, let body) = nested[0] else { return assert(false) }
        assert(summary == "Outer" && body.contains("<summary>Inner</summary>") && body.hasSuffix("after"),
               "the inner <details> survives in the body and folds when that body renders")

        assert(ranked([ListItem(marker: bullet, text: "a", done: nil, indent: 0),
                       ListItem(marker: bullet, text: "b", done: nil, indent: 4)])
            .map(\.depth) == [0, 1], "4-space nesting ranks the same as 2-space")
        assert(image(in: #"<img width="20" alt="a shot" src="https://x/y.png" />"#)
               == .image("a shot", URL(string: "https://x/y.png")!))
        let clip = URL(string: "https://github.com/user-attachments/assets/aa79e530-1b2c")!
        assert(Self.blocks(of: "Before:\n\n\(clip.absoluteString)\n\nAfter")
               == [.prose("Before:"), .video(clip), .prose("After")],
               "a bare attachment URL on its own line is a video, not a link")
        assert(Self.blocks(of: "---\r\n\(clip.absoluteString)\r\n") == [.rule, .video(clip)],
               "CRLF bodies, as GitHub stores them, parse like LF ones")
        assert(video(in: #"<video src="https://x/y.mp4" controls></video>"#)
               == .video(URL(string: "https://x/y.mp4")!))
        assert(video(in: "see \(clip.absoluteString)") == nil, "mid-sentence stays a link")
        assert(video(in: "https://github.com/user-attachments/files/1/log.txt") == nil,
               "a file attachment is not a video")
        assert(stripTags("Array<String> is fine <br> here") == "Array<String> is fine  here")
        // An anchor keeps its URL by becoming markdown; stripping the tag alone loses it.
        assert(stripTags(#"see <a href="https://x/y">the doc</a> now"#)
               == "see [the doc](https://x/y) now")
        assert(attributed(stripTags(#"<a href="https://x/y">doc</a>"#))
               .runs.contains { $0.link?.absoluteString == "https://x/y" })
        assert(attributed("see https://x.dev/a now").runs.contains { $0.link?.absoluteString == "https://x.dev/a" },
               "a bare URL is linked")
        assert(Self.blocks(of: "just prose") == [.prose("just prose")])

        // A summary bot's raw HTML: a linked badge inside <picture>, an inline counter image.
        assert(stripTags(#"<a href="https://x/y"><picture><source srcset="https://x/d.svg"><img src="https://x/l.svg" alt="Review →" height="32"></picture></a>"#)
               == "[Review →](https://x/y)", "a linked image keeps its link, labelled by its alt")
        assert(stripTags(#"<strong title="t">Autofix</strong> · <code>x</code>"#)
               == "**Autofix** · `x`", "emphasis and code survive as markdown")
        assert(Self.blocks(of: "<hr>") == [.rule])

        func flat(_ blocks: [Block]) -> [Block] {
            blocks.flatMap { if case .details(_, let body) = $0 { [$0] + flat(Self.blocks(of: body)) } else { [$0] } }
        }
        let bot = flat(Self.blocks(of: summaryBotComment))
        assert(!bot.contains { block in
            let text: String
            switch block {
            case .prose(let s), .heading(_, let s), .quote(let s): text = s
            case .details(let s, _): text = s
            case .list(let items): text = items.map(\.text).joined()
            case .table(let h, let rows): text = (h + rows.joined()).joined()
            default: return false
            }
            return text.range(of: "</?[a-z]+[\\s>/]", options: .regularExpression) != nil
        }, "no HTML tag is left visible anywhere in a summary bot's comment")
    }

    /// The raw HTML a summary bot posts: a linked badge inside `<picture>`, `<details>` wrapped
    /// in `<dl><dd>`, an inline counter image in a summary, `<strong>` and `<hr>`. Each of those
    /// once rendered as literal tags or vanished.
    static let summaryBotComment = """
        <!-- This is an auto-generated comment: summarize by coderabbit.ai -->

        <a href="https://example.com/change-stack/101?a=1&amp;b=2"><picture><source media="(prefers-color-scheme: dark)" srcset="https://example.com/stack-dark.svg"><img src="https://example.com/stack.svg" alt="Review in Change Stack →" height="32"></picture></a>

        <details>
        <summary><strong>📝 Walkthrough</strong></summary>
        <dl>
        <dd>

        ## Walkthrough

        Session refresh is single-flighted, so two requests that race share one refresh.

        |Layer / File(s)|Summary|
        |:---|:---|
        |**Refresh** <br> `session_store.rb`|One in-flight promise per store.|

        **Suggested reviewers:** `dana`

        <hr>

        </dd>
        </dl>
        </details>

        **Merge Risk:** **🔵 Low** · up to `9c1f2ab`

        The refresh timeout moves to 15s; confirm the load balancer allows it before merging.

        <details>
        <summary><strong>Pre-merge checks | <sup><picture><img src="https://example.com/passed.svg" width="14" alt="Passed"></picture></sup> 2</strong></summary>
        <dl>
        <dd>

        | Check name | Status | Explanation |
        | :--- | :---: | :--- |
        | Title check | ![Passed](https://example.com/passed.svg) | The title names the change. |
        | Description Check | ![Passed](https://example.com/passed.svg) | Skipped. |

        </dd>
        </dl>
        </details>

        - [ ] <!-- {"checkboxId":"x"} --> <strong title="Keep fixing findings">Autofix</strong> · Keep fixing findings and required CI

        ---

        <sub>Comment `@coderabbitai help` to get the list of available commands.</sub>
        """
}
