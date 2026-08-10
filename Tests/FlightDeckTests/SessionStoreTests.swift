// Tests/FlightDeckTests/SessionStoreTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStoreTests: XCTestCase {
    /// Stub provider: records calls, returns no real surface (nil retained).
    final class StubProvider: SurfaceProvider {
        var madeCount = 0
        var tickCount = 0
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            madeCount += 1
            return nil
        }
        func tick() { tickCount += 1 }
    }

    func testNewSessionCreatesRepoAndSelects() {
        let store = SessionStore(provider: StubProvider())
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "foo")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testDedupesReposByStandardizedPath() {
        let store = SessionStore(provider: StubProvider())
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/foo/", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
    }

    func testTitlesIncrement() {
        let store = SessionStore(provider: StubProvider())
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(a.title, "session 1")
        XCTAssertEqual(b.title, "session 2")
    }

    func testCloseRemovesSessionAndEmptyRepo() {
        let store = SessionStore(provider: StubProvider())
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.closeSession(s.id)
        XCTAssertTrue(store.repos.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testCloseReselectsRemainingSession() {
        let store = SessionStore(provider: StubProvider())
        let s1 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let s2 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.selectSession(s1.id)
        store.closeSession(s1.id)
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, s2.id)
    }

    func testSeedInitialSessionCreatesOneHomeRepoOnce() {
        let store = SessionStore(provider: StubProvider())
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        store.seedInitialSession(homeURL: home)
        store.seedInitialSession(homeURL: home) // second call must be a no-op
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "tester")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertNotNil(store.selectedSessionID)
    }

    func testProviderInvokedPerSession() {
        let stub = StubProvider()
        let store = SessionStore(provider: stub)
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(stub.madeCount, 2)
        XCTAssertEqual(stub.tickCount, 2)
    }
}
