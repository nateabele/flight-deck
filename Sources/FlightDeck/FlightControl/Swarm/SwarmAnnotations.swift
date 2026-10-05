import IntakeKit
import SwiftUI

struct SwarmSessionAnnotation: Equatable {
    /// `fd-3x9 · snapshot-tests` (spec §6).
    var taskChip: String?
    var contested: Bool
    /// The account's worst-window utilization, only once it is past soft.
    var meter: Double?
    /// waiting / done <task> / handed off → / a failure note.
    var marker: String?
    var lastActive: String?
}

struct SwarmHeaderSummary: Equatable {
    var text: String
    var banner: String?
    var state: SwarmState
    var canPause: Bool { state == .running || state == .draining }
    var canResume: Bool { state == .paused || state == .draining }
    /// The header chip shows the banner when there is one — it is what needs the human.
    var chipText: String { banner ?? text }
}

/// Pure builders for every swarm annotation. Views below only render their output.
enum SwarmAnnotations {
    static func activeAgo(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes <= 0 ? "active just now" : "active \(minutes) min ago"
    }

    static func session(_ agent: SwarmAgentRecord, headroom: AccountHeadroom?, contested: Bool,
                        lastActive: Date?, now: Date) -> SwarmSessionAnnotation {
        let marker: String?
        switch agent.state {
        case .working: marker = nil
        case .starting: marker = "starting"
        case .idle: marker = agent.marker ?? agent.lastTask.map { "done \($0)" } ?? "waiting"
        case .handedOff: marker = "handed off →"
        case .done: marker = agent.marker == "tab closed" ? nil : "done"
        }
        let meter: Double?
        switch headroom?.state {
        case .overSoft?, .overHard?: meter = headroom?.worstUtilization ?? 1
        default: meter = nil
        }
        return SwarmSessionAnnotation(
            taskChip: agent.task.map { "\($0) · \(agent.block.block.kind)" },
            contested: contested, meter: meter, marker: marker,
            lastActive: activeAgo(lastActive, now: now))
    }

    static func header(_ record: SwarmRecord, contested: Int) -> SwarmHeaderSummary {
        let counts = "\(record.activeCount)/\(record.cap)"
        var parts = [record.state == .running ? "swarm \(counts)" : "swarm \(record.state.rawValue) · \(counts)"]
        if !record.waiting.isEmpty { parts.append("\(record.waiting.count) waiting") }
        if contested > 0 { parts.append("\(contested) contested") }
        return SwarmHeaderSummary(text: parts.joined(separator: " · "), banner: record.banner, state: record.state)
    }
}

extension SwarmService {
    func agentRecord(_ session: UUID) -> (SwarmRecord, SwarmAgentRecord)? {
        for record in allRecords {
            if let agent = record.agent(session) { return (record, agent) }
        }
        return nil
    }

    func annotation(for session: UUID, now: Date = Date()) -> SwarmSessionAnnotation? {
        guard let (_, agent) = agentRecord(session) else { return nil }
        let headroom = agent.lease.flatMap { dependencies?.capacity.headroom(for: $0.lease) }
        return SwarmAnnotations.session(agent, headroom: headroom, contested: isContested(session),
                                        lastActive: host?.lastActiveAt(for: session), now: now)
    }

    func summary(forProject path: String) -> SwarmHeaderSummary? {
        guard let record = record(forProject: path) else { return nil }
        let contested = record.agents.filter { $0.state == .working || $0.state == .idle }
            .filter { isContested($0.session) }.count
        return SwarmAnnotations.header(record, contested: contested)
    }
}

/// The chips after a swarm session's title. Plain text and shapes only: anything that takes a
/// mouse-down here breaks the row's drag and rename (see `SessionRow`'s comments).
struct SwarmRowChips: View {
    let annotation: SwarmSessionAnnotation

    var body: some View {
        HStack(spacing: 4) {
            if let chip = annotation.taskChip {
                Text(chip)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityIdentifier("swarm-task-chip")
            }
            if annotation.contested {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help("Waiting on a file another agent holds")
                    .accessibilityLabel("contested")
                    .accessibilityIdentifier("swarm-contested")
            }
            if let meter = annotation.meter {
                MinimalMeter(value: meter)
                    .frame(width: 22, height: 4)
                    .help("Account at \(Int(meter * 100))%")
                    .accessibilityLabel("account at \(Int(meter * 100)) percent")
                    .accessibilityIdentifier("swarm-meter")
            }
            if let marker = annotation.marker {
                Text(marker).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("swarm-marker")
            }
            if let ago = annotation.lastActive {
                Text(ago).font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("swarm-last-active")
            }
        }
    }
}

/// A minimal meter drawn from `AccountHeadroom`. Integration swaps in L3-U's standalone meter
/// view; this exists so L3-S's own UI and UI tests have something real to show.
struct MinimalMeter: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(value >= 1 ? Color.red : .orange)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
    }
}
