import Foundation

// The `flightdeck infra` ↔ app half of cloud infra hosts (spec §5, §7.3, §8.4, §10), on the
// control socket. The app owns every cloud credential, the OpenTofu state and the budget, so
// the CLI only names what it wants; nothing here is resolved on the CLI's side.
//
//   FleetRequest.infra(InfraRequest)   {"op":…, …} inside `req`
//     infra.up        {name, cwd}         the app reads `[infra.<name>]` from `cwd`'s repo's
//                                         `.flightdeck/delegate.toml`, as `delegate.*` does
//     infra.down      {name, orphanID?}   orphanID: a `kind:id` from `infra.ls --orphans`
//                                         (`instance:i-0…`, `firewall:fd-gpu`); `name` is then
//                                         ignored, and sent empty
//     infra.ls        {orphans}           orphans: also scan every account (slow; spends API calls)
//     infra.doctor    {}
//     infra.extend    {name, seconds}     the CLI parses `1h` itself
//
//   Replies, all `ServerFrame`s correlated by `cid`, all undotted tags:
//     infraProgress   {line}              one step, printed `flightdeck: <line>` on stderr;
//                                         a §8.4 cost line arrives as `cost: <line>`
//     infraMachine    {machine:{WireInfraMachine}}  up and extend: the machine as it now is
//     infraList       {machines:[WireInfraMachine], orphans:[string], unreadable:{cloud: why}}
//                                         ls. `orphans` is empty and `unreadable` is {} unless
//                                         asked; an `unreadable` cloud was NOT scanned, so an
//                                         empty `orphans` means "none" only when it is {} too
//     infraDoctor     {checks:[WireInfraCheck]}  doctor
//     infraDone       {}                  down finished: the machine (or orphan) is gone
//   A failure is `err(code, message)`, the message being what the CLI prints after
//   `flightdeck: `:
//     infra_preflight       a check failed before anything was created; one failing check
//                           per line, `name: detail — fix`
//     infra_name_in_use     the name is a paired host or another repo's machine
//     infra_enroll_timeout  the machine never said hello; kept for `infra down`, its console
//                           output (when the cloud had one) after the first line
//     infra_not_found       no such machine, orphan, or `[infra.<name>]` recipe
//     infra_refused         a rule forbids it (extend past the machine's own timer or a cap,
//                           a name already being created or destroyed)
//     infra_failed          anything else: OpenTofu's diagnostics, with their fix
//     infra_unavailable     this Flight Deck has no cloud service wired
//
// Streams. `up` and `down` may draw many `infraProgress` frames on one `cid`; the stream ends
// at its terminal frame (`infraMachine`, `infraDone` or `err`), after which nothing more is
// sent on that `cid`. Every other request is answered by exactly one frame. A CLI that is
// interrupted mid-`up` leaves the app going: a half-created machine must never be abandoned
// because a reader went away.
//
// Every one of these frames is sent only on the connection that asked, and only the local CLI
// asks: the phone app never sends an `infra.*` request, so an installed phone that cannot
// decode these tags never receives one.
//
// Strings rather than enums for every value a newer Mac may extend (`state`, `network`,
// `cloud`), for `WireSession.agent`'s reason: a client-side enum throws on a value added after
// the client shipped.

/// A `flightdeck infra` subcommand, as `FleetRequest.infra`.
public enum InfraRequest: Codable, Equatable, Sendable {
    /// Create (or take over) `[infra.<name>]` from `cwd`'s repo.
    case up(name: String, cwd: String)
    /// Destroy the machine `name`, or, when `orphanID` is set, that one orphaned resource.
    case down(name: String, orphanID: String?)
    case list(orphans: Bool)
    case doctor
    /// Move the controller's deadline `seconds` later.
    case extend(name: String, seconds: Int)

    /// `ls` and `doctor` change nothing; the rest create, destroy or spend.
    public var isReadOnly: Bool {
        switch self {
        case .list, .doctor: return true
        case .up, .down, .extend: return false
        }
    }

    private enum Op: String, Codable {
        case up = "infra.up"
        case down = "infra.down"
        case list = "infra.ls"
        case doctor = "infra.doctor"
        case extend = "infra.extend"
    }

    enum CodingKeys: String, CodingKey { case op, name, cwd, orphanID, orphans, seconds }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .up(let name, let cwd):
            try c.encode(Op.up, forKey: .op)
            try c.encode(name, forKey: .name)
            try c.encode(cwd, forKey: .cwd)
        case .down(let name, let orphanID):
            try c.encode(Op.down, forKey: .op)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(orphanID, forKey: .orphanID)
        case .list(let orphans):
            try c.encode(Op.list, forKey: .op)
            try c.encode(orphans, forKey: .orphans)
        case .doctor:
            try c.encode(Op.doctor, forKey: .op)
        case .extend(let name, let seconds):
            try c.encode(Op.extend, forKey: .op)
            try c.encode(name, forKey: .name)
            try c.encode(seconds, forKey: .seconds)
        }
    }

    /// An unknown `op` throws, as `FleetRequest`'s does, for its reason.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .up:
            self = .up(name: try c.decode(String.self, forKey: .name), cwd: try c.decode(String.self, forKey: .cwd))
        case .down:
            self = .down(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                         orphanID: try c.decodeIfPresent(String.self, forKey: .orphanID))
        case .list:
            self = .list(orphans: try c.decodeIfPresent(Bool.self, forKey: .orphans) ?? false)
        case .doctor:
            self = .doctor
        case .extend:
            self = .extend(name: try c.decode(String.self, forKey: .name), seconds: try c.decode(Int.self, forKey: .seconds))
        }
    }
}

/// One cloud machine with the spec §8.4 figures, for `infra up`, `extend` and `ls` (and their
/// `--json`). Dollar figures are estimates; `costLine` is the one-line form the CLI prints.
public struct WireInfraMachine: Codable, Equatable, Sendable {
    public let name: String
    /// "aws" | "gcp".
    public let cloud: String
    /// Empty for a user module, which chooses its own machine.
    public let instanceType: String
    public let region: String
    /// `InfraState`'s raw value: "planned", "provisioning", "enrolling", "ready", "idle",
    /// "destroying", "gone", "failed", "orphaned".
    public let state: String
    /// "tailnet" | "public".
    public let network: String
    /// Nil when the machine cannot be priced.
    public let hourlyUsd: Double?
    public let spentUsd: Double
    /// Seconds until the controller's deadline; never negative.
    public let ttlRemaining: Int
    /// This month's spend on every machine.
    public let monthUsd: Double
    public let monthCapUsd: Double?
    /// What went wrong, for a `failed` machine, with its fix.
    public let failure: String?
    public let costLine: String

    public init(name: String, cloud: String, instanceType: String, region: String, state: String, network: String,
                hourlyUsd: Double?, spentUsd: Double, ttlRemaining: Int, monthUsd: Double, monthCapUsd: Double?,
                failure: String?, costLine: String) {
        self.name = name
        self.cloud = cloud
        self.instanceType = instanceType
        self.region = region
        self.state = state
        self.network = network
        self.hourlyUsd = hourlyUsd
        self.spentUsd = spentUsd
        self.ttlRemaining = ttlRemaining
        self.monthUsd = monthUsd
        self.monthCapUsd = monthCapUsd
        self.failure = failure
        self.costLine = costLine
    }
}

/// One line of `infra doctor`: what was checked, whether it passed, what was found, and for a
/// failure the exact thing to do about it.
public struct WireInfraCheck: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let fix: String?

    public init(name: String, ok: Bool, detail: String, fix: String?) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.fix = fix
    }
}
