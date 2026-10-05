import Foundation

// Delegated-execution wire (protocol 1.1), carried inside `HostWire`'s frames:
//
//   HostRequest   {"op":…, …}            controller -> host, in `req`
//     sync.tips      {repoRoot, wtKey}                          -> {tips:[string]}
//     sync.push      {ref, channel}                             -> {}  (bundle on channel)
//     run.start      {ref, spec, owner, apply}                  -> {runID}
//     run.attach     {runID, offset}                            -> {}  (events follow)
//     run.signal     {runID, signal}                            -> {}
//     run.cancel     {runID}                                    -> {}
//     run.result     {runID, channel}                           -> {commit?} (bundle on channel)
//     run.artifacts  {runID, globs, channel}                    -> {found} (tar on channel)
//     port.check     {ports:[int]}                              -> {ports:[{port, holder}]}
//     port.open      {service, remote, channel}                 -> {}  (bytes on channel)
//     service.down   {service}                                  -> {}
//     service.sync   {service, ref}                             -> {}
//     screen.status  {}                                         -> {screen:{…}}
//   HostReply     {"op":<the request's op>, …}  in `reply`; an `{}` above is `{"op":…}` alone.
//   HostServerFrame event  {"t":"event","runID":string,"ev":{"kind":…}}
//     kind queued {position, holder?} | started {runID} | output {stream, offset, data(base64)}
//          | exited {exit} | serviceDied {exit};  exit = {"code":n} | {"signal":n}
//
// `run.start` with `apply: false` is `flightdeck exec`: run in the worktree's existing checkout
// without applying `ref`, whose commit and tree are then the controller's view only and are
// not verified. With `apply: true` the host applies and verifies `ref` first (§4.4).
//
// A `run.start` attaches the requesting controller from offset 0; `run.attach` is for a
// controller that reconnected, resuming from the last offset it saw. Events for a run go to
// every controller connection attached to it, so a dropped one loses nothing it can't replay.
//
// Every channel named here is opened by the controller (`ChannelOpening`), and the host claims
// it by id (`ChannelAccepting`).
//
// Hand-rolled like the rest of `HostWire`, for its reason: these strings are the contract
// between a Linux hostd and a Mac controller built months apart. Optionals are omitted, never
// `null`. An unknown `op` or event `kind` throws, which `HostServerCore` answers `unsupported`.

/// The `op` strings, spelled out rather than derived from case names a refactor could rename.
private enum DelegationOp: String, Codable {
    case syncTips = "sync.tips"
    case syncPush = "sync.push"
    case runStart = "run.start"
    case runAttach = "run.attach"
    case runSignal = "run.signal"
    case runCancel = "run.cancel"
    case runResult = "run.result"
    case runArtifacts = "run.artifacts"
    case portCheck = "port.check"
    case portOpen = "port.open"
    case serviceDown = "service.down"
    case serviceSync = "service.sync"
    case screenStatus = "screen.status"
}

private enum DelegationKey: String, CodingKey {
    case op, repoRoot, wtKey, ref, channel, spec, owner, apply, runID, offset, signal
    case globs, ports, service, remote, tips, commit, found, screen
}

/// Controller → host, the delegated-execution half of `HostRequest`.
public enum DelegationRequest: Codable, Sendable, Equatable {
    case syncTips(repoRoot: String, wtKey: String)
    case syncPush(ref: SnapshotRef, channel: ChannelID)
    case runStart(ref: SnapshotRef, spec: RunSpec, owner: String, apply: Bool)
    case runAttach(runID: String, offset: Int64)
    case runSignal(runID: String, signal: Int32)
    case runCancel(runID: String)
    case runResult(runID: String, channel: ChannelID)
    case runArtifacts(runID: String, globs: [String], channel: ChannelID)
    case portCheck(ports: [UInt16])
    /// `service` is the service's run id.
    case portOpen(service: String, remote: UInt16, channel: ChannelID)
    case serviceDown(service: String)
    /// Re-applies `ref` to the service's pinned checkout in place (`flightdeck sync`, §6.2).
    case serviceSync(service: String, ref: SnapshotRef)
    case screenStatus

