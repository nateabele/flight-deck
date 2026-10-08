import Foundation

/// The host's delegation router (spec §4–§6): every `DelegationRequest` a controller sends,
/// served against the runner and the workspace store, with the service, port and screen ops
/// handed to `DelegationHostServices`. `HostServerCore` owns the connections and calls in here;
/// both hostds build one per process (`standard`).
///
/// **Never blocks the core.** Every request runs in its own task and is answered whenever it
/// finishes. `sync.push` waits on channel bytes that arrive on the same connection as the
/// request, so a router that answered inline from the core's serial `receive` would stall that
/// connection behind its own bundle, and every other request queued behind it.
///
/// **One mux per connection,** created when the core accepts its hello (before `helloAck`, so a
/// controller that saw the ack can open channels at once) and shut down when it closes. A
/// binary frame for a connection with no mux is dropped: before hello it is a peer breaking
/// the protocol, after close it is the tail of a dead stream.
///
/// **Runs are scoped by controller** (amendment A2). A run belongs to the paired slot that
/// started it, taken from the connection and never from the request; every other slot is told
/// `unknown_run`, so one paired Mac can neither see nor stop another's work, nor learn that it
/// exists.
///
/// **Events.** Each connection attaches to a run at most once: a `run.attach` replaces that
/// connection's earlier subscription, so a controller re-attaching after a hiccup does not get
/// every chunk twice. Output goes out in `event` frames of at most 64 KiB of raw bytes (A3).
public final class DelegationHost: @unchecked Sendable {
    /// What `helloAck` advertises beside `host.info`.
    public let capabilities: [HostCapability]
    /// The host's one screen, shared with the runner and the services: macOS hostd shows its
    /// "don't touch" panel while it is held.
    public let screen: ScreenLease

    private let runner: any RunControlling
    private let workspace: any WorkspaceStore
    private let services: DelegationHostServices
    private let live: LiveSlots
    private let git = GitRunner(isolated: true)
    /// Told of every request and every run, service and transfer, for `host.info`'s
    /// `idleSince`. Public so a hostd hands the core the same tracker the router feeds.
    public let idle: IdleTracker?
    /// How long a transfer channel (`sync.push`'s bundle in, `run.result`'s and
    /// `run.artifacts`' out) may go without moving a byte before its request fails
    /// `transfer_stalled`. Ten minutes: far past any link's hiccup, short enough that a frozen
    /// controller cannot hold a billed cloud box "busy" until its TTL.
    public static let transferStall: TimeInterval = 600
    private let stall: TimeInterval

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// The repo each run's result lives under: `run.result` names only the run, and the store
    /// keys results by repo. In memory, because a run does not outlive hostd (`shutdown`, and
    /// `Runner`'s startup kill of groups a crashed hostd left).
    private var runRepos: [String: String] = [:]
    /// Runs that ended without ever running (a failed checkout, a locked screen). Their
    /// `run.result` is "nothing changed", not `result_expired`: there never was a result.
    private var failedRuns: Set<String> = []
    /// Slots whose pairing was revoked. A `run.start` from one that was already being routed
    /// when the revoke landed must not start anything afterwards.
    private var revokedSlots: Set<UUID> = []

    public init(runner: any RunControlling, workspace: any WorkspaceStore, screen: ScreenLease,
                portCheck: any PortChecking, screenSupported: Bool, idle: IdleTracker? = nil,
                transferStall: TimeInterval = DelegationHost.transferStall) {
        self.runner = runner
        self.idle = idle
        stall = transferStall
        self.workspace = workspace
        self.screen = screen
        let live = LiveSlots()
        self.live = live
        services = DelegationHostServices(context: DelegationHostContext(
            runner: runner, workspace: workspace, portCheck: portCheck, screen: screen,
            isConnected: { live.contains($0) }))
        capabilities = [.run, .sync, .service, .submodules] + (screenSupported ? [.screen] : [])
    }

