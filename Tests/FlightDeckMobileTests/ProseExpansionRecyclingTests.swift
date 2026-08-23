import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// **Does an expanded answer survive being scrolled away from?**
///
/// It is the question about this feature most likely to be quietly wrong — a row that
/// re-collapsed because the list rebuilt it would be a bug with nothing on screen to explain it
/// — and it is the one question a test process can answer by *doing* it rather than by
/// reasoning about it. So these three drive a real 6,000pt scroll, and a real removal from the
/// feed, against real rows in a real key `UIWindow`, and read the row's height off the
/// collection view's own layout afterwards. **The answer is yes**, at 30, 200 and 600 rows.
///
/// **What the probe measured, which is not what was expected.** `RowLocalStateProbe` is a row
/// that keeps a `@State` of its own, mounted beside the subject and carried through the
/// identical round trip. It was put there to fail — to show a `List` tearing row state out and
/// so to justify keeping the expansion on the screen. It does not fail: SwiftUI recycles the
/// *cell* (its `onAppear` fires a second time) while keeping the row's state box alive, at
/// every scale tried, and it keeps it even across the row leaving the view tree entirely and
/// coming back. A row-owned `isExpanded` would therefore survive too, today.
///
/// That measurement did not change the design, and it is worth saying why. The expansion still
/// lives on the screen, for two reasons that do not depend on it: a row that is a pure function
/// of a flag cannot be affected by any `List` behaviour, present or future — this file is the
/// tripwire if that behaviour ever changes — and state reachable without a view is state a test
/// can drive, which is what `TimelineProseExpansionTests` does with no window at all.
///
/// **Honest about what is proved.** The height assertions before each round trip are killed by
/// any real defect in the feature. The assertion *after* it is a tripwire rather than a proved
/// test: with SwiftUI preserving state on every path that can be driven here, no mutation makes
/// it fail on its own, and it is shipped as the record of a measurement rather than as a claim
/// that something would otherwise break.
///
/// **Nothing here renders an image.** `layer.render(in:)` comes back blank after a programmatic
/// scroll (docs/MOBILE.md), and none of this needs a pixel: a row's height is a number.
@MainActor
final class ProseExpansionRecyclingTests: XCTestCase {

    /// The 201-line answer the ceiling was argued from — collapsed it lays out at 2,834pt and
    /// expanded at 3,960pt, which is a difference no measurement noise reaches.
    private let subject = TimelineFixtures.assistantVeryLongAnswer

    /// Enough short rows below it to put thousands of points of conversation between the top of
    /// the list and the bottom. An expanded subject is around 4,000pt on its own, and a scroll
    /// that leaves any part of it on screen recycles nothing.
    private func filler(_ count: Int = 30) -> [TimelineItem] {
        (1...count).map { index in
            TimelineItem(
                id: "\(index)#0", kind: .assistantText, status: .complete,
                body: .init(text: "A short reply, row \(index) of the filler below the subject.")
            )
        }
    }

    func testAnExpandedAnswerIsStillExpandedAfterAScrollTakesItsRowOffScreenAndBack() {
        let harness = Harness(subject: subject, filler: filler())
        let window = harness.mount()
        defer { window.isHidden = true }

        guard let list = harness.list else {
            return XCTFail("the harness mounted no List — nothing below can mean anything")
        }
        let collapsed = harness.subjectHeight()
        XCTAssertGreaterThan(collapsed, 800, "the subject row was never laid out")

        // Not the claim: More has to change the row before "it stayed changed" is a sentence
        // about anything.
        harness.tapMore()
        let expanded = harness.subjectHeight()
        XCTAssertGreaterThan(
            expanded, collapsed + 800,
            "expanding a 201-line answer past a 120-line ceiling must add screenfuls"
        )

        harness.scrollToBottom()
        harness.scrollToTop()

        XCTAssertEqual(
            harness.probeAppearances.count, 2,
            "the subject's neighbour never left the screen and came back, so this list was "
            + "never scrolled far enough for the assertion below to mean anything"
        )
        XCTAssertEqual(
            harness.subjectHeight(), expanded, accuracy: 1,
            "the answer re-collapsed when the List rebuilt its row"
        )
    }

