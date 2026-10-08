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
        // The refusal has to say why, or "azure" reads like a typo in some other key.
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"azure\"\nttl = \"1h\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.preset \"azure\" is not one of aws-linux"), "\($0)")
        }
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\nttll = \"2h\"\n")) {
            XCTAssertTrue("\($0)".contains("ttll"))
        }
    }

    /// Each case leaves out exactly one key, so the message must name that one and not the other:
    /// "needs region and instance_type" sends someone who set instance_type looking for a typo.
    func testPresetWithoutRegionNamesRegion() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\ninstance_type = \"t\"\nttl = \"1h\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.region"), "\($0)")
            XCTAssertFalse("\($0)".contains("instance_type"), "\($0)")
        }
    }

    func testPresetWithoutInstanceTypeNamesInstanceType() {
        XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\nttl = \"1h\"\n")) {
            XCTAssertTrue("\($0)".contains("infra.a.instance_type"), "\($0)")
            XCTAssertFalse("\($0)".contains("region"), "\($0)")
        }
    }

    /// A zero or negative disk or price cap is never a request; passing it on would surface as an
    /// OpenTofu error far from the line that caused it, or a cap that refuses every launch.
    func testNonPositiveDiskAndPriceCapAreErrorsNamingTheKey() {
        let base = "[infra.a]\npreset = \"aws-linux\"\nregion = \"r\"\ninstance_type = \"t\"\nttl = \"1h\"\n"
        for (line, key) in [("disk_gb = 0", "infra.a.disk_gb"), ("disk_gb = -5", "infra.a.disk_gb"),
                            ("max_hourly = 0", "infra.a.max_hourly"), ("max_hourly = 0.0", "infra.a.max_hourly"),
                            ("max_hourly = -1.5", "infra.a.max_hourly")] {
            XCTAssertThrowsError(try DelegateConfigParser.parse(base + line + "\n"), line) {
                XCTAssertTrue("\($0)".contains(key) && "\($0)".contains("greater than zero"), "\(line): \($0)")
            }
        }
        XCTAssertNoThrow(try DelegateConfigParser.parse(base + "disk_gb = 1\nmax_hourly = 0.01\n"))
    }

    func testModuleMustStayInsideRepo() {
        // `~x` is a home-relative path to tofu, and "" is the repo root itself: neither is a module
        // directory inside the project, and the refusal must say that rather than just fail.
        for path in ["../x", "/abs", "infra/../../x", "~x", ""] {
            XCTAssertThrowsError(try DelegateConfigParser.parse("[infra.a]\nmodule = \"\(path)\"\nttl = \"1h\"\n"), path) {
                XCTAssertTrue("\($0)".contains("infra.a.module must be a path inside the repo, not \"\(path)\""), "\($0)")
            }
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
