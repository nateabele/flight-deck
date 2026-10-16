import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A fleet that answers nothing: these tests never fetch.
@MainActor
private final class NoFleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {}
    func markRead(_ id: UUID) {}
    func viewing(_ session: UUID?) {}
    func sendPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
    func answerPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
}

/// What is typed in a composer survives the process ending without warning — a crash, a force
/// quit, a deploy's relaunch — because it is written as it is typed, not on quit.
@MainActor
final class DraftStoreTests: XCTestCase {
    private func store() -> DraftStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DraftStore(directory: dir)
    }

    private func spill() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spill-\(UUID().uuidString)")
    }

    /// The whole point: a model that is simply gone — no quit, no background, nothing — and a
    /// new one for the same session opens with what was typed.
    func testWhatWasTypedIsThereInTheNextProcessAndASendClearsIt() {
        let drafts = store()
        let session = UUID()
        let typing = SessionTimelineModel(
            sessionID: session, fleet: NoFleet(), spillDirectory: spill(), drafts: drafts
        )
        typing.draft = "half a thought"
        typing.draft = "half a thought, finished"
        // No lifecycle call of any kind: the process just ends here.

        let relaunched = SessionTimelineModel(
            sessionID: session, fleet: NoFleet(), spillDirectory: spill(), drafts: drafts
        )
        XCTAssertEqual(relaunched.draft, "half a thought, finished")

        relaunched.draft = ""
        drafts.flush()
        XCTAssertNil(drafts.draft(for: session), "a sent message must not come back as a draft")
        let afterSend = SessionTimelineModel(
            sessionID: session, fleet: NoFleet(), spillDirectory: spill(), drafts: drafts
        )
        XCTAssertEqual(afterSend.draft, "")
    }

    func testDraftsAreKeptPerSessionPrunedAndPurged() {
        let drafts = store()
        let kept = UUID(), closed = UUID()
        drafts.save("for the live tab", for: kept)
        drafts.save("for a closed tab", for: closed)
        drafts.prune(keeping: [kept])
        XCTAssertEqual(drafts.draft(for: kept), "for the live tab")
        XCTAssertNil(drafts.draft(for: closed))
        drafts.purgeAll()
        XCTAssertNil(drafts.draft(for: kept), "unpairing takes every draft with it")
    }

    /// Through `FleetModel`, the way the app builds it: unpair forgets what was typed.
    func testUnpairingForgetsDrafts() {
        let drafts = store()
        let mac = PairedMac(key: .mint(), macName: "Mac", serviceName: "svc-\(UUID().uuidString)",
                            endpoints: [])
        let pairs = InMemoryPairedMacStore()
        pairs.save(mac)
        let session = UUID()
        drafts.save("typed under this pairing", for: session)
        let model = FleetModel(store: pairs, drafts: drafts)
        model.unpair()
        XCTAssertNil(drafts.draft(for: session))
    }
}