    /// hostd's wiring: the workspace store and the run spools under the state root, the
    /// runner releasing its slot only after the result and artifacts are taken (C2's order,
    /// `RunLifecycle.workspace`), and the store's hourly expiry of results nobody fetched.
    /// `power` and `console` are HostKitDarwin's on a Mac, HostKit's own (Linux) elsewhere.
    public static func standard(root: URL,
                                power: any PowerAsserting = PowerAssertion.platformDefault,
                                console: any ConsoleSessionProbing = ConsoleSession.platformDefault,
                                screenSupported: Bool, idle: IdleTracker? = nil) -> DelegationHost {
        let workspace = Workspace(root: root)
        let screen = ScreenLease()
        let runner = Runner(runsRoot: root.appendingPathComponent("runs"), power: power, console: console,
                            screen: screen, lifecycle: .workspace(workspace))
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await workspace.gc()
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
        return DelegationHost(runner: runner, workspace: workspace, screen: screen, portCheck: PortCheck(),
                              screenSupported: screenSupported, idle: idle)
    }

    /// hostd is stopping (its SIGTERM path): every service downed, `down` command and all,
    /// and every other run ended, SIGTERM then SIGKILL after `grace`. Returns within
    /// `deadline`. The defaults fit launchd's 20 s ExitTimeOut, after which it SIGKILLs hostd
    /// alone and leaves every run's group (each its own) running unowned, while the next hostd
    /// hands their slots to new runs.
    public func shutdown(grace: Double = 5, deadline: Double = 15) async {
        await runner.shutdown(grace: grace, deadline: deadline)
    }

    /// `slot`'s pairing was revoked (`HostServerCore.disconnect`). Its runs are cancelled and its
    /// services downed now, not after the orphan timeout: nothing a key the user no longer
    /// trusts started keeps running or holding a port.
    public func revoked(_ slot: UUID) {
        lock.withLock { _ = revokedSlots.insert(slot) }
        // Services go down through the services, and only there: a cancel would end one
        // without its `down` command.
        let serviceIDs = services.serviceIDs(controller: slot)
        for id in runner.liveRuns(controller: slot) where !serviceIDs.contains(id) { runner.cancel(runID: id) }
        let services = self.services
        Task { await services.revoked(slot) }
    }

    // MARK: - Connections (called by HostServerCore)

    /// The core accepted `peer`'s hello. Idempotent: a second hello keeps the mux, and with it
    /// every channel already open on the connection.
    public func connected(_ peer: any HostPeer) {
        let first: Bool = lock.withLock {
            let key = ObjectIdentifier(peer)
            guard connections[key] == nil else { return false }
            connections[key] = Connection(peer: peer, mux: ChannelMux(role: .host) { [weak peer] in
                peer?.send(binary: $0)
            })
            return live.add(peer.slot)
        }
        if first { services.controllerConnected(peer.slot) }
    }

    /// `peer` is gone (closed, refused or revoked). Its channels fail with `.shutdown` and its
    /// event subscriptions end; its runs carry on. The services hear when a controller's last
    /// connection drops, which starts its orphan timeout.
    public func disconnected(_ peer: any HostPeer) {
        let (gone, last): (Connection?, Bool) = lock.withLock {
            guard let gone = connections.removeValue(forKey: ObjectIdentifier(peer)) else { return (nil, false) }
            return (gone, live.remove(peer.slot))
        }
        guard let gone else { return }
        gone.mux.shutdown()
        for task in lock.withLock({ gone.attaches.values.map(\.task) }) { task.cancel() }
        if last { services.controllerDisconnected(peer.slot) }
    }

    /// One binary message, in transport order. Never blocks (`ChannelMux.receive` does not).
    public func receive(binary data: Data, from peer: any HostPeer) {
        lock.withLock { connections[ObjectIdentifier(peer)]?.mux }?.receive(binary: data)
    }

    /// Answers request `id` whenever it is done, from a task of its own; returns at once.
    ///
    /// Every request is activity for the idle tracker from arrival until it is answered, not
    /// just at arrival: a `sync.push` or `run.result` streaming a bundle over a slow link for
    /// minutes is the host at work. Ended on every path out, a failed or aborted transfer too.
    public func handle(id: Int, _ request: DelegationRequest, from peer: any HostPeer) {
        guard let connection = lock.withLock({ connections[ObjectIdentifier(peer)] }) else {
            // The core registers the connection before it acks the hello, so this is a request
            // racing its own connection's close: nobody is left to read an answer.
            return
        }
        let activity = idle?.begin()
        Task {
            defer { if let activity { self.idle?.end(activity) } }
            do {
                let routed = try await self.route(request, on: connection)
                self.send(.reply(id: id, .delegation(routed.reply)), to: peer)
                routed.then?()
            } catch {
                let (code, message) = Self.describe(error)
                self.send(.error(id: id, code: code, message: message), to: peer)
            }
        }
    }

