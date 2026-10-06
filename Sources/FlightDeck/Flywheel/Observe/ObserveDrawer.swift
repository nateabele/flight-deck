import SwiftUI

/// The fixed rows of the per-tab Observe drawer, in display order. `assignment` (L3-S) is
/// first and appears only for a swarm agent.
enum ObserveLane: Equatable, Sendable {
    case assignment, workingOn, files, dependency, activity
}

/// A jump to another tab — the assignment lane's previous/next hand-off agents.
struct ObserveLaneLink: Equatable, Sendable {
    let title: String
    let session: UUID
}

/// One rendered row. `isUnavailable` means the poll couldn't answer this lane's question
/// at all (a degraded `FlywheelSnapshot` lane, per `FlywheelProjection.lanesUnavailable`) —
/// distinct from an available lane whose answer happens to be empty, which still renders
/// its own "nothing here" copy rather than this flag.
struct ObserveLaneRow: Equatable, Sendable {
    let lane: ObserveLane
    let title: String
    let detail: String
    let isUnavailable: Bool
    var links: [ObserveLaneLink] = []
}

/// Pure reduction from a projected `Agent` to the drawer's rows: four, plus the Assignment lane
/// first for a swarm agent. No SwiftUI, no I/O —
/// `ObserveDrawer` is a thin wiring of this plus the collapse/toggle callbacks, so every
/// decision here is unit-testable without a view host (AGENTS.md rule 2: agents can't drive
/// the real GUI, so logic that lived in the view body would be unverifiable by an agent).
struct ObserveLaneModel {
    /// Which `FlywheelProjection.lanesUnavailable` key backs each `ObserveLane`. `dependency`
    /// and `activity` both key off `depEdges`/`events`, which the projection reports
    /// separately — a lane degrades if EITHER of its inputs did, since a partial answer
    /// (edges with no timestamps, or vice versa) isn't one this drawer can render.
    private static func unavailableKeys(for lane: ObserveLane) -> [String] {
        switch lane {
        case .assignment: return []
        case .workingOn: return ["agents", "beads"]
        case .files: return ["reservations"]
        case .dependency: return ["depEdges"]
        case .activity: return ["events"]
        }
    }

    /// `nil` agent means the tab's identity never showed up in this poll (the external
    /// case documented on `FlywheelProjection.agent(for:)`) — there is no per-lane data to
    /// degrade, so the drawer itself is absent rather than showing a column of unavailable rows.
    static func lanes(for agent: FlywheelProjection.Agent?, assignment: SwarmAssignmentDetail? = nil,
                      unavailable: Set<String>) -> [ObserveLaneRow] {
        guard let agent else { return [] }
        let head = assignment.map {
            [ObserveLaneRow(lane: .assignment, title: "Assignment", detail: $0.lines.joined(separator: "\n"),
                            isUnavailable: false, links: $0.links)]
        } ?? []
        return head + [
            row(.workingOn, title: "Working on", unavailable: unavailable) {
                workingOnDetail(agent)
            },
            row(.files, title: "Files", unavailable: unavailable) {
                filesDetail(agent)
            },
            row(.dependency, title: "Dependency", unavailable: unavailable) {
                dependencyDetail(agent)
            },
            row(.activity, title: "Activity", unavailable: unavailable) {
                activityDetail(agent)
            },
        ]
    }

    private static func row(_ lane: ObserveLane, title: String, unavailable: Set<String>,
                             detail: () -> String) -> ObserveLaneRow {
        let degraded = unavailableKeys(for: lane).contains { unavailable.contains($0) }
        return ObserveLaneRow(lane: lane, title: title,
                               detail: degraded ? "unavailable" : detail(),
                               isUnavailable: degraded)
    }

    private static func workingOnDetail(_ agent: FlywheelProjection.Agent) -> String {
        guard let bead = agent.bead else { return "no assigned task" }
        return "\(bead.id) · \(bead.title)"
    }

    private static func filesDetail(_ agent: FlywheelProjection.Agent) -> String {
        var parts: [String] = []
        if !agent.holds.isEmpty {
            parts.append("held ✓ " + agent.holds.joined(separator: ", "))
        }
        for reservation in agent.waitsOn {
            let idleMinutes = Int(Date().timeIntervalSince(reservation.since) / 60)
            parts.append("waiting ◔ \(reservation.file) · held by \(reservation.holder) · idle \(idleMinutes)m")
        }
        return parts.isEmpty ? "no held or waited-on files" : parts.joined(separator: "\n")
    }

