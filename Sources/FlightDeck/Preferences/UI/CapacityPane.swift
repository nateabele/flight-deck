import SwiftUI
import IntakeKit

/// Settings → Capacity (L3-U §6): pools and the order inside each, thresholds, local caps,
/// "Confirm hand-offs" and the hand-off deadline, with the live meters of the selected pool.
struct CapacityPane: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageService
    /// Adapters with no accounts (`AccountModel.none`) can have local pools. None on master;
    /// the OpenCode adapter brings the first.
    let localAgents: [AgentID]
    @State private var selection: PoolID?

    init(preferences: PreferencesStore, usage: UsageService, localAgents: [AgentID]) {
        self.preferences = preferences; self.usage = usage; self.localAgents = localAgents
    }

    /// `AccountModel.none` spelled out: `.none` here would compare against `Optional.none`.
    @MainActor
    static func defaultLocalAgents() -> [AgentID] {
        let registry = RoutingCapabilityRegistry.standard()
        return registry.agents.filter { registry.capabilities(for: $0)?.accountModel == AccountModel.none }
    }

    private var accounts: [AgentAccount] { preferences.preferences.accounts }
    private var pools: [CapacityPool] { preferences.effectivePools }
    private var selected: CapacityPool? { pools.first { $0.id == (selection ?? pools.first?.id) } }

    /// Pool edits go to the Accounts list, which is where pools live now (unify brief R6).
    private func edit(_ change: (inout AccountList) -> Void) {
        try? preferences.updateAccountList { change(&$0) }
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
                        Text(pool.kind == .local ? "Local · \(pool.agent.rawValue)" : "\(pool.accounts.count) accounts · \(pool.agent.rawValue)")
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
                            edit { selection = CapacityEditing.addHostedPool(&$0, agent: agent) }
                        }
                    }
                    ForEach(localAgents, id: \.self) { agent in
                        Button("Local \(agent.rawValue) pool") {
                            edit { selection = CapacityEditing.addLocalPool(&$0, agent: agent) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("capacity-add-pool")
                Button {
                    guard let id = selected?.id else { return }
                    edit { _ = CapacityEditing.removePool(id, &$0) }
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
                                                set: { v in edit { CapacityEditing.rename(pool.id, to: v, &$0) } }))
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
                    if !pool.isDefault {
                        Button("Remove") { edit { CapacityEditing.toggle(id, in: pool.id, &$0) } }.buttonStyle(.borderless)
                    }
                }
            }
            .onMove { from, to in edit { CapacityEditing.move(in: pool.id, from: from, to: to, &$0) } }
        }
        .frame(minHeight: 90, maxHeight: 160)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capacity-accounts")
        if pool.isDefault {
            Text("A default pool holds every \(accountNoun(pool)) account. Make a new pool to choose accounts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        let others = accounts.filter { $0.agent == pool.agent && !$0.isRemoved && !pool.accounts.contains($0.id) }
        if !others.isEmpty {
            Menu("Add account") {
                ForEach(others) { a in Button(a.displayName) { edit { CapacityEditing.toggle(a.id, in: pool.id, &$0) } } }
            }
            .fixedSize()
        }
        Stepper(value: Binding(get: { Int((pool.softThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: Double(v) / 100, hard: pool.hardThreshold, &$0) } }),
                in: 5...99) {
            Text("New work stops at \(Int((pool.softThreshold * 100).rounded()))% (soft)")
        }
        .accessibilityIdentifier("capacity-soft")
        Stepper(value: Binding(get: { Int((pool.hardThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: pool.softThreshold, hard: Double(v) / 100, &$0) } }),
                in: 10...100) {
            Text("Agents hand off at \(Int((pool.hardThreshold * 100).rounded()))% (hard)")
        }
        .accessibilityIdentifier("capacity-hard")
    }

    private func accountNoun(_ pool: CapacityPool) -> String {
        pool.agent.displayName
    }

    @ViewBuilder
    private func localEditor(_ pool: CapacityPool) -> some View {
        TextField("Endpoint", text: Binding(get: { pool.endpoint ?? "" },
                                            set: { v in edit { CapacityEditing.setEndpoint(pool.id, v, &$0) } }))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("capacity-endpoint")
        Stepper(value: Binding(get: { pool.concurrencyCap },
                               set: { v in edit { CapacityEditing.setCap(pool.id, v, &$0) } }),
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
                // Greyed out until something can answer a confirmation: switched on, every agent
                // that crossed its hard limit waited for an answer nobody could give, still
                // running on the exhausted account (see `CapacityPreferences.confirmSurfaceExists`).
                .disabled(!CapacityPreferences.confirmSurfaceExists)
                .accessibilityIdentifier("capacity-confirm-handoffs")
            if !CapacityPreferences.confirmSurfaceExists {
                Text("Not available yet: Flight Control has no place to confirm a hand-off, so agents hand off without asking.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("capacity-confirm-unavailable")
            }
            let minutes = (preferences.capacity.handoffDeadlineSeconds ?? CapacityPreferences.defaultDeadlineSeconds) / 60
            Stepper(value: Binding(get: { minutes }, set: { m in preferences.updateCapacity { $0.handoffDeadlineSeconds = max(1, m) * 60 } }),
                    in: 1...60) {
                Text("Interrupt a busy agent after \(minutes) min")
            }
            .accessibilityIdentifier("capacity-deadline")
            Text("Your own tabs are never handed off. When their account passes its hard limit, you get one notification.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Takes effect when Flight Control runs swarm agents.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
