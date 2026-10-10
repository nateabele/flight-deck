import SwiftUI
import IntakeKit

/// Settings → Flight Control → Capacity (L3-U §6): "Confirm hand-offs", the hand-off deadline,
/// and the live meters of every pool. Pools themselves — their accounts, order and limits — are
/// edited in Settings → Accounts (unify brief R7), where the accounts are; this pane points
/// there rather than keeping a second editor that could disagree with it.
struct CapacityPane: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageService
    /// Adapters with no accounts (`AccountModel.none`) can have local pools. None on master;
    /// the OpenCode adapter brings the first. Read by the Accounts tab's pool popover.
    let localAgents: [AgentID]

    init(preferences: PreferencesStore, usage: UsageService, localAgents: [AgentID]) {
        self.preferences = preferences; self.usage = usage; self.localAgents = localAgents
    }

    /// `AccountModel.none` spelled out: `.none` here would compare against `Optional.none`.
    @MainActor
    static func defaultLocalAgents() -> [AgentID] {
        let registry = RoutingCapabilityRegistry.standard()
        return registry.agents.filter { registry.capabilities(for: $0)?.accountModel == AccountModel.none }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                handoffSettings
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Current usage").font(.headline)
                    Spacer()
                    Button("Edit Pools in Accounts…") { preferences.selectedTab = .accounts }
                        .accessibilityIdentifier("capacity-open-accounts")
                }
                let _ = usage.revision
                PoolMeterList(pools: MeterFormatter.pools(usage.ledger, now: Date()))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capacity-pool-meters")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
