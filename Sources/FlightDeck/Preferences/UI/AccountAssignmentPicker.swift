import IntakeKit
import SwiftUI

/// One choice in an account-or-pool picker: nil is "Default", whatever that means where the
/// picker sits (a project's agent's topmost account; the capability index's claude pool).
struct AccountAssignmentOption: Equatable {
    var value: AccountAssignment?
    var title: String
    var isPool: Bool
}

/// The account-or-pool menu (unify brief R8), shared by Settings → Projects (per agent) and the
/// capability index pane, so both list the same choices in the same order and both show a
/// stale assignment as "Missing" rather than silently reading Default.
struct AccountAssignmentPicker: View {
    let options: [AccountAssignmentOption]
    @Binding var selection: AccountAssignment?
    let identifier: String

    var body: some View {
        Picker("Account", selection: $selection) {
            // By position: two accounts may share a display name.
            ForEach(Array(options.filter { !$0.isPool }.enumerated()), id: \.offset) { _, option in
                Text(option.title).tag(option.value)
            }
            let pools = options.filter(\.isPool)
            if !pools.isEmpty {
                Divider()
                ForEach(Array(pools.enumerated()), id: \.offset) { _, option in
                    Label(option.title, systemImage: "square.stack.3d.up").tag(option.value)
                }
            }
            // An assignment that names something gone still has to be shown as what it is, or
            // the picker silently reads "Default" while runs are refused as BROKEN.
            if let assigned = selection, !options.contains(where: { $0.value == assigned }) {
                Divider()
                Text("Missing \(assigned.poolID == nil ? "account" : "pool")").tag(AccountAssignment?.some(assigned))
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}

/// The capability index's choices: Projects' list for claude, with Default naming the pool an
/// unset assignment leases from (`AccountResolver.defaultIndexPool`) — the index's Default is a
/// pool, not the topmost account a project's Default is, and the menu must say which.
enum IndexAccountChoices {
    static func options(for agent: AgentID, in list: AccountList) -> [AccountAssignmentOption] {
        var options = ProjectsSettingsTab.accountOptions(for: agent, in: list)
        let pools = list.effectivePools()
        if let id = AccountResolver.defaultIndexPool(for: agent, in: pools),
           let pool = pools.first(where: { $0.id == id }) {
            options[0].title = "Default (\(AccountBilling.poolName(pool.label)))"
        }
        return options
    }
}