    // MARK: - Routing

    /// A reply, and what to do once it has been sent: events for a run must follow the reply
    /// that names it, on the same ordered connection.
    private struct Routed {
        let reply: DelegationReply
        var then: (@Sendable () -> Void)?
    }

    private func route(_ request: DelegationRequest, on connection: Connection) async throws -> Routed {
        let slot = connection.peer.slot
        switch request {
        case .syncTips(let repoRoot, let wtKey):
            return Routed(reply: .syncTips(tips: try await workspace.tips(controller: slot, repoRoot: repoRoot, wtKey: wtKey)))

        case .syncPush(let ref, let channelID):
            return try await withChannel(channelID, on: connection) { channel in
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-push-\(UUID().uuidString).bundle")
                defer { try? FileManager.default.removeItem(at: file) }
                try await Self.save(channel, to: file, stall: stall)
                try await workspace.receive(controller: slot, bundle: file, ref: ref)
                return Routed(reply: .syncPush)
            }

        case .runStart(let ref, let spec, let owner, let apply):
            let owner = LeaseHolderOwner(controller: slot, session: owner)
            let acquire = try await acquire(ref, spec, apply: apply, controller: slot)
            try notRevoked(slot)
            // A service starts through the services, which call the runner themselves: they
            // must hold its pinned slot (for `service.sync`) and know which controller's
            // services to down when its orphan timeout runs out, and the runner exposes neither.
            let runID = spec.service ? services.startService(spec, owner: owner, acquire: acquire)
                                     : runner.start(spec, owner: owner, acquire: acquire)
            // Before this request's own activity ends, so the host never looks idle between
            // the reply and the run's first event.
            watchUntilEnded(runID)
            let revokedMeanwhile: Bool = lock.withLock {
                // Pruned to the runs the runner still knows, so a hostd up for weeks does not
                // keep a row per run it ever started.
                runRepos = runRepos.filter { runner.owner(runID: $0.key) != nil }
                failedRuns = failedRuns.filter { runner.owner(runID: $0) != nil }
                runRepos[runID] = ref.repoRoot
                return revokedSlots.contains(slot)
            }
            // A revoke between the check above and the start: its sweep may have listed the
            // slot's runs before this one existed.
            if revokedMeanwhile {
                if spec.service { try? await runner.down(runID: runID) } else { runner.cancel(runID: runID) }
                try notRevoked(slot)
            }
            return Routed(reply: .runStart(runID: runID)) { [self] in attach(runID, from: 0, on: connection) }

        case .runAttach(let runID, let offset):
            try owned(runID, by: slot)
            return Routed(reply: .runAttach) { [self] in attach(runID, from: offset, on: connection) }

        case .runSignal(let runID, let signal):
            try owned(runID, by: slot)
            try runner.signal(runID: runID, signal)
            return Routed(reply: .runSignal)

        case .runCancel(let runID):
            try owned(runID, by: slot)
            runner.cancel(runID: runID)
            return Routed(reply: .runCancel)

        case .runResult(let runID, let channelID):
            return try await withChannel(channelID, on: connection) { channel in
                try await result(runID, controller: slot, over: channel)
            }

        case .runArtifacts(let runID, _, let channelID):
            // The globs were the run's own `fetch`, captured at exit (`RunLifecycle`): by now
            // the slot may hold someone else's tree, so there is nothing left to match them on.
            return try await withChannel(channelID, on: connection) { channel in
                try owned(runID, by: slot)
                guard let tar = workspace.storedArtifacts(runID: runID) else {
                    await channel.finish()
                    return Routed(reply: .runArtifacts(found: false))
                }
                try await Self.stream(tar, over: channel, stall: stall)
                return Routed(reply: .runArtifacts(found: true))
            }

        case .runAck(let runID, let repoRoot):
            // Scoped like every run op while the runner still knows the run. After a hostd
            // restart it does not, and the store's own per-controller keying is the scope:
            // another slot's ack finds nothing of its own to drop.
            if runner.owner(runID: runID) != nil { try owned(runID, by: slot) }
            guard let repoRoot = repoRoot ?? lock.withLock({ runRepos[runID] }) else { throw RunnerError.unknownRun(runID) }
            try await workspace.ackResult(controller: slot, repoRoot: repoRoot, runID: runID)
            return Routed(reply: .runAck)

        case .workspaceUsage:
            return Routed(reply: .usage(try await workspace.usage(controller: slot)))

        case .workspacePrune(let repoRoot):
            try await workspace.prune(controller: slot, repoRoot: repoRoot)
            return Routed(reply: .workspacePrune)

        case .portCheck, .portOpen, .serviceDown, .serviceSync, .screenStatus:
            let mux = connection.mux
            if let reply = try await services.handle(request, controller: slot, accept: { try await mux.accept($0) }) {
                return Routed(reply: reply)
            }
            // A named channel nobody will serve is cancelled, so the controller's end fails
            // now and its buffer goes (A6).
            if case .portOpen(_, _, let channelID) = request { (try? await mux.accept(channelID))?.cancel() }
            throw DelegationError(code: "not_implemented",
                                  message: "\(request.capability.rawValue) requests are not served by this host yet")
        }
    }

