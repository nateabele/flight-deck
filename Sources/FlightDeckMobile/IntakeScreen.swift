import FleetKit
import SwiftUI

/// One intake (spec §4.3–§4.5), read-only in Phase 1.
struct IntakeScreen: View {
    let id: UUID
    let model: IntakeDetailModel
    let fleet: FleetModel
    @State private var confirmingStop = false
    private var commands: IntakeCommandModel { fleet.flightControl.commands(for: id) }
    private var frozenAt: Date? { if case .lost = fleet.state { return fleet.lastLive }; return nil }

    var body: some View {
        Group {
            if model.gone {
                ContentUnavailableView("This intake is no longer on your Mac", systemImage: "airplane.departure")
            } else if let detail = model.detail {
                content(detail)
            } else if model.failure != nil {
                // A first fetch that failed for any other reason would otherwise spin forever.
                // The raw error is not shown: it names wire codes, not anything to do.
                VStack(spacing: 12) {
                    Text("Couldn't load this intake.").font(.subheadline).foregroundStyle(.secondary)
                    Button { model.refresh() } label: { Text("Retry").font(.subheadline) }
                }
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
        .intakePresence(id: id, model: model, flightControl: fleet.flightControl)
    }

    @ViewBuilder private func content(_ d: WireIntakeDetail) -> some View {
        VStack(spacing: 0) {
            let strip = BoardStripModel(detail: d)
            BoardStrip(
                model: strip, offset: model.macClockOffset, frozenAt: frozenAt,
                onDot: { checkpoint in fleet.path.append(IntakeRoute.round(intake: id, checkpoint: checkpoint)) },
                keys: TransportKeys.keys(detail: d, inFlight: commands.inFlight),
                onKey: { key in
                    if key == "stop" { confirmingStop = true } else { tape(key) }
                },
                onDefault: { mode in
                    commands.send(.defaultPlay(mode), command: { .intakeDefaultPlay(id: id, token: $0, mode: mode) },
                                  onAck: { model.refresh() })
                })
            .padding(.bottom, 4)
            if let message = commands.message {
                HStack(alignment: .firstTextBaseline) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { commands.clearMessage() } label: {
                        Image(systemName: "xmark").font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
            }
            TimelineView(ClockSchedule(since: strip.clockSince, offset: model.macClockOffset, frozenAt: frozenAt, idle: strip.idle)) { context in
                let now = (frozenAt ?? context.date).addingTimeInterval(model.macClockOffset)
                List {
                    sections(for: d, now: now)
                }
                .opacity(frozenAt == nil ? 1 : 0.5)
            }
        }
        .confirmationDialog(
            TransportKeys.stopConfirmation(detail: d).title, isPresented: $confirmingStop, titleVisibility: .visible
        ) {
            Button("Stop Run", role: .destructive) { tape("stop") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TransportKeys.stopConfirmation(detail: d).message).font(.subheadline)
        }
    }

    private func tape(_ command: String, stage: String? = nil) {
        commands.send(.tape(command), command: { .intakeTape(id: id, token: $0, command: command, stage: stage) },
                      onAck: { model.refresh() })
    }

    @ViewBuilder private func roundsHeader(_ d: WireIntakeDetail) -> some View {
        if let control = RoundsControlModel.make(detail: d, inFlight: commands.inFlight) {
            let live = frozenAt == nil
            HStack(spacing: 0) {
                Text("Rounds · \(control.title)").font(.footnote)
                Spacer()
                Button { tape("trim", stage: control.stage) } label: {
                    Image(systemName: "minus").font(.subheadline).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!control.canTrim || !live)
                .accessibilityLabel("Remove a \(control.stage) round")
                Button { tape("extend", stage: control.stage) } label: {
                    Image(systemName: "plus").font(.subheadline).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!control.canExtend || !live)
                .accessibilityLabel("Add another \(control.stage) round")
            }
            .buttonStyle(.borderless)
        } else {
            Text("Rounds").font(.footnote)
        }
    }

    @ViewBuilder private func sections(for d: WireIntakeDetail, now: Date) -> some View {
        if let open = d.questions?.open {
            Section("Round \(d.questions!.answered.count + 1) · \(open.count) question\(open.count == 1 ? "" : "s")") {
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
            Section {
                ForEach(d.rounds, id: \.checkpoint) { r in
                    NavigationLink(value: IntakeRoute.round(intake: id, checkpoint: r.checkpoint)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.subheadline)
                                roundFactText(r).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(RoundFacts(r).time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { roundsHeader(d) }
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
        if r.linesAdded > 0 || r.linesRemoved > 0 { return "+\(r.linesAdded) −\(r.linesRemoved)" }
        return ""
    }

    /// Whether the fact line carries "fell back ⇄" — only beside line counts or alone, as before.
    static func fellBack(_ r: WireRound) -> Bool {
        r.outcome == "fallback" && !(r.verdicts != nil && r.changeCount != nil)
    }

    /// The fallback fragment is amber (spec §3: fallback is an exception), as it is in round
    /// detail; the rest of the line stays secondary.
    private func roundFactText(_ r: WireRound) -> Text {
        let base = Self.roundFact(r)
        guard Self.fellBack(r) else { return Text(base) }
        let fragment = Text("fell back ⇄").foregroundStyle(.orange)
        return base.isEmpty ? fragment : Text("\(base) · \(fragment)")
    }
}
