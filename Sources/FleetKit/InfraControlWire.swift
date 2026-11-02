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
//     infra.budget    {action, usd?}      the asking tab's session budget (`/budget`): action
//                                         "show" | "set" (usd) | "renew" (usd optional, keeps
//                                         the cap) | "clear". The session is the caller
//                                         token's, never the request's: a tab reaches only its own
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
//     infraBudget     {budget:{WireSessionBudget}}  budget: the session's budget as it now is
//   A failure is `err(code, message)`, the message being what the CLI prints after
//   `flightdeck: `:
//     infra_preflight       a check failed before anything was created; one failing check
//                           per line, `name: detail — fix`
//     infra_name_in_use     the name is a paired host or another repo's machine
//     infra_enroll_timeout  the machine never said hello; kept for `infra down`, its console
//                           output (when the cloud had one) after the first line
//     infra_enroll_failed   the machine ended before it enrolled (its boot could not install or
//                           enroll hostd, and it powered itself off); destroyed, its console
//                           output (when the cloud had one) after the first line
//     infra_not_found       no such machine, orphan, or `[infra.<name>]` recipe
//     infra_refused         a rule forbids it (extend past the machine's own timer or a cap,
//                           a name already being created or destroyed)
//     infra_failed          anything else: OpenTofu's diagnostics, with their fix
//     infra_unavailable     this Flight Deck has no cloud service wired
//     infra_no_session      `infra.budget` from a caller with no valid tab token
//
// Streams. `up` and `down` may draw many `infraProgress` frames on one `cid`; the stream ends
// at its terminal frame (`infraMachine`, `infraDone` or `err`), after which nothing more is
// sent on that `cid`. Every other request is answered by exactly one frame. A CLI that is
// interrupted mid-`up` leaves the app going: a half-created machine must never be abandoned
// because a reader went away.
//
// Every one of these frames is sent only on the connection that asked. The local CLI may send
// any request; a paired phone may send exactly `infra.ls` (without `orphans`), `infra.extend`
// and `infra.down` by name, for its cloud pane, and any other draws `err(out_of_scope)`. A
// phone that sends them has claimed `FleetCapability.cloud`, so one that cannot decode these
// tags never receives one.
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
    /// Read or change the asking tab's session budget.
    case budget(BudgetAction)

    /// `ls`, `doctor` and `budget show` change nothing; the rest create, destroy or spend.
    public var isReadOnly: Bool {
        switch self {
        case .list, .doctor: return true
        case .budget(let action): return action == .show
        case .up, .down, .extend: return false
        }
    }

    /// What `infra.budget` does to the session's budget.
    public enum BudgetAction: Equatable, Sendable {
        case show
        /// Sets the cap, keeping the window's start; a first budget starts now.
        case set(usd: Double)
        /// A fresh window from now, at `usd` or the cap it already has.
        case renew(usd: Double?)
        case clear

        var name: String {
            switch self {
            case .show: return "show"
            case .set: return "set"
            case .renew: return "renew"
            case .clear: return "clear"
            }
        }
    }

    private enum Op: String, Codable {
        case up = "infra.up"
        case down = "infra.down"
        case list = "infra.ls"
        case doctor = "infra.doctor"
        case extend = "infra.extend"
        case budget = "infra.budget"
    }

    enum CodingKeys: String, CodingKey { case op, name, cwd, orphanID, orphans, seconds, action, usd }

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
        case .budget(let action):
            try c.encode(Op.budget, forKey: .op)
            try c.encode(action.name, forKey: .action)
            switch action {
            case .set(let usd): try c.encode(usd, forKey: .usd)
            case .renew(let usd): try c.encodeIfPresent(usd, forKey: .usd)
            case .show, .clear: break
            }
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
        case .budget:
            let usd = try c.decodeIfPresent(Double.self, forKey: .usd)
            switch try c.decode(String.self, forKey: .action) {
            case "show": self = .budget(.show)
            case "set":
                guard let usd else { throw DecodingError.keyNotFound(CodingKeys.usd, .init(codingPath: c.codingPath, debugDescription: "set needs usd")) }
                self = .budget(.set(usd: usd))
            case "renew": self = .budget(.renew(usd: usd))
            case "clear": self = .budget(.clear)
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "unknown budget action \(other)")
            }
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

