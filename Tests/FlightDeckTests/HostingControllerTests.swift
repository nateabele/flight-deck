import FleetKit
import HostKit
import ServiceManagement
import XCTest
@testable import FlightDeck

/// The Hosting tab's model against a fake `SMAppService` and a real admin socket. The actions
/// return their task, and these await it: the admin calls run off the main actor, so the state
/// is published a hop after the call returns, never during it.
@MainActor
final class HostingControllerTests: XCTestCase {
    final class FakeAgent: AgentServiceRegistering {
        var status: SMAppService.Status = .notRegistered
        var registerError: Error?
        func register() throws {
            if let registerError { throw registerError }
            status = .enabled
        }
        func unregister() throws { status = .notRegistered }
    }

    private var dirs: [String] = []

    /// Short and in /tmp, because a unix socket path is capped at 103 bytes; inside its own
    /// 0700 directory, because the server refuses a parent others can write and /tmp is 1777.
    private func socketPath() -> String {
        let dir = "/tmp/fdhc-\(UUID().uuidString.prefix(8))"
        mkdir(dir, 0o700)
        dirs.append(dir)
        return dir + "/admin.sock"
    }

    override func tearDown() {
        for dir in dirs { unlink(dir + "/admin.sock"); rmdir(dir) }
        dirs = []
        super.tearDown()
    }

