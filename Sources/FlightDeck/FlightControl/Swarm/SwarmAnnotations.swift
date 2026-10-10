import IntakeKit
import SwiftUI

struct SwarmSessionAnnotation: Equatable {
    /// `fd-3x9 · snapshot-tests` (spec §6).
    var taskChip: String?
    var contested: Bool
    /// The account's worst-window utilization, only once it is past soft.
    var meter: Double?
    /// The leased account, so the row can ask `MeterFormatter` for the real meter. The Double above
    /// only decides whether there is anything to draw.
    var meterAccount: UUID? = nil
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
            contested: contested, meter: meter, meterAccount: agent.lease?.account.id, marker: marker,
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

    func lastActiveAt(for session: UUID) -> Date? { host?.lastActiveAt(for: session) }

    func annotation(for session: UUID, now: Date = Date()) -> SwarmSessionAnnotation? {
        guard let (_, agent) = agentRecord(session) else { return nil }
        let headroom = agent.lease.flatMap { dependencies?.capacity.headroom(for: $0.lease) }
        return SwarmAnnotations.session(agent, headroom: headroom, contested: isContested(session),
                                        lastActive: lastActiveAt(for: session), now: now)
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
    /// Observed so a reading that crosses soft redraws the meter with no other state changing;
    /// `UsageService` bumps `revision` on every reading and tick. Injectable for tests.
    @ObservedObject var usage: UsageService = .shared

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
            // The formatter, not the annotation, decides what is drawn: it answers per account
            // across every pool, so the row and the Capacity pane can never disagree.
            // Gated on the live result alone: `annotation.meter` is a snapshot from the last
            // sidebar render and would leave a meter lingering (or missing) after a reading.
            if let account = annotation.meterAccount,
               let model = MeterFormatter.rowMeter(account: account, ledger: usage.ledger, now: Date()) {
                RowMiniMeter(model: model)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.label) usage")
                    .accessibilityValue(model.accessibilityValue)
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

/// The header's swarm summary. Text, not a button: `ProjectHeaderRow` keeps every mouse-down
/// for its drag (see that file). Its popover opens from the header's context menu.
struct SwarmHeaderChip: View {
    let summary: SwarmHeaderSummary
    var body: some View {
        Text(summary.chipText)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .background(Capsule().fill(summary.banner == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.opacity(0.25))))
            .accessibilityIdentifier("swarm-header-chip")
    }
}

/// Pool meters (L3-U's `PoolMeterList`, for the pools this swarm leases from) and the tasks the swarm cannot start, with why.
struct SwarmPopover: View {
    let record: SwarmRecord
    /// Rebuilt from the live ledger on every render, so an open popover follows the readings.
    let pools: (CapacityLedger, Date) -> [PoolMeterModel]
    @ObservedObject var usage: UsageService = .shared
    let summary: SwarmHeaderSummary
    let onPause: () -> Void
    let onResume: () -> Void

