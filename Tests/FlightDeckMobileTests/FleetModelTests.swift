import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A store that refuses every write, standing in for the two keychain failures seen for real:
/// a build with no access group (`errSecMissingEntitlement`, -34018) and a device that has
/// not been unlocked since boot. `InMemoryPairedMacStore` cannot express either — its `save`
/// does not throw at all — which is why the failing half lives here.
private final class RefusingPairedMacStore: PairedMacStoring {
    static let status: OSStatus = -34018
    private(set) var saveAttempts = 0

    func load() -> PairedMac? { nil }

    func save(_ mac: PairedMac) throws {
        saveAttempts += 1
        throw PairedMacStoreError.keychainWriteFailed(status: Self.status)
    }

    func clear() {}
}

@MainActor
final class FleetModelTests: XCTestCase {
    /// The QR path. A pairing that exists only in memory looks exactly like a working one —
    /// the fleet arrives, the list fills in — right up until the next launch, when `load()`
    /// returns nil and the phone is back at the pairing screen with nothing to explain why.
    /// So the save has to come first and its failure has to abort: `mac` staying `nil` is the
    /// assertion that matters, and the thrown status is what the screen puts on the screen.
    func testAdoptingAScannedCodeSurfacesAKeychainFailureInsteadOfPairingAnyway() {
        let store = RefusingPairedMacStore()
        let model = FleetModel(store: store)

        XCTAssertThrowsError(try model.adopt(code: Self.scannableCode())) { error in
            XCTAssertEqual(
                error as? PairedMacStoreError,
                .keychainWriteFailed(status: RefusingPairedMacStore.status)
            )
        }
        XCTAssertEqual(store.saveAttempts, 1)
        XCTAssertNil(model.mac, "a pairing that could not be stored must not look adopted")
    }

    /// The typed path's completion, where the same failure cannot be thrown — the SPAKE2
    /// exchange has already succeeded by the time this runs, on a callback nobody can `try`.
    /// It has to become copy instead, and the status has to survive into it: -34018 is a
    /// developer problem and `errSecInteractionNotAllowed` is not, and the number is the only
    /// thing that tells them apart.
    func testTypedPairingReportsAKeychainFailureInsteadOfLookingPaired() {
        let store = RefusingPairedMacStore()
        let model = FleetModel(store: store)

        model.adopt(key: .mint(), serviceName: "Studio._flightdeck._tcp", macName: "Studio")

        XCTAssertNil(model.mac, "a pairing that could not be stored must not look adopted")
        XCTAssertEqual(
            model.pairingFailure,
            "Couldn't save this pairing to the keychain (error -34018)."
        )
    }

    /// Two failures, opposite instructions. `.wrongCode` sends the user back to the keyboard;
    /// `.attemptsExhausted` says that Mac's window is burned and only a new code will do.
    /// Swapping them spends one of three tries teaching the user nothing — and neither string
    /// is reachable from the Mac's side, so nothing but this notices.
    func testWrongCodeAndExhaustedAttemptsSendTheUserInOppositeDirections() {
        XCTAssertEqual(
            FleetModel.message(for: .wrongCode),
            "No Mac on this network accepted that code. Check it against your Mac's screen."
        )
        XCTAssertEqual(
            FleetModel.message(for: .attemptsExhausted),
            "Too many tries. Show a new code on your Mac and start again."
        )
    }

    /// The other two are distinct for the same reason: one sends the user to the network and
    /// one to the App Store, and a single "pairing failed" for all four would send them
    /// nowhere. Asserted as four distinct strings rather than four literals, so this keeps
    /// working when the copy is reworded and stops working when two branches collapse.
    func testEveryPairingFailureGetsItsOwnMessage() {
        let messages = [
            PairingInitiator.Failure.wrongCode,
            .attemptsExhausted,
            .connectionFailed,
            .malformedResponse,
        ].map(FleetModel.message(for:))

        XCTAssertEqual(Set(messages).count, 4, "two failures share one message: \(messages)")
        XCTAssertFalse(messages.contains(where: \.isEmpty))
    }

    /// The history channel's one entry point from the phone, and the only thing it must never
    /// do is nothing. A request has no second channel — a command's effect comes back as a
    /// northbound event, so dropping one is merely ineffective, while dropping a request is a
    /// screen spinning on a page that will never arrive. With no paired Mac there is no
    /// connector to forward to, so the refusal has to be manufactured here, and it has to
    /// arrive **before this call returns**: `SessionTimelineModel` arms its deadline ahead of
    /// the request precisely because this completion can run inside the frame that started it.
    func testAskingForAPageWithNothingConnectedIsRefusedBeforeTheCallReturns() {
        let model = FleetModel(store: RefusingPairedMacStore())
        var answer: Result<TimelinePage, FleetRequestError>?

        model.timelinePage(.timeline(session: UUID(), anchor: .latest, limit: 40)) {
            answer = $0
        }

        guard case .failure(let error)? = answer else {
            return XCTFail("a request with no connector answered \(String(describing: answer))")
        }
        XCTAssertEqual(error, .disconnected)
    }

    /// **The model behind a session screen is made once and kept**, and the reason is not
    /// bandwidth. A `navigationDestination` closure re-runs on any change to what it reads —
    /// a fleet event, a rename, the connection state — so a model constructed inside it would
    /// be a *new* model with an empty feed each time, and the conversation would empty itself
    /// under the reader while a poll or a status change ran in the background.
    func testOpeningASessionTwiceKeepsTheConversationThePhoneAlreadyHolds() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let session = UUID()

        XCTAssertTrue(
            model.timelineModel(for: session) === model.timelineModel(for: session),
            "a second visit to the same session must find the pages it already downloaded"
        )
        XCTAssertFalse(
            model.timelineModel(for: session) === model.timelineModel(for: UUID()),
            "and two sessions must not share one feed"
        )
    }

    /// Held conversation content is as much "this pairing" as the fleet snapshot is: a phone
    /// that unpaired and kept a transcript in memory is showing the user something they
    /// believe they revoked. The `phase` is what proves the old model was carrying state — it
    /// only reaches `.failed` because this model asked for a page and was refused.
    func testUnpairingDropsHeldConversationsRatherThanKeepingThemInMemory() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let session = UUID()
        let before = model.timelineModel(for: session)
        before.loadLatest()
        XCTAssertEqual(before.phase, .failed("Not connected to your Mac."),
                       "the premise: this model is holding something")

        model.unpair()

        let after = model.timelineModel(for: session)
        XCTAssertFalse(before === after, "the revoked pairing's transcript is still in memory")
        XCTAssertEqual(after.phase, .idle)
    }

    /// A real `FD2-` code, minted here rather than checked in: `PairingPayload.encoded()` is
    /// the Mac's own encoder, so this exercises the decode `adopt(code:)` actually performs.
    private static func scannableCode() -> String {
        PairingPayload(
            key: .mint(), macName: "Studio",
            serviceName: "Studio._flightdeck._tcp", endpoints: []
        ).encoded()
    }
}