    /// The other direction over the same round trip, and it is not the same code path: a fresh
    /// row draws collapsed anyway, so a screen that lost the whole set would still look right
    /// here — which is exactly why the expansion *before* the collapse is part of the sequence.
    func testAnAnswerTheReaderShutAgainStaysShutAcrossTheSameScroll() {
        let harness = Harness(subject: subject, filler: filler())
        let window = harness.mount()
        defer { window.isHidden = true }

        guard harness.list != nil else { return XCTFail("the harness mounted no List") }
        let collapsed = harness.subjectHeight()

        harness.tapMore()
        XCTAssertGreaterThan(harness.subjectHeight(), collapsed + 800, "More opened it")
        harness.tapMore()
        XCTAssertEqual(harness.subjectHeight(), collapsed, accuracy: 1, "Less put it back")

        harness.scrollToBottom()
        harness.scrollToTop()

        XCTAssertEqual(harness.probeAppearances.count, 2, "this list was never scrolled far")
        XCTAssertEqual(
            harness.subjectHeight(), collapsed, accuracy: 1,
            "a row the reader shut re-opened itself on a scroll"
        )
    }

    /// **The paging case, which is a different thing from a scroll.** A `reset` page replaces
    /// the feed and "Load earlier" rebuilds it, so a row can leave the view tree outright and
    /// return — not merely leave the viewport. The set is keyed by the record's id, which is its
    /// byte offset in the file the agent wrote and is therefore the same string on both sides of
    /// a refetch; an implementation keyed by row position would come back opened on the wrong
    /// message.
    func testAnExpandedAnswerSurvivesItsRowLeavingTheFeedAndComingBack() {
        let harness = Harness(subject: subject, filler: filler())
        let window = harness.mount()
        defer { window.isHidden = true }

        guard let list = harness.list else { return XCTFail("the harness mounted no List") }
        let collapsed = harness.subjectHeight()

        harness.tapMore()
        let expanded = harness.subjectHeight()
        // Without this the test passes on an implementation where More does nothing at all:
        // `expanded` would simply be the collapsed height, and the assertion at the end would
        // compare it with itself. It survived a mutation for exactly that reason once.
        XCTAssertGreaterThan(expanded, collapsed + 800, "More opened it")

        harness.setSubjectPresent(false)
        XCTAssertEqual(
            list.numberOfItems(inSection: 0), harness.filler.count,
            "the subject never actually left the feed, so nothing was rebuilt"
        )

        harness.setSubjectPresent(true)
        XCTAssertEqual(
            harness.subjectHeight(), expanded, accuracy: 1,
            "the answer came back collapsed after a page rebuilt its row"
        )
    }
}

// MARK: The mounted list

/// The screen's arrangement in the smallest list that can be recycled, plus the handles a test
/// process needs to drive it.
///
/// **The expansion set is `@State` one level ABOVE the rows**, exactly where
/// `SessionTimelineScreen` holds it, so what is being scrolled is the real arrangement rather
/// than an imitation of it.
@MainActor
private final class Harness {
    let subject: TimelineItem
    let filler: [TimelineItem]

    private let box = Controls()
    private var window: UIWindow?

    init(subject: TimelineItem, filler: [TimelineItem]) {
        self.subject = subject
        self.filler = filler
    }

    /// A window that is **key and visible**, which is what SwiftUI lays out under at all —
    /// docs/MOBILE.md records the same requirement for the render harness, and a hosting
    /// controller whose view never reaches one produces an empty hierarchy and a silent pass.
    func mount() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(
            rootView: HarnessView(subject: subject, filler: filler, controls: box)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        settle()
        window.layoutIfNeeded()
        settle()
        self.window = window
        return window
    }

    /// The `List`'s own collection view, reached as a `UICollectionView` and never by class
    /// name, so a renamed private class costs nothing here.
    var list: UICollectionView? {
        guard let window else { return nil }
        return Self.collectionView(in: window)
    }

    /// What the probe row reported, in order — see this file's own comment for what it measured.
    var probeAppearances: [Int] { box.appearances }

