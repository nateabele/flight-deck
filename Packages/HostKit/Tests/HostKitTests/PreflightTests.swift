import XCTest
@testable import HostKit

/// Spec §7: seven checks, in order, before any sync or remote work; a failure releases what
/// was reserved and is one 125 line naming the next step.
final class PreflightTests: XCTestCase {
    private let plan = PreflightPlan(host: "mini", ports: [PortMapping(local: .fixed(15432), remote: 5432),
                                                           PortMapping(local: .auto, remote: 3000)],
                                     screen: true, service: true, sync: true, include: ["secrets.env"], fetch: ["build/**"])

    func testPreflightOrderIsExact() async throws {
        let checks = RecordingChecks(plan: plan)
        let reservation = try await Preflight.run(checks)
        XCTAssertEqual(checks.calls, ["resolve", "host", "paths", "localPorts", "remotePorts", "screen", "lfs"])
        XCTAssertEqual(checks.remotePortsAsked, [5432, 3000])
        XCTAssertEqual(reservation.plan, plan)
        XCTAssertEqual(reservation.forwards, [PortForward(local: 15432, remote: 5432), PortForward(local: 50123, remote: 3000)])
        XCTAssertEqual(checks.releases, 0, "a passing preflight hands its ports on, it does not drop them")
    }

    /// Steps with nothing to check are skipped, not called with empty input: an `exec` with
    /// no ports and no screen never asks the host about ports or the console.
    func testStepsWithNothingToCheckAreSkipped() async throws {
        let bare = PreflightPlan(host: "mini", ports: [], screen: false, service: false, sync: false)
        let checks = RecordingChecks(plan: bare)
        let reservation = try await Preflight.run(checks)
        XCTAssertEqual(checks.calls, ["resolve", "host", "paths", "lfs"])
        XCTAssertEqual(reservation.forwards, [])
    }

    /// A failure at any step stops every later one and releases the local ports if step 4 had
    /// already taken them; nothing is left bound for a retry to trip over.
    func testEachFailureStopsLaterStepsAndReleasesPorts() async {
        let order = ["resolve", "host", "paths", "localPorts", "remotePorts", "screen", "lfs"]
        for (i, step) in order.enumerated() {
            let checks = RecordingChecks(plan: plan, failAt: step)
            do {
                _ = try await Preflight.run(checks)
                XCTFail("\(step): expected a failure")
            } catch let error as DelegationError {
                XCTAssertEqual(error.code, "boom_\(step)", step)
            } catch {
                XCTFail("\(step): not a DelegationError: \(error)")
            }
            XCTAssertEqual(checks.calls, Array(order.prefix(i + 1)), step)
            XCTAssertEqual(checks.releases, i > 3 ? 1 : 0, step)
        }
    }

    /// Review Focus 3 at the pipeline level: a held local port fails at step 4, before the
    /// host is asked anything about ports, screen or LFS (and so before any sync).
    func testHeldPortFailsBeforeRemoteWork() async {
        let checks = RecordingChecks(plan: plan, localPortError: .localPortHeld(
            local: 15432, remote: 5432, holder: .process(name: "postgres", pid: 812), suggestion: 25432))
        do {
            _ = try await Preflight.run(checks)
            XCTFail("expected a failure")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "port_held")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(checks.calls, ["resolve", "host", "paths", "localPorts"])
    }

