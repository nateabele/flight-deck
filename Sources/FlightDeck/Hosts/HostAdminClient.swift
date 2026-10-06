import Combine
import Foundation
import HostKit
import ServiceManagement

/// The slice of `SMAppService` the Hosting tab uses, so tests drive a fake and never register
/// a real LaunchAgent: a test that called the real `register()` would leave a hostd running
/// on port 47410 under the developer's login, outliving the test run.
protocol AgentServiceRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// The bundled hostd's LaunchAgent, `Contents/Library/LaunchAgents/<plistName>`.
final class SMAppServiceAgent: AgentServiceRegistering {
    private let service: SMAppService

    init(plistName: String) {
        service = SMAppService.agent(plistName: plistName)
    }

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// An agent that is never registered and registers nothing: what a UITest reset launch gets,
/// so toggling Hosting in a UI test cannot install a LaunchAgent under the developer's login
/// that binds port 47410 and outlives the run.
final class InertAgentService: AgentServiceRegistering {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

/// The Hosting tab's model: whether this Mac's hostd is registered and running, its pairing
/// window, and the controllers paired with it — all read from the hostd's admin socket.
///
/// Every admin call is a blocking POSIX connect/read with a 5 s budget, so each one runs on a
/// detached task and only its result comes back to the main actor. Run on main, a wedged hostd
/// would freeze the whole app for 5 s on every 2 s refresh tick.
///
/// The actions return their task so a caller can await the outcome (the tests do); the UI
/// ignores it.
@MainActor
final class HostingController: ObservableObject {
    enum State: Equatable {
        /// Not registered: other Macs cannot reach this one.
        case off
        /// Registered, and the hostd has not answered yet.
        case starting
        case on(paired: Int, port: Int?)
        /// Registered, and macOS is holding it until the user allows it in Login Items.
        case needsApproval
        /// Registered, and nothing answers the admin socket.
        case notRunning
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The code to show while a pairing window is open, `PairingCode.formatted`, and the port
    /// its listener bound — 47411 unless that was taken (`DarwinHostServer.pairingPort`).
    @Published private(set) var armed: (code: String, expiresAt: Date, port: Int)?
    /// Where the other Mac can reach this one at `armed.port`, best first. Filled a moment
    /// after `armed`, because the Tailscale CLI it asks can take up to its 2 s bound.
    @Published private(set) var pairingAddresses: [HostPairingAddresses.Entry] = []
    @Published private(set) var controllers: [AdminController] = []
    /// The hostd's own name for this Mac, shown on the pairing sheet.
    @Published private(set) var hostName: String?
    /// The last arm or revoke that did not go through. Kept apart from `state`, because a
    /// failed revoke says nothing about whether the host is running.
    @Published private(set) var actionError: String?

    /// `<HostStateRoot>/admin.sock`, the same path `DarwinHostServer` binds. Computed from the
    /// same `HostStateRoot.default()`, never spelled out, so the two cannot drift apart.
    nonisolated static var defaultAdminPath: String {
        HostStateRoot.default().appendingPathComponent("admin.sock").path
    }

    private let service: AgentServiceRegistering
    private let adminPath: String
    /// `HostPairingAddresses.current`, injectable so a test lists fixed addresses rather than
    /// this Mac's interfaces and whatever its Tailscale says.
    private let addresses: @Sendable (Int) -> [HostPairingAddresses.Entry]
    /// How long after enabling a silent admin socket still reads as `.starting`. launchd takes
    /// a moment to spawn the hostd, and the first refresh runs straight after `register()`, so
    /// without this every enable flashed "not running" before the host came up.
    private let startingGrace: TimeInterval
    private var enabledAt: Date?

    /// Bumped by every enable or disable, so a refresh that was in flight across one cannot
    /// write a stale "running" over the "off" the user just chose.
    private var generation = 0
    /// Bumped whenever `armed` is set or cleared here, so a refresh whose status was read
    /// before the window opened (and so says it is closed) cannot close the new sheet.
    private var armSequence = 0
    /// The paired count when the window opened; the sheet closes once it grows.
    private var pairedAtArm: Int?
    private var refreshing: Task<Void, Never>?

    init(service: AgentServiceRegistering = SMAppServiceAgent(plistName: "dev.flightdeck.hostd.plist"),
         adminPath: String, startingGrace: TimeInterval = 5,
         addresses: @escaping @Sendable (Int) -> [HostPairingAddresses.Entry] = { HostPairingAddresses.current(port: $0) }) {
        self.service = service
        self.adminPath = adminPath
        self.addresses = addresses
        self.startingGrace = startingGrace
    }

    /// Whether the agent is registered at all, which is what the toggle shows. Not `state`:
    /// a registered host that failed to start is still switched on.
    var isEnabled: Bool { Self.isRegistered(service.status) }

