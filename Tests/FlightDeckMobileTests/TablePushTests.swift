import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Opening a conversation that has tables in it must not freeze the phone.
///
/// On 2026-10-16 every tap on one session hung the phone until the watchdog killed it (iOS
/// 18.3.1, iPhone 15 Pro). The push put `KeyboardOverlapReader`'s host into the window, its first
/// read of `keyboardLayoutGuide` laid the whole window out synchronously, mid-transition, and
/// inside that layout `PlanTableView`'s height feedback (content height → preference → `@State` →
/// `.frame(height:)`) never settled. See `PlanTableView.width`.
///
/// The fixtures are that session's rows, every letter and digit scrambled: the same lengths,
/// tables, question and tags, none of the words. `table-push-cache.json` is the phone's cached
/// copy as it was, far enough behind the live edge that the screen draws it, throws it away, and
/// draws `table-push-latest.json` during the push — the sequence that hung.
///
/// **It reproduces on a device only.** The broken code passes in the simulator, on iOS 26.5 and
/// on 18.3.1 alike, and hung on the handset two runs out of two. `scripts/test-ios.sh` runs it on
/// a simulator, where it guards nothing but the sizing; run it on a phone to mean anything:
/// `-destination 'platform=iOS,name=<phone>' -only-testing:FlightDeckMobileTests/TablePushTests`.
@MainActor
final class TablePushTests: XCTestCase {
    /// Serves the fixture the way the Mac would: everything for the live edge, and for the
    /// restored feed's forward cursor a page with more behind it, which is what makes the screen
    /// discard the cache.
    final class Fleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
        let items: [TimelineItem]
        let session: UUID
        let source: String
        let first: Int
        let end: Int

        init(items: [TimelineItem], session: UUID, source: String) {
            self.items = items
            self.session = session
            self.source = source
            let offsets = items.compactMap { Int($0.id.prefix { $0 != "#" }) }
            first = offsets.min() ?? 0
            end = (offsets.max() ?? 0) + 1
        }

        func viewing(_ session: UUID?) {}
        func markRead(_ id: UUID) {}
        func timelinePage(_ request: FleetRequest,
                          then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void) {
            guard case .timeline(_, let anchor, _, let agent) = request, agent == nil else {
                return DispatchQueue.main.async { completion(.failure(.server(code: "unsupported"))) }
            }
            let page: TimelinePage
            switch anchor {
            case .latest, .around:
                page = TimelinePage(session: session, items: items, start: first, end: end,
                                    hasMore: true, reset: false, source: source)
            case .before:
                page = TimelinePage(session: session, items: [], start: first, end: first,
                                    hasMore: false, reset: false, source: source)
            case .after(let cursor) where cursor < first:
                page = TimelinePage(session: session, items: Array(items.prefix(10)), start: cursor, end: first,
                                    hasMore: true, reset: false, source: source)
            case .after:
                page = TimelinePage(session: session, items: [], start: end, end: end,
                                    hasMore: false, reset: false, source: source)
            }
            // A round trip's worth later, so the page lands while the push is still animating.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion(.success(page)) }
        }
        func sendPrompt(_ command: FleetCommand,
                        then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
        func answerPrompt(_ command: FleetCommand,
                          then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
    }

    @Observable final class Path { var ids: [UUID] = [] }

    /// The fleet list's shape: a row, and the conversation pushed by its id.
    struct Root: View {
        let session: WireSession
        let model: SessionTimelineModel
        @Bindable var path: Path

        var body: some View {
            NavigationStack(path: $path.ids) {
                List { NavigationLink(session.title, value: session.id) }
                    .navigationDestination(for: UUID.self) { _ in
                        SessionTimelineScreen(session: session, model: model, onAbortBlocked: { _ in })
                    }
            }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testPushingAConversationWithTablesFromItsCacheFinishes() throws {
        let session = try JSONDecoder().decode(WireSession.self, from: fixture("table-push-session"))
        let items = try JSONDecoder().decode([TimelineItem].self, from: fixture("table-push-latest"))
        let cacheData = try fixture("table-push-cache")
        let source = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: cacheData) as? [String: Any])?["source"] as? String)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let timelines = root.appendingPathComponent("timelines")
        try FileManager.default.createDirectory(at: timelines, withIntermediateDirectories: true)
        try cacheData.write(to: timelines.appendingPathComponent("\(session.id.uuidString).json"))

        let fleet = Fleet(items: items, session: session.id, source: source)
        let model = SessionTimelineModel(sessionID: session.id, fleet: fleet, cache: PhoneCache(directory: root))
        let path = Path()
        let controller = UIHostingController(rootView: Root(session: session, model: model, path: path))
        // In the app's own scene, as the real window is. The keyboard layout guide is kept per
        // scene, and a window outside one never takes the path that hung.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        spin(window, for: 0.5)
        path.ids = [session.id]
        let longest = spin(window, for: 5)

        XCTAssertEqual(model.rendered.count, TimelineRender.entries(from: items).count, "the live edge replaced the cache")
        // A hang never returns at all, and the test runs out its time allowance instead. The bound
        // is for a stall that does end: well over a Debug build's ~0.6s first draw on a phone.
        XCTAssertLessThan(longest, 2, "the main thread was held for \(longest)s")
    }

    /// Runs the main run loop for `seconds`, returning the longest single turn.
    @discardableResult
    private func spin(_ window: UIWindow, for seconds: TimeInterval) -> TimeInterval {
        var longest: TimeInterval = 0
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            let start = Date()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            longest = max(longest, Date().timeIntervalSince(start))
        }
        return longest
    }
}