    func testLocalPortMessageIsTheSpecsExample() {
        let e = DelegationError.localPortHeld(local: 5432, remote: 5432, holder: .process(name: "postgres", pid: 812), suggestion: 15433)
        XCTAssertEqual(e.message, "localhost:5432 is held by postgres (pid 812); try --port 15433:5432 or --port auto:5432")
        XCTAssertEqual(e.description, "flightdeck: localhost:5432 is held by postgres (pid 812); try --port 15433:5432 or --port auto:5432")
        XCTAssertEqual(DelegationError.exitStatus, 125)

        let own = DelegationError.localPortHeld(local: 8080, remote: 80, holder: .flightDeck(session: "api"), suggestion: nil)
        XCTAssertEqual(own.message, #"localhost:8080 is held by Flight Deck session "api"; try --port auto:80"#)
    }

    func testRemotePortHeldNamesTheContainerAndTheHost() async {
        let checks = RecordingChecks(plan: plan, remote: [PortStatus(port: 5432, holder: .free),
                                                          PortStatus(port: 3000, holder: .container(name: "web-1"))])
        do {
            _ = try await Preflight.run(checks)
            XCTFail("expected a failure")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "port_held")
            XCTAssertEqual(error.message, #"mini:3000 is held by Docker container "web-1"; stop it on mini (docker stop web-1), or change the recipe's remote port"#)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(checks.releases, 1)
    }

    func testRemoteProcessAndUnknownHolders() {
        XCTAssertEqual(DelegationError.remotePortHeld(host: "mini", port: 5432, holder: .process(name: "postgres", pid: 90)).message,
                       "mini:5432 is held by postgres (pid 90); stop it on mini, or change the recipe's remote port")
        XCTAssertEqual(DelegationError.remotePortHeld(host: "mini", port: 5432, holder: .unknown).message,
                       "mini:5432 is held by another process; stop it on mini, or change the recipe's remote port")
    }

    /// A host that answers "free" for fewer ports than asked has not checked them all; that
    /// is not a pass.
    func testMissingRemoteAnswerFails() async {
        let checks = RecordingChecks(plan: plan, remote: [PortStatus(port: 5432, holder: .free)])
        do {
            _ = try await Preflight.run(checks)
            XCTFail("expected a failure")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "remote_port_unchecked")
        } catch { XCTFail("\(error)") }
    }

    func testHostNotConnectedOrMissingCapability() async {
        for (caps, code, message) in [
            (nil, "host_unavailable", "mini is not connected; check flightdeck host ls, and that hostd is running on mini"),
            (Set<HostCapability>([.hostInfo, .run, .sync]), "unsupported",
             "mini's hostd does not support services and screen runs; update Flight Deck on mini, then retry"),
        ] as [(Set<HostCapability>?, String, String)] {
            let checks = RecordingChecks(plan: plan, capabilities: caps)
            do {
                _ = try await Preflight.run(checks)
                XCTFail("expected a failure")
            } catch let error as DelegationError {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.message, message)
            } catch { XCTFail("\(error)") }
            XCTAssertEqual(checks.calls, ["resolve", "host"])
        }
    }

    /// The lease itself queues (§7 step 6); only an unusable console fails.
    func testScreenChecks() async throws {
        let cases: [(ScreenStatus, String?)] = [
            (ScreenStatus(supported: false, consoleUser: false, locked: false, holder: nil, queued: 0), "screen_unsupported"),
            (ScreenStatus(supported: true, consoleUser: false, locked: false, holder: nil, queued: 0), "no_console_user"),
            (ScreenStatus(supported: true, consoleUser: true, locked: true, holder: nil, queued: 0), "screen_locked"),
            (ScreenStatus(supported: true, consoleUser: true, locked: false, holder: nil, queued: 2), nil),
        ]
        for (status, code) in cases {
            let checks = RecordingChecks(plan: plan, screen: status)
            do {
                let r = try await Preflight.run(checks)
                XCTAssertNil(code, "\(status) passed")
                r.release()
            } catch let error as DelegationError {
                XCTAssertEqual(error.code, code)
                XCTAssertTrue(error.message.hasPrefix("mini"), error.message)
                XCTAssertEqual(checks.releases, 1)
            }
        }
    }

