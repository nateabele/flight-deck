import FleetKit
import SwiftUI

/// Where the Sessions stack goes for a session's cloud pane: from the row's cloud icon and from
/// the session screen's toolbar. Its own `Hashable` beside `UUID` and `IntakeRoute` so a session
/// id can never be taken for the pane.
struct CloudRoute: Hashable {
    let session: UUID
}

/// What a session's cloud machines are, what they cost against the budget, and the two controls
/// the phone has: extend an hour, destroy. The same detail as the Mac sidebar's popover.
///
/// **Live and extrapolated.** `cloud` is read from the fleet on every update, and the figures
/// that move with the clock are drawn from a one-second `TimelineView` off the Mac's baseline
/// (`WireSessionCloud.spent(at:)`), so they tick between the Mac's infrequent re-anchors.
///
/// **No abrupt pop.** When the last machine goes the pane stays and says so, rather than
/// vanishing under a reader who has just watched a destroy finish.
struct SessionCloudScreen: View {
    let title: String?
    let cloud: WireSessionCloud?
    /// Pins the clock for a render of the screen; nil is the wall clock, the only thing the app passes.
    let fixedNow: Date?
    @State private var model: SessionCloudModel
    @State private var destroying: WireCloudMachine?

    init(title: String?, cloud: WireSessionCloud?, commander: any InfraCommanding, now: Date? = nil) {
        self.title = title
        self.cloud = cloud
        self.fixedNow = now
        _model = State(initialValue: SessionCloudModel(commander: commander))
    }