    /// The capability a host must have advertised in `helloAck` for this request. Checked
    /// before sending, so a 1.1 controller never sends `run.start` to a 1.0 host and waits on
    /// an answer it cannot get.
    public var capability: HostCapability {
        switch self {
        case .syncTips, .syncPush: return .sync
        case .runStart, .runAttach, .runSignal, .runCancel, .runResult, .runArtifacts: return .run
        case .portCheck, .portOpen, .serviceDown, .serviceSync: return .service
        case .screenStatus: return .screen
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DelegationKey.self)
        switch self {
        case .syncTips(let repoRoot, let wtKey):
            try c.encode(DelegationOp.syncTips, forKey: .op)
            try c.encode(repoRoot, forKey: .repoRoot)
            try c.encode(wtKey, forKey: .wtKey)
        case .syncPush(let ref, let channel):
            try c.encode(DelegationOp.syncPush, forKey: .op)
            try c.encode(ref, forKey: .ref)
            try c.encode(channel, forKey: .channel)
        case .runStart(let ref, let spec, let owner, let apply):
            try c.encode(DelegationOp.runStart, forKey: .op)
            try c.encode(ref, forKey: .ref)
            try c.encode(spec, forKey: .spec)
            try c.encode(owner, forKey: .owner)
            try c.encode(apply, forKey: .apply)
        case .runAttach(let runID, let offset):
            try c.encode(DelegationOp.runAttach, forKey: .op)
            try c.encode(runID, forKey: .runID)
            try c.encode(offset, forKey: .offset)
        case .runSignal(let runID, let signal):
            try c.encode(DelegationOp.runSignal, forKey: .op)
            try c.encode(runID, forKey: .runID)
            try c.encode(signal, forKey: .signal)
        case .runCancel(let runID):
            try c.encode(DelegationOp.runCancel, forKey: .op)
            try c.encode(runID, forKey: .runID)
        case .runResult(let runID, let channel):
            try c.encode(DelegationOp.runResult, forKey: .op)
            try c.encode(runID, forKey: .runID)
            try c.encode(channel, forKey: .channel)
        case .runArtifacts(let runID, let globs, let channel):
            try c.encode(DelegationOp.runArtifacts, forKey: .op)
            try c.encode(runID, forKey: .runID)
            try c.encode(globs, forKey: .globs)
            try c.encode(channel, forKey: .channel)
        case .portCheck(let ports):
            try c.encode(DelegationOp.portCheck, forKey: .op)
            try c.encode(ports, forKey: .ports)
        case .portOpen(let service, let remote, let channel):
            try c.encode(DelegationOp.portOpen, forKey: .op)
            try c.encode(service, forKey: .service)
            try c.encode(remote, forKey: .remote)
            try c.encode(channel, forKey: .channel)
        case .serviceDown(let service):
            try c.encode(DelegationOp.serviceDown, forKey: .op)
            try c.encode(service, forKey: .service)
        case .serviceSync(let service, let ref):
            try c.encode(DelegationOp.serviceSync, forKey: .op)
            try c.encode(service, forKey: .service)
            try c.encode(ref, forKey: .ref)
        case .screenStatus:
            try c.encode(DelegationOp.screenStatus, forKey: .op)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DelegationKey.self)
        switch try c.decode(DelegationOp.self, forKey: .op) {
        case .syncTips:
            self = .syncTips(repoRoot: try c.decode(String.self, forKey: .repoRoot),
                             wtKey: try c.decode(String.self, forKey: .wtKey))
        case .syncPush:
            self = .syncPush(ref: try c.decode(SnapshotRef.self, forKey: .ref),
                             channel: try c.decode(ChannelID.self, forKey: .channel))
        case .runStart:
            self = .runStart(ref: try c.decode(SnapshotRef.self, forKey: .ref),
                             spec: try c.decode(RunSpec.self, forKey: .spec),
                             owner: try c.decode(String.self, forKey: .owner),
                             apply: try c.decode(Bool.self, forKey: .apply))
        case .runAttach:
            self = .runAttach(runID: try c.decode(String.self, forKey: .runID),
                              offset: try c.decode(Int64.self, forKey: .offset))
        case .runSignal:
            self = .runSignal(runID: try c.decode(String.self, forKey: .runID),
                              signal: try c.decode(Int32.self, forKey: .signal))
        case .runCancel:
            self = .runCancel(runID: try c.decode(String.self, forKey: .runID))
        case .runResult:
            self = .runResult(runID: try c.decode(String.self, forKey: .runID),
                              channel: try c.decode(ChannelID.self, forKey: .channel))
        case .runArtifacts:
            self = .runArtifacts(runID: try c.decode(String.self, forKey: .runID),
                                 globs: try c.decode([String].self, forKey: .globs),
                                 channel: try c.decode(ChannelID.self, forKey: .channel))
        case .portCheck:
            self = .portCheck(ports: try c.decode([UInt16].self, forKey: .ports))
        case .portOpen:
            self = .portOpen(service: try c.decode(String.self, forKey: .service),
                             remote: try c.decode(UInt16.self, forKey: .remote),
                             channel: try c.decode(ChannelID.self, forKey: .channel))
        case .serviceDown:
            self = .serviceDown(service: try c.decode(String.self, forKey: .service))
        case .serviceSync:
            self = .serviceSync(service: try c.decode(String.self, forKey: .service),
                                ref: try c.decode(SnapshotRef.self, forKey: .ref))
        case .screenStatus:
            self = .screenStatus
        }
    }
}

