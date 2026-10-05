import Foundation
import IntakeKit
@testable import FlightDeck

/// A third harness, `"fake"`, so "any registered adapter" is exercised from day one without
/// adding an `AgentID` case (which would touch every exhaustive switch in the app).
@MainActor
final class FakeRoutingCapabilities: AgentRoutingCapabilities {
    var harness: HarnessID = "fake"
    var accountModel: AccountModel = .login
    var knobSchema: [String: [String]] = [:]
    var catalog: RoutingCapability<[ModelEntry]> = .supported([])
    var meter: RoutingCapability<any UsageMeterSource> = .unsupported(reason: "fake")
    var pointer: RoutingCapability<TranscriptPointer> = .unsupported(reason: "fake")
    var resetResult: Result<RoutingCapability<Void>, Error> = .success(.supported(()))
    var overridesResult: RoutingCapability<AgentOptions>?
    private(set) var resetCalls: [UUID] = []
    private(set) var overrideCalls: [LaunchOverrides] = []

    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { catalog }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { meter }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { pointer }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        resetCalls.append(session.id); return try resetResult.get()
    }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        overrideCalls.append(overrides); return overridesResult ?? .supported(options)
    }
}

@MainActor
final class FakeSwarmSpawner: SwarmSpawner {
    struct Call: Equatable { let task: TaskRef; let block: ExecutionBlock; let lease: AccountLease?; let firstPrompt: String }
    /// Consumed in order; when empty, spawns fail with `.launchFailed("unscripted")`.
    var results: [Result<SessionRef, SpawnError>] = []
    private(set) var calls: [Call] = []
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        calls.append(Call(task: task, block: block, lease: lease, firstPrompt: firstPrompt))
        return results.isEmpty ? .failure(.launchFailed("unscripted")) : results.removeFirst()
    }
}
