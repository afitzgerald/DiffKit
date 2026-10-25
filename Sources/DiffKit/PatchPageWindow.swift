import SwiftUI

/// What a host needs to list only the files near the top of a page of `PatchRows` items, and to
/// stand a spacer in for each file further off.
///
/// Placing a lazy stack, and walking the `ForEach` that feeds it, cost time per item rather than
/// per item on screen. A page of 150 files read through held some 50,000 items and dropped most
/// of its frames. So the host lists the items of the files in `plan(...)`'s window and puts
/// `above` and `below` points of blank page either side.
///
/// ```
/// VStack(spacing: 0) {                  // a plain VStack, not the lazy one
///     Color.clear.frame(height: plan.above)
///     LazyVStack(spacing: 0) { ForEach(live items) { … } }.scrollTargetLayout()
///     Color.clear.frame(height: plan.below)
/// }
/// ```
///
/// Three things about that are not obvious, and each one cost a run to find:
/// - **The spacers go outside the lazy stack.** Inside it, a `LazyVStack` sizes what it has not
///   built by the average of what it has, so a tall spacer counts as one row and the page reads
///   a sixtieth of its height.
/// - **A spacer has no item for `.patchPagePosition` to report**, so dragging the scrollbar into
///   one selects nothing and shows blank page. `.patchFollowsScrollbar` reports the offset and
///   `fileToFollow` names the file under it; the host selects that file, which jumps as a click
///   in its file list does.
/// - **What an unseen row is taken to be must not move.** A running average swung from 36 to 19
///   as plain rows followed a few tall ones, shifting 500,000 points of spacer under the reader.
///   Every shift changed which file the offset was over, and the selection flipped between two
///   files indefinitely. The estimate is the median of the first 64 rows, for good.
///
/// A class the host holds and does not read in its body: nothing here is observed.
public final class PatchPageWindow {
    public init() {}

    /// The files the page lists, and the height of the files left out either side.
    public struct Plan: Equatable {
        public var files: ClosedRange<Int>
        public var above: CGFloat
        public var below: CGFloat
    }

    /// False before macOS 15, which does not report the scroll geometry: `plan` then lists every
    /// file, as a page without windowing does.
    public static var followsScrollbar: Bool {
        if #available(macOS 15, iOS 18, *) { true } else { false }
    }

    // MARK: Heights

    /// What was measured per file: its header, chrome and note, and its rows one by one.
    private struct Measured {
        var fixed: [String: CGFloat] = [:]
        var rows: [String: CGFloat] = [:]
        var rowsSum: CGFloat = 0
    }
    private var measured: [String: Measured] = [:]
    private var unseenRow: CGFloat = PatchPageWindow.firstGuess
    private var unseenSample: [CGFloat]? = []
    private var measureKey = ""

    private static let firstGuess: CGFloat = 20
    private static let headerGuess: CGFloat = 36
    private static let chromeGuess: CGFloat = 80
    private static let noteGuess: CGFloat = 30
    private static let sampleSize = 64

    /// Heights hold for one font size, layout and (wrapped) width: pass a key naming them, and a
    /// new key forgets what was measured. Call it before each plan.
    public func measuring(under key: String) {
        guard key != measureKey else { return }
        measureKey = key
        measured = [:]
        unseenRow = Self.firstGuess
        unseenSample = []
    }

    /// An item's height as laid out. `part` is the item's own part of its id: "header", "chrome"
    /// or "note" for the host's items above the rows, else a row's `PatchRows.Item.id`.
    public func record(_ path: String, _ part: String, height: CGFloat) {
        var file = measured[path] ?? Measured()
        if part == "header" || part == "chrome" || part == "note" {
            // Zero counts: a file with nothing above its rows has a chrome of no height.
            file.fixed[part] = height
        } else {
            // Not a zero: a row in a file whose patch is not built is a placeholder.
            guard height > 0 else { return }
            let before = file.rows.updateValue(height, forKey: part)
            file.rowsSum += height - (before ?? 0)
            if before == nil, var sample = unseenSample {
                sample.append(height)
                if sample.count == Self.sampleSize {
                    unseenRow = sample.sorted()[Self.sampleSize / 2]
                    unseenSample = nil
                } else {
                    unseenSample = sample
                }
            }
        }
        measured[path] = file
    }

    /// The file's whole height as a spacer: header, what is above its rows, and `rows` of them
    /// (nil for none: still loading, or something else in their place). What was measured counts
    /// as it measured; a row not yet seen, as the file's average, else the estimate of an unseen
    /// row. A collapsed file is its header, and its `note` when it has one.
    ///
    /// Ceiling: a row whose id has since gone, such as an unchanged-lines gap that was revealed,
    /// stays in the sum, so a revealed file is a little tall.
    public func parkedHeight(of path: String, rows: Int?, collapsed: Bool, note: Bool) -> CGFloat {
        let m = measured[path] ?? Measured()
        var height = m.fixed["header"] ?? Self.headerGuess
        if collapsed { return height + (note ? m.fixed["note"] ?? Self.noteGuess : 0) }
        height += m.fixed["chrome"] ?? Self.chromeGuess
        guard let rows else { return height }
        let known = m.rows.count
        guard rows > known else { return height + m.rowsSum }
        let average = known > 0 ? m.rowsSum / CGFloat(known) : unseenRow
        return height + m.rowsSum + average * CGFloat(rows - known)
    }

