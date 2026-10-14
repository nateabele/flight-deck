import FleetKit
import Foundation
import IntakeKit

/// What the phone's Rounds editor needs from the Mac, and the way back: the menus it builds its
/// pickers from, the roles a shaping tape has locked, and an edited `WireRoundConfig` read as a
/// `RoundConfig`. The editing rules themselves are the Mac editor's (`RoundConfigEditor`,
/// `ShapingEdit`); this only carries them across, so the phone cannot do what the Mac's own
/// editor would not.
enum PhoneRoundsEdit {
    // MARK: Menus

    /// Every agent the Mac's model menu lists, in its order: those usable now with their models
    /// (named by the CLI, else `ModelNaming`) and effort levels per model, and those installed but
    /// not usable with detection's reason. `accounts` is each agent's account picker for the
    /// intake's project.
    static func menu(available: AvailableModels, accounts: [AgentID: AccountMenu],
                     naming: IntakeDetailProjection.Naming) -> WireRoundsMenu {
        WireRoundsMenu(agents: RoundConfigEditor.menuAgents(in: available, chosen: nil).map { agent in
            let catalog = AgentProfiles.profile(for: agent).modelCatalog
            let reason = RoundConfigEditor.unavailableReason(agent, available: available)
            guard reason == nil else {
                return WireAgentOption(agent: agent.rawValue, name: agent.displayName, reason: reason)
            }
            func options(_ account: AccountChoice?) -> [WireModelOption] {
                available.menuOptions(for: agent, account: account).map {
                    WireModelOption(id: $0.id, name: $0.name,
                                    efforts: available.effortValues(agent: agent, model: $0.id, account: account))
                }
            }
            let own = options(nil)
            let menu = accounts[agent]
            // Only the accounts whose list differs from the project default's: most share it.
            var byAccount: [String: [WireModelOption]] = [:]
            for option in menu?.options ?? [] {
                let list = options(option.choice)
                if list != own { byAccount[option.choice.key] = list }
            }
            return WireAgentOption(
                agent: agent.rawValue, name: agent.displayName, models: own,
                accountModels: byAccount.isEmpty ? nil : byAccount, efforts: catalog.effortValues,
                planningEffort: catalog.defaultPlanningEffort,
                defaultChoice: available.choice(for: agent).map { IntakeDetailProjection.wireChoice($0, naming: naming) },
                accounts: menu.map { menu in
                    WireAccountMenu(
                        defaultTitle: menu.defaultTitle, offersChoice: menu.offersChoice,
                        options: menu.options.map { WireAccountOption(key: $0.choice.key, title: $0.title, isPool: $0.isPool) })
                })
        })
    }

    /// The roles a shaping tape has run, by the ids the phone's inspector uses, with the caps'
    /// bookkeeping and whether an edit would be taken now.
    static func lock(_ shaping: ShapingEdit, config: RoundConfig, editing: DetailLayout.RoundsEditing) -> WireRoundsLock {
        var locked: [String] = []
        for index in config.drafters.indices where shaping.isLocked(.drafter(index)) { locked.append("drafter\(index)") }
        let roles: [(String, SlotKeyPath)] = [
            ("synthesizer", .synthesizer), ("reviewer", .reviewer), ("crossReviewer", .crossReviewer),
            ("integrator", .integrator), ("encoder", .encoder), ("polisher", .polisher),
        ]
        locked += roles.filter { shaping.isLocked($0.1) }.map(\.0)
        return WireRoundsLock(
            editable: editing == .editable, reason: editing == .editable ? nil : IntakeService.pauseToEdit,
            locked: locked, refineDone: shaping.refineDone, polishDone: shaping.polishDone,
            freshEyesDone: shaping.freshEyesDone, extraRefinement: shaping.extraRefinement,
            extraPolish: shaping.extraPolish, refinementFloor: shaping.refinementFloor, polishFloor: shaping.polishFloor)
    }

    // MARK: Reading an edit

