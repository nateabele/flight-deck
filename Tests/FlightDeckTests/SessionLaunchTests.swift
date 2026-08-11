// Tests/FlightDeckTests/SessionLaunchTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionLaunchTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    func testLaunchesClaudeBoundToSessionUUID() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        let input = try? XCTUnwrap(provider.configs.first?.initialInput)
        XCTAssertEqual(
            input,
            "claude --session-id \(session.id.uuidString.lowercased()) --name '\(session.title)'\n"
        )
    }

    func testStillLaunchesTheShellAsTheCommand() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(provider.configs.first?.command, ShellResolver.resolve())
    }
}