    // MARK: Window

    private var kept: (files: ClosedRange<Int>, count: Int)?
    private var placed: (heights: [CGFloat], files: ClosedRange<Int>, above: CGFloat, below: CGFloat)?

    /// The files to list: the one at `top` and those either side of it, until `budget` points of
    /// page lie between (a few screens). Counted from the top file's edge, not its far end, since
    /// the reader may be at the bottom of a long one. Kept until `top` comes within two files of
    /// an end of the window, so crossing a file moves nothing. `heights` is `parkedHeight` for
    /// every file in order; nil for none.
    public func plan(heights: [CGFloat], top: Int, budget: CGFloat) -> Plan? {
        guard let last = heights.indices.last else { return nil }
        let top = min(max(top, 0), last)
        let files = window(heights: heights, top: top, budget: budget)
        let above = heights[..<files.lowerBound].reduce(0, +)
        let below = heights[(files.upperBound + 1)...].reduce(0, +)
        placed = (heights, files, above, below)
        return Plan(files: files, above: above, below: below)
    }

    private func window(heights: [CGFloat], top: Int, budget: CGFloat) -> ClosedRange<Int> {
        let last = heights.count - 1
        guard Self.followsScrollbar else { return 0...last }
        if let kept, kept.count == heights.count, kept.files.contains(top),
           top - kept.files.lowerBound >= 2 || kept.files.lowerBound == 0,
           kept.files.upperBound - top >= 2 || kept.files.upperBound == last {
            return kept.files
        }
        var low = top, high = top
        var spent: CGFloat = 0
        while low > 0, spent < budget { low -= 1; spent += heights[low] }
        spent = 0
        while high < last, spent < budget { high += 1; spent += heights[high] }
        kept = (low...high, heights.count)
        return low...high
    }

    /// Whether the file at `index` is listed as of the last `plan`.
    public func lists(_ index: Int) -> Bool { placed?.files.contains(index) ?? false }

    // MARK: Following the scrollbar

    private var pausedUntil = Date.distantPast

    /// A jump to a file is landing: `fileToFollow` names nothing for `seconds`. Between the window
    /// moving and the page following it the old offset is a spacer, and following it would select
    /// that file back. A jump to a file outside the window also has to wait for the window to
    /// move before it sets the page's position, since an id the page does not have yet is dropped.
    public func pauseFollowing(for seconds: TimeInterval = 0.5, now: Date = Date()) {
        pausedUntil = now.addingTimeInterval(seconds)
    }

    /// The index of the file under `offset` when that is in a spacer, else nil: the page is the
    /// spacer above, the listed files, the spacer below, then `endRoom` (the host's room after
    /// the last file). The host selects that file, which moves the window and the page to it.
    /// Not left at the offset: the spacers are estimates, and once the window holds the file its
    /// measured heights move it, to a place that can be a spacer again.
    public func fileToFollow(offset: CGFloat, contentHeight: CGFloat, endRoom: CGFloat,
                             now: Date = Date()) -> Int? {
        guard now > pausedUntil, let p = placed, p.heights.indices.contains(p.files.upperBound) else { return nil }
        func file(in indices: Range<Int>, at distance: CGFloat) -> Int? {
            var top: CGFloat = 0
            for i in indices {
                top += p.heights[i]
                if distance < top { return i }
            }
            return indices.last
        }
        if offset < p.above { return file(in: 0..<p.files.lowerBound, at: offset) }
        let belowTop = contentHeight - endRoom - p.below
        if p.below > 0, offset >= belowTop {
            return file(in: (p.files.upperBound + 1)..<p.heights.count, at: offset - belowTop)
        }
        return nil
    }
}

extension View {
    /// Calls `action` with the page's scroll offset and content height whenever either changes,
    /// where macOS 15 and iOS 18 report them; before that, never. Put it on the page's
    /// `ScrollView`, and feed the pair to `PatchPageWindow.fileToFollow`.
    public func patchFollowsScrollbar(_ action: @escaping (_ offset: CGFloat, _ contentHeight: CGFloat) -> Void)
        -> some View {
        modifier(PatchFollowsScrollbar(action: action))
    }
}

private struct PatchFollowsScrollbar: ViewModifier {
    let action: (CGFloat, CGFloat) -> Void

    private struct Spot: Equatable {
        var offset: CGFloat
        var height: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content.onScrollGeometryChange(for: Spot.self) {
                Spot(offset: $0.contentOffset.y, height: $0.contentSize.height)
            } action: { _, spot in
                action(spot.offset, spot.height)
            }
        } else {
            content
        }
    }
}

