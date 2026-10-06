import XCTest
import IntakeKit
@testable import FlightDeck

/// The pane's words and identifiers are what the UI test and VoiceOver read, so their pure
/// parts are pinned here, headless: a cell says its score, confidence and where the score came
/// from; a diff row says what moved and by how much; times are UTC so a screenshot means the
/// same thing in every zone. And the new copy obeys the house words.
@MainActor
final class CapabilityIndexPaneTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    /// Replaces a tautological `allCases.contains` check: what matters is that the opener can
    /// actually land Settings on this pane, which is the path anything that links here uses.
    func testOpeningSettingsAtFlightControlSelectsIt() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        PreferencesOpener.select(store, tab: .flightControl)
        XCTAssertEqual(store.selectedTab, .flightControl)
    }

    func testCellIdentifierIsStable() {
        XCTAssertEqual(CapabilityIndexPane.cellIdentifier(model: IndexFixtures.sol, dimension: "test-authoring"),
                       "index-cell-codex/gpt-6-sol[effort=high]-test-authoring")
    }

    func testCellValueSaysScoreConfidenceAndOrigin() {
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.82, confidence: 0.75)), "0.82, confidence 0.75, computed")
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.5, confidence: 1, origin: .manual)), "0.50, confidence 1.00, manual")
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.68, confidence: 0.75, origin: .inherited, inheritedFrom: IndexFixtures.sol)),
                       "0.68, confidence 0.75, inherited from codex · gpt-6-sol (effort high)")
        XCTAssertEqual(CapabilityIndexPane.cellValue(nil), "unknown")
    }

    func testOpacityTracksConfidenceButNeverVanishes() {
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 7), 1, accuracy: 1e-12)
    }

    func testDiffRowWording() {
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sol, dimension: "test-authoring", before: 0.6, after: 0.8)),
                       "codex · gpt-6-sol (effort high) — test-authoring 0.60 → 0.80 (+0.20)")
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sonnet, dimension: "speed", before: nil, after: 0.3)),
                       "claude · sonnet — speed new 0.30")
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sonnet, dimension: "docs-prose", before: 0.5, after: nil)),
                       "claude · sonnet — docs-prose 0.50 → unknown")
    }

    func testTimesAreUTC() {
        XCTAssertEqual(CapabilityIndexPane.utc(Date(timeIntervalSince1970: 1_791_093_600)), "2026-10-04 06:00 UTC")
    }

    func testManualEditorKeepsOnlyScoresInRange() {
        XCTAssertEqual(ManualScoresEditor.parse(["debugging": "0.7", "speed": " 1 ", "docs-prose": "", "frontend-ui": "1.5", "x": "abc"]),
                       ["debugging": 0.7, "speed": 1])
    }

    func testNewCopyUsesTheHouseWords() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // …/Tests/FlightDeckTests/FlightControlL3/Index
            .appendingPathComponent("../../../../").standardized
        for dir in ["Sources/FlightDeck/FlightControl", "Sources/IntakeKit/FlightControl", "Sources/FlightDeck/Preferences/UI"] {
            let offenders = try TerminologyScan.offenders(under: root.appendingPathComponent(dir), allow: TerminologyScan.internalAllowList)
            XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift").path),
                      "the sweep must actually reach the pane")
    }
}