    /// The slot-acquiring half of `run.start`. `apply` (run) checks the snapshot out into a
    /// pool slot, waiting its turn; no apply (exec) leases the worktree's existing checkout.
    ///
    /// Exec probes for that checkout before the run is created, so a worktree never synced
    /// here answers the request itself with `no_checkout` rather than a run that fails later.
    /// The probe's lease goes straight back: holding it while the run queued for the screen
    /// would pin a slot, and a run that failed before `acquire` would leak it.
    private func acquire(_ ref: SnapshotRef, _ spec: RunSpec, apply: Bool, controller: UUID) async throws
        -> @Sendable () async throws -> CheckoutLease {
        let workspace = self.workspace
        guard !apply else {
            return {
                // A recipe's `pool` is the concrete store's knob; the protocol has none.
                if let store = workspace as? Workspace {
                    return try await store.checkout(controller: controller, ref: ref, pin: spec.service, pool: spec.pool)
                }
                return try await workspace.checkout(controller: controller, ref: ref, pin: spec.service)
            }
        }
        await workspace.release(try await workspace.existingCheckout(controller: controller, repoRoot: ref.repoRoot,
                                                                      wtKey: ref.wtKey))
        return { try await workspace.existingCheckout(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey) }
    }

    /// `run.result`: the result bundle on `channel`, then the reply naming its commit.
    ///
    /// Streamed before the reply, so the reply means "all of it was sent". Never acked here:
    /// the controller sends `run.ack` once its copy is stored (ruling 24). Acking after the
    /// last write would lose the result whenever the connection died between that write and
    /// the controller's disk; un-acked, a second `run.result` simply sends it again.
    private func result(_ runID: String, controller: UUID, over channel: any ByteChannel) async throws -> Routed {
        try owned(runID, by: controller)
        guard let repoRoot = lock.withLock({ runRepos[runID] }) else { throw RunnerError.unknownRun(runID) }
        // Asked before the run ended there is no result yet, and `result_expired` would tell
        // the controller it was lost.
        if let phase = (runner as? Runner)?.phase(runID: runID), !phase.isTerminal { throw SyncError.runActive }
        let bundle: URL?
        do {
            bundle = try await workspace.resultBundle(controller: controller, repoRoot: repoRoot, runID: runID)
        } catch SyncError.resultExpired where lock.withLock({ failedRuns.contains(runID) }) {
            bundle = nil
        }
        guard let bundle else {
            await channel.finish()
            return Routed(reply: .runResult(commit: nil))
        }
        defer { try? FileManager.default.removeItem(at: bundle) }
        let commit = try await commit(of: bundle)
        try await Self.stream(bundle, over: channel, stall: stall)
        return Routed(reply: .runResult(commit: commit))
    }

    /// The commit a result bundle carries: its one head.
    private func commit(of bundle: URL) async throws -> String {
        let git = self.git
        let heads = try await GitRunner.offload { try git.text(["bundle", "list-heads", bundle.path],
                                                               in: bundle.deletingLastPathComponent()) }
        guard let commit = heads.split(separator: "\n").first?.split(separator: " ").first else {
            throw SyncError.bundleLacksSnapshot(bundle.lastPathComponent)
        }
        return String(commit)
    }

