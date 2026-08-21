import XCTest
@testable import FlightDeck

/// The Accounts pane's Sign In path. Everything here is store-level: what gets typed at the
/// shell, and what gets queued to be typed at the agent once it is up.
@MainActor
final class AccountSignInTests: XCTestCase {
    /// Keeps every configuration it was handed — `initialInput` is the assertion.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface.
    private var retained: [RecordingProvider] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        retained = []
    }

    /// A command with no trailing newline is typed and never run: `initial_input` reaches the
    /// pty verbatim, and nothing downstream presses Return.
    func testAnUnterminatedCommandGainsItsNewline() {
        XCTAssertEqual(SessionStore.terminated("claude"), "claude\n")
        XCTAssertEqual(SessionStore.terminated("codex login"), "codex login\n")
    }

    /// Not doubled: `ClaudeSession.launchCommand` already ends in one, and a blank line typed
    /// at a shell is a stray empty prompt.
    func testAnAlreadyTerminatedCommandIsLeftAlone() {
        XCTAssertEqual(SessionStore.terminated("claude\n"), "claude\n")
    }
}
