import Foundation
import IntakeKit

/// "Retry with another model": which agents the failed seat could be moved to, and the round
/// config that results — pure, so the halt panel only draws the menu and hands back a choice.
///
/// The seat is found from the halt's `Slot` (its role name, as `RoundExecutor.runName` writes it,
/// and its place in a rotation or among the drafters) and edited through
/// `RoundConfigEditor.updatingChoice`, the one writer the Rounds editor and the phone use, so a
/// rotation's single field and its first entry stay equal here too.
enum HaltReseat {
    /// One agent's models, as the picker lists them.
    struct Group: Equatable {
        var agent: AgentID
        var choices: [ModelChoice]
    }

    /// The config's seat for `slot`, nil for a role this config does not seat.
    static func keyPath(for slot: HaltStatus.Slot, in config: RoundConfig) -> SlotKeyPath? {
        let index = slot.slotIndex ?? 0
        let path: SlotKeyPath
        switch slot.role {
        case "drafter": path = .drafter(index)
        case "synthesizer": path = .synthesizer
        case "crossReviewer": path = .crossReviewer
        case "encoder": path = .encoder
        case "reviewer": path = RotatingRole.reviewer.keyPath(at: rotated(index, config.reviewerRotation.count))
        case "integrator": path = RotatingRole.integrator.keyPath(at: rotated(index, config.integratorRotation.count))
        case "polisher": path = RotatingRole.polisher.keyPath(at: rotated(index, config.polisherRotation.count))
        default: return nil
        }
        return RoundConfigEditor.choice(for: path, in: config) == nil ? nil : path
    }

    private static func rotated(_ index: Int, _ count: Int) -> Int { count > 0 ? index % count : 0 }

    /// Every other model on every installed agent, grouped by agent, the failed seat's own agent
    /// first (the likelier fix for a model that is gone, not for a network that is down). A
    /// model keeps the seat's effort on its own agent; another agent starts at its planning
    /// default, since an effort name is only meaningful to the agent that defined it.
    static func options(for slot: HaltStatus.Slot, config: RoundConfig, available: AvailableModels) -> [Group] {
        guard let path = keyPath(for: slot, in: config), let current = RoundConfigEditor.choice(for: path, in: config) else { return [] }
        let agents = available.choices.keys.sorted { lhs, rhs in
            lhs == current.agent || (rhs != current.agent && lhs.rawValue < rhs.rawValue)
        }
        return agents.compactMap { agent in
            let base = agent == current.agent ? current : available.choices[agent]
            let choices = available.menuOptions(for: agent, account: agent == current.agent ? current.account : nil)
                .filter { !(agent == current.agent && $0.id == current.model) }
                .compactMap { option in
                    base.map { ModelChoice(agent: agent, model: option.id, effort: $0.effort, account: agent == current.agent ? current.account : nil) }
                }
            return choices.isEmpty ? nil : Group(agent: agent, choices: choices)
        }
    }

    /// `config` with the failed seat moved to `choice`; nil when the seat is not in it.
    static func applying(_ choice: ModelChoice, to slot: HaltStatus.Slot, in config: RoundConfig) -> RoundConfig? {
        guard let path = keyPath(for: slot, in: config) else { return nil }
        return RoundConfigEditor.updatingChoice(config, at: path) { $0 = choice }
    }
}
