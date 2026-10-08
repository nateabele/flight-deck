import Foundation
import IntakeKit

extension RoutingService {
    /// The routing a real launch runs: the standard adapter registry's catalogs for the agents in
    /// preferences, `<agent>-default` pools until L3-U's land, no capability index until L3-I's,
    /// the headless compiler preferences name, and `br` for re-routes. Building it spawns
    /// nothing; codex's catalog is fetched on first use.
    static func live(preferences: PreferencesStore) -> RoutingService {
        let registry = RoutingCapabilityRegistry.standard()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("FlightDeck-rule-compiler", isDirectory: true)
        return RoutingService(
            preferences: preferences,
            kindStore: KindRegistryStore(),
            makeCompiler: { [weak preferences] in
                RuleCompiler(runner: SystemCommandRunner(),
                             settings: preferences?.routingCompilerSettings ?? .default,
                             workDirectory: work,
                             baseEnvironment: { LoginShellPath.repairing(ProcessInfo.processInfo.environment) })
            },
            loadCatalogs: { [weak preferences] in
                await registry.catalogs(enabled: Set((preferences?.preferences.agents ?? []).map(\.id)))
            },
            pools: DefaultPoolDirectory(agents: registry.agents),
            tasks: BrOpenTaskReader(),
            writer: BeadWriter(actor: "flightdeck-routing"))
    }

    /// `live`, or the UI-test fixture under `-FlightDeckResetState YES -FlightDeckRoutingFixture YES`.
    static func make(preferences: PreferencesStore) -> RoutingService {
        RoutingUIFixture.isActive ? RoutingUIFixture.service(preferences: preferences) : live(preferences: preferences)
    }
}
