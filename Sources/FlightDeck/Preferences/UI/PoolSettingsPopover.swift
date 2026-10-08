import IntakeKit
import SwiftUI

/// A pool's settings (unify brief R7): name, kind, the soft and hard limits, and a local pool's
/// endpoint and concurrency cap. Same two-column form as the Routing popovers — labels on the
/// left, one control width on the right — and, like them, every change applies at once (a
/// slider on release), so there is no Save to forget.
///
/// Also edits an agent's DEFAULT pool (`<agent>-default`, every unpooled account): its
/// settings materialize as a memberless entry on first edit (`CapacityEditing.edit`), and it has
/// no Remove — there is nothing to remove but the settings.
struct PoolSettingsPopover: View {
    @ObservedObject var preferences: PreferencesStore
    let poolID: PoolID
    let agent: AgentID
    /// Agents whose pools can be local (no accounts, a concurrency cap). None on master — the
    /// Kind row shows only for them, or for a pool that is already local.
    var localAgents: [AgentID] = []
    var onRemove: (() -> Void)?
    let close: () -> Void

    @State private var name = ""
    @State private var soft = CapacityPool.defaultSoftThreshold
    @State private var hard = CapacityPool.defaultHardThreshold
    @State private var endpoint = ""
    @State private var loaded = false

    /// The pool as Level 3 sees it — for a default pool that only exists synthesized.
    private var pool: CapacityPool? {
        preferences.effectivePools.first { $0.id == poolID }
            ?? preferences.preferences.accountList.pool(poolID)?.capacityPool
    }
    private var isDefault: Bool { poolID == CapacityPool.defaultID(for: agent) }

    private func edit(_ change: (inout AccountList) -> Void) {
        try? preferences.updateAccountList { change(&$0) }
    }

    var body: some View {
        RoutingPopoverForm {
            RoutingPopoverRow("Name") {
                TextField("Pool name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitName)
                    .onChange(of: name) { _, _ in commitName() }
                    .accessibilityIdentifier("pool-settings-name")
            }
            if localAgents.contains(agent) || pool?.kind == .local {
                RoutingPopoverRow("Kind") {
                    FillingSegments(selection: Binding(get: { pool?.kind ?? .hosted }, set: { kind in
                        edit { list in try? list.updatePool(poolID) { $0.kind = kind } }
                    }), items: [(CapacityPool.Kind.hosted, "Accounts"), (.local, "Local endpoint")],
                    identifier: "pool-settings-kind")
                }
            }
            if pool?.kind == .local {
                RoutingPopoverRow("Endpoint") {
                    TextField("http://localhost:11434", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { edit { CapacityEditing.setEndpoint(poolID, endpoint, &$0) } }
                        .accessibilityIdentifier("pool-settings-endpoint")
                }
                RoutingPopoverRow("At once") {
                    Stepper(value: Binding(get: { pool?.concurrencyCap ?? CapacityPool.defaultConcurrencyCap },
                                           set: { v in edit { CapacityEditing.setCap(poolID, v, &$0) } }),
                            in: 1...64) {
                        Text("Up to \(pool?.concurrencyCap ?? CapacityPool.defaultConcurrencyCap) agents")
                            .monospacedDigit()
                    }
                    .accessibilityIdentifier("pool-settings-cap")
                }
            } else {
                RoutingPopoverRow("Soft limit") {
                    threshold($soft, in: 0.05...1.0, identifier: "pool-settings-soft")
                }
                RoutingPopoverRow("Hard limit") {
                    threshold($hard, in: 0.05...1.0, identifier: "pool-settings-hard")
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("New work goes to the first account under the soft limit. Flight Control's own agents hand off at the hard limit; your tabs are never moved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: RoutingPopoverForm<EmptyView, EmptyView>.controlWidth, alignment: .leading)
                }
            }
        } footer: {
            if !isDefault, let onRemove {
                Button("Remove Pool…", role: .destructive, action: onRemove)
                    .accessibilityIdentifier("pool-settings-remove")
            }
            Spacer()
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("pool-settings-done")
        }
        .onAppear(perform: load)
    }

    private func threshold(_ value: Binding<Double>, in range: ClosedRange<Double>, identifier: String) -> some View {
        HStack(spacing: 8) {
            // No `step:` — on macOS it draws a tick under every step, twenty dots that read as
            // noise. The value snaps to whole 5 % on release instead (`commitThresholds`).
            Slider(value: value, in: range) { editing in
                if !editing { commitThresholds() }
            }
            .accessibilityValue(AccountsPaneModel.percent(value.wrappedValue))
            .accessibilityIdentifier(identifier)
            // Fixed width and monospaced, so the track never shifts as 80 % becomes 100 %.
            Text(AccountsPaneModel.percent(value.wrappedValue))
                .font(.body.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func load() {
        guard !loaded, let pool else { return }
        loaded = true
        name = pool.label
        soft = pool.softThreshold
        hard = pool.hardThreshold
        endpoint = pool.endpoint ?? ""
    }

    private func commitName() {
        guard loaded, name.trimmingCharacters(in: .whitespacesAndNewlines) != pool?.label else { return }
        edit { CapacityEditing.rename(poolID, to: name, &$0) }
    }

    /// Clamped by `CapacityEditing` (soft stays at least 5 points under hard), and the sliders
    /// re-read the clamped values so they never show a pair the pool does not have.
    private func commitThresholds() {
        soft = (soft * 20).rounded() / 20
        hard = (hard * 20).rounded() / 20
        edit { CapacityEditing.setThresholds(poolID, soft: soft, hard: hard, &$0) }
        if let pool { soft = pool.softThreshold; hard = pool.hardThreshold }
    }
}

/// "Add Pool…": which agent's accounts it will hold, and its name. The pool is created empty;
/// accounts are dragged in (or moved with "Move to Pool") from the list.
struct AddPoolSheet: View {
    @ObservedObject var preferences: PreferencesStore
    let onCreate: (PoolID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentID
    @State private var name = ""

    init(preferences: PreferencesStore, agent: AgentID, onCreate: @escaping (PoolID) -> Void) {
        self.preferences = preferences
        self.onCreate = onCreate
        _agent = State(initialValue: agent)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Pool")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Agent").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    FillingPopUp(selection: $agent, items: AgentID.allCases.map { ($0, $0.displayName) },
                                 identifier: "pool-add-agent")
                        .frame(width: AddAccountSheet.fieldWidth)
                        .accessibilityLabel("Agent")
                }
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("New \(agent.displayName) pool", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AddAccountSheet.fieldWidth)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("pool-add-name")
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("A pool shares work across its accounts: each new tab or planning run takes the first account under the pool's soft limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: AddAccountSheet.fieldWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pool-add-confirm")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .fixedSize()
    }

    private func create() {
        var id: PoolID?
        try? preferences.updateAccountList { list in
            let made = CapacityEditing.addHostedPool(&list, agent: agent)
            if !trimmed.isEmpty { CapacityEditing.rename(made, to: trimmed, &list) }
            id = made
        }
        dismiss()
        if let id { onCreate(id) }
    }
}