/// A session's cloud budget as `infra.budget` answers it. Every figure counts only the
/// machines that session created, from its window's start (`since`). Dollar figures are
/// estimates; `line` is the one-line form the CLI and `/budget` print.
public struct WireSessionBudget: Codable, Equatable, Sendable {
    public let session: String
    /// Nil when the session has no budget: `spentUsd` is then everything its machines cost.
    public let capUsd: Double?
    /// ISO 8601; nil with no budget.
    public let since: String?
    public let spentUsd: Double
    public let remainingUsd: Double?
    /// What the session's running machines bill per hour right now.
    public let hourlyUsd: Double
    /// Seconds until the budget runs out at the current rates; nil when the machines' TTLs end
    /// first, or there is no budget. 0 is used up: its machines are being destroyed.
    public let exhaustsIn: Int?
    /// The session's machines that still exist.
    public let machines: [String]
    public let line: String

    public init(session: String, capUsd: Double?, since: String?, spentUsd: Double, remainingUsd: Double?,
                hourlyUsd: Double, exhaustsIn: Int?, machines: [String], line: String) {
        self.session = session
        self.capUsd = capUsd
        self.since = since
        self.spentUsd = spentUsd
        self.remainingUsd = remainingUsd
        self.hourlyUsd = hourlyUsd
        self.exhaustsIn = exhaustsIn
        self.machines = machines
        self.line = line
    }
}

// MARK: - A session's cloud, as the sidebar and the phone show it

/// The cloud machines one session created and where its budget stands, carried on
/// `WireSession.cloud` and moved by `FleetEvent.sessionCloudChanged` (withheld from a peer
/// without `FleetCapability.cloud`).
///
/// **Built to change rarely.** Spend grows every second a machine runs, and an event per tick
/// per session would flood the replay ring. So every figure that moves with the clock is sent
/// as a baseline plus a rate — `spentUsd` at `asOf`, burning `hourlyUsd` — and a deadline as an
/// absolute date, and a client extrapolates (`spent(at:)`, `remaining(at:)`). The Mac re-sends
/// on a structural change (a machine added, gone or changing state, a budget set or cleared,
/// a deadline moved) and otherwise only every few minutes, to re-anchor the baseline.
///
/// Absent (nil on `WireSession`) when the session has no machine that still exists; a budget
/// with no machines is not a reason to draw the icon.
public struct WireSessionCloud: Codable, Equatable, Sendable {
    /// When `spentUsd` and `monthUsd` were measured.
    public var asOf: Date
    /// The session's machines that still exist, oldest first.
    public var machines: [WireCloudMachine]
    /// What every machine of this session cost since the budget's window began (or ever, with
    /// no budget), as of `asOf`.
    public var spentUsd: Double
    /// What its running machines bill per hour now: the rate `spentUsd` grows at.
    public var hourlyUsd: Double
    /// The session's budget cap; nil with no budget.
    public var budgetCapUsd: Double?
    /// When the budget's window began; nil with no budget.
    public var budgetSince: Date?
    /// When the budget runs out at current rates; nil with no budget, or when every machine's
    /// deadline comes first. In the past: used up, its machines are being destroyed.
    public var budgetExhaustsAt: Date?
    /// This month's spend on every machine of this Mac, as of `asOf`, and the monthly cap.
    public var monthUsd: Double
    public var monthCapUsd: Double?

