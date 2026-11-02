import FleetKit
import XCTest
@testable import FlightDeck

/// Every fixture is the shape a live agent wrote on 2026-11-01, trimmed to the fields read.
final class AgentContextReaderTests: XCTestCase {
    // MARK: codex

    private func tokenCount(total: Int, window: Int, at stamp: String = "2026-11-02T01:48:40.000Z") -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"input_tokens":20000,"output_tokens":642,"total_tokens":\(total)},"model_context_window":\(window)},"rate_limits":null}}
        """
    }

    func testCodexMatchesTheTUIsPercentLeftNotThePlainRatio() throws {
        // The live tab: 20 642 of 475 000, shown as "Context 98% left".
        let context = try XCTUnwrap(AgentContextReader.codex(rolloutTail: tokenCount(total: 20_642, window: 475_000)))
        XCTAssertEqual(context.usedPercent.rounded(), 2)
        XCTAssertEqual(context.windowSize, 475_000)
        XCTAssertEqual(context.readAt, AgentContextReader.timestamp("2026-11-02T01:48:40.000Z"))
    }

    func testCodexTakesTheNewestTokenCountThatHasInfo() throws {
        let text = [
            tokenCount(total: 100_000, window: 475_000),
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#,
            tokenCount(total: 243_500, window: 475_000),
            #"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#,
        ].joined(separator: "\n")
        let context = try XCTUnwrap(AgentContextReader.codex(rolloutTail: text))
        XCTAssertEqual(context.usedPercent, 50, accuracy: 0.01)
    }

    func testCodexBelowTheBaselineIsEmpty() {
        XCTAssertEqual(AgentContextReader.codexUsedPercent(tokens: 9_000, window: 272_000), 0)
        XCTAssertNil(AgentContextReader.codex(rolloutTail: #"{"payload":{"type":"token_count","info":null}}"#))
    }

    // MARK: grok

    func testGrokReadsSignalsTokensOverItsWindow() throws {
        let data = Data(#"{"turnCount":1,"contextWindowUsage":9,"contextTokensUsed":24548,"contextWindowTokens":256000}"#.utf8)
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let context = try XCTUnwrap(AgentContextReader.grok(signals: data, readAt: at))
        XCTAssertEqual(context.usedPercent, 9.589, accuracy: 0.001)
        XCTAssertEqual(context.windowSize, 256_000)
        XCTAssertEqual(context.readAt, at)
    }

    func testGrokFallsBackToItsRoundedPercentAndRefusesNoWindow() {
        let percentOnly = Data(#"{"contextWindowUsage":14,"contextWindowTokens":256000}"#.utf8)
        XCTAssertEqual(AgentContextReader.grok(signals: percentOnly, readAt: Date())?.usedPercent, 14)
        XCTAssertNil(AgentContextReader.grok(signals: Data(#"{"contextWindowUsage":14}"#.utf8), readAt: Date()))
    }

    // MARK: gemini

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }

    private func uint(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }
    private func message(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(body.count)) + body
    }

    func testGeminiReadsWhatAgysContextCommandShows() throws {
        // `/context`: "11.1k/1.0M tokens (1.1%)". Field 1.9.10.4 is 256 000 and is not the window.
        let generation = Data(message(1, uint(3, 1318) + message(9, message(10, uint(1, 11_065) + uint(4, 256_000)))))
        let executor = Data(message(10, message(1, message(13, message(2, uint(22, 1_048_576))))))
        let context = try XCTUnwrap(AgentContextReader.gemini(generation: generation, executor: executor, readAt: Date()))
        XCTAssertEqual((context.usedPercent * 10).rounded() / 10, 1.1)
        XCTAssertEqual(context.windowSize, 1_048_576)
    }

    func testGeminiWithoutEitherFieldIsNoReading() {
        let executor = Data(message(10, message(1, message(13, message(2, uint(22, 1_048_576))))))
        XCTAssertNil(AgentContextReader.gemini(generation: Data(message(1, uint(3, 1))), executor: executor, readAt: Date()))
        XCTAssertNil(AgentContextReader.gemini(generation: Data([0xFF, 0xFF]), executor: Data(), readAt: Date()))
    }

    // MARK: opencode

    func testOpenCodeCountsTheNewestAssistantMessageWithOutput() throws {
        let messages = [
            #"{"role":"assistant","tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"big-pickle","providerID":"opencode"}"#,
            #"{"role":"user","modelID":"big-pickle","providerID":"opencode"}"#,
            #"{"role":"assistant","tokens":{"input":1200,"output":300,"reasoning":100,"cache":{"read":8000,"write":400}},"modelID":"big-pickle","providerID":"opencode","time":{"created":1793000000000,"completed":1793000005000}}"#,
        ].map { Data($0.utf8) }
        let tokens = try XCTUnwrap(AgentContextReader.openCodeTokens(messages: messages))
        XCTAssertEqual(tokens.tokens, 10_000)
        XCTAssertEqual(tokens.modelID, "big-pickle")
        XCTAssertEqual(tokens.readAt, Date(timeIntervalSince1970: 1_793_000_005))
        XCTAssertEqual(AgentContextReader.openCode(tokens, window: 200_000).usedPercent, 5)
    }

    func testOpenCodeWindowComesFromTheProviderCatalogAndZeroIsUnknown() {
        let body = Data(#"""
        {"providers":[{"id":"opencode","models":{"big-pickle":{"limit":{"context":200000,"output":32000}}}},
                      {"id":"ollama","models":{"glm-4.7-flash:latest":{"limit":{"context":0,"output":0}}}}],
         "default":{}}
        """#.utf8)
        XCTAssertEqual(AgentContextReader.openCodeWindow(providers: body, providerID: "opencode", modelID: "big-pickle"), 200_000)
        XCTAssertNil(AgentContextReader.openCodeWindow(providers: body, providerID: "ollama", modelID: "glm-4.7-flash:latest"))
        XCTAssertNil(AgentContextReader.openCodeWindow(providers: body, providerID: "opencode", modelID: "missing"))
    }
}
