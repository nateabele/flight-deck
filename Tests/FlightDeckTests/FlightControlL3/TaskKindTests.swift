import XCTest
import IntakeKit

/// Kinds are dynamic per project, so the only fixed ground is the dimension list. These tests
/// pin what routing relies on: weights only ever name real dimensions, merges always resolve
/// (even when someone builds a cycle), and the seed set is valid on its own.
final class TaskKindTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func kind(_ id: KindID, _ dims: [String: Double] = ["agentic-coding": 0.5],
                      status: KindStatus = .active) -> TaskKind {
        TaskKind(id: id, name: id.rawValue, description: "d", dimensions: dims, origin: .user, status: status, createdAt: at)
    }

    func testDimensionListIsTheSpecsTen() {
        XCTAssertEqual(Dimensions.all.map(\.id), [
            "agentic-coding", "algorithmic-reasoning", "test-authoring", "frontend-ui",
            "large-context-refactor", "debugging", "docs-prose", "tool-use-reliability",
            "speed", "cost-efficiency"])
    }

    func testValidateRejectsUnknownDimensionAndOutOfRangeWeight() {
        XCTAssertThrowsError(try kind("a", ["vibes": 0.5]).validate()) {
            XCTAssertEqual($0 as? KindValidationError, .unknownDimension("vibes"))
        }
        XCTAssertThrowsError(try kind("a", ["debugging": 1.5]).validate()) {
            XCTAssertEqual($0 as? KindValidationError, .weightOutOfRange("debugging", 1.5))
        }
        var unnamed = kind("a"); unnamed.name = "  "
        XCTAssertThrowsError(try unnamed.validate()) { XCTAssertEqual($0 as? KindValidationError, .emptyName) }
    }

    func testStatusCodesAsSpecStrings() throws {
        let k = kind("snap", status: .merged(into: "tests"))
        let data = try JSONEncoder().encode(k)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "merged:tests")
        XCTAssertEqual(try JSONDecoder().decode(TaskKind.self, from: data), k)
    }

    func testResolveFollowsMergeChain() {
        let kinds = [kind("a", status: .merged(into: "b")), kind("b", status: .merged(into: "c")), kind("c")]
        XCTAssertEqual(KindResolution.resolve("a", in: kinds)?.id, "c")
        XCTAssertEqual(KindResolution.resolve("c", in: kinds)?.id, "c")
        XCTAssertNil(KindResolution.resolve("missing", in: kinds))
    }

    func testResolveTerminatesOnMergeCycle() {
        let kinds = [kind("a", status: .merged(into: "b")), kind("b", status: .merged(into: "a"))]
        XCTAssertNil(KindResolution.resolve("a", in: kinds))
    }

    func testSeedSetIsValidAndNamed() throws {
        let seeds = SeedKinds.all(createdAt: at)
        XCTAssertEqual(seeds.map(\.id.rawValue), ["implement-simple", "implement-complex", "algorithm", "tests",
                                                  "refactor", "docs", "investigate", "review", "ui"])
        for s in seeds { XCTAssertNoThrow(try s.validate()); XCTAssertEqual(s.origin, .seed) }
    }

    func testNormalizedKindID() {
        XCTAssertEqual(KindID.normalized("  Snapshot Tests!! "), "snapshot-tests")
        XCTAssertEqual(KindID.normalized("UI/UX work"), "ui-ux-work")
    }

    func testRegistryFileRoundTrips() throws {
        let file = KindRegistryFile(v: 1, kinds: SeedKinds.all(createdAt: at))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(KindRegistryFile.self, from: enc.encode(file)), file)
    }
}