    public init(asOf: Date, machines: [WireCloudMachine], spentUsd: Double, hourlyUsd: Double,
                budgetCapUsd: Double? = nil, budgetSince: Date? = nil, budgetExhaustsAt: Date? = nil,
                monthUsd: Double, monthCapUsd: Double? = nil) {
        self.asOf = asOf
        self.machines = machines
        self.spentUsd = spentUsd
        self.hourlyUsd = hourlyUsd
        self.budgetCapUsd = budgetCapUsd
        self.budgetSince = budgetSince
        self.budgetExhaustsAt = budgetExhaustsAt
        self.monthUsd = monthUsd
        self.monthCapUsd = monthCapUsd
    }

    /// The session's spend extrapolated to `now` from the baseline at its current rate.
    public func spent(at now: Date) -> Double {
        spentUsd + hourlyUsd * max(0, now.timeIntervalSince(asOf)) / 3600
    }

    /// What is left of the budget at `now`; nil with no budget. Never negative.
    public func remaining(at now: Date) -> Double? {
        budgetCapUsd.map { max(0, $0 - spent(at: now)) }
    }

    /// This value with the clock-driven figures zeroed, for deciding whether a change is
    /// structural (worth an event) or only the baseline moving.
    public var structure: WireSessionCloud {
        var s = self
        s.asOf = .distantPast
        s.spentUsd = 0
        s.monthUsd = 0
        s.machines = machines.map { var m = $0; m.spentUsd = 0; return m }
        return s
    }

    /// The worst state among the machines, for the icon's tint: "failed" over "provisioning"
    /// (anything not yet ready) over "ready".
    public var badge: Badge {
        if machines.contains(where: { $0.state == "failed" || $0.state == "orphaned" }) { return .failed }
        if let exhausts = budgetExhaustsAt, exhausts <= asOf { return .failed }
        if machines.contains(where: { !["ready", "idle"].contains($0.state) }) { return .busy }
        return .ready
    }

    public enum Badge: Sendable { case ready, busy, failed }
}

/// One machine of a session's cloud. Strings for `state`, `cloud` and `network`, for
/// `WireInfraMachine`'s reason.
public struct WireCloudMachine: Codable, Equatable, Sendable, Identifiable {
    /// The `[infra.<name>]` name, unique on this Mac: what `infra.down`/`infra.extend` take.
    public var name: String
    public var cloud: String
    /// Empty for a user module, which chooses its own machine.
    public var instanceType: String
    public var region: String
    /// `InfraState`'s raw value.
    public var state: String
    public var network: String
    /// Nil when the machine cannot be priced.
    public var hourlyUsd: Double?
    /// What this machine has cost, as of the cloud's `asOf`.
    public var spentUsd: Double
    public var createdAt: Date
    /// The controller's deadline (the Reaper destroys it then).
    public var deadline: Date
    /// The machine's own TTL, past which `extend` cannot move `deadline`; nil means `deadline`.
    public var machineDeadline: Date?
    /// What went wrong, for a `failed` machine.
    public var failure: String?
    public var id: String { name }

    public init(name: String, cloud: String, instanceType: String, region: String, state: String, network: String,
                hourlyUsd: Double?, spentUsd: Double, createdAt: Date, deadline: Date,
                machineDeadline: Date? = nil, failure: String? = nil) {
        self.name = name
        self.cloud = cloud
        self.instanceType = instanceType
        self.region = region
        self.state = state
        self.network = network
        self.hourlyUsd = hourlyUsd
        self.spentUsd = spentUsd
        self.createdAt = createdAt
        self.deadline = deadline
        self.machineDeadline = machineDeadline
        self.failure = failure
    }

    /// This machine's spend extrapolated from `asOf` to `now`, at its rate, stopping at its
    /// deadline.
    public func spent(asOf: Date, at now: Date) -> Double {
        guard let rate = hourlyUsd, state != "gone" else { return spentUsd }
        let end = min(now, deadline)
        return spentUsd + rate * max(0, end.timeIntervalSince(asOf)) / 3600
    }
}
