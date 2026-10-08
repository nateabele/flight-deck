import XCTest
import IntakeKit
@testable import FlightDeck

/// What a swarm spawn types at the shell. The launch command is the only observable evidence that
/// an override reached the agent, so it is asserted directly, through the real `createSession`.
@MainActor
final class CreateSessionOverridesTests: XCTestCase {
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { configs.append(config); return nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private var retained: [RecordingProvider] = []
    override func tearDown() { retained = [] }

    private func makeStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider(); retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store.transcriptsRootOverride = root.appendingPathComponent("projects")
        store.statusRootOverride = root.appendingPathComponent("status")
        return (store, provider)
    }

    func testClaudeSpawnLaunchesWithTheBlocksModelAndEffort() async throws {
        let (store, provider) = makeStore()
        let id = try await store.createSession(agent: .claude, in: "/tmp/p", selecting: false,
                                               overrides: LaunchOverrides(model: "opus", knobs: ["effort": "high"])).get()
        XCTAssertTrue(store.sessionExists(id))
        let input = try XCTUnwrap(provider.configs.last?.initialInput)
        XCTAssertTrue(input.contains("--model opus"), input)
        XCTAssertTrue(input.contains("--effort high"), input)
    }

    func testNoOverridesLaunchesExactlyAsBefore() async throws {
        let (store, provider) = makeStore()
        _ = try await store.createSession(agent: .claude, in: "/tmp/p", selecting: false).get()
        XCTAssertFalse(try XCTUnwrap(provider.configs.last?.initialInput).contains("--model"))
    }

    func testAnUnmappableOverrideRefusesTheTabBeforeCreatingIt() async {
        let (store, provider) = makeStore()
        let result = await store.createSession(agent: .claude, in: "/tmp/p", selecting: false,
                                               overrides: LaunchOverrides(model: nil, knobs: ["persona": "x"]))
        guard case .failure(.prepareFailed(let why)) = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("persona"))
        XCTAssertTrue(provider.configs.isEmpty, "a refused override must not open a tab")
    }

    func testLaunchOptionsAppliesThroughTheRegistry() throws {
        let (store, _) = makeStore()
        let fake = FakeRoutingCapabilities(); fake.agent = .claude
        fake.overridesResult = .unsupported(reason: "nope")
        store.routingCapabilities = RoutingCapabilityRegistry([fake])
        guard case .failure(.prepareFailed("nope")) = store.launchOptions(
            for: .claude, project: "/tmp/p", overrides: LaunchOverrides(model: "m", knobs: [:])) else {
            return XCTFail("the registry's answer must decide")
        }
        XCTAssertEqual(fake.overrideCalls, [LaunchOverrides(model: "m", knobs: [:])])
    }
}
