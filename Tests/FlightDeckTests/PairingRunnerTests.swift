import Foundation
import Network
import XCTest
@testable import FleetKit

/// Spec §7's discovery arm: 0 Macs, 1 Mac, 2+ Macs.
///
/// Every ordering test drives `start(code:candidates:)` with a list built by hand rather than
/// `start(code:)` with a real browse, and that is deliberate rather than a shortcut: a
/// development machine has a real Flight Deck on it, so a browse-driven ordering test would
/// depend on what else is armed on the LAN. Real discovery is proved once, in
/// `PairingDiscoveryTests`, and wired in `testABrowseWithNothingArmedReportsNoMacsFound`.
@MainActor
final class PairingRunnerTests: XCTestCase {
    private var listeners: [PairingListener] = []
    private var initiators: [PairingInitiator] = []
    private var runner: PairingRunner?

    override func tearDown() async throws {
        runner?.cancel()
        runner = nil
        for initiator in initiators { initiator.cancel() }
        initiators.removeAll()
        for listener in listeners { listener.stop() }
        listeners.removeAll()
    }

    private func arm(
        code: PairingCode, macName: String
    ) async throws -> (PairingListener, PairingBrowser.DiscoveredMac) {
        let listener = PairingListener()
        listeners.append(listener)
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let port = try await listener.start(
            code: code, key: .mint(), macName: macName, serviceName: serviceName, port: nil
        )
        return (listener, PairingBrowser.DiscoveredMac(
            serviceName: serviceName, displayName: macName,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        ))
    }

    private struct Outcome {
        var key: FleetDeviceKey?
        var serviceName: String?
        var macName: String?
        var progress: [PairingRunner.Progress] = []
    }

    private func run(
        code: PairingCode, candidates: [PairingBrowser.DiscoveredMac]
    ) async -> Outcome {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome = Outcome()
        let runner = PairingRunner()
        self.runner = runner
        runner.onProgress = { progress in
            MainActor.assumeIsolated {
                outcome.progress.append(progress)
                switch progress {
                case .noMacsFound, .failed, .paired: settled.fulfill()
                default: break
                }
            }
        }
        runner.onPaired = { key, serviceName, macName in
            MainActor.assumeIsolated {
                outcome.key = key
                outcome.serviceName = serviceName
                outcome.macName = macName
            }
        }
        runner.start(code: code, candidates: candidates)
        await fulfillment(of: [settled], timeout: 30)
        return outcome
    }

    func testOneArmedMacPairsAndReportsTheNameItWasDiscoveredUnder() async throws {
        let code = PairingCode.mint()
        let (_, mac) = try await arm(code: code, macName: "Nate's MacBook")
        let outcome = await run(code: code, candidates: [mac])

        XCTAssertNotNil(outcome.key)
        // The Bonjour instance name, not the display name: it is what `FleetConnector` matches
        // on to find this Mac again, and a typed pair stores no endpoints at all.
        XCTAssertEqual(outcome.serviceName, mac.serviceName)
        // The display name comes out of the *seal*, not out of the TXT record — the TXT
        // record is unauthenticated until this point.
        XCTAssertEqual(outcome.macName, "Nate's MacBook")
        XCTAssertEqual(outcome.progress.last, .paired)
    }

    /// Two Macs armed, the code belonging to the second. The first is tried, refuses, and the
    /// runner moves on — spending exactly one attempt on the wrong Mac and none on the right
    /// one. That last clause is the spec's per-Mac rule seen from the phone's side.
    func testTheRunnerWalksPastAWrongMacAndPairsWithTheRightOne() async throws {
        let wrongCode = PairingCode.mint()
        let rightCode = PairingCode.mint()
        let (wrongMac, wrongCandidate) = try await arm(code: wrongCode, macName: "Other Mac")
        let (rightMac, rightCandidate) = try await arm(code: rightCode, macName: "Nate's MacBook")

        let outcome = await run(code: rightCode, candidates: [wrongCandidate, rightCandidate])

        XCTAssertNotNil(outcome.key)
        XCTAssertEqual(outcome.macName, "Nate's MacBook")
        XCTAssertEqual(wrongMac.attemptsSpent, 1)
        XCTAssertEqual(rightMac.attemptsSpent, 0)
        XCTAssertEqual(
            outcome.progress.prefix(3).map(String.init(describing:)),
            [
                PairingRunner.Progress.searching,
                .trying(displayName: "Other Mac"),
                .trying(displayName: "Nate's MacBook")
            ].map(String.init(describing:)),
            "the runner must try candidates in the order it was given them"
        )
    }