    func testEnableRegistersAndReportsNotRunningUntilAdminAnswers() async {
        let agent = FakeAgent()
        let c = HostingController(service: agent, adminPath: socketPath(), startingGrace: 0)
        c.setEnabled(true)
        await c.refresh().value
        XCTAssertEqual(agent.status, .enabled)
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.state, .notRunning)   // Review Focus 5: says so, does not hang
    }

    func testASilentHostJustEnabledStillReadsAsStarting() async {
        let c = HostingController(service: FakeAgent(), adminPath: socketPath(), startingGrace: 60)
        c.setEnabled(true)
        await c.refresh().value
        XCTAssertEqual(c.state, .starting)
    }

    func testRequiresApprovalIsSurfaced() async {
        let a = FakeAgent(); a.status = .requiresApproval
        let c = HostingController(service: a, adminPath: socketPath())
        await c.refresh().value
        XCTAssertEqual(c.state, .needsApproval)
    }

    func testARegisterThatThrowsForApprovalSaysApproveNotFailed() {
        let a = FakeAgent()
        a.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        a.status = .requiresApproval
        let c = HostingController(service: a, adminPath: socketPath())
        c.setEnabled(true)
        XCTAssertEqual(c.state, .needsApproval)
    }

    func testDisableUnregistersAndReadsOff() async {
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: socketPath(), startingGrace: 0)
        c.setEnabled(false)
        XCTAssertEqual(a.status, .notRegistered)
        XCTAssertEqual(c.state, .off)
        XCTAssertFalse(c.isEnabled)
    }

    func testArmShowsCodeFromAdmin() async throws {
        let path = socketPath()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .arm: .armed(code: "AAAA-BBBB-CCCC", expiresAt: .distantFuture)
            case .status: .status(paired: 0, armedUntil: nil, listeningPort: 47410, hostName: "m")
            default: .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path)
        await c.refresh().value
        await c.arm().value
        XCTAssertEqual(c.armed?.code, "AAAA-BBBB-CCCC")
        XCTAssertEqual(c.state, .on(paired: 0, port: 47410))
        XCTAssertEqual(c.hostName, "m")
    }

    /// The sheet lists where to reach this Mac at the port the window really bound, and the
    /// copy button's string is the best of those plus the code: a pairing port that fell back
    /// to an ephemeral one must not be shown, or copied, as 47411.
    func testArmListsAddressesAtTheReportedPortAndCopiesTheBest() async throws {
        let path = socketPath()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .arm: .armed(code: "K7QM-2XPA-9TRB", expiresAt: .distantFuture, pairingPort: 52001)
            default: .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path, addresses: { port in
            HostPairingAddresses.list(tailscale: .init(ipv4: ["100.64.0.7"], dnsName: nil),
                                      interfaces: [], primary: nil, localHostName: "studio", port: port)
        })
        await c.arm().value
        XCTAssertEqual(c.armed?.port, 52001)
        XCTAssertEqual(c.pairingAddresses.map(\.endpoint), ["100.64.0.7:52001", "studio.local:52001"])
        XCTAssertEqual(c.pairingDetails, "100.64.0.7:52001 K7QM-2XPA-9TRB")
    }

    /// A hostd that names no port (a Linux one, or one built before the field) listens on the
    /// fixed 47411, and only a port other than that one earns its own line on the sheet.
    func testAnUnreportedPortIsTheFixedOneAndOnlyAnotherIsCalledOut() async throws {
        let path = socketPath()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .arm: .armed(code: "K7QM-2XPA-9TRB", expiresAt: .distantFuture)
            default: .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path, addresses: { port in
            HostPairingAddresses.list(tailscale: nil, interfaces: [], primary: nil, localHostName: "m", port: port)
        })
        await c.arm().value
        XCTAssertEqual(c.armed?.port, 47411)
        XCTAssertEqual(c.pairingDetails, "m.local:47411 K7QM-2XPA-9TRB")
        XCTAssertNil(ControllerPairingSheet.portNote(port: 47411))
        XCTAssertEqual(ControllerPairingSheet.portNote(port: 52001),
                       "Pairing on port 52001 because 47411 is in use. Include it when you type this Mac's address.")
    }

    /// The pairing sheet closes itself on this: a controller that paired grows the count.
    func testTheWindowClosesOnceAControllerPairs() async throws {
        let path = socketPath()
        let paired = Counter()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .arm: .armed(code: "AAAA-BBBB-CCCC", expiresAt: .distantFuture)
            case .status: .status(paired: paired.value, armedUntil: .distantFuture,
                                  listeningPort: 47410, hostName: "m")
            case .listControllers: .controllers([])
            default: .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path)
        await c.refresh().value
        await c.arm().value
        await c.refresh().value
        XCTAssertNotNil(c.armed, "a window still open and unpaired must stay on screen")

        paired.value = 1
        await c.refresh().value
        XCTAssertNil(c.armed)
        XCTAssertEqual(c.state, .on(paired: 1, port: 47410))
    }

    func testTheWindowClosesWhenTheHostNoLongerHoldsIt() async throws {
        let path = socketPath()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .arm: .armed(code: "AAAA-BBBB-CCCC", expiresAt: .distantFuture)
            case .status: .status(paired: 0, armedUntil: nil, listeningPort: 47410, hostName: "m")
            default: .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path)
        await c.arm().value
        XCTAssertNotNil(c.armed)
        await c.refresh().value
        XCTAssertNil(c.armed)
    }

    func testControllersAreListedAndARevokeIsSentAndReadBack() async throws {
        let path = socketPath()
        let keep = AdminController(slot: UUID(), name: "laptop", pairedAt: Date(timeIntervalSince1970: 0))
        let doomed = AdminController(slot: UUID(), name: "studio", pairedAt: Date(timeIntervalSince1970: 0))
        let revoked = Counter()
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .status: return .status(paired: 2 - revoked.value, armedUntil: nil, listeningPort: 47410, hostName: "m")
            case .listControllers: return .controllers(revoked.value == 0 ? [keep, doomed] : [keep])
            case .revoke(let slot):
                guard slot == doomed.slot else { return .failed("unknown slot") }
                revoked.value += 1
                return .ok
            default: return .ok
            }
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path)
        await c.refresh().value
        XCTAssertEqual(c.controllers, [keep, doomed])

        await c.revoke(slot: doomed.slot).value
        XCTAssertEqual(revoked.value, 1)
        XCTAssertEqual(c.controllers, [keep])
        XCTAssertNil(c.actionError)
    }

    func testArmAgainstAStoppedHostSaysSoInsteadOfOpeningASheet() async {
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: socketPath())
        await c.arm().value
        XCTAssertNil(c.armed)
        XCTAssertEqual(c.actionError, "The host service is not running, so there is no code to show.")
    }

    /// The toggle switched off while a refresh was in flight must stay off.
    func testARefreshInFlightAcrossADisableCannotTurnTheStateBackOn() async throws {
        let path = socketPath()
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let server = try AdminSocketServer(path: path) { r in
            if case .status = r { entered.signal(); gate.wait() }
            return .status(paired: 0, armedUntil: nil, listeningPort: 47410, hostName: "m")
        }
        defer { server.stop() }
        let a = FakeAgent(); a.status = .enabled
        let c = HostingController(service: a, adminPath: path)
        let inFlight = c.refresh()
        // Off the main actor, which is what lets the refresh reach the socket meanwhile.
        await Task.detached { entered.wait() }.value
        c.setEnabled(false)
        gate.signal()
        await inFlight.value
        XCTAssertEqual(c.state, .off)
    }

    func testTheAdminPathIsTheOneTheHostdBinds() {
        XCTAssertEqual(HostingController.defaultAdminPath,
                       HostStateRoot.default().appendingPathComponent("admin.sock").path)
        XCTAssertTrue(HostingController.defaultAdminPath.hasSuffix("Library/Application Support/Flight Deck Host/admin.sock"))
    }

    // MARK: - Linux install command

    func testTheInstallCommandIsBuiltFromTheBundleKeys() {
        let command = LinuxHostInstaller.command(info: [
            "FDHostdReleaseBaseURL": "https://example.com/hostd/",
            "FDHostdInstallerSHA256": "abc123",
        ])
        XCTAssertEqual(command, "curl -fsSL https://example.com/hostd/hostd-install.sh | sh -s -- --sha256 abc123")
    }

    func testAnUnpublishedInstallerShowsNoCommand() {
        XCTAssertNil(LinuxHostInstaller.command(info: [
            "FDHostdReleaseBaseURL": "https://example.com/hostd", "FDHostdInstallerSHA256": "",
        ]))
        XCTAssertNil(LinuxHostInstaller.command(info: [
            "FDHostdReleaseBaseURL": "", "FDHostdInstallerSHA256": "abc123",
        ]))
        XCTAssertNil(LinuxHostInstaller.command(info: nil))
    }

    // MARK: - Pairing errors

    func testEveryPairingFailureHasItsOwnAdvice() {
        let messages = PairingInitiator.Failure.allCases.map { HostPairingMessages.message(for: .failed($0)) }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertFalse(messages.contains { $0.localizedCaseInsensitiveContains("seat") })
    }
}

/// A value the admin handler (on the socket's accept thread) and the test both touch.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
