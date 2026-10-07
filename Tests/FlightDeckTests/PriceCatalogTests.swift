import XCTest
import IntakeKit
@testable import FlightDeck

/// Published on-demand prices — what `PriceCatalog` must reproduce from each cloud's own price
/// list. Recorded 2026-10-07 (Task 0's P4 probe runs in parallel, so these were taken here).
/// - GCP, us-central1: https://cloud.google.com/compute/vm-instance-pricing (E2, N2, G2 tables;
///   the G2 figure includes its one NVIDIA L4). The page renders its tables client-side, so the
///   numbers were cross-checked against the Billing Catalog mirror at
///   https://github.com/Cyclenerd/google-cloud-pricing-cost-calculator (pricing.yml generated
///   2026-09-24: 0.06701142, 0.194236, 0.706832255).
/// - AWS, us-east-1: https://aws.amazon.com/ec2/pricing/on-demand/ (Linux, g6.xlarge), and the
///   same figure from a read-only `aws pricing get-products` the fixture was captured from.
enum P4 {
    static let e2Standard2UsCentral1 = 0.067006
    static let n2Standard4UsCentral1 = 0.194236
    static let g2Standard4UsCentral1 = 0.70683
    static let g6XlargeUsEast1 = 0.8048
}

/// A counter a `@Sendable` fake source can bump. Named for this file so it can't collide with
/// the target's other `LockedBox` (Intake), whose storage is optional and has no `mutate`.
private final class PriceTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
}

