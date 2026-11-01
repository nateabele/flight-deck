import WebKit
import XCTest
@testable import FlightDeckMobile

/// How the live viewer is locked down (V3 review 1): pinned as text, because a web view's
/// configuration is otherwise untestable and a loosened rule would pass every other test.
@MainActor
final class VisualViewerConfigTests: XCTestCase {
    func testTheRuleListBlocksEverythingButOurScheme() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(VisualWebConfig.contentRuleListJSON.utf8)) as? [[String: [String: String]]]
        XCTAssertEqual(rules?.count, 2)
        XCTAssertEqual(rules?[0]["trigger"]?["url-filter"], ".*")
        XCTAssertEqual(rules?[0]["action"]?["type"], "block")
        XCTAssertEqual(rules?[1]["trigger"]?["url-filter"], "^fdvisual:")
        XCTAssertEqual(rules?[1]["action"]?["type"], "ignore-previous-rules")
    }

    func testTheRuleListCompilesAndIsAttached() async throws {
        let rules = await VisualWebConfig.compileRules()
        XCTAssertNotNil(rules, "a viewer that cannot compile its rules must not open")
    }

    func testTheCSPIsDenyByDefaultAndScriptComesOnlyFromTheRevision() {
        XCTAssertEqual(VisualWebConfig.contentSecurityPolicy,
                       "default-src 'none'; img-src fdvisual: data:; style-src fdvisual: 'unsafe-inline'; font-src fdvisual: data:; "
                       + "script-src fdvisual: 'unsafe-inline'; connect-src fdvisual:; media-src fdvisual:; "
                       + "worker-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'")
    }

    func testScriptIsOnBehindTheLockdownTheStoreIsNotPersistentAndTheHandlerIsRegistered() {
        let handler = VisualSchemeHandler(cache: VisualCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("VCfg-\(UUID())")),
                                          visualID: "flow", revision: 1, files: [])
        let config = VisualWebConfig.makeConfiguration(handler: handler, rules: nil)
        XCTAssertTrue(config.defaultWebpagePreferences.allowsContentJavaScript, "interactive comps run their script")
        XCTAssertFalse(config.preferences.javaScriptCanOpenWindowsAutomatically)
        let scripts = config.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.source, VisualWebConfig.lockdownScript)
        XCTAssertEqual(scripts.first?.injectionTime, .atDocumentStart, "before any page script")
        XCTAssertEqual(scripts.first?.isForMainFrameOnly, false, "child frames too")
        XCTAssertFalse(config.websiteDataStore.isPersistent)
        XCTAssertTrue(config.urlSchemeHandler(forURLScheme: "fdvisual") === handler)
    }
}
