import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// **Scrolling a conversation must not re-run `SessionTimelineScreen.body`.**
///
/// Each run of that body rebuilds the `List`, and SwiftUI then re-diffs the `ForEach` identity
/// over every row in the conversation and re-runs each visible row's modifier chain. That work
/// is O(conversation). The phone's stall samples were mostly inside it
/// (`SectionAccumulator`, `ForEach.IDGenerator.makeID`, `ViewList` sublists). A scroll makes
/// rows appear and disappear, and every one of those callbacks used to write `@State` on the
/// screen. So a scroll paid that O(conversation) diff once per row crossing the edge.
///
/// The test drives a real 6,000pt scroll, in small steps like a finger, against the real screen
/// in a real key window, and counts body runs while it goes.
@MainActor
final class ScrollBodyCostTests: XCTestCase {
    final class Fleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
        let items: [TimelineItem]
        let session: UUID

        init(items: [TimelineItem], session: UUID) {
            self.items = items
            self.session = session
        }

        func viewing(_ session: UUID?) {}
        func markRead(_ id: UUID) {}
        func timelinePage(_ request: FleetRequest,
                          then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void) {
            let end = items.count * 10
            let page: TimelinePage
            switch request {
            case .timeline(_, .latest, _, _), .timeline(_, .around, _, _):
                page = TimelinePage(session: session, items: items, start: 0, end: end,
                                    hasMore: false, reset: false, source: "test")
            default:
                page = TimelinePage(session: session, items: [], start: end, end: end,
                                    hasMore: false, reset: false, source: "test")
            }
            DispatchQueue.main.async { completion(.success(page)) }
        }
        func sendPrompt(_ command: FleetCommand,
                        then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
        func answerPrompt(_ command: FleetCommand,
                          then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
    }

    /// A conversation long enough that a 6,000pt scroll moves dozens of rows across both edges:
    /// prose answers, and tool calls with results, as a real session alternates them.
    private func conversation(_ turns: Int = 150) -> [TimelineItem] {
        (0..<turns).flatMap { turn -> [TimelineItem] in
            let base = turn * 30
            return [
                TimelineItem(
                    id: "\(base)#0", kind: .assistantText, status: .complete,
                    body: .init(text: "Turn \(turn). A reply of a few sentences, so the row has "
                        + "some height. It mentions `code` and **bold** text, like real prose.")
                ),
                TimelineItem(
                    id: "\(base + 10)#0", kind: .toolCall, status: .complete,
                    body: .init(text: "{\"command\":\"ls -la\"}", tool: "Bash",
                                callID: "call-\(turn)")
                ),
                TimelineItem(
                    id: "\(base + 20)#0", kind: .toolResult, status: .complete,
                    body: .init(text: "total 8\nfile-\(turn).swift\n", callID: "call-\(turn)")
                ),
            ]
        }
    }

    func testScrollingAConversationDoesNotReRunTheScreenBody() throws {
        let id = UUID()
        let fleet = Fleet(items: conversation(), session: id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SessionTimelineModel(sessionID: id, fleet: fleet, cache: PhoneCache(directory: root))
        let controller = UIHostingController(rootView: NavigationStack {
            SessionTimelineScreen(session: nil, model: model, onAbortBlocked: { _ in })
        })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        spin(window, for: 2)
        XCTAssertFalse(model.rendered.isEmpty, "the page never landed, so nothing below means anything")
        let list = try XCTUnwrap(collectionView(in: window), "the screen mounted no List")
        XCTAssertGreaterThan(list.contentSize.height, 9_000, "the conversation is too short to scroll 6,000pt")

        // The open jumps to the bottom; scroll up from there, the way a reader goes back.
        let start = list.contentOffset.y
        SessionTimelineScreen.bodyEvaluations = 0
        var appeared = Set<IndexPath>(list.indexPathsForVisibleItems)
        for step in 1...120 {
            list.setContentOffset(CGPoint(x: 0, y: max(0, start - CGFloat(step) * 50)), animated: false)
            spin(window, for: 0.02)
            appeared.formUnion(list.indexPathsForVisibleItems)
        }
        let runs = SessionTimelineScreen.bodyEvaluations

        XCTAssertGreaterThan(
            appeared.count, 40,
            "too few rows crossed the screen edge for the count below to mean anything"
        )
        XCTAssertLessThanOrEqual(
            runs, 2,
            "a 6,000pt scroll across \(appeared.count) rows re-ran the screen body \(runs) times"
        )
    }

    /// The fleet list's shape: the screen is built from the fleet's copy of its session, with
    /// fresh callback closures each time. A fleet update hands the screen a new `WireSession`
    /// whenever anything about this session moved; here that is its title, which the screen
    /// draws in the navigation bar and the conversation list does not draw at all.
    @Observable final class FleetBox {
        var session: WireSession
        init(session: WireSession) { self.session = session }
    }

    struct Host: View {
        let box: FleetBox
        let model: SessionTimelineModel

        var body: some View {
            NavigationStack {
                // Capturing, as `FleetListScreen`'s closures capture its `FleetModel`.
                SessionTimelineScreen(
                    session: box.session, model: model,
                    onAbortBlocked: { [box] _ in _ = box.session },
                    loadAccounts: { [box] _ in _ = box.session; return .failure(.disconnected) }
                )
            }
        }
    }

    func testASessionUpdateTheListDoesNotDrawDoesNotReDiffTheConversation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "table-push-session", withExtension: "json"))
        var session = try JSONDecoder().decode(WireSession.self, from: Data(contentsOf: url))
        session.activity = "idle"
        session.apiError = nil
        let fleet = Fleet(items: conversation(), session: session.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SessionTimelineModel(sessionID: session.id, fleet: fleet, cache: PhoneCache(directory: root))
        let box = FleetBox(session: session)
        let controller = UIHostingController(rootView: Host(box: box, model: model))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        spin(window, for: 2)
        XCTAssertFalse(model.rendered.isEmpty, "the page never landed")

        SessionTimelineScreen.bodyEvaluations = 0
        SessionTimelineScreen.listBodyEvaluations = 0
        for tick in 1...20 {
            box.session.title = "Renamed \(tick)"
            spin(window, for: 0.1)
        }
        let screenRuns = SessionTimelineScreen.bodyEvaluations
        let listRuns = SessionTimelineScreen.listBodyEvaluations

        // Updates landing in one frame coalesce, so not every tick re-runs the screen. Enough of
        // them must, or the assertion below is about nothing.
        XCTAssertGreaterThanOrEqual(screenRuns, 5, "the screen barely re-ran, so this measured nothing")
        XCTAssertEqual(
            listRuns, 0,
            "\(screenRuns) session updates the list does not draw re-diffed the conversation "
            + "\(listRuns) times"
        )
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for sub in view.subviews {
            if let found = collectionView(in: sub) { return found }
        }
        return nil
    }

    private func spin(_ window: UIWindow, for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
