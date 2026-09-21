import XCTest
@testable import FlightDeck

/// `SessionStore.composerReadiness(for:)` and the `.lifecycle` arm of `apply(_:to:)`.
///
/// Only the store's half of the wire is under test here — `ClaudeRuntime.ingest(readiness:)`
/// (the hook watcher's fan-out point) has its own coverage in `ClaudeRuntimeTests`, the same
/// split `testStatusEntriesBecomeActivityEvents` draws for `.activity`.
@MainActor
final class SessionStoreComposerReadinessTests: XCTestCase {
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// Same shape as `SessionStoreAbortTests.makeStore`: the base init, never
    /// `startStatusWatching()`, so this suite never risks tailing a real registry or hook log.
    private func makeStore() -> (SessionStore, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let session = store.newSession(in: tmp)
        return (store, session.id)
    }

    func testReadinessStartsUnknown() {
        let (store, tab) = makeStore()
        XCTAssertEqual(store.composerReadiness(for: tab), .unknown)
    }

    func testLifecycleEventUpdatesReadiness() {
        let (store, tab) = makeStore()
        store.apply(.lifecycle(.live), to: tab)
        XCTAssertEqual(store.composerReadiness(for: tab), .live)
        store.apply(.lifecycle(.absent), to: tab)
        XCTAssertEqual(store.composerReadiness(for: tab), .absent)
    }

    /// `startHookEventWatching()`'s own gate: a store that never calls `startStatusWatching()`
    /// must not build the app-wide watcher, mirroring `isStatusWatchingEnabled`'s existing
    /// guard on the per-account watchers. This is what makes `makeStore()` above safe to use
    /// without a `hookEventDirectoryOverride` — the fallback to the real
    /// `ClaudePluginLocation.eventDirectory` is never reached because nothing here starts it.
    func testHookEventWatcherStaysNilUntilStatusWatchingStarts() {
        let (store, _) = makeStore()
        XCTAssertNil(store.hookEventWatcherForTesting,
                     "a store that never calls startStatusWatching() must not build the watcher")
    }

    /// Identity, not just non-nilness — the same distinction
    /// `testEachAccountWithAClaudeTabGetsItsOwnStatusWatcher` draws for the per-account
    /// watchers: rebuilding this one on a second sweep would leave the replaced object's
    /// registration on the shared `WatchClock` behind, still polling beside the new one.
    func testStartStatusWatchingBuildsTheHookEventWatcherOnceAndReusesIt() throws {
        let (store, _) = makeStore()
        store.statusRootOverride = projectsRoot.appendingPathComponent("status")
        store.hookEventDirectoryOverride = projectsRoot.appendingPathComponent("hook-events")

        store.startStatusWatching()
        let first = try XCTUnwrap(store.hookEventWatcherForTesting)

        store.startStatusWatching()
        XCTAssertTrue(store.hookEventWatcherForTesting === first,
                      "a second sweep must reuse the existing watcher, not register another")
    }

    // The brief's third test asserts on `store.pendingPersistContainsReadiness`, a property
    // that does not exist and that the task instructions say not to invent. `persist()` is
    // private and `SessionPersistence.Entry` has no constructor from a live `Session` a test
    // could drive without inventing new production surface either, so there is no seam to
    // assert through. Persistence is instead verified structurally: `composerReadinessByTab`
    // is a plain `[UUID: ComposerReadiness]` with no `Codable` conformance, declared nowhere
    // near `Session` or `SessionPersistence.Entry` — see `SessionStore.swift`. It cannot reach
    // `sessions.json` because nothing encodes it.
}
