import XCTest
import IntakeKit

/// The registry is user-editable data, so the only things worth pinning are the ones that make
/// a source silently contribute nothing: a unit nobody knows (its rows all reject), a weight on
/// a dimension that does not exist (scores nothing), a URL that is not a web address. Plus the
/// probe's result, so a source that stops being a data file is a test change, not a surprise.
final class IndexSourceRegistryTests: XCTestCase {
    func testInitialSetCoversTheSpecsSources() {
        XCTAssertEqual(IndexSourceRegistry.initial.map(\.id), [
            "swe-bench-verified", "swe-bench-pro", "terminal-bench", "aider-polyglot", "livecodebench",
            "swt-bench", "webdev-arena", "aa-speed", "aa-price", "anthropic-models", "openai-models"])
    }

    func testInitialSetHasNoProblems() {
        XCTAssertEqual(IndexSourceRegistry.problems(IndexSourceRegistry.initial), [])
    }

    func testMachineReadableMatchesTheProbe() {
        XCTAssertEqual(Set(IndexSourceRegistry.initial.filter(\.machineReadable).map(\.id)),
                       ["swe-bench-verified", "aider-polyglot"])
    }

    func testEveryDimensionButDocsProseHasASource() {
        let fed = Set(IndexSourceRegistry.initial.flatMap { s in s.dimensions.filter { $0.value > 0 }.keys })
        XCTAssertEqual(Dimensions.ids.subtracting(fed), ["docs-prose"])
    }

    func testLowerIsBetterUnits() {
        XCTAssertFalse(IndexUnit.usdPerMillionTokens.higherIsBetter)
        XCTAssertFalse(IndexUnit.seconds.higherIsBetter)
        for unit in [IndexUnit.percent, .score, .elo, .tokensPerSecond, .contextTokens] {
            XCTAssertTrue(unit.higherIsBetter, unit.rawValue)
        }
    }

    func testProblemsNameEachBadField() {
        func src(_ id: String, url: String = "https://x.test", dims: [String: Double] = ["speed": 1],
                 how: String = "read it", unit: String = "percent") -> IndexSource {
            var s = IndexSource(id: id, name: id, url: url, dimensions: dims, howToRead: how,
                                unit: .percent, machineReadable: false)
            s.unit = unit
            return s
        }
        XCTAssertEqual(IndexSourceRegistry.problems([
            src("a", url: "ftp://x"), src("b", dims: ["vibes": 1]), src("c", dims: ["speed": 2]),
            src("d", how: " "), src("e", unit: "stars"), src("e")]), [
            "a: url is not a web address",
            "b: unknown dimension vibes", "b: feeds no dimension",
            "c: weight 2.0 for speed is outside 0...1", "c: feeds no dimension",
            "d: no reading instructions",
            "e: unknown unit stars",
            "e: duplicate id"])
    }
}