extension PatchPageWindow {
    @_spi(Testing) public static func demo() {
        let w = PatchPageWindow()

        // A file out of the window is one spacer: header, chrome, then its rows, those measured as
        // they measured and those not yet seen as the file's own average.
        w.measuring(under: "demo")
        assert(w.parkedHeight(of: "a", rows: 5, collapsed: false, note: false) == 36 + 80 + 5 * 20,
               "guesses before anything is measured")
        w.record("a", "header", height: 40)
        w.record("a", "chrome", height: 0)
        for n in 1...3 { w.record("a", "row\(n)", height: 30) }
        let measuredRows: CGFloat = 3 * 30, unseenRows: CGFloat = 2 * 30
        assert(w.parkedHeight(of: "a", rows: 5, collapsed: false, note: false) == 40 + measuredRows + unseenRows)
        assert(w.parkedHeight(of: "a", rows: 3, collapsed: false, note: false) == 40 + measuredRows)
        assert(w.parkedHeight(of: "a", rows: nil, collapsed: false, note: false) == 40, "no rows listed")
        // A collapsed file is its header, and its note when it has one.
        assert(w.parkedHeight(of: "a", rows: 5, collapsed: true, note: false) == 40)
        assert(w.parkedHeight(of: "gone", rows: 3, collapsed: true, note: true) == 36 + 30)
        // A zero row is a placeholder, and a zero chrome is a real height.
        w.record("a", "row9", height: 0)
        assert(w.parkedHeight(of: "a", rows: 3, collapsed: false, note: false) == 40 + measuredRows)
        // New measurements hold only for the layout they were made in.
        w.measuring(under: "other")
        assert(w.parkedHeight(of: "a", rows: 5, collapsed: false, note: false) == 36 + 80 + 5 * 20)
        // Sixty-four rows fix what an unseen row is, by their median, and a few tall ones in the
        // first of them do not move it. Sixteen tall, thirty-two plain, sixteen short: neither
        // end is the median.
        w.measuring(under: "median")
        for n in 1...64 { w.record("sample", "row\(n)", height: n <= 16 ? 90 : n <= 48 ? 18 : 10) }
        assert(w.parkedHeight(of: "b", rows: 1, collapsed: false, note: false) == 36 + 80 + 18)
        w.record("sample", "row65", height: 500)
        assert(w.parkedHeight(of: "b", rows: 1, collapsed: false, note: false) == 36 + 80 + 18,
               "and later rows leave it alone")

        // The window: ten files of 100, the reader on the sixth, 250 points of budget a side.
        let tens = [CGFloat](repeating: 100, count: 10)
        assert(w.plan(heights: [], top: 0, budget: 250) == nil)
        assert(w.plan(heights: tens, top: 5, budget: 250) == Plan(files: 2...8, above: 200, below: 100))
        assert(w.plan(heights: tens, top: 6, budget: 250)?.files == 2...8, "kept while two from an end")
        assert(w.plan(heights: tens, top: 7, budget: 250)?.files == 4...9, "moved a file from the end")
        assert(w.plan(heights: tens, top: 9, budget: 250)?.files == 4...9, "an end of the page is not near")
        assert(w.plan(heights: tens, top: 5, budget: 250)?.files == 2...8, "moved a file from the start")
        assert(w.plan(heights: tens + [100], top: 9, budget: 250)?.files == 6...10, "forgotten when files change")
        assert(w.plan(heights: tens, top: 0, budget: 250) == Plan(files: 0...3, above: 0, below: 600))
        assert(w.plan(heights: tens, top: 99, budget: 250)?.files.upperBound == 9, "top clamps")
        assert(w.lists(9) && !w.lists(0))

        // Which file the scrollbar is over when that is a spacer: five files, the third listed.
        let spans: [CGFloat] = [100, 200, 300, 400, 500]
        assert(w.plan(heights: spans, top: 2, budget: 1) == Plan(files: 1...3, above: 100, below: 500))
        // A window of the third alone, which a budget does not give, placed by hand.
        let single = PatchPageWindow()
        single.place(heights: spans, files: 2...2)
        let end: CGFloat = 1_000, total: CGFloat = 300 + 300 + 900 + end
        func at(_ offset: CGFloat, _ now: Date = Date()) -> Int? {
            single.fileToFollow(offset: offset, contentHeight: total, endRoom: end, now: now)
        }
        assert(at(0) == 0 && at(99) == 0)
        assert(at(100) == 1 && at(299) == 1)
        assert(at(300) == nil && at(599) == nil, "the listed files")
        assert(at(600) == 3 && at(999) == 3)
        assert(at(1_000) == 4)
        assert(at(5_000) == 4, "past the last: the last")
        // A jump landing pauses it, for a while only.
        let t = Date(timeIntervalSinceReferenceDate: 0)
        single.pauseFollowing(for: 0.5, now: t)
        assert(at(0, t.addingTimeInterval(0.4)) == nil)
        assert(at(0, t.addingTimeInterval(0.6)) == 0)
        assert(PatchPageWindow().fileToFollow(offset: 0, contentHeight: 10, endRoom: 0) == nil, "no plan yet")
    }

    /// A window placed by hand, for the checks.
    fileprivate func place(heights: [CGFloat], files: ClosedRange<Int>) {
        let above = heights[..<files.lowerBound].reduce(0, +)
        placed = (heights, files, above, heights[(files.upperBound + 1)...].reduce(0, +))
    }
}
