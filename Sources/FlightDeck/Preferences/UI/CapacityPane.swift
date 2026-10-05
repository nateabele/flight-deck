import SwiftUI
import IntakeKit

/// Settings → Capacity (L3-U §6): pools and the order inside each, thresholds, local caps,
/// "Confirm hand-offs" and the hand-off deadline, with the live meters of the selected pool.
struct CapacityPane: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageService
    /// Adapters with no accounts (`AccountModel.none`) can have local pools. None on master;
    /// the OpenCode adapter brings the first.
    let localHarnesses: [HarnessID]
    @State private var selection: PoolID?

    init(preferences: PreferencesStore, usage: UsageService, localHarnesses: [HarnessID]) {
        self.preferences = preferences; self.usage = usage; self.localHarnesses = localHarnesses
    }

    /// `AccountModel.none` spelled out: `.none` here would compare against `Optional.none`.
    @MainActor
    static func defaultLocalHarnesses() -> [HarnessID] {
        let registry = RoutingCapabilityRegistry.standard()
        return registry.harnesses.filter { registry.capabilities(for: $0)?.accountModel == AccountModel.none }
    }

    private var accounts: [AgentAccount] { preferences.preferences.accounts }
    private var pools: [CapacityPool] { preferences.capacity.effectivePools(accounts: accounts) }
    private var selected: CapacityPool? { pools.first { $0.id == (selection ?? pools.first?.id) } }

    private func edit(_ change: (inout CapacityPreferences, [AgentAccount]) -> Void) {
        let snapshot = accounts
        preferences.updateCapacity { change(&$0, snapshot) }
    }

    var body: some View {
        HStack(spacing: 0) {
            poolList.frame(width: 210)
            Divider()
            ScrollView { detail.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var poolList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(pools) { pool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pool.label)
                        Text(pool.kind == .local ? "Local · \(pool.harness.rawValue)" : "\(pool.accounts.count) accounts · \(pool.harness.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(pool.id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capacity-pool-list")
            HStack(spacing: 4) {
                Menu {
                    ForEach(AgentID.allCases, id: \.self) { agent in
                        Button("\(agent.displayName) pool") {
                            edit { prefs, accts in selection = CapacityEditing.addHostedPool(&prefs, agent: agent, accounts: accts) }
                        }
                    }
                    ForEach(localHarnesses, id: \.self) { harness in
                        Button("Local \(harness.rawValue) pool") {
                            edit { prefs, accts in selection = CapacityEditing.addLocalPool(&prefs, harness: harness, accounts: accts) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("capacity-add-pool")
                Button {
                    guard let id = selected?.id else { return }
                    edit { prefs, accts in _ = CapacityEditing.removePool(id, &prefs, accounts: accts) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selected?.isDefault ?? true)
                    .help("Default pools cannot be removed")
                    .accessibilityIdentifier("capacity-remove-pool")
                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pool = selected {
                TextField("Name", text: Binding(get: { pool.label },
                                                set: { v in edit { CapacityEditing.rename(pool.id, to: v, &$0, accounts: $1) } }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("capacity-pool-name")
                if pool.kind == .hosted { hostedEditor(pool) } else { localEditor(pool) }
            }
            Divider()
            handoffSettings
            Divider()
            Text("Current usage").font(.headline)
            let _ = usage.revision
            PoolMeterList(pools: MeterFormatter.pools(usage.ledger, now: Date()).filter { $0.id == selected?.id })
        }
    }

    @ViewBuilder
    private func hostedEditor(_ pool: CapacityPool) -> some View {
        Text("Accounts, in lease order").font(.headline)
        List {
            ForEach(pool.accounts, id: \.self) { id in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Text(accounts.first { $0.id == id }?.displayName ?? "Removed account")
                    Spacer()
                    Button("Remove") { edit { CapacityEditing.toggle(id, in: pool.id, &$0, accounts: $1) } }.buttonStyle(.borderless)
                }
            }
            .onMove { from, to in edit { CapacityEditing.move(in: pool.id, from: from, to: to, &$0, accounts: $1) } }
        }
        .frame(minHeight: 90, maxHeight: 160)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capacity-accounts")
        let others = accounts.filter { $0.agent.harnessID == pool.harness && !$0.isRemoved && !pool.accounts.contains($0.id) }
        if !others.isEmpty {
            Menu("Add account") {
                ForEach(others) { a in Button(a.displayName) { edit { CapacityEditing.toggle(a.id, in: pool.id, &$0, accounts: $1) } } }
            }
            .fixedSize()
        }
        Stepper(value: Binding(get: { Int((pool.softThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: Double(v) / 100, hard: pool.hardThreshold, &$0, accounts: $1) } }),
                in: 5...99) {
            Text("New work stops at \(Int((pool.softThreshold * 100).rounded()))% (soft)")
        }
        .accessibilityIdentifier("capacity-soft")
        Stepper(value: Binding(get: { Int((pool.hardThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: pool.softThreshold, hard: Double(v) / 100, &$0, accounts: $1) } }),
                in: 10...100) {
            Text("Agents hand off at \(Int((pool.hardThreshold * 100).rounded()))% (hard)")
        }
        .accessibilityIdentifier("capacity-hard")
    }

    @ViewBuilder
    private func localEditor(_ pool: CapacityPool) -> some View {
        TextField("Endpoint", text: Binding(get: { pool.endpoint ?? "" },
                                            set: { v in edit { CapacityEditing.setEndpoint(pool.id, v, &$0, accounts: $1) } }))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("capacity-endpoint")
        Stepper(value: Binding(get: { pool.concurrencyCap },
                               set: { v in edit { CapacityEditing.setCap(pool.id, v, &$0, accounts: $1) } }),
                in: 1...64) {
            Text("Up to \(pool.concurrencyCap) agents at once")
        }
        .accessibilityIdentifier("capacity-cap")
        Text("Flight Deck counts only the agents it runs here. Load from outside Flight Deck is not visible.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var handoffSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand-offs").font(.headline)
            Toggle("Confirm hand-offs", isOn: Binding(get: { preferences.capacity.handoffSettings.confirm },
                                                      set: { v in preferences.updateCapacity { $0.confirmHandoffs = v } }))
                .accessibilityIdentifier("capacity-confirm-handoffs")
            let minutes = (preferences.capacity.handoffDeadlineSeconds ?? CapacityPreferences.defaultDeadlineSeconds) / 60
            Stepper(value: Binding(get: { minutes }, set: { m in preferences.updateCapacity { $0.handoffDeadlineSeconds = max(1, m) * 60 } }),
                    in: 1...60) {
                Text("Interrupt a busy agent after \(minutes) min")
            }
            .accessibilityIdentifier("capacity-deadline")
            Text("Your own tabs are never handed off. When their account passes its hard limit, you get one notification.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