    /// Claims `id` and runs `body` with it. A failed request cancels its channel (A6), so the
    /// controller's end fails at once instead of waiting on bytes that will never come.
    private func withChannel(_ id: ChannelID, on connection: Connection,
                             _ body: (any ByteChannel) async throws -> Routed) async throws -> Routed {
        let channel = try await connection.mux.accept(id)
        do {
            return try await body(channel)
        } catch {
            channel.cancel()
            throw error
        }
    }

    private func notRevoked(_ slot: UUID) throws {
        guard !lock.withLock({ revokedSlots.contains(slot) }) else {
            throw DelegationError(code: "unsupported", message: "this controller's pairing was revoked")
        }
    }

    private func owned(_ runID: String, by controller: UUID) throws {
        guard runner.owner(runID: runID)?.controller == controller else { throw RunnerError.unknownRun(runID) }
    }

    // MARK: - Idle

    /// Holds the host busy until `runID` ends, however it ends: an exit, a service's death or
    /// `down`, a cancel or revoke, or a failure before it ever ran (the stream throws). Watches
    /// the runner, not a controller's subscription, because a run outlives the connection
    /// that started it, and a box whose controller closed its lid mid-build must not be
    /// reaped as idle while the build goes on.
    private func watchUntilEnded(_ runID: String) {
        guard let idle else { return }
        let activity = idle.begin()
        let runner = self.runner
        Task {
            defer { idle.end(activity) }
            // From past any spool's end: only the run's end matters here, and replaying its
            // output for nobody would read the whole spool once per run.
            do { for try await _ in runner.events(runID: runID, from: .max) {} } catch {}
        }
    }

    // MARK: - Events

    /// Subscribes `connection` to `runID` from `offset`, replacing its earlier subscription to
    /// that run. A connection closed meanwhile gets none.
    private func attach(_ runID: String, from offset: Int64, on connection: Connection) {
        let token = UUID()
        let task = Task { [weak self] in
            await self?.forward(runID, from: offset, to: connection.peer)
            self?.lock.withLock {
                if connection.attaches[runID]?.token == token { connection.attaches[runID] = nil }
            }
        }
        let previous: Task<Void, Never>? = lock.withLock {
            guard connections[ObjectIdentifier(connection.peer)] === connection else {
                task.cancel()
                return nil
            }
            defer { connection.attaches[runID] = (token, task) }
            return connection.attaches[runID]?.task
        }
        previous?.cancel()
    }

    private func forward(_ runID: String, from offset: Int64, to peer: any HostPeer) async {
        var end = max(offset, 0)
        do {
            for try await event in runner.events(runID: runID, from: offset) {
                guard !Task.isCancelled else { return }
                if case .output(let stream, let at, let data) = event {
                    for piece in Self.pieces(of: data, at: at) {
                        send(.event(runID: runID, .output(stream: stream, offset: piece.offset, data: piece.data)), to: peer)
                    }
                    end = max(end, at + Int64(data.count))
                } else {
                    send(.event(runID: runID, event), to: peer)
                }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            // A run that never ran (its checkout failed, the screen locked between preflight
            // and start, its working directory is missing) has no exit of its own; the event
            // stream just throws, and the wire has no event for that. Without this the
            // controller would wait on a run that is already over. It gets the reason as the
            // usual `flightdeck:` line and the 125 every delegation failure exits with (§5).
            lock.withLock { _ = failedRuns.insert(runID) }
            let line = Data("flightdeck: \(Self.describe(error).message)\n".utf8)
            send(.event(runID: runID, .output(stream: .stderr, offset: end, data: line)), to: peer)
            send(.event(runID: runID, .exited(.code(DelegationError.exitStatus))), to: peer)
        }
    }

    /// `data` cut at the wire's 64 KiB, each piece at its own run-wide offset. The runner
    /// already reads its spool in such chunks; this keeps the cap the router's guarantee too.
    static func pieces(of data: Data, at offset: Int64) -> [(offset: Int64, data: Data)] {
        guard data.count > ChannelFrame.maxPayload else { return [(offset, data)] }
        return stride(from: 0, to: data.count, by: ChannelFrame.maxPayload).map { start in
            let lower = data.startIndex + start
            let upper = min(lower + ChannelFrame.maxPayload, data.endIndex)
            return (offset + Int64(start), data.subdata(in: lower..<upper))
        }
    }

    // MARK: - Plumbing

    private func send(_ frame: HostServerFrame, to peer: any HostPeer) {
        guard let text = try? HostWire.encode(frame) else { return }
        peer.send(text: text)
    }

    /// Everything the controller writes on `channel` until its EOF, into `file`. Each read
    /// must arrive within `stall` seconds (`progressing`).
    private static func save(_ channel: any ByteChannel, to file: URL, stall: TimeInterval) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        while let chunk = try await progressing(channel, within: stall, { try await channel.read() }) {
            try handle.write(contentsOf: chunk)
        }
        // Our side's EOF too: a channel retires only once both ends have finished, and without
        // it every push left an entry in both muxes for as long as the connection lived.
        await channel.finish()
    }