final class PriceCatalogTests: XCTestCase {
    private final class Token {}

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/prices") else {
            throw NSError(domain: "PriceCatalogTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    // MARK: AWS

    func testAWSOnDemandPlusDisk() throws {
        let json = try fixture("aws-getproducts-g6")
        // g6.xlarge us-east-1 on-demand from the fixture, plus 100 GB gp3 at $0.08/GB-month / 730 h
        XCTAssertEqual(try AWSPriceSource.parseOnDemand(json) + AWSPriceSource.diskHourly(gb: 100), 0.8048 + 100 * 0.08 / 730, accuracy: 1e-4)
        XCTAssertEqual(try AWSPriceSource.parseOnDemand(json), P4.g6XlargeUsEast1, accuracy: 1e-9)
    }

    func testAWSSpotIsTheDearestZone() throws {
        // The zone is not chosen yet when a machine is priced, so the estimate never undercuts.
        XCTAssertEqual(try AWSPriceSource.parseSpot(try fixture("aws-spot")), 0.6891, accuracy: 1e-9)
    }

    func testAWSEmptyPriceListIsAnErrorNotZero() {
        XCTAssertThrowsError(try AWSPriceSource.parseOnDemand(Data(#"{"PriceList":[],"FormatVersion":"aws_v1"}"#.utf8)))
        XCTAssertThrowsError(try AWSPriceSource.parseSpot(Data(#"{"SpotPriceHistory":[]}"#.utf8)))
    }

    func testAWSSourceRunsTheCLIForSpot() async throws {
        let spot = try fixture("aws-spot")
        let calls = PriceTestBox<[[String]]>([])
        struct Canned: CommandRunner {
            let calls: PriceTestBox<[[String]]>; let stdout: Data
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
                calls.mutate { $0.append([executable] + arguments) }
                return CommandResult(stdout: stdout, stderr: "", exitCode: 0)
            }
        }
        let source = AWSPriceSource(aws: URL(fileURLWithPath: "/opt/aws/aws"), runner: Canned(calls: calls, stdout: spot), profile: "dev")
        let price = try await source.hourly(PriceQuery(cloud: "aws", region: "us-east-1", instanceType: "g6.xlarge", spot: true, diskGB: 100))
        XCTAssertEqual(price, 0.6891 + 100 * 0.08 / 730, accuracy: 1e-9)
        let argv = try XCTUnwrap(calls.value.first)
        XCTAssertEqual(argv.first, "/opt/aws/aws")
        XCTAssertTrue(argv.contains("describe-spot-price-history"), "\(argv)")
        XCTAssertEqual(argv.firstIndex(of: "--profile").map { argv[$0 + 1] }, "dev")
        XCTAssertEqual(argv.firstIndex(of: "--instance-types").map { argv[$0 + 1] }, "g6.xlarge")
    }

    func testAWSSourceFailsOnANonZeroExit() async {
        struct Failing: CommandRunner {
            func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                     processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
                CommandResult(stdout: Data(), stderr: "Unable to locate credentials", exitCode: 255)
            }
        }
        let source = AWSPriceSource(aws: URL(fileURLWithPath: "/opt/aws/aws"), runner: Failing(), profile: nil)
        do {
            _ = try await source.hourly(PriceQuery(cloud: "aws", region: "us-east-1", instanceType: "g6.xlarge", spot: false, diskGB: 0))
            XCTFail("a failed CLI run must not price the machine")
        } catch {}
    }

    // MARK: GCP

    func testGCPMachineFromSKUs() throws {
        let skus = try fixture("gcp-skus-compute")
        // Expected = P4 published price for e2-standard-2 in us-central1 (Task 0), within 1%.
        let price = try GCPPriceSource.price(machineType: "e2-standard-2", region: "us-central1", spot: false, skus: skus, shapes: .builtIn)
        XCTAssertEqual(price, P4.e2Standard2UsCentral1, accuracy: P4.e2Standard2UsCentral1 * 0.01)
    }

    func testGCPOtherP4TypesMatchPublishedPrices() throws {
        let skus = try fixture("gcp-skus-compute")
        let n2 = try GCPPriceSource.price(machineType: "n2-standard-4", region: "us-central1", spot: false, skus: skus, shapes: .builtIn)
        XCTAssertEqual(n2, P4.n2Standard4UsCentral1, accuracy: P4.n2Standard4UsCentral1 * 0.01)
        let g2 = try GCPPriceSource.price(machineType: "g2-standard-4", region: "us-central1", spot: false, skus: skus, shapes: .builtIn)
        XCTAssertEqual(g2, P4.g2Standard4UsCentral1, accuracy: P4.g2Standard4UsCentral1 * 0.01)
    }

    func testGCPSpotUsesTheSpotSKUs() throws {
        let skus = try fixture("gcp-skus-compute")
        let spot = try GCPPriceSource.price(machineType: "g2-standard-4", region: "us-central1", spot: true, skus: skus, shapes: .builtIn)
        XCTAssertEqual(spot, 4 * 0.014993 + 16 * 0.0017551 + 0.336, accuracy: 1e-6)
    }

    func testGCPMatchesOnlyTheQueriedRegion() throws {
        let skus = try fixture("gcp-skus-compute")
        let price = try GCPPriceSource.price(machineType: "e2-standard-2", region: "europe-west1", spot: false, skus: skus, shapes: .builtIn)
        XCTAssertEqual(price, 2 * 0.023955 + 8 * 0.003210, accuracy: 1e-6)
        XCTAssertThrowsError(try GCPPriceSource.price(machineType: "n2-standard-4", region: "europe-west1", spot: false, skus: skus, shapes: .builtIn),
                             "no N2 SKU in that region: unknown, never another region's price")
    }

    func testGCPUnknownMachineTypeIsAnError() throws {
        let skus = try fixture("gcp-skus-compute")
        XCTAssertThrowsError(try GCPPriceSource.price(machineType: "a3-highgpu-8g", region: "us-central1", spot: false, skus: skus, shapes: .builtIn))
    }

    func testGCPSourcePagesTheCatalogWithTheBearerToken() async throws {
        let all = try JSONSerialization.jsonObject(with: try fixture("gcp-skus-compute")) as! [String: Any]
        let skus = all["skus"] as! [Any]
        let page1 = try JSONSerialization.data(withJSONObject: ["skus": Array(skus.prefix(10)), "nextPageToken": "p2"])
        let page2 = try JSONSerialization.data(withJSONObject: ["skus": Array(skus.dropFirst(10)), "nextPageToken": ""])
        let seen = PriceTestBox<[(URL, [String: String])]>([])
        struct Paged: HTTPFetching {
            let seen: PriceTestBox<[(URL, [String: String])]>; let page1: Data; let page2: Data
            func get(_ url: URL, headers: [String: String]) async throws -> (Data, [String: String]) {
                seen.mutate { $0.append((url, headers)) }
                return (url.query?.contains("pageToken=p2") == true ? page2 : page1, [:])
            }
            func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, [String: String]) { throw HTTPStatusError(status: 405) }
            func delete(_ url: URL, headers: [String: String]) async throws { throw HTTPStatusError(status: 405) }
        }
        let source = GCPPriceSource(token: { "tok" }, http: Paged(seen: seen, page1: page1, page2: page2), machineTypes: .builtIn)
        let price = try await source.hourly(PriceQuery(cloud: "gcp", region: "us-central1", instanceType: "g2-standard-4", spot: false, diskGB: 100))
        XCTAssertEqual(price, 4 * 0.024988 + 16 * 0.0029275 + 0.56004 + 100 * 0.10 / 730, accuracy: 1e-6)
        XCTAssertEqual(seen.value.count, 2)
        XCTAssertEqual(seen.value.first?.1["Authorization"], "Bearer tok")
        XCTAssertTrue(seen.value.first?.0.absoluteString.hasPrefix("https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?") == true)
    }

    // MARK: Cache

    func testCacheServesWithinTTLAndUnknownWithoutIt() async {
        struct Counting: PriceSource { let box: PriceTestBox<Int>; func hourly(_ q: PriceQuery) async throws -> Double { box.mutate { $0 += 1 }; return 1.5 } }
        struct Failing: PriceSource { func hourly(_ q: PriceQuery) async throws -> Double { throw URLError(.notConnectedToInternet) } }
        let box = PriceTestBox(0), clock = PriceTestBox(Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let q = PriceQuery(cloud: "aws", region: "r", instanceType: "t", spot: false, diskGB: 0)
        let c = PriceCatalog(sources: ["aws": Counting(box: box)], cacheURL: url, now: { clock.value })
        _ = await c.hourly(q); _ = await c.hourly(q)
        XCTAssertEqual(box.value, 1)
        let offline = PriceCatalog(sources: ["aws": Failing()], cacheURL: url, now: { clock.value })
        let cached = await offline.hourly(q)
        XCTAssertEqual(cached, 1.5)
        clock.mutate { $0 = Date(timeIntervalSince1970: 90_000) }
        let stale = await offline.hourly(q)
        XCTAssertNil(stale, "expired cache and failed lookup is unknown, never a guess")
    }

    func testCacheKeysOnEveryQueryField() async {
        let box = PriceTestBox(0)
        struct Counting: PriceSource { let box: PriceTestBox<Int>; func hourly(_ q: PriceQuery) async throws -> Double { box.mutate { $0 += 1 }; return Double(q.diskGB) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let c = PriceCatalog(sources: ["aws": Counting(box: box)], cacheURL: url)
        let a = await c.hourly(PriceQuery(cloud: "aws", region: "r", instanceType: "t", spot: false, diskGB: 10))
        let b = await c.hourly(PriceQuery(cloud: "aws", region: "r", instanceType: "t", spot: true, diskGB: 10))
        let d = await c.hourly(PriceQuery(cloud: "aws", region: "r", instanceType: "t", spot: false, diskGB: 20))
        XCTAssertEqual([a, b, d], [10, 10, 20])
        XCTAssertEqual(box.value, 3)
        let unknownCloud = await c.hourly(PriceQuery(cloud: "azure", region: "r", instanceType: "t", spot: false, diskGB: 0))
        XCTAssertNil(unknownCloud)
    }
}