    private static func dependencyDetail(_ agent: FlywheelProjection.Agent) -> String {
        guard let reservation = agent.waitsOn.first else { return "no blocking dependency" }
        return "blocked on \(reservation.holder) ⤢ open graph"
    }

    private static func activityDetail(_ agent: FlywheelProjection.Agent) -> String {
        guard let lastEventAt = agent.lastEventAt else { return "no recent activity" }
        let idleMinutes = Int(Date().timeIntervalSince(lastEventAt) / 60)
        return idleMinutes <= 0 ? "active just now" : "last event \(idleMinutes)m ago"
    }
}

/// Per-tab bottom drawer, mounted under `TerminalPane`. Every decision (which lanes
/// render, what their detail text says, whether a lane reads as unavailable) comes from
/// `ObserveLaneModel`, tested separately — this body only wires that model's output plus
/// the collapse/jump/open callbacks into SwiftUI, per AGENTS.md rule 2 (this view is
/// GUI-verified by hand in Task 13, not by an agent).
struct ObserveDrawer: View {
    let agent: FlywheelProjection.Agent?
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onJumpToRootCause: () -> Void
    let onOpenDAG: () -> Void
    var assignment: SwarmAssignmentDetail? = nil
    /// The focused tab, for its hand-off history. Nil outside a swarm.
    var session: UUID? = nil
    /// Read from memory on every render; refreshed off the main thread by `.task` below.
    @ObservedObject private var handoffs = HandoffHistoryCache.shared
    var onJumpToSession: (UUID) -> Void = { _ in }

    var body: some View {
        if let agent {
            if collapsed {
                collapsedBar(agent)
            } else {
                expanded(agent)
            }
        }
    }

    private func collapsedBar(_ agent: FlywheelProjection.Agent) -> some View {
        HStack(spacing: 6) {
            statusDot(agent.status)
            Text(agent.bead?.id ?? agent.name)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand Observe drawer")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Without .contain the id is stamped onto every child, hiding the lanes' own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observe-drawer-collapsed")
    }

    private func expanded(_ agent: FlywheelProjection.Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusDot(agent.status)
                Text(agent.name)
                    .font(.headline)
                Spacer()
                Button(action: onToggleCollapse) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Observe drawer")
            }

            ForEach(ObserveLaneModel.lanes(for: agent, assignment: assignment, unavailable: []), id: \.lane) { row in
                laneRow(row)
            }

            Button("Jump to root cause", action: onJumpToRootCause)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(8)
        // Without .contain the id is stamped onto every child, hiding the lanes' own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observe-drawer-expanded")
        .task(id: session) { if session != nil { await handoffs.refresh() } }
    }

    private func laneRow(_ row: ObserveLaneRow) -> some View {
        HStack(alignment: .top) {
            Text(row.title)
                .font(.caption.bold())
                .frame(width: 80, alignment: .leading)
            if row.lane == .assignment {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.detail).font(.caption).textSelection(.enabled)
                    if let meter = assignment?.meter { AccountMeterBar(model: meter) }
                    if let session {
                        ForEach(HandoffHistory.lines(for: session, entries: handoffs.entries(for: session)), id: \.self) {
                            Text($0).font(.caption2).foregroundStyle(.secondary)
                                .accessibilityIdentifier("observe-handoff-history")
                        }
                    }
                    HStack {
                        ForEach(row.links, id: \.session) { link in
                            Button(link.title) { onJumpToSession(link.session) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                // A container id would otherwise stamp every child, hiding the detail text's value.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("observe-lane-assignment")
            } else if row.lane == .dependency {
                Button(action: onOpenDAG) {
                    Text(row.detail)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(row.isUnavailable ? .secondary : .primary)
            }
        }
    }

    private func statusDot(_ status: AgentStatus) -> some View {
        Circle()
            .fill(color(for: status))
            .frame(width: 8, height: 8)
    }

    private func color(for status: AgentStatus) -> Color {
        switch status {
        case .active: return .green
        case .blocked: return .red
        case .stalled: return .orange
        case .external, .unknown: return .secondary
        }
    }
}