    /// `file` onto `channel`, then EOF. A write waits on the controller's credit, so a slow
    /// link backs up this transfer and nothing else on the connection.
    private static func stream(_ file: URL, over channel: any ByteChannel, stall: TimeInterval) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: ChannelFrame.maxPayload), !chunk.isEmpty {
            try await progressing(channel, within: stall) { try await channel.write(chunk) }
        }
        await channel.finish()
    }

    /// One step of a transfer (a read, or a write waiting on the controller's credit), failed
    /// `transfer_stalled` if it has not finished within `seconds`. A deadline per step, not per
    /// transfer, so a big bundle over a slow link is never cut while bytes still move.
    ///
    /// The transport's TCP keepalive drops a peer whose machine is gone, but not one that is
    /// alive and silent (a wedged controller, a channel it forgot): without this, that request
    /// would hold the host busy, and a cloud box billing, until its TTL. On a stall the channel
    /// is cancelled, which is also what frees the step's own pending read or write.
    static func progressing<T: Sendable>(_ channel: any ByteChannel, within seconds: TimeInterval,
                                         _ step: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: StepOutcome<T>.self) { group in
            group.addTask { .done(try await step()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .stalled
            }
            defer { group.cancelAll() }
            switch try await group.next() {
            case .done(let value)?:
                return value
            case .stalled?, nil:
                channel.cancel()
                throw DelegationError(code: "transfer_stalled",
                                      message: "the transfer made no progress for \(Int(seconds)) s; the controller stopped sending or reading")
            }
        }
    }

    /// An error as the `err` frame's code (the DelegationWire A5 table) and message (the
    /// text after `flightdeck: ` on the CLI).
    static func describe(_ error: Error) -> (code: String, message: String) {
        switch error {
        case let e as SyncError: return (e.code, e.description)
        case let e as DelegationError: return (e.code, e.message)
        case let e as RunnerError:
            switch e {
            case .unknownRun: return ("unknown_run", e.description)
            case .screenUnsupported: return ("screen_unsupported", e.description)
            case .noConsoleUser: return ("no_console_user", e.description)
            case .screenLocked: return ("screen_locked", e.description)
            case .subdirEscapes, .missingSubdir, .spawnFailed, .shuttingDown: return ("unsupported", e.description)
            }
        default: return ("unsupported", "\(error)")
        }
    }

    // MARK: -

    /// One controller connection. Its mutable state is guarded by the host's `lock`.
    private final class Connection: @unchecked Sendable {
        let peer: any HostPeer
        let mux: ChannelMux
        var attaches: [String: (token: UUID, task: Task<Void, Never>)] = [:]

        init(peer: any HostPeer, mux: ChannelMux) {
            self.peer = peer
            self.mux = mux
        }
    }
}

/// A transfer step's race against its stall deadline (`DelegationHost.progressing`).
private enum StepOutcome<T: Sendable>: Sendable {
    case done(T)
    case stalled
}

/// Live connections per controller slot, shared with the services' `isConnected`, which must
/// not reach back into the router's own lock.
private final class LiveSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]

    /// True when this is the slot's first connection.
    func add(_ slot: UUID) -> Bool {
        lock.withLock {
            counts[slot, default: 0] += 1
            return counts[slot] == 1
        }
    }

    /// True when this was the slot's last connection.
    func remove(_ slot: UUID) -> Bool {
        lock.withLock {
            guard let n = counts[slot] else { return false }
            counts[slot] = n > 1 ? n - 1 : nil
            return n == 1
        }
    }

    func contains(_ slot: UUID) -> Bool { lock.withLock { counts[slot] != nil } }
}