    /// A Mac whose window is already burned — by an earlier typo, or by a stranger on the LAN
    /// guessing at it — is one Mac's problem and not the run's. The budget is per Mac, per
    /// window (spec §7), so `.attemptsExhausted` from the first candidate must not be treated
    /// as a verdict on the walk: the right Mac still has all three of its guesses and this
    /// user needs none of them.
    func testABurnedMacDoesNotEndTheWalkForTheOnesBehindIt() async throws {
        let code = PairingCode.mint()
        let (_, burned) = try await arm(code: .mint(), macName: "Burned")
        await spendTheWholeBudget(of: burned)
        let (right, rightCandidate) = try await arm(code: code, macName: "Nate's MacBook")

        let outcome = await run(code: code, candidates: [burned, rightCandidate])

        XCTAssertNotNil(outcome.key)
        XCTAssertEqual(outcome.macName, "Nate's MacBook")
        XCTAssertEqual(
            right.attemptsSpent, 0, "another Mac's burned window cost the right Mac a guess"
        )
        XCTAssertEqual(outcome.progress.last, .paired)
    }

    /// Everything refused. The verdict the user sees is the last Mac's, not a generic one —
    /// "no Mac accepted that code" and "that Mac's window is burned" send them to different
    /// places.
    func testWhenEveryMacRefusesTheLastVerdictIsReported() async throws {
        let (_, first) = try await arm(code: .mint(), macName: "One")
        let (_, second) = try await arm(code: .mint(), macName: "Two")
        let outcome = await run(code: .mint(), candidates: [first, second])

        XCTAssertNil(outcome.key)
        XCTAssertEqual(outcome.progress.last, .failed(.wrongCode))
    }

    func testNoCandidatesReportsNoMacsFoundRatherThanAFailure() async throws {
        let outcome = await run(code: .mint(), candidates: [])
        XCTAssertNil(outcome.key)
        XCTAssertEqual(outcome.progress.last, .noMacsFound)
        XCTAssertFalse(
            outcome.progress.contains { if case .failed = $0 { return true } else { return false } },
            "an empty network is not a pairing failure and must not be reported as one"
        )
    }

    /// The browse-driven entry point, exercised once end to end. Nothing is armed by this
    /// test, so the only correct answer after the discovery window is `noMacsFound` — unless a
    /// real Flight Deck on the LAN happens to be armed, in which case this is skipped rather
    /// than failed, because the network is not the thing under test.
    func testABrowseWithNothingArmedReportsNoMacsFound() async throws {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var last: PairingRunner.Progress?
        let runner = PairingRunner()
        self.runner = runner
        runner.discoveryWindow = 2
        runner.onProgress = { progress in
            MainActor.assumeIsolated {
                last = progress
                switch progress {
                case .noMacsFound, .failed, .paired: settled.fulfill()
                default: break
                }
            }
        }
        runner.start(code: .mint())
        await fulfillment(of: [settled], timeout: 30)
        if case .failed = last {
            throw XCTSkip("another Flight Deck on this LAN is armed for pairing")
        }
        XCTAssertEqual(last, .noMacsFound)
    }

    /// Burns a Mac's whole window with wrong codes, so a test can hand the runner a candidate
    /// that is already spent rather than one the runner spends itself.
    private func spendTheWholeBudget(of mac: PairingBrowser.DiscoveredMac) async {
        for index in 1...PairingListener.maxAttempts {
            let settled = expectation(description: "attempt \(index) settled")
            let initiator = PairingInitiator()
            initiators.append(initiator)
            initiator.onPaired = { _, _ in XCTFail("a wrong code paired") }
            initiator.onFailure = { _ in MainActor.assumeIsolated { settled.fulfill() } }
            initiator.start(code: .mint(), endpoint: mac.endpoint)
            await fulfillment(of: [settled], timeout: 15)
        }
    }
}
