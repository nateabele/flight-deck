import XCTest
@testable import FlightDeck

@MainActor
final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()

    private func session(_ title: String = "work") -> Session {
        Session(title: title, workingDirectory: "/w/a")
    }

    func testPrepareMintsAConversationIDEqualToTheTabID() async throws {
        // Claude lets the caller choose the id (`--session-id`), and Flight Deck has always
        // used the tab's own id. Anything else would break every persisted session.
        let s = session()
        let binding = try await adapter.prepare(for: s, options: .claude(FlagSet()))
        XCTAssertEqual(binding.conversationID, s.id)
    }

    func testPrepareDerivesTheTranscriptPathFromTheWorkingDirectory() async throws {
        let s = session()
        let binding = try await adapter.prepare(for: s, options: .claude(FlagSet()))
        XCTAssertEqual(
            binding.transcriptURL,
            ClaudeSession.transcriptURL(sessionID: s.id, workingDirectory: "/w/a"),
            "the adapter must not invent a second path rule"
        )
    }

    func testLaunchCommandIsByteIdenticalToTodaysCommand() async throws {
        let s = session("my tab")
        let flags = FlagSet()
        let binding = try await adapter.prepare(for: s, options: .claude(flags))
        XCTAssertEqual(
            adapter.launchCommand(binding, s, .claude(flags)),
            ClaudeSession.launchCommand(sessionID: s.id, title: "my tab", flags: flags),
            "wrapping must not change what gets typed into the pty"
        )
    }

    func testResumeCommandIsByteIdenticalToTodaysCommand() async throws {
        let s = session("my tab")
        let flags = FlagSet()
        let binding = try await adapter.prepare(for: s, options: .claude(flags))
        XCTAssertEqual(
            adapter.resumeCommand(binding, s, .claude(flags)),
            ClaudeSession.resumeCommand(sessionID: s.id, flags: flags)
        )
    }
}
