import Foundation
import Network
import XCTest
@testable import FleetKit

/// Spec §7: "Rate limiting is per-Mac, per-window. … It is explicitly *not* a global counter:
/// a phone legitimately trying three discovered Macs must not exhaust the budget on the right
/// one. A failed *checksum* is not an attempt — it never reaches the Mac."
@MainActor
final class PairingRateLimitTests: XCTestCase {
    private var listeners: [PairingListener] = []
    private var initiators: [PairingInitiator] = []

    override func tearDown() async throws {
        for initiator in initiators { initiator.cancel() }
        for listener in listeners { listener.stop() }
        initiators.removeAll()
        listeners.removeAll()
    }

    private func arm(code: PairingCode) async throws -> (PairingListener, NWEndpoint) {
        let listener = PairingListener()
        listeners.append(listener)
        let port = try await listener.start(
            code: code, key: .mint(), macName: "Mac \(listeners.count)",
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return (listener, .hostPort(host: "127.0.0.1", port: port))
    }

    @discardableResult
    private func attempt(
        code: PairingCode, endpoint: NWEndpoint
    ) async -> Result<FleetDeviceKey, PairingInitiator.Failure> {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome: Result<FleetDeviceKey, PairingInitiator.Failure>?
        let initiator = PairingInitiator()
        initiators.append(initiator)
        initiator.onPaired = { key, _ in
            MainActor.assumeIsolated { outcome = .success(key); settled.fulfill() }
        }
        initiator.onFailure = { failure in
            MainActor.assumeIsolated { outcome = .failure(failure); settled.fulfill() }
        }
        initiator.start(code: code, endpoint: endpoint)
        await fulfillment(of: [settled], timeout: 15)
        return outcome ?? .failure(.unreachable)
    }

    func testThreeWrongCodesBurnTheWindowAndTheFourthIsRefusedEvenWhenCorrect() async throws {
        let code = PairingCode.mint()
        let (listener, endpoint) = try await arm(code: code)
        let exhausted = expectation(description: "exhausted")
        listener.onAttemptsExhausted = { exhausted.fulfill() }

        for index in 1...PairingListener.maxAttempts {
            let outcome = await attempt(code: .mint(), endpoint: endpoint)
            guard case .failure(let failure) = outcome else {
                return XCTFail("a wrong code paired on attempt \(index)")
            }
            XCTAssertEqual(
                failure,
                index < PairingListener.maxAttempts ? .wrongCode : .attemptsExhausted,
                "attempt \(index) reported the wrong verdict"
            )
        }
        await fulfillment(of: [exhausted], timeout: 5)
        XCTAssertEqual(listener.attemptsSpent, PairingListener.maxAttempts)

        // The correct code, after the budget is gone. The listener is still up — closing it is
        // `FleetService`'s job, proved in Task 8 — so this is the listener refusing on its own
        // terms rather than the port simply being closed.
        guard case .failure(let afterwards) = await attempt(code: code, endpoint: endpoint) else {
            return XCTFail("the correct code paired after the window was burned")
        }
        XCTAssertEqual(afterwards, .attemptsExhausted)
        XCTAssertEqual(
            listener.attemptsSpent, PairingListener.maxAttempts,
            "a refusal after exhaustion must not increment the counter further"
        )
    }

    /// The isolation the spec calls out by name. A phone that types the right code but reaches
    /// the wrong Mac first must not arrive at the right one with a spent budget.
    func testAWrongMacSpendsAnAttemptOnlyOnItself() async throws {
        let wrongCode = PairingCode.mint()
        let rightCode = PairingCode.mint()
        let (wrongMac, wrongEndpoint) = try await arm(code: wrongCode)
        let (rightMac, rightEndpoint) = try await arm(code: rightCode)

        guard case .failure = await attempt(code: rightCode, endpoint: wrongEndpoint) else {
            return XCTFail("the wrong Mac accepted a code it never minted")
        }
        XCTAssertEqual(wrongMac.attemptsSpent, 1)
        XCTAssertEqual(rightMac.attemptsSpent, 0, "an attempt landed on the wrong Mac's budget")

        guard case .success = await attempt(code: rightCode, endpoint: rightEndpoint) else {
            return XCTFail("the right Mac refused the right code")
        }
        XCTAssertEqual(rightMac.attemptsSpent, 0)
    }

    /// A mistyped code is rejected on the phone and never reaches the Mac (spec §4, §7).
    ///
    /// Two things carry this, and only one of them is a runtime check. `PairingInitiator.start`
    /// takes a `PairingCode`, not a `String`, so a code that failed its checksum cannot be
    /// handed to it at all — the type is the enforcement. This exercises the other half: that
    /// a single-character typo really does fail `PairingCode(normalizing:)`, across the whole
    /// alphabet and every position, so the type-level guarantee is reachable in practice. The
    /// Mac's counter never moves.
    func testASingleCharacterTypoNeverReachesTheMac() async throws {
        let code = PairingCode.mint()
        let (listener, _) = try await arm(code: code)
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var symbols = Array(code.formatted.filter { $0 != "-" })

        // Without this, the loop below is exercise with no verdict: it always leaves
        // `listener` untouched regardless of whether `PairingCode(normalizing:)` rejects
        // anything at all, which would make the assertion below true unconditionally.
        var caughtAtLeastOneTypo = false

        for position in symbols.indices {
            let original = symbols[position]
            for replacement in alphabet where replacement != original {
                symbols[position] = replacement
                let typo = String(symbols)
                if PairingCode(normalizing: typo) != nil {
                    // 5 bits of checksum: roughly one typo in 32 collides, by construction.
                    // Those are the ones that DO reach the Mac and spend an attempt, which is
                    // the tradeoff the spec accepts. Not a failure — just not a local catch.
                    continue
                }
                caughtAtLeastOneTypo = true
            }
            symbols[position] = original
        }
        XCTAssertTrue(
            caughtAtLeastOneTypo, "not one single-character typo was rejected by the checksum"
        )
        XCTAssertEqual(
            listener.attemptsSpent, 0,
            "validating typos locally must not touch the network at all"
        )
    }

    /// The checksum catches the overwhelming majority of single-character typos, which is what
    /// makes "that code doesn't look right" a useful thing for the phone to say. Pinned as a
    /// rate rather than as "every typo", because 5 bits cannot catch every one.
    func testTheChecksumCatchesNearlyEverySingleCharacterTypo() {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var caught = 0
        var total = 0
        for _ in 0..<20 {
            let code = PairingCode.mint()
            var symbols = Array(code.formatted.filter { $0 != "-" })
            for position in symbols.indices {
                let original = symbols[position]
                for replacement in alphabet where replacement != original {
                    symbols[position] = replacement
                    total += 1
                    if PairingCode(normalizing: String(symbols)) == nil { caught += 1 }
                }
                symbols[position] = original
            }
        }
        // 5 bits of checksum ⇒ ~1/32 collide ⇒ ~96.9% caught. The floor is loose enough not to
        // flake and tight enough that a checksum that stopped working would fail it.
        XCTAssertGreaterThan(Double(caught) / Double(total), 0.9)
    }
}