    /// An error that is not already a 125 line still becomes one, naming the host, rather than
    /// surfacing as a Swift error dump the agent cannot act on.
    func testForeignErrorIsWrapped() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "disk on fire" } }
        let checks = RecordingChecks(plan: plan, foreign: Boom())
        do {
            _ = try await Preflight.run(checks)
            XCTFail("expected a failure")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "preflight_failed")
            XCTAssertEqual(error.message, "preflight for mini failed: disk on fire; fix it, then retry")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(checks.releases, 1)
    }

    func testReleaseIsIdempotent() async throws {
        let checks = RecordingChecks(plan: plan)
        let reservation = try await Preflight.run(checks)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { reservation.release() } }
        }
        reservation.release()
        XCTAssertEqual(checks.releases, 1)
    }

    // MARK: Port merging

    /// §6.2: a CLI `--port L:R` replaces the recipe's entry for the same R, in place; a CLI
    /// port for a new R is added after the recipe's.
    func testCLIPortOverridesRecipeSameRemote() throws {
        let merged = try Preflight.mergePorts(recipe: ["5432", "8080:80", "auto:3000"], cli: ["15432:5432", "9000", "auto:80"])
        XCTAssertEqual(merged.map(\.notation), ["15432:5432", "auto:80", "auto:3000", "9000:9000"])
    }

    func testInvalidPortIsA125() {
        XCTAssertThrowsError(try Preflight.mergePorts(recipe: [], cli: ["0"])) { error in
            XCTAssertEqual((error as? DelegationError)?.code, "invalid_port")
        }
    }

    /// Two entries asking for one local port would have the second fail to bind against the
    /// first, and the message would blame Flight Deck itself.
    func testDuplicateLocalPortIsRefused() {
        XCTAssertThrowsError(try Preflight.mergePorts(recipe: ["5432"], cli: ["5432:6543"])) { error in
            XCTAssertEqual((error as? DelegationError)?.code, "invalid_port")
            XCTAssertEqual((error as? DelegationError)?.message,
                           "local port 5432 is mapped twice (5432:5432, 5432:6543); give one of them another local port")
        }
    }
}

/// Records each step it is asked to run; fails at the named one.
private final class RecordingChecks: PreflightChecks, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _remoteAsked: [UInt16] = []
    private let plan: PreflightPlan
    private let failAt: String?
    private let capabilities: Set<HostCapability>?
    private let localPortError: DelegationError?
    private let remote: [PortStatus]?
    private let screen: ScreenStatus
    private let foreign: (any Error)?
    let reservation = FakeReservation()

    init(plan: PreflightPlan, failAt: String? = nil,
         capabilities: Set<HostCapability>? = [.hostInfo, .run, .sync, .service, .screen],
         localPortError: DelegationError? = nil, remote: [PortStatus]? = nil,
         screen: ScreenStatus = ScreenStatus(supported: true, consoleUser: true, locked: false, holder: nil, queued: 0),
         foreign: (any Error)? = nil) {
        self.plan = plan
        self.failAt = failAt
        self.capabilities = capabilities
        self.localPortError = localPortError
        self.remote = remote
        self.screen = screen
        self.foreign = foreign
    }

    var calls: [String] { lock.withLock { _calls } }
    var remotePortsAsked: [UInt16] { lock.withLock { _remoteAsked } }
    var releases: Int { reservation.releases }

    private func record(_ step: String) throws {
        lock.withLock { _calls.append(step) }
        if failAt == step { throw DelegationError(code: "boom_\(step)", message: "\(step) failed") }
    }

    func resolve() async throws -> PreflightPlan { try record("resolve"); return plan }
    func hostCapabilities(_ host: String) async throws -> Set<HostCapability>? { try record("host"); return capabilities }
    func checkLocalPaths(_ plan: PreflightPlan) async throws { try record("paths") }
    func reserveLocalPorts(_ ports: [PortMapping], host: String) async throws -> any PortReservation {
        try record("localPorts")
        if let localPortError { throw localPortError }
        return reservation
    }
    func remotePorts(_ ports: [UInt16], host: String) async throws -> [PortStatus] {
        try record("remotePorts")
        lock.withLock { _remoteAsked = ports }
        return remote ?? ports.map { PortStatus(port: $0, holder: .free) }
    }
    func screenStatus(_ host: String) async throws -> ScreenStatus { try record("screen"); return screen }
    func checkLFS(_ plan: PreflightPlan) async throws {
        try record("lfs")
        if let foreign { throw foreign }
    }
}

private final class FakeReservation: PortReservation, @unchecked Sendable {
    private let lock = NSLock()
    private var _releases = 0
    var releases: Int { lock.withLock { _releases } }
    let forwards = [PortForward(local: 15432, remote: 5432), PortForward(local: 50123, remote: 3000)]
    func startForwarding(_ connect: @escaping @Sendable (UInt16) -> any ChannelOpening) {}
    func release() { lock.withLock { _releases += 1 } }
}