    /// There is nothing to tap in a process with no touch events, so this calls the very
    /// closure the row's own More button calls. The same affordance, and the same reason, as
    /// `TimelineBodyBlock.showsRaw` and `PromptComposer.draft`.
    func tapMore() {
        box.toggle?(subject.id)
        settleLayout()
    }

    /// Removes the subject and its neighbour from the feed, or puts them back — a page reset,
    /// rather than a scroll.
    func setSubjectPresent(_ present: Bool) {
        box.setPresent?(present)
        settleLayout()
    }

    func scrollToBottom() {
        guard let list else { return }
        let bottom = max(0, list.collectionViewLayout.collectionViewContentSize.height
                            - list.bounds.height)
        list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        settleLayout()
    }

    func scrollToTop() {
        list?.setContentOffset(.zero, animated: false)
        settleLayout()
    }

    /// The subject row's laid-out height, off the layout rather than off a cell: it is item 1 of
    /// section 0 — the probe is item 0 — and asking the layout works whether or not a cell is
    /// currently realized.
    ///
    /// **Both indices are checked before either is used.** A regression that emptied the list
    /// would otherwise take the whole test process down with it, which is how a failure here
    /// once reached a reader as "FlightDeckMobile quit unexpectedly".
    func subjectHeight() -> CGFloat {
        settleLayout()
        guard let list, list.numberOfSections > 0,
              list.numberOfItems(inSection: 0) > 1 else { return 0 }
        let path = IndexPath(item: 1, section: 0)
        return list.collectionViewLayout.layoutAttributesForItem(at: path)?.frame.height ?? 0
    }

    /// **Not a formality.** SwiftUI answers a state change on a later run-loop turn and the
    /// collection view re-measures after that; read straight after a toggle, the height came
    /// back as the old one once and as a half-torn-down 52pt once. Every reading goes through
    /// this.
    private func settleLayout() {
        settle()
        list?.layoutIfNeeded()
        settle()
        list?.layoutIfNeeded()
    }

    /// Run-loop turns rather than an expectation: `@MainActor` tests here deadlock on
    /// `wait(for:)`, and what is being waited for is SwiftUI's own update pass, which is not an
    /// event anything signals.
    private func settle(_ turns: Int = 8) {
        for _ in 0..<turns {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func collectionView(in root: UIView) -> UICollectionView? {
        if let list = root as? UICollectionView { return list }
        for sub in root.subviews {
            if let found = collectionView(in: sub) { return found }
        }
        return nil
    }
}

/// The handles the harness reaches the mounted view through, and the probe's report coming back.
@MainActor
private final class Controls {
    var toggle: ((String) -> Void)?
    var setPresent: ((Bool) -> Void)?
    private(set) var appearances: [Int] = []

    func record(_ count: Int) { appearances.append(count) }
}

private struct HarnessView: View {
    let subject: TimelineItem
    let filler: [TimelineItem]
    let controls: Controls

    @State private var expansion = SessionTimelineScreen.Expansion()
    @State private var subjectIsInTheFeed = true

    var body: some View {
        List {
            if subjectIsInTheFeed {
                // The probe first, so it is on screen at rest: the subject below it is taller
                // than the window on its own, and a probe underneath one never appears at all —
                // which is how the first run of this file reported an empty log.
                RowLocalStateProbe(controls: controls)
                    .listRowSeparator(.hidden)
                TimelineRow(
                    item: subject,
                    isExpanded: expansion.isExpanded(subject.id),
                    toggleExpanded: { expansion.toggle(subject.id) }
                )
                .listRowSeparator(.hidden)
            }
            ForEach(filler, id: \.id) { item in
                TimelineRow(item: item)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .onAppear {
            controls.toggle = { id in expansion.toggle(id) }
            controls.setPresent = { present in subjectIsInTheFeed = present }
        }
    }
}

/// **The design this feature does not use, mounted so the test can watch what happens to it.**
///
/// A row with a `@State` of its own, counting how many times it has appeared. One appearance
/// means the round trip never happened; two mean the cell came back — and whether the count
/// resets is the measurement this file's own comment records.
private struct RowLocalStateProbe: View {
    let controls: Controls

    @State private var appearances = 0

    var body: some View {
        Color.clear
            .frame(height: 24)
            .onAppear {
                appearances += 1
                controls.record(appearances)
            }
    }
}
