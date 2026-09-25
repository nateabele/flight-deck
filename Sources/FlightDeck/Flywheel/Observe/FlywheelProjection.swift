import Foundation

/// One poll's raw lanes, straight from `FlywheelReadCommands`. `nil` means "this lane's
/// command degraded" (unconfirmed shape, non-zero exit, unparseable stdout — see that
/// type's doc comment), never "empty on the wire" — `project(_:...)` is what turns a nil
/// lane into an empty collection plus a `lanesUnavailable` marker, so a drawer render never
/// has to distinguish "no reservations" from "couldn't ask about reservations".
struct FlywheelSnapshot: Equatable, Sendable {
    var agents: [FlywheelReadCommands.RawAgent]?
    var beads: [FlywheelReadCommands.RawBead]?
    var reservations: [FlywheelReadCommands.RawReservation]?
    var depEdges: [FlywheelReadCommands.RawDepEdge]?
    var events: [FlywheelReadCommands.RawEvent]?
}

/// `.blocked` beats `.stalled` beats `.active` beats `.unknown` — see `project(_:...)`'s
/// status derivation for the exact ordering and why. `.external` is reserved for an agent
/// that never joins (see `FlywheelProjection.agent(for:)`); `project(_:...)` itself never
/// produces it, since every row it builds came from the `agents` lane.
enum AgentStatus: Equatable, Sendable {
    case active, blocked, stalled, external, unknown
}

/// The observable model Observe's views render — a pure reduction of a `FlywheelSnapshot`
/// against the tab's `FlywheelIdentity`. No I/O, no SwiftUI: `project(_:...)` is a plain
/// function so the stall/continuity rules are unit-testable without a process, a clock
/// mock, or a view host.
struct FlywheelProjection: Equatable, Sendable {
    struct Bead: Equatable, Sendable {
        let id: String; let title: String; let status: String; let assignee: String?
    }

    struct Reservation: Equatable, Sendable {
        let file: String; let holder: String; let since: Date; let waiters: [String]
    }

    struct Agent: Equatable, Sendable {
        let name: String
        var bead: Bead?
        var status: AgentStatus
        var holds: [String]
        var waitsOn: [Reservation]
        var lastEventAt: Date?
        var stalledSince: Date?
    }

    enum EdgeKind: Equatable, Sendable { case dependency, reservation }
    struct DepEdge: Equatable, Sendable { let from: String; let to: String; let kind: EdgeKind }

    var agents: [Agent]
    var reservations: [Reservation]
    var depEdges: [DepEdge]
    var beadsByID: [String: Bead]
    var lanesUnavailable: Set<String>

    /// The join point between a booted tab and this poll's rows. `nil` is the **external**
    /// case — the identity's `agentName` never showed up in the `agents` lane at all, which
    /// is a normal outcome (the flywheel session hasn't registered yet, or isn't running
    /// under this project) and must render as "no data", not as an error.
    func agent(for identity: FlywheelIdentity) -> Agent? {
        agents.first { $0.name == identity.agentName }
    }

    /// Reduce one poll's raw lanes into the observable model, carrying `stalledSince`
    /// forward from `previous` so a refreshed lease (a new `RawReservation.since`) is
    /// continuity, not a reset stall clock — see `testRefreshedLeaseKeepsStallClockNotReset`.
    static func project(_ snapshot: FlywheelSnapshot, now: Date, stallThreshold: TimeInterval,
                         previous: FlywheelProjection?) -> FlywheelProjection {
        var lanesUnavailable: Set<String> = []
        if snapshot.agents == nil { lanesUnavailable.insert("agents") }
        if snapshot.beads == nil { lanesUnavailable.insert("beads") }
        if snapshot.reservations == nil { lanesUnavailable.insert("reservations") }
        if snapshot.depEdges == nil { lanesUnavailable.insert("depEdges") }
        if snapshot.events == nil { lanesUnavailable.insert("events") }

        let beads = (snapshot.beads ?? []).map {
            Bead(id: $0.id, title: $0.title, status: $0.status, assignee: $0.assignee)
        }
        // A duplicate bead id (corrupt db, a br bug) must degrade, not crash the drawer —
        // keep the last-seen row rather than trap via Dictionary(uniqueKeysWithValues:).
        let beadsByID = Dictionary(beads.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        let reservations = (snapshot.reservations ?? []).map {
            Reservation(file: $0.file, holder: $0.holder, since: $0.since, waiters: $0.waiters)
        }

        // `br dep`/`graph` edges pass through verbatim; a contended reservation (someone
        // waiting on the holder) additionally becomes a reservation edge from each waiter
        // to the holder, so the dependency view can show lock contention alongside real
        // bead dependencies without a second lane. With `depEdges` still a Task 2 nil-stub,
        // this is currently the only source of edges in practice.
        let dependencyEdges = (snapshot.depEdges ?? []).map { DepEdge(from: $0.from, to: $0.to, kind: .dependency) }
        let reservationEdges = reservations.flatMap { reservation -> [DepEdge] in
            guard !reservation.waiters.isEmpty else { return [] }
            return reservation.waiters
                .filter { $0 != reservation.holder }
                .map { DepEdge(from: $0, to: reservation.holder, kind: .reservation) }
        }
        let depEdges = dependencyEdges + reservationEdges

        let events = snapshot.events ?? []

        let agents = (snapshot.agents ?? []).map { raw -> Agent in
            let bead = beads.first { $0.assignee == raw.name }
            let holds = reservations.filter { $0.holder == raw.name }.map(\.file)
            let waitsOn = reservations.filter { $0.waiters.contains(raw.name) }
            let lastEventAt = events.filter { $0.agent == raw.name }.map(\.at).max()

            let blocked = bead?.status == "blocked"
            // Holds a file someone else is waiting on. The critical-path half of this
            // OR (from the spec) needs DependencyGraphLayout, which doesn't exist until
            // Task 4 — left out here rather than guessed; see task-3-brief.md ruling 1.
            let holdsContended = reservations.contains { $0.holder == raw.name && !$0.waiters.isEmpty }
            // No event at all reads as "no known recent activity", same as one older
            // than the threshold — either way there's nothing to call "active".
            let idlePastThreshold = lastEventAt.map { now.timeIntervalSince($0) >= stallThreshold } ?? true
            let recentActivity = lastEventAt.map { now.timeIntervalSince($0) < stallThreshold } ?? false

            let status: AgentStatus
            if blocked {
                status = .blocked
            } else if holdsContended && idlePastThreshold {
                status = .stalled
            } else if recentActivity {
                status = .active
            } else {
                status = .unknown
            }

            let stalledSince: Date?
            if status == .stalled {
                let previousAgent = previous?.agents.first { $0.name == raw.name }
                if let carried = previousAgent, carried.status == .stalled, let since = carried.stalledSince {
                    stalledSince = since
                } else {
                    stalledSince = now
                }
            } else {
                stalledSince = nil
            }

            return Agent(name: raw.name, bead: bead, status: status, holds: holds,
                          waitsOn: waitsOn, lastEventAt: lastEventAt, stalledSince: stalledSince)
        }

        return FlywheelProjection(agents: agents, reservations: reservations, depEdges: depEdges,
                                   beadsByID: beadsByID, lanesUnavailable: lanesUnavailable)
    }
}