    func setEnabled(_ on: Bool) {
        generation += 1
        actionError = nil
        do {
            if on {
                try service.register()
                enabledAt = Date()
                state = .starting
                refresh()
            } else {
                try service.unregister()
                enabledAt = nil
                clearHost()
                state = .off
            }
        } catch {
            // `register()` throws when macOS wants the user's approval first, and the agent is
            // registered regardless — say "approve it", not "it failed".
            if service.status == .requiresApproval {
                state = .needsApproval
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// One in flight at a time: the timer ticks every 2 s and a call can take 5 s, so without
    /// this a wedged hostd would stack up refreshes.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshing { return refreshing }
        let task = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshing = nil
        }
        refreshing = task
        return task
    }

    @discardableResult
    func arm() -> Task<Void, Never> {
        actionError = nil
        let path = adminPath
        return Task { [weak self] in
            let reply = await Self.send(.arm, path: path)
            guard let self else { return }
            switch reply {
            case .success(.armed(let code, let expiresAt, let reported)):
                armSequence += 1
                if case .on(let paired, _) = state { pairedAtArm = paired } else { pairedAtArm = nil }
                // No port named: a hostd from before the field, which (like Linux) means 47411.
                let port = reported ?? Int(HostService.pairingPort)
                armed = (code, expiresAt, port)
                pairingAddresses = []
                let sequence = armSequence, addresses = addresses
                let list = await Task.detached(priority: .userInitiated) { addresses(port) }.value
                // A window closed or replaced while the CLI ran keeps its own list, or none.
                if sequence == armSequence { pairingAddresses = list }
            case .success(.failed(let message)):
                actionError = message
            case .failure(AdminSocketError.notRunning):
                actionError = "The host service is not running, so there is no code to show."
            default:
                actionError = "The host service could not open a pairing window."
            }
        }
    }

    /// Closes the sheet at once and the window behind it: a code the user backed out of must
    /// stop being a key, not just stop being drawn.
    @discardableResult
    func cancelArm() -> Task<Void, Never> {
        closeWindow()
        let path = adminPath
        return Task { _ = await Self.send(.cancelArm, path: path) }
    }

    @discardableResult
    func revoke(slot: UUID) -> Task<Void, Never> {
        actionError = nil
        let path = adminPath
        return Task { [weak self] in
            let reply = await Self.send(.revoke(slot: slot), path: path)
            guard let self else { return }
            switch reply {
            case .success(.ok):
                controllers.removeAll { $0.slot == slot }
            case .success(.failed(let message)):
                actionError = message
            default:
                actionError = "The host service did not confirm the revoke. The controller may still be paired."
            }
            // Read back rather than trusted: the list is the hostd's, not ours.
            await loadControllers(generation: generation)
        }
    }

    /// What "Copy pairing details" copies: the best address, at the window's port, and the
    /// code — one paste into the other Mac's address field fills both of its fields.
    var pairingDetails: String? {
        guard let armed, let best = pairingAddresses.first else { return nil }
        return PairingDetails.format(endpoint: best.endpoint, code: armed.code)
    }

    // MARK: - Refresh

    private func performRefresh() async {
        let generation = generation
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            clearHost()
            state = .needsApproval
            return
        case .notRegistered, .notFound:
            // `.notFound` too: an agent that has never been registered reports it on some
            // macOS releases, and that is "off", not an error to show.
            clearHost()
            state = .off
            return
        @unknown default:
            state = .failed("macOS reported a host service state Flight Deck does not know.")
            return
        }

        let sequence = armSequence
        let path = adminPath
        let reply = await Self.send(.status, path: path)
        guard generation == self.generation else { return }
        switch reply {
        case .success(.status(let paired, let armedUntil, let port, let name)):
            enabledAt = nil
            state = .on(paired: paired, port: port)
            hostName = name
            if armed != nil, sequence == armSequence {
                let paired = pairedAtArm.map { paired > $0 } ?? false
                let expired = armed.map { $0.expiresAt <= Date() } ?? false
                // A window the host no longer holds was paired, cancelled or ran out —
                // whichever, there is no code left worth showing.
                if paired || expired || armedUntil == nil { closeWindow() }
            }
            await loadControllers(generation: generation)
        case .success(.failed(let message)):
            state = .failed(message)
        case .success:
            state = .failed("The host service answered with something Flight Deck didn't understand.")
        case .failure(AdminSocketError.notRunning):
            if let enabledAt, Date().timeIntervalSince(enabledAt) < startingGrace {
                state = .starting
            } else {
                clearHost()
                state = .notRunning
            }
        case .failure(AdminSocketError.timedOut):
            state = .failed("The host service is not answering.")
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func loadControllers(generation: Int) async {
        let reply = await Self.send(.listControllers, path: adminPath)
        guard generation == self.generation, case .success(.controllers(let list)) = reply else { return }
        controllers = list
    }

    /// What the host knew stops being true once it is off or gone: a Revoke button for a
    /// controller of a hostd that is not running would only fail.
    private func clearHost() {
        controllers = []
        closeWindow()
    }

    private func closeWindow() {
        guard armed != nil else { return }
        armSequence += 1
        armed = nil
        pairingAddresses = []
        pairedAtArm = nil
    }

    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Off the main actor: `AdminSocketClient.send` blocks in connect and read.
    nonisolated private static func send(_ request: AdminRequest, path: String) async -> Result<AdminReply, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try AdminSocketClient.send(request, path: path) }
        }.value
    }
}
