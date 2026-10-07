import XCTest
@testable import FlightDeck

final class HuJSONPatcherTests: XCTestCase {
    let commented = """
    // Our policy
    {
      // owners
      "tagOwners": {
        "tag:ci": ["autogroup:admin"], // trailing comma below
      },
      "grants": [
        {"src": ["*"], "dst": ["*"], "ip": ["*"]},
      ],
    }
    """

    func testInsertsIntoExistingSectionsKeepingComments() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("// Our policy")); XCTAssertTrue(p.patched.contains("// trailing comma below"))
        XCTAssertTrue(p.patched.contains(#""tag:flightdeck-cloud": ["autogroup:admin"]"#))
        XCTAssertTrue(p.patched.contains(#""dst": ["tag:flightdeck-cloud"]"#))
        XCTAssertTrue(p.patched.contains("tcp:47410-47411"))
        XCTAssertTrue(p.diff.contains("+"))
    }

    func testCreatesMissingSections() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: "{\n  \"acls\": []\n}\n", tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("\"tagOwners\"")); XCTAssertTrue(p.patched.contains("\"grants\""))
    }

    func testIdempotent() throws {
        let once = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        let twice = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: once.patched, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertEqual(twice.patched, once.patched); XCTAssertTrue(twice.diff.isEmpty)
    }

    func testRefusesWhatItCannotParse() {
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{ \"tagOwners\": /* unterminated", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "[1,2]", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
    }

    func testStringsContainingBracesAreNotStructure() throws {
        let tricky = "{ \"note\": \"} { not structure\", \"grants\": [] }"
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: tricky, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains("\"} { not structure\""))
    }

    // Beyond the brief: the patched text must still be the policy it was, plus the two rules —
    // checked by stripping the HuJSON down to JSON and decoding it.

    func testPatchedPolicyDecodesWithBothRulesAndTheOriginalOnes() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        let policy = try decode(p.patched)
        let owners = try XCTUnwrap(policy["tagOwners"] as? [String: [String]])
        XCTAssertEqual(owners, ["tag:ci": ["autogroup:admin"], "tag:flightdeck-cloud": ["autogroup:admin"]])
        let grants = try XCTUnwrap(policy["grants"] as? [[String: [String]]])
        XCTAssertEqual(grants, [["src": ["*"], "dst": ["*"], "ip": ["*"]],
                                ["src": ["autogroup:member"], "dst": ["tag:flightdeck-cloud"], "ip": ["tcp:47410-47411"]]])
    }

    func testAddsTheMissingCommaAfterALastMemberWithoutOne() throws {
        let bare = "{\n  \"tagOwners\": {\n    \"tag:ci\": [\"autogroup:admin\"] // no comma\n  }\n}\n"
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: bare, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        XCTAssertTrue(p.patched.contains(#"["autogroup:admin"], // no comma"#), p.patched)
        XCTAssertTrue(p.patched.contains("    \"tag:flightdeck-cloud\": [\"autogroup:admin\"],\n"), p.patched)
        let policy = try decode(p.patched)
        XCTAssertNotNil(policy["grants"]); XCTAssertEqual((policy["tagOwners"] as? [String: Any])?.count, 2)
        let single = try decode(try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(
            to: "{ \"note\": \"} { not structure\", \"grants\": [] }", tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin")).patched)
        XCTAssertEqual(single["note"] as? String, "} { not structure")
        XCTAssertNotNil(single["tagOwners"]); XCTAssertEqual((single["grants"] as? [Any])?.count, 1)
    }

    func testRefusesDuplicateKeysAndWrongSectionShapes() {
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{\"grants\": [], \"grants\": []}", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{\"grants\": {}}", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{\"tagOwners\": []}", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{\"a\": \"unterminated}", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
        XCTAssertNil(HuJSONPatcher.addFlightDeckRules(to: "{} {}", tag: "tag:x", ownerAutogroup: "autogroup:admin"))
    }

    func testDiffMarksOnlyTheInsertedLines() throws {
        let p = try XCTUnwrap(HuJSONPatcher.addFlightDeckRules(to: commented, tag: "tag:flightdeck-cloud", ownerAutogroup: "autogroup:admin"))
        let changed = p.diff.split(separator: "\n").filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
        XCTAssertEqual(changed.count, 2, p.diff)
        XCTAssertTrue(changed.allSatisfy { $0.hasPrefix("+") }, p.diff)
    }

    /// HuJSON → JSON for the assertions. Deliberately not the patcher's own tokenizer, which
    /// would only check itself: a naive stripper of `//` comments and trailing commas, fed only
    /// policies whose strings hold neither.
    private func decode(_ hujson: String) throws -> [String: Any] {
        var text = hujson.replacingOccurrences(of: #"//[^\n"]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #",(\s*[\]}])"#, with: "$1", options: .regularExpression)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