/// Host → controller, the delegated-execution half of `HostReply`. Each case echoes its
/// request's `op`, so a reply is self-describing.
public enum DelegationReply: Codable, Sendable, Equatable {
    case syncTips(tips: [String])
    /// The bundle was received and fetched into the store.
    case syncPush
    case runStart(runID: String)
    case runAttach
    case runSignal
    case runCancel
    /// nil: the run changed nothing, and the channel carries only EOF.
    case runResult(commit: String?)
    /// false: no glob matched, and the channel carries only EOF.
    case runArtifacts(found: Bool)
    case portCheck([PortStatus])
    case portOpen
    case serviceDown
    case serviceSync
    case screenStatus(ScreenStatus)

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DelegationKey.self)
        switch self {
        case .syncTips(let tips):
            try c.encode(DelegationOp.syncTips, forKey: .op)
            try c.encode(tips, forKey: .tips)
        case .syncPush: try c.encode(DelegationOp.syncPush, forKey: .op)
        case .runStart(let runID):
            try c.encode(DelegationOp.runStart, forKey: .op)
            try c.encode(runID, forKey: .runID)
        case .runAttach: try c.encode(DelegationOp.runAttach, forKey: .op)
        case .runSignal: try c.encode(DelegationOp.runSignal, forKey: .op)
        case .runCancel: try c.encode(DelegationOp.runCancel, forKey: .op)
        case .runResult(let commit):
            try c.encode(DelegationOp.runResult, forKey: .op)
            try c.encodeIfPresent(commit, forKey: .commit)
        case .runArtifacts(let found):
            try c.encode(DelegationOp.runArtifacts, forKey: .op)
            try c.encode(found, forKey: .found)
        case .portCheck(let statuses):
            try c.encode(DelegationOp.portCheck, forKey: .op)
            try c.encode(statuses, forKey: .ports)
        case .portOpen: try c.encode(DelegationOp.portOpen, forKey: .op)
        case .serviceDown: try c.encode(DelegationOp.serviceDown, forKey: .op)
        case .serviceSync: try c.encode(DelegationOp.serviceSync, forKey: .op)
        case .screenStatus(let status):
            try c.encode(DelegationOp.screenStatus, forKey: .op)
            try c.encode(status, forKey: .screen)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DelegationKey.self)
        switch try c.decode(DelegationOp.self, forKey: .op) {
        case .syncTips: self = .syncTips(tips: try c.decode([String].self, forKey: .tips))
        case .syncPush: self = .syncPush
        case .runStart: self = .runStart(runID: try c.decode(String.self, forKey: .runID))
        case .runAttach: self = .runAttach
        case .runSignal: self = .runSignal
        case .runCancel: self = .runCancel
        case .runResult: self = .runResult(commit: try c.decodeIfPresent(String.self, forKey: .commit))
        case .runArtifacts: self = .runArtifacts(found: try c.decode(Bool.self, forKey: .found))
        case .portCheck: self = .portCheck(try c.decode([PortStatus].self, forKey: .ports))
        case .portOpen: self = .portOpen
        case .serviceDown: self = .serviceDown
        case .serviceSync: self = .serviceSync
        case .screenStatus: self = .screenStatus(try c.decode(ScreenStatus.self, forKey: .screen))
        }
    }
}