    static func lines(for record: SwarmRecord) -> [String] {
        record.waiting.map { "\($0.task) — \($0.reason)" } + record.unroutable.map { "\($0.task) — unroutable: \($0.reason)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.text).font(.headline)
            if let banner = summary.banner { Text(banner).foregroundStyle(.orange) }
            let models = pools(usage.ledger, Date())
            if !models.isEmpty { PoolMeterList(pools: models) }
            let waiting = Self.lines(for: record)
            if !waiting.isEmpty {
                Text("Waiting").font(.subheadline)
                ForEach(waiting, id: \.self) { Text($0).font(.caption) }
            }
            HStack {
                if summary.canPause { Button("Pause", action: onPause).buttonStyle(.link).accessibilityIdentifier("swarm-pause") }
                if summary.canResume { Button("Resume", action: onResume).buttonStyle(.link).accessibilityIdentifier("swarm-resume") }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        // A container-level identifier would otherwise stamp every child, hiding their strings
        // from a UI test that reads `popover.staticTexts`.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swarm-popover")
    }
}

/// One account row of a pool's headroom, as the phone's `WireSwarmMeter` carries it. It serves
/// only the phone path now: the Mac popover draws `PoolMeterModel`s instead, from the same ledger.
struct SwarmMeterRow: Hashable {
    let pool: String
    let label: String
    let value: Double?
    let state: HeadroomState
}

extension SwarmService {
    /// The meter models for the pools this swarm's agents lease from, not every pool in the
    /// ledger: a project's popover answering for pools it never touches would bury its own.
    func meterPools(forProject path: String, ledger: CapacityLedger, now: Date) -> [PoolMeterModel] {
        guard let record = record(forProject: path) else { return [] }
        let used = Set(record.agents.compactMap { $0.lease?.pool })
        return MeterFormatter.pools(ledger, now: now).filter { used.contains($0.id) }
    }

    /// One row per account in every pool the swarm's agents lease from.
    func meters(forProject path: String) -> [SwarmMeterRow] {
        guard let record = record(forProject: path), let capacity = dependencies?.capacity else { return [] }
        let pools = Set(record.agents.compactMap { $0.lease?.pool }).sorted { $0.rawValue < $1.rawValue }
        return pools.flatMap { pool in
            capacity.headroom(pool: pool).map {
                SwarmMeterRow(pool: pool.rawValue, label: $0.account.label, value: $0.worstUtilization, state: $0.state)
            }
        }
    }
}

struct SwarmAssignmentDetail: Equatable {
    var lines: [String]
    var links: [ObserveLaneLink]
    /// The leased account's meter, drawn under the lines. Only the reference is held here: the
    /// drawer builds the model from the live ledger so it does not go stale.
    var meter: AssignmentMeterRef? = nil
}

struct AssignmentMeterRef: Equatable {
    let pool: PoolID
    let account: UUID

    /// Nil when the pool or account is gone from the ledger.
    func model(ledger: CapacityLedger, now: Date) -> AccountMeterModel? {
        MeterFormatter.pools(ledger, now: now).first { $0.id == pool }?
            .accounts.first { $0.id.hasSuffix("|\(account.uuidString)") }
    }
}

extension SwarmAnnotations {
    static func assignment(agent: SwarmAgentRecord, headroom: AccountHeadroom?, previous: SwarmAgentRecord?,
                           next: SwarmAgentRecord?, lastActive: Date?, now: Date) -> SwarmAssignmentDetail {
        let block = agent.block.block
        var lines = ["\(agent.task.map { "task \($0)" } ?? "no task") · kind \(block.kind.rawValue)"]
        let knobs = ConfigKey.knobsText(block.knobs)
        lines.append([block.agent.rawValue, block.model, knobs.isEmpty ? nil : knobs, "pool \(block.pool.rawValue)"]
            .compactMap { $0 }.joined(separator: " · "))
        if block.pinned {
            lines.append("pinned by hand — \(block.source.reason)")
        } else {
            let rule = block.source.ruleId.map { " \($0)" } ?? ""
            lines.append("routed by \(block.source.by.rawValue)\(rule) — \(block.source.reason)")
        }
        if let lease = agent.lease?.lease {
            let percent = headroom?.worstUtilization.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            lines.append("account \(lease.account.label)\(percent)")
        } else {
            lines.append("no account lease")
        }
        var links: [ObserveLaneLink] = []
        if let previous {
            lines.append("handed off from \(previous.agentName)")
            links.append(ObserveLaneLink(title: "← \(previous.agentName)", session: previous.session))
        }
        if let next {
            lines.append("handed off to \(next.agentName)")
            links.append(ObserveLaneLink(title: "\(next.agentName) →", session: next.session))
        }
        if let ago = activeAgo(lastActive, now: now) { lines.append(ago) }
        return SwarmAssignmentDetail(lines: lines, links: links)
    }
}

extension SwarmService {
    func assignment(for session: UUID, now: Date = Date()) -> SwarmAssignmentDetail? {
        guard let (record, agent) = agentRecord(session) else { return nil }
        let headroom = agent.lease.flatMap { dependencies?.capacity.headroom(for: $0.lease) }
        var detail = SwarmAnnotations.assignment(
            agent: agent, headroom: headroom,
            previous: agent.handedOffFrom.flatMap { record.agent($0) },
            next: agent.handedOffTo.flatMap { record.agent($0) },
            lastActive: lastActiveAt(for: session), now: now)
        if let lease = agent.lease?.lease, let id = lease.account.id {
            detail.meter = AssignmentMeterRef(pool: lease.pool, account: id)
        }
        if let contest = contest(for: session) { detail.lines += SwarmAnnotations.contestLines(contest, now: now) }
        return detail
    }
}

extension SwarmAnnotations {
    /// Spec §7.5's drawer sentence and the quoted message.
    static func contestLines(_ contest: Contest, now: Date) -> [String] {
        let minutes = Int(now.timeIntervalSince(contest.heldSince ?? contest.at) / 60)
        return ["waits on \(contest.file), held by \(contest.holder) · \(minutes) min", "“\(contest.message)”"]
    }
}
