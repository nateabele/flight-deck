import XCTest
import IntakeKit

/// "An unmapped model is ignored, never guessed" (spec §5). The table is the only bridge from a
/// leaderboard's name to a model Flight Deck can run, so these tests pin that only a confirmed
/// entry maps, that a proposal is only ever an exact normalized match, and that a name the user
/// rejected is never proposed again.
final class AliasTableTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus

    func testOnlyConfirmedAliasesMap() {
        var t = AliasTable()
        t.set(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)", model: sol, status: .pending)
        XCTAssertNil(t.model(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)"))
        XCTAssertTrue(t.confirm(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)"))
        XCTAssertEqual(t.model(source: "terminal-bench", benchmarkModel: " GPT-6 Sol (high) "), sol)
        XCTAssertNil(t.model(source: "aider-polyglot", benchmarkModel: "GPT-6 Sol (high)"), "an alias belongs to one source")
    }

    func testProposalMatchesDisplayNameAndCarriesTheSetting() {
        let p = AliasProposer.propose([UnmappedName(source: "terminal-bench", benchmarkModel: "Opus 5 (high)"),
                                       UnmappedName(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (low)")],
                                      table: AliasTable(), catalogs: IndexFixtures.catalogs())
        XCTAssertEqual(p.map(\.model), [ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "low"]), opus])
        XCTAssertEqual(Set(p.map(\.status)), [.pending])
    }

    func testProposalNeverGuesses() {
        XCTAssertEqual(AliasProposer.propose([UnmappedName(source: "s", benchmarkModel: "Mystery-1"),
                                              UnmappedName(source: "s", benchmarkModel: "Opus 4")],
                                             table: AliasTable(), catalogs: IndexFixtures.catalogs()), [])
    }

    func testRejectedNameIsNeverReproposed() {
        var t = AliasTable()
        t.addProposals([AliasEntry(source: "s", benchmarkModel: "Opus 5 (high)", model: opus, status: .pending)])
        XCTAssertTrue(t.reject(source: "s", benchmarkModel: "Opus 5 (high)"))
        XCTAssertEqual(AliasProposer.propose([UnmappedName(source: "s", benchmarkModel: "Opus 5 (high)")],
                                             table: t, catalogs: IndexFixtures.catalogs()), [])
        t.addProposals([AliasEntry(source: "s", benchmarkModel: "Opus 5 (high)", model: opus, status: .pending)])
        XCTAssertEqual(t.entries.map(\.status), [.rejected])
    }

    func testOneModelAtTwoSettingsKeepsBothKnobs() {
        var t = AliasTable()
        t.set(source: "s", benchmarkModel: "GPT-6 Sol (high)", model: sol, status: .confirmed)
        t.set(source: "s", benchmarkModel: "GPT-6 Sol (low)",
              model: ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "low"]), status: .confirmed)
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "GPT-6 Sol (low)")?.knobs, ["effort": "low"])
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "GPT-6 Sol (high)")?.knobs, ["effort": "high"])
    }

    func testSetReplacesAnExistingMapping() {
        var t = AliasTable()
        t.set(source: "s", benchmarkModel: "X", model: sol, status: .confirmed)
        t.set(source: "s", benchmarkModel: "X", model: opus, status: .confirmed)
        XCTAssertEqual(t.entries.count, 1)
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "X"), opus)
        t.remove(source: "s", benchmarkModel: "X")
        XCTAssertEqual(t.entries, [])
    }

    func testKeyIsStableAcrossKnobOrder() {
        XCTAssertEqual(IndexKeys.key(ModelRef(agent: .codex, model: "m", knobs: ["b": "2", "a": "1"])), "codex/m[a=1,b=2]")
        XCTAssertEqual(IndexKeys.key(IndexFixtures.sonnet), "claude/sonnet")
        XCTAssertEqual(IndexKeys.label(sol), "codex · gpt-6-sol (effort high)")
        XCTAssertEqual(AliasProposer.split("GPT-6 Sol (High)").base, "gpt-6-sol")
        XCTAssertEqual(AliasProposer.split("GPT-6 Sol (High)").setting, "high")
        XCTAssertNil(AliasProposer.split("Sonnet 5").setting)
    }
}