// MARK: - Run events

private enum EventKey: String, CodingKey {
    case kind, position, holder, runID, stream, offset, data, exit
}

extension RunEvent: Codable {
    private enum Kind: String, Codable { case queued, started, output, exited, serviceDied }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: EventKey.self)
        switch self {
        case .queued(let position, let holder):
            try c.encode(Kind.queued, forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encodeIfPresent(holder, forKey: .holder)
        case .started(let runID):
            try c.encode(Kind.started, forKey: .kind)
            try c.encode(runID, forKey: .runID)
        case .output(let stream, let offset, let data):
            // `Data` is base64 under JSONEncoder's default strategy, which both ends use.
            try c.encode(Kind.output, forKey: .kind)
            try c.encode(stream, forKey: .stream)
            try c.encode(offset, forKey: .offset)
            try c.encode(data, forKey: .data)
        case .exited(let exit):
            try c.encode(Kind.exited, forKey: .kind)
            try c.encode(exit, forKey: .exit)
        case .serviceDied(let exit):
            try c.encode(Kind.serviceDied, forKey: .kind)
            try c.encode(exit, forKey: .exit)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: EventKey.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .queued:
            self = .queued(position: try c.decode(Int.self, forKey: .position),
                           holder: try c.decodeIfPresent(String.self, forKey: .holder))
        case .started:
            self = .started(runID: try c.decode(String.self, forKey: .runID))
        case .output:
            self = .output(stream: try c.decode(RunOutputStream.self, forKey: .stream),
                           offset: try c.decode(Int64.self, forKey: .offset),
                           data: try c.decode(Data.self, forKey: .data))
        case .exited:
            self = .exited(try c.decode(RunExit.self, forKey: .exit))
        case .serviceDied:
            self = .serviceDied(try c.decode(RunExit.self, forKey: .exit))
        }
    }
}

/// `{"code":n}` or `{"signal":n}`, exactly one.
extension RunExit: Codable {
    private enum Key: String, CodingKey { case code, signal }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .code(let n): try c.encode(n, forKey: .code)
        case .signal(let n): try c.encode(n, forKey: .signal)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch (try c.decodeIfPresent(Int32.self, forKey: .code),
                try c.decodeIfPresent(Int32.self, forKey: .signal)) {
        case (let code?, nil): self = .code(code)
        case (nil, let signal?): self = .signal(signal)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "an exit is exactly one of code or signal"))
        }
    }
}

// MARK: - Ports

/// A bare number, or the string `"auto"`, so the JSON reads like the TOML it came from.
extension PortMapping.Local: Codable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .fixed(let port): try c.encode(port)
        case .auto: try c.encode("auto")
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let port = try? c.decode(UInt16.self) {
            self = .fixed(port)
        } else if try c.decode(String.self) == "auto" {
            self = .auto
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "a local port is a number or \"auto\"")
        }
    }
}

extension PortHolder: Codable {
    private enum Kind: String, Codable { case free, process, container, flightDeck, unknown }
    private enum Key: String, CodingKey { case kind, name, pid, session }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .free: try c.encode(Kind.free, forKey: .kind)
        case .process(let name, let pid):
            try c.encode(Kind.process, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(pid, forKey: .pid)
        case .container(let name):
            try c.encode(Kind.container, forKey: .kind)
            try c.encode(name, forKey: .name)
        case .flightDeck(let session):
            try c.encode(Kind.flightDeck, forKey: .kind)
            try c.encode(session, forKey: .session)
        case .unknown: try c.encode(Kind.unknown, forKey: .kind)
        }
    }

    /// An unknown holder kind reads as `.unknown` rather than throwing: the port is held
    /// either way, and losing the whole `port.check` reply over who holds it would turn a
    /// precise conflict into a vague failure.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch Kind(rawValue: try c.decode(String.self, forKey: .kind)) {
        case .free: self = .free
        case .process:
            self = .process(name: try c.decode(String.self, forKey: .name),
                            pid: try c.decode(Int32.self, forKey: .pid))
        case .container: self = .container(name: try c.decode(String.self, forKey: .name))
        case .flightDeck: self = .flightDeck(session: try c.decode(String.self, forKey: .session))
        case .unknown, nil: self = .unknown
        }
    }
}
