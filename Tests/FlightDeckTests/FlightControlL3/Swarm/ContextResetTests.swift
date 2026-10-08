import XCTest
import IntakeKit
@testable import FlightDeck

/// Reuse depends on one property: the reset is typed through the same gated channel a phone
/// prompt is, so it lands only into a real composer and queues behind a running turn instead of
/// being pasted into a dialog. A refusal must throw — a reset that "succeeded" without typing
/// would hand the next task an agent still holding the last task's context.
@MainActor
final class ContextResetTests: XCTestCase {
    private final class Sink: SessionCommandSink {
        var answer: SessionStore.PromptDispatch = .queued
        private(set) var typed: [(String, UUID)] = []
        func submitCommand(_ text: String, to session: UUID) -> SessionStore.PromptDispatch {
            typed.append((text, session)); return answer
        }
    }

    func testClaudeResetTypesClear() async throws {
        let sink = Sink(); let caps = ClaudeRoutingCapabilities(); caps.commands = sink
        let session = Session(title: "t", workingDirectory: "/p")
        guard case .supported = try await caps.resetContext(session) else { return XCTFail("expected supported") }
        XCTAssertEqual(sink.typed.map { $0.0 }, ["/clear"])
        XCTAssertEqual(sink.typed.map { $0.1 }, [session.id])
    }

    func testCodexResetTypesNew() async throws {
        let sink = Sink(); let caps = CodexRoutingCapabilities(); caps.commands = sink
        guard case .supported = try await caps.resetContext(Session(title: "t", workingDirectory: "/p", agent: .codex)) else {
            return XCTFail("expected supported")
        }
        XCTAssertEqual(sink.typed.map { $0.0 }, ["/new"])
    }

    func testARefusedTypeThrows() async {
        let sink = Sink(); sink.answer = .notRunning
        let caps = ClaudeRoutingCapabilities(); caps.commands = sink
        do {
            _ = try await caps.resetContext(Session(title: "t", workingDirectory: "/p"))
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual(error as? ContextResetError, .refused("not_running"))
        }
    }

    func testNoSinkIsUnsupportedNotSuccess() async throws {
        guard case .unsupported = try await ClaudeRoutingCapabilities().resetContext(Session(title: "t", workingDirectory: "/p")) else {
            return XCTFail("an unattached capability must say it cannot reset")
        }
    }

    func testTheStoreAttachesItselfToTheStandardRegistry() async throws {
        let store = SessionStore(provider: nil, persistence: nil)
        let claude = try XCTUnwrap(store.routingCapabilities.capabilities(for: .claude) as? ClaudeRoutingCapabilities)
        XCTAssertTrue(claude.commands === store)
    }
}
