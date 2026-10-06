import XCTest
import IntakeKit
@testable import FlightDeck

/// Global rules live in preferences, project rules in the repo (spec L3-R §2). The repo file is
/// the user's: it may be hand-edited, merged badly, or written by a newer Flight Deck. Routing
/// then treats it as empty (spec §8), and nothing here may overwrite it.
@MainActor
final class RoutingStorageTests: XCTestCase {
    private var project: URL!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingStorageTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saves = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saves += 1 }
    }

    private let rule = RoutingRule(id: "r1", sentence: "Use Claude for docs")

    func testAMissingFileIsNoRules() {
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .missing)
        XCTAssertEqual(ProjectRoutingStore().load(project: project).rules, [])
    }

    func testSaveCreatesTheFileAndLoadReadsItBack() throws {
        try ProjectRoutingStore().save([rule], project: project)
        let url = ProjectRoutingStore.fileURL(project: project)
        XCTAssertEqual(url.path, project.appendingPathComponent(".flightdeck/routing.json").path)
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .loaded(RoutingRuleFile(rules: [rule])))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty-printed, so the repo file diffs line by line")
    }

    func testAnInvalidFileRoutesAsEmptyAndSaysWhy() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let load = ProjectRoutingStore().load(project: project)
        guard case .invalid(let why) = load else { return XCTFail("\(load)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(load.rules, [])
    }

    func testANewerFileIsInvalidNotPartlyRead() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":2,"rules":[]}"#.utf8).write(to: url)
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .invalid("written by a newer Flight Deck (v2)"))
    }

    func testSaveRefusesToOverwriteAnInvalidFile() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("<<<<<<< HEAD\n".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try ProjectRoutingStore().save([rule], project: project)) {
            XCTAssertTrue($0 is ProjectRulesUnwritable)
        }
        XCTAssertEqual(try Data(contentsOf: url), broken, "the user's file is untouched")
    }

    func testGlobalRulesAndCompilerSurviveARelaunch() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.globalRoutingRules = [rule]
        store.routingCompilerSettings = RuleCompilerSettings(harness: .codex, model: "gpt-6-luna", effort: "low")
        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reopened.globalRoutingRules, [rule])
        XCTAssertEqual(reopened.routingCompilerSettings.model, "gpt-6-luna")
    }

    func testAnUnconfiguredStoreHasNoRulesAndTheDefaultCompiler() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertEqual(store.globalRoutingRules, [])
        XCTAssertEqual(store.routingCompilerSettings, .default)
    }

    func testAPreferencesBlobFromBeforeRoutingStillDecodes() throws {
        var withRouting = Preferences()
        withRouting.flightControlRouting = RoutingPreferences(globalRules: [rule])
        let old = try JSONEncoder().encode(withRouting)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        XCTAssertNotNil(obj["flightControlRouting"], "the key must be encoded, or removing it proves nothing")
        obj.removeValue(forKey: "flightControlRouting")
        let back = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.flightControlRouting)
    }

    func testSeenKindsAreKeyedByStandardizedPathAndWriteOnlyWhenNew() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.markKindsSeen(["snapshot-tests"], project: "/w/p/")
        XCTAssertEqual(store.seenKinds(project: "/w/p"), ["snapshot-tests"])
        let saves = persistence.saves
        store.markKindsSeen(["snapshot-tests"], project: "/w/p")
        XCTAssertEqual(persistence.saves, saves, "re-marking a seen kind must not rewrite preferences")
    }

    func testADismissedHintStaysDismissedOnlyForItsSnapshot() {
        let store = PreferencesStore(persistence: nil)
        let d1 = Date(timeIntervalSince1970: 1_000), d2 = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(store.isHintDismissed(ruleID: "r3", snapshot: d1))
        store.dismissHint(ruleID: "r3", snapshot: d1)
        XCTAssertTrue(store.isHintDismissed(ruleID: "r3", snapshot: d1))
        XCTAssertFalse(store.isHintDismissed(ruleID: "r3", snapshot: d2), "a new index snapshot brings the hint back")
    }
}