    /// `wire` as the Mac's config, or nil for anything it cannot be (an agent, account, persona,
    /// policy or play this build does not know). A rotation's first entry is written back to the
    /// role's single field, which the Mac keeps equal to it (`RoundConfig.reviewers`).
    static func roundConfig(_ wire: WireRoundConfig) -> RoundConfig? {
        func choice(_ c: WireModelChoice) -> ModelChoice? {
            guard let agent = AgentID(rawValue: c.agent) else { return nil }
            guard let key = c.accountKey else { return ModelChoice(agent: agent, model: c.model, effort: c.effort) }
            return AccountChoice(key: key).map { ModelChoice(agent: agent, model: c.model, effort: c.effort, account: $0) }
        }
        func slot(_ s: WireSeat) -> Slot? {
            guard let picked = choice(s.choice) else { return nil }
            var persona = DrafterPersona.general
            if let raw = s.persona {
                guard let known = DrafterPersona(rawValue: raw) else { return nil }
                persona = known
            }
            guard let wireFallback = s.fallback else { return Slot(picked, persona: persona) }
            return choice(wireFallback).map { Slot(picked, persona: persona, fallback: $0) }
        }
        // All or nothing: one entry this build cannot read makes the whole config unreadable.
        func all<T>(_ seats: [WireSeat], _ read: (WireSeat) -> T?) -> [T]? {
            let read = seats.compactMap(read)
            return read.count == seats.count ? read : nil
        }
        guard let play = PlayMode(rawValue: wire.defaultPlay),
              let drafters = all(wire.drafters, slot),
              let integrator = choice(wire.integrator.choice),
              let encoder = choice(wire.encoder.choice) else { return nil }
        var cross: CrossCheckPolicy?
        if let raw = wire.crossCheck {
            guard let known = CrossCheckPolicy(rawValue: raw) else { return nil }
            cross = known
        }
        var config = RoundConfig(
            drafters: drafters, synthesizer: nil, reviewer: nil, integrator: integrator, encoder: encoder,
            polisher: nil, refinementCap: wire.refinementCap, polishCap: wire.polishCap,
            freshEyesAndDedup: wire.freshEyesAndDedup, defaultPlay: play, customized: wire.customized,
            crossReviewer: nil, crossCheck: cross)
        if let seat = wire.synthesizer { guard let s = slot(seat) else { return nil }; config.synthesizer = s }
        if let seat = wire.reviewer { guard let s = slot(seat) else { return nil }; config.reviewer = s }
        if let seat = wire.crossReviewer { guard let s = slot(seat) else { return nil }; config.crossReviewer = s }
        if let seat = wire.polisher { guard let c = choice(seat.choice) else { return nil }; config.polisher = c }
        // A rotation means nothing for a role the config does not seat (Sketch has no polisher).
        if config.reviewer != nil, let list = wire.reviewers, list.count > 1 {
            guard let rotation = all(list, slot) else { return nil }
            config.reviewers = rotation; config.reviewer = rotation[0]
        }
        if let list = wire.integrators, list.count > 1 {
            guard let rotation = all(list, { choice($0.choice) }) else { return nil }
            config.integrators = rotation; config.integrator = rotation[0]
        }
        if config.polisher != nil, let list = wire.polishers, list.count > 1 {
            guard let rotation = all(list, { choice($0.choice) }) else { return nil }
            config.polishers = rotation; config.polisher = rotation[0]
        }
        return config
    }

    /// Whether two configs run the same rounds: everything but the `customized` flag, with an
    /// empty rotation the same as none — how a stale `base` is told from a current one.
    static func sameRounds(_ a: RoundConfig, _ b: RoundConfig) -> Bool { normalized(a) == normalized(b) }

    private static func normalized(_ c: RoundConfig) -> RoundConfig {
        var n = c
        n.customized = false
        if n.reviewers?.isEmpty == true { n.reviewers = nil }
        if n.integrators?.isEmpty == true { n.integrators = nil }
        if n.polishers?.isEmpty == true { n.polishers = nil }
        return n
    }

    /// Whether `edited` is a config the phone could have made from `reference`: the same drafters
    /// (the editor neither adds nor removes one, nor changes a persona), the same roles seated,
    /// round counts a person could have set, and only agents that are usable now or that the
    /// reference already ran.
    static func accepts(_ edited: RoundConfig, reference: RoundConfig, available: AvailableModels) -> Bool {
        guard edited.drafters.map(\.persona) == reference.drafters.map(\.persona),
              (edited.synthesizer == nil) == (reference.synthesizer == nil),
              (edited.reviewer == nil) == (reference.reviewer == nil),
              (edited.polisher == nil) == (reference.polisher == nil),
              (0...maxRounds).contains(edited.refinementCap), (0...maxRounds).contains(edited.polishCap)
        else { return false }
        let known = Set(choices(of: reference).map(\.agent))
        return choices(of: edited).allSatisfy { available.choice(for: $0.agent) != nil || known.contains($0.agent) }
    }

    /// Far past anything the Mac's stepper reaches (it opens at 12 and grows only when a config
    /// already holds more): a typo in a command, not a plan.
    static let maxRounds = 50

    private static func choices(of c: RoundConfig) -> [ModelChoice] {
        let slots = c.drafters + [c.synthesizer, c.reviewer, c.crossReviewer].compactMap { $0 } + c.reviewerRotation
        return slots.flatMap { [$0.choice] + ($0.fallback.map { [$0] } ?? []) }
            + [c.integrator, c.encoder] + [c.polisher].compactMap { $0 } + c.integratorRotation + c.polisherRotation
    }
}
