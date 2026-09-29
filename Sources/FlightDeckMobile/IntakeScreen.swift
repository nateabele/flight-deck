import FleetKit
import SwiftUI

/// One intake (spec §4.3–§4.5), read-only in Phase 1.
struct IntakeScreen: View {
    let id: UUID
    let model: IntakeDetailModel
    let fleet: FleetModel
    @Environment(\.scenePhase) private var scenePhase

    private var frozenAt: Date? { if case .lost = fleet.state { return fleet.lastLive }; return nil }

    var body: some View {
        Group {
            if model.gone {
                ContentUnavailableView("This intake is no longer on your Mac", systemImage: "airplane.departure")
            } else if let detail = model.detail {
                content(detail)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.detail?.summary.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let s = model.detail?.summary {
                    VStack(spacing: 0) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text([IntakeRowStyle.presetName(s.preset), IntakeRowStyle.stateWord(s)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { fleet.flightControl.onScreen = id }
        .onDisappear { if fleet.flightControl.onScreen == id { fleet.flightControl.onScreen = nil } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                model.refresh()
            }
        }
    }

    @ViewBuilder private func content(_ d: WireIntakeDetail) -> some View {
        VStack(spacing: 0) {
            BoardStrip(model: BoardStripModel(detail: d), offset: model.macClockOffset, frozenAt: frozenAt) { checkpoint in
                fleet.path.append(IntakeRoute.round(intake: id, checkpoint: checkpoint))
            }
            .padding(.bottom, 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = (frozenAt ?? context.date).addingTimeInterval(model.macClockOffset)
                List {
                    sections(for: d, now: now)
                }
                .opacity(frozenAt == nil ? 1 : 0.5)
            }
        }
    }

    @ViewBuilder private func sections(for d: WireIntakeDetail, now: Date) -> some View {
        if let open = d.questions?.open {
            Section("Round \(d.questions!.answered.count + 1) · \(open.count) questions") {
                ForEach(Array(open.enumerated()), id: \.offset) { i, q in
                    Text("\(i + 1). \(q)").font(.subheadline)
                }
                Text("Answer on your Mac for now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let answered = d.questions?.answered, !answered.isEmpty {
            Section {
                NavigationLink(value: IntakeRoute.clarifications(id)) {
                    Text("✓ Clarifications · \(answered.count) round\(answered.count == 1 ? "" : "s")").font(.subheadline)
                }
            }
        }
        if let choice = d.choice {
            Section("Fidelity") {
                if let rec = IntakeRowStyle.presetName(choice.recommended) {
                    Text("Recommended: \(rec).").font(.subheadline.weight(.semibold))
                }
                if let reason = choice.reason { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
                if let rounds = choice.roundsSummary { Text(rounds).font(.caption).foregroundStyle(.secondary) }
                Text("Choose fidelity and start on your Mac for now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if d.summary.state == "review" {
            Section { Text("Review and release on your Mac for now.").font(.subheadline) }
        }
        if let failure = d.failure {
            Section("Failure") {
                Text(failure.reason).font(.subheadline).foregroundStyle(.red)
                if let output = failure.output {
                    DisclosureGroup("Show output") { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
                        .font(.subheadline)
                }
            }
        }
        if !d.agents.isEmpty {
            let done = d.agents.filter(AgentRowStyle.finished).count
            Section("Agents · \(done) of \(d.agents.count) done") {
                ForEach(d.agents, id: \.id) { AgentRow(agent: $0, now: now) }
            }
        }
        if !d.rounds.isEmpty {
            Section("Rounds") {
                ForEach(d.rounds, id: \.checkpoint) { r in
                    NavigationLink(value: IntakeRoute.round(intake: id, checkpoint: r.checkpoint)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.subheadline)
                                Text(Self.roundFact(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(RoundFacts(r).time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if d.headCheckpoint != nil {
            Section {
                NavigationLink(value: IntakeRoute.plan(intake: id, checkpoint: nil)) {
                    HStack {
                        Text("Plan").font(.subheadline).foregroundStyle(Color.accentColor)
                        Spacer()
                        if d.pendingNotes > 0 { Text("\(d.pendingNotes) note\(d.pendingNotes == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    static func roundFact(_ r: WireRound) -> String {
        if let v = r.verdicts, let c = r.changeCount { return "\(c) changes · agreed \(v.agreed) · somewhat \(v.somewhat) · declined \(v.declined)" }
        if r.linesAdded > 0 || r.linesRemoved > 0 { return "+\(r.linesAdded) −\(r.linesRemoved)" + (r.outcome == "fallback" ? " · fell back ⇄" : "") }
        return r.outcome == "fallback" ? "fell back ⇄" : ""
    }
}
