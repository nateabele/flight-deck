import XCTest
@testable import HostKit

final class InfraConfigTests: XCTestCase {
    let full = """
    [infra.gpu]
    preset = "aws-linux"
    region = "us-east-1"
    instance_type = "g6.xlarge"
    arch = "x86_64"
    disk_gb = 100
    spot = true
    ttl = "4h"
    idle = "20m"
    auto_up = true
    vars = { team = "ml" }
    max_hourly = 1.5
    """

    func testParsesEveryField() throws {
        let c = try XCTUnwrap(DelegateConfigParser.parse(full).config.infra["gpu"])
        XCTAssertEqual(c.source, .preset("aws-linux"))
        XCTAssertEqual(c.region, "us-east-1"); XCTAssertEqual(c.instanceType, "g6.xlarge")
        XCTAssertEqual(c.arch, "x86_64"); XCTAssertEqual(c.diskGB, 100); XCTAssertTrue(c.spot)
        XCTAssertEqual(c.ttl.seconds, 14_400); XCTAssertEqual(c.idle.seconds, 1200)
        XCTAssertTrue(c.autoUp); XCTAssertEqual(c.vars, ["team": "ml"]); XCTAssertEqual(c.maxHourly, 1.5)
    }

    func testDefaults() throws {
        let c = try XCTUnwrap(DelegateConfigParser.parse("[infra.a]\npreset = \"gcp-linux\"\nregion = \"us-central1\"\ninstance_type = \"e2-standard-2\"\nttl = \"1h\"\n").config.infra["a"])
        XCTAssertEqual(c.idle, InfraConfig.defaultIdle); XCTAssertFalse(c.autoUp); XCTAssertFalse(c.spot)
    }

    func testTTLIsRequired() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.ttl"), "\($0)")
        }
    }

    func testExactlyOneSource() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\nttl = \"1h\"\n"))
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nmodule = \"infra/x\"\nttl = \"1h\"\n"))
    }

    func testUnknownPresetAndUnknownKeyAreErrors() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"azure\"\nttl = \"1h\"\n"))
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\nttll = \"2h\"\n")) {
            XCTAssertTrue("\($0)".contains("ttll"))
        }
    }

    func testPresetNeedsRegionAndInstanceType() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nttl = \"1h\"\n"))
    }

    func testModuleMustStayInsideRepo() {
        for path in ["../x", "/abs", "infra/../../x"] {
            XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\nmodule = \"\(path)\"\nttl = \"1h\"\n"), path)
        }
        XCTAssertNoThrow(try DelegateConfigParser.parse("[infra.a]\nmodule = \"infra/gpu\"\nttl = \"1h\"\n"))
    }

    func testBadDurationNamesTheKey() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"forever\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.ttl"))
        }
    }

    /// An infra name that is already a paired host would make `--on` ambiguous.
    func testValidateRefusesClashWithPairedHost() throws {
        let config = try DelegateConfigParser.parse("[infra.mini]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\n").config
        let issues = config.validate(hosts: ["mini": "macOS"])
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("mini") }, "\(issues)")
    }
}