    var body: some View {
        // The whole list is the timeline's content: a `TimelineView` inside a `List` is one row,
        // and what ticks is spread over several sections.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let cloud {
                    content(cloud, now: fixedNow ?? context.date)
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Destroy \(destroying?.name ?? "")?",
            isPresented: Binding(get: { destroying != nil }, set: { if !$0 { destroying = nil } }),
            titleVisibility: .visible,
            presenting: destroying
        ) { machine in
            Button("Destroy", role: .destructive) {
                Task { await model.destroy(machine.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text(CloudStyle.destroyMessage(machine))
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud").font(.largeTitle).foregroundStyle(.secondary)
            Text("No cloud machines").font(.headline)
            Text("\(title ?? "This session") has no machines left. They were destroyed or reached their time limit.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ cloud: WireSessionCloud, now: Date) -> some View {
        budgetSection(cloud, now: now)
        ForEach(cloud.machines) { machine in
            machineSection(machine, cloud: cloud, now: now)
        }
    }

    private func budgetSection(_ cloud: WireSessionCloud, now: Date) -> some View {
        Section {
            row("Spent", CloudStyle.money(cloud.spent(at: now)))
            row("Burning", CloudStyle.rate(cloud.hourlyUsd))
            if let cap = cloud.budgetCapUsd, let fraction = CloudStyle.budgetFraction(cloud, now: now) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Budget").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(CloudStyle.money(cloud.spent(at: now))) of \(CloudStyle.money(cap))")
                            .monospacedDigit()
                    }
                    bar(fraction, level: CloudStyle.budgetLevel(cloud, now: now) ?? .ok)
                    HStack {
                        Text("\(CloudStyle.money(cloud.remaining(at: now) ?? 0)) left").monospacedDigit()
                        Spacer()
                        if let runsOut = CloudStyle.runsOut(cloud, now: now) { Text(runsOut).monospacedDigit() }
                    }
                    .font(.caption)
                    .foregroundStyle(CloudStyle.budgetLevel(cloud, now: now) == .exhausted ? Instrument.red : .secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("No budget for this session").foregroundStyle(.secondary)
            }
            monthRow(cloud)
        } header: {
            Text(title ?? "Session").font(.system(.footnote, design: .monospaced))
        }
    }

    private func monthRow(_ cloud: WireSessionCloud) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This month").foregroundStyle(.secondary)
                Spacer()
                Text(cloud.monthCapUsd.map { "\(CloudStyle.money(cloud.monthUsd)) of \(CloudStyle.money($0))" }
                     ?? CloudStyle.money(cloud.monthUsd))
                    .monospacedDigit()
            }
            if let fraction = CloudStyle.monthFraction(cloud) {
                bar(fraction, level: CloudStyle.level(fraction: fraction))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func machineSection(_ machine: WireCloudMachine, cloud: WireSessionCloud, now: Date) -> some View {
        let failed = CloudStyle.isFailed(machine)
        let activity = model.activity[machine.name]
        return Section {
            HStack {
                Text(machine.name).font(.system(.body, design: .monospaced))
                Spacer()
                Text(CloudStyle.stateLabel(machine))
                    .font(.subheadline)
                    .foregroundStyle(failed ? Instrument.red : .secondary)
            }
            Text(CloudStyle.detail(machine)).font(.caption.monospaced()).foregroundStyle(.secondary)
            row("Rate", CloudStyle.rate(machine.hourlyUsd))
            row("Spent", CloudStyle.money(machine.spent(asOf: cloud.asOf, at: now)))
            row("Up", CloudStyle.duration(now.timeIntervalSince(machine.createdAt)))
            row("Stops in", CloudStyle.countdown(to: machine.deadline, now: now))
            if let failure = machine.failure, !failure.isEmpty {
                Text(failure).font(.footnote).foregroundStyle(Instrument.red)
            }
            controls(machine, activity: activity, now: now)
        }
    }

    @ViewBuilder
    private func controls(_ machine: WireCloudMachine, activity: SessionCloudModel.Activity?, now: Date) -> some View {
        let busy = activity?.running ?? false
        Button {
            Task { await model.extend(machine.name) }
        } label: {
            Label("Extend 1 hour", systemImage: "clock.badge.plus")
        }
        .disabled(busy || !CloudStyle.canExtend(machine))
        // Stated, not left to the list's disabled dimming, which a row of plain-looking text
        // survives: a disabled Extend must read as spent.
        .foregroundStyle(busy || !CloudStyle.canExtend(machine) ? Color.secondary.opacity(0.6) : Color.accentColor)
        .accessibilityIdentifier("cloud-extend-\(machine.name)")
        if let footnote = CloudStyle.extendFootnote(machine, now: now) {
            Text(footnote).font(.footnote).foregroundStyle(.secondary)
        }
        Button(role: .destructive) {
            destroying = machine
        } label: {
            Label("Destroy", systemImage: "trash")
        }
        .foregroundStyle(Instrument.red)
        .disabled(busy)
        .accessibilityIdentifier("cloud-destroy-\(machine.name)")
        if let activity {
            VStack(alignment: .leading, spacing: 2) {
                if activity.running {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(activity.action == .destroy ? "Destroying…" : "Extending…").font(.footnote)
                    }
                }
                ForEach(Array(activity.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let failure = activity.failure {
                    Text(failure).font(.footnote).foregroundStyle(Instrument.red)
                    Button("Dismiss") { model.dismissFailure(machine.name) }.font(.footnote)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Pieces

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func bar(_ fraction: Double, level: CloudStyle.Level) -> some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(Self.tint(level))
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    static func tint(_ level: CloudStyle.Level) -> Color {
        switch level {
        case .ok: Color.accentColor
        case .warning: Instrument.amber
        case .exhausted: Instrument.red
        }
    }
}

/// The session row's cloud glyph. A `Button` only where there is somewhere to go, with a 44pt
/// hit area that does not grow the row (the row's own insets and 52pt floor already hold it);
/// `.borderless` so the tap is the button's and not the enclosing `NavigationLink`'s.
struct CloudIcon: View {
    let cloud: WireSessionCloud
    let action: (() -> Void)?

    /// Grey when ready, the accent while something is still coming up, red when failed (the
    /// Mac's sidebar draws failed red too).
    static func tint(_ badge: WireSessionCloud.Badge) -> Color {
        switch badge {
        case .ready: .secondary
        case .busy: .accentColor
        case .failed: Instrument.red
        }
    }

    var body: some View {
        let image = Image(systemName: CloudStyle.iconName(cloud))
            .font(.subheadline)
            .foregroundStyle(Self.tint(cloud.badge))
        if let action {
            Button(action: action) {
                image.frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(Self.tint(cloud.badge))
            .frame(width: 44, height: 44)
            // Trimmed to 36pt of layout so the row stays at its 52pt floor; the hit area is the full 44.
            .padding(.vertical, -4)
            .accessibilityLabel(CloudStyle.iconLabel(cloud))
            .accessibilityIdentifier("session-cloud-icon")
        } else {
            image.accessibilityLabel(CloudStyle.iconLabel(cloud))
        }
    }
}
