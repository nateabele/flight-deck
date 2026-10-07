import Foundation
import IntakeKit
import OSLog

// The hourly USD price of a cloud machine, from each cloud's own price list (spec §8.1).
//
// Every figure here is an ESTIMATE and must be shown labelled "est.": it is compute plus the
// boot disk only — no egress, snapshots, taxes, sustained-use or committed-use discounts.

/// One machine to price. `diskGB` is the boot disk; it is part of the key because the disk
/// is part of the price.
struct PriceQuery: Hashable, Sendable {
    let cloud: String
    let region: String
    let instanceType: String
    let spot: Bool
    let diskGB: Int
}

/// One cloud's price list. Throws whenever it cannot name a price: a guessed rate under a
/// dollar cap is worse than none, because `up` refuses an unknown price but trusts a known one.
protocol PriceSource: Sendable {
    func hourly(_ q: PriceQuery) async throws -> Double
}

/// The HTTP verbs the price lookup and the Tailscale API need. A protocol so tests hand back
/// canned pages and never reach a real API.
protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
    /// The response headers come back because the Tailscale policy endpoint answers with the
    /// `ETag` its next write must quote.
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, [String: String])
    func delete(_ url: URL, headers: [String: String]) async throws
}

struct HTTPStatusError: Error, Equatable {
    let status: Int
}

struct URLSessionHTTPFetcher: HTTPFetching {
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await send(request(url, "GET", headers)).0
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, [String: String]) {
        var request = request(url, "POST", headers)
        request.httpBody = body
        return try await send(request)
    }

    func delete(_ url: URL, headers: [String: String]) async throws {
        _ = try await send(request(url, "DELETE", headers))
    }

    private func request(_ url: URL, _ method: String, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, [String: String]) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, [:]) }
        // A 401/403 body is a JSON error document that would otherwise decode as an empty
        // price list and surface as "no SKU for this machine" instead of "sign in again".
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { out, field in
            if let name = field.key as? String, let value = field.value as? String { out[name] = value }
        }
        return (data, headers)
    }
}

enum PriceLookupError: Error, Equatable {
    case noPrice(String)
    case commandFailed(String)
}

// MARK: - AWS

/// AWS through its own CLI: the Pricing API (`get-products`) for on-demand and
/// `describe-spot-price-history` for spot, plus gp3 storage for the boot disk.
struct AWSPriceSource: PriceSource {
    let aws: URL
    let runner: CommandRunner
    let profile: String?

    init(aws: URL, runner: CommandRunner, profile: String?) {
        self.aws = aws; self.runner = runner; self.profile = profile
    }

    /// gp3 list price in the US regions, $/GB-month. A constant in v1: the Pricing API row
    /// for it is a second paged lookup per region for a figure that has not moved since
    /// launch, and every figure is labelled "est." anyway.
    static let gp3PerGBMonth = 0.08
    /// The clouds' own month for prorating a monthly rate to an hour.
    static let hoursPerMonth = 730.0

    static func diskHourly(gb: Int) -> Double {
        Double(gb) * gp3PerGBMonth / hoursPerMonth
    }

    func hourly(_ q: PriceQuery) async throws -> Double {
        let compute = q.spot
            ? try Self.parseSpot(try await aws(spotArguments(q)))
            : try Self.parseOnDemand(try await aws(onDemandArguments(q)))
        return compute + Self.diskHourly(gb: q.diskGB)
    }

    /// The Pricing API answers only in a few regions; us-east-1 serves every region's prices.
    private func onDemandArguments(_ q: PriceQuery) -> [String] {
        let filters = [("instanceType", q.instanceType), ("regionCode", q.region), ("operatingSystem", "Linux"),
                       ("tenancy", "Shared"), ("preInstalledSw", "NA"), ("capacitystatus", "Used")]
        return ["pricing", "get-products", "--region", "us-east-1", "--service-code", "AmazonEC2", "--filters"]
            + filters.map { "Type=TERM_MATCH,Field=\($0),Value=\($1)" } + ["--output", "json"]
    }

    private func spotArguments(_ q: PriceQuery) -> [String] {
        let now = ISO8601DateFormatter().string(from: Date())
        return ["ec2", "describe-spot-price-history", "--region", q.region, "--instance-types", q.instanceType,
                "--product-descriptions", "Linux/UNIX", "--start-time", now, "--output", "json"]
    }

    private func aws(_ arguments: [String]) async throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        // v2 pipes output through `less` when AWS_PAGER is unset, even with no terminal.
        environment["AWS_PAGER"] = ""
        let result = try await runner.run(executable: aws.path,
                                          arguments: arguments + (profile.map { ["--profile", $0] } ?? []),
                                          cwd: FileManager.default.temporaryDirectory, environment: environment)
        guard result.exitCode == 0 else {
            throw PriceLookupError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// `PriceList[0]` is itself a JSON document, as a string; its on-demand rate is the
    /// single `terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD`.
    static func parseOnDemand(_ json: Data) throws -> Double {
        struct Response: Decodable { let PriceList: [String] }
        struct Product: Decodable { let terms: Terms }
        struct Terms: Decodable { let OnDemand: [String: Term] }
        struct Term: Decodable { let priceDimensions: [String: Dimension] }
        struct Dimension: Decodable { let pricePerUnit: [String: String] }
        guard let first = try JSONDecoder().decode(Response.self, from: json).PriceList.first else {
            throw PriceLookupError.noPrice("the Pricing API returned no product")
        }
        let product = try JSONDecoder().decode(Product.self, from: Data(first.utf8))
        let rates = product.terms.OnDemand.values.flatMap(\.priceDimensions.values)
            .compactMap { $0.pricePerUnit["USD"].flatMap(Double.init) }
        // The rate is never free: a zero row is a placeholder (a reserved-only offering, say).
        guard let rate = rates.first(where: { $0 > 0 }) else {
            throw PriceLookupError.noPrice("the product has no on-demand USD rate")
        }
        return rate
    }

    /// The dearest zone's current price. The zone is not known when a machine is priced (the
    /// cloud picks it at launch), so the estimate takes the one it can never undercut.
    static func parseSpot(_ json: Data) throws -> Double {
        struct Response: Decodable { let SpotPriceHistory: [Entry] }
        struct Entry: Decodable { let SpotPrice: String }
        guard let rate = try JSONDecoder().decode(Response.self, from: json).SpotPriceHistory
            .compactMap({ Double($0.SpotPrice) }).max()
        else { throw PriceLookupError.noPrice("no spot price for this type in this region") }
        return rate
    }
}

// MARK: - GCP

/// What a predefined machine type is made of — the Billing Catalog prices the parts, never
/// the machine.
struct GCPMachineShape: Hashable, Sendable {
    let vCPUs: Int
    let memoryGB: Double
    let gpus: Int
    /// The accelerator's SKU description stem (`Nvidia L4`), or nil for none.
    let gpuModel: String?
}

/// The allowlisted families (spec §7: general purpose up to 16 vCPU, single-GPU families),
/// each with the stem its SKUs are described by. A type outside this table cannot be priced,
/// and `up` refuses it while a dollar cap is set.
struct GCPMachineTypes: Sendable {
    let shapes: [String: GCPMachineShape]
    /// Family → SKU description stem, e.g. `n2d` → `N2D AMD Instance`.
    let skuStems: [String: String]

    func shape(_ machineType: String) -> GCPMachineShape? { shapes[machineType] }

    func stem(_ machineType: String) -> String? {
        machineType.split(separator: "-").first.flatMap { skuStems[String($0)] }
    }

    static let builtIn: GCPMachineTypes = {
        var shapes: [String: GCPMachineShape] = [:]
        // GB of memory per vCPU for each predefined class.
        let classes: [(String, Double)] = [("standard", 4), ("highmem", 8), ("highcpu", 1)]
        for family in ["e2", "n2", "n2d"] {
            for (name, perCPU) in classes {
                for cpus in [2, 4, 8, 16] {
                    shapes["\(family)-\(name)-\(cpus)"] = GCPMachineShape(
                        vCPUs: cpus, memoryGB: Double(cpus) * perCPU, gpus: 0, gpuModel: nil)
                }
            }
        }
        for cpus in [4, 8, 12, 16] {
            shapes["g2-standard-\(cpus)"] = GCPMachineShape(
                vCPUs: cpus, memoryGB: Double(cpus) * 4, gpus: 1, gpuModel: "Nvidia L4")
        }
        return GCPMachineTypes(shapes: shapes, skuStems: [
            "e2": "E2 Instance", "n2": "N2 Instance", "n2d": "N2D AMD Instance", "g2": "G2 Instance",
        ])
    }()
}

/// GCP from the Cloud Billing Catalog: the Compute Engine service's SKUs, paged, with an
/// application-default bearer token.
struct GCPPriceSource: PriceSource {
    let token: @Sendable () async throws -> String
    let http: HTTPFetching
    let machineTypes: GCPMachineTypes

    init(token: @escaping @Sendable () async throws -> String, http: HTTPFetching, machineTypes: GCPMachineTypes) {
        self.token = token; self.http = http; self.machineTypes = machineTypes
    }

    /// Compute Engine's service id in the catalog — public and the same for every account.
    static let catalogURL = URL(string: "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus")!

    func hourly(_ q: PriceQuery) async throws -> Double {
        let skus = try await fetchSKUs()
        return try Self.price(machineType: q.instanceType, region: q.region, spot: q.spot,
                              skus: skus, shapes: machineTypes)
            + Self.diskHourly(gb: q.diskGB, region: q.region, skus: skus)
    }

    private func fetchSKUs() async throws -> [SKU] {
        let headers = ["Authorization": "Bearer \(try await token())"]
        var skus: [SKU] = []
        var pageToken = ""
        repeat {
            var components = URLComponents(url: Self.catalogURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "currencyCode", value: "USD"),
                                     URLQueryItem(name: "pageSize", value: "5000")]
                + (pageToken.isEmpty ? [] : [URLQueryItem(name: "pageToken", value: pageToken)])
            let page = try JSONDecoder().decode(SKUPage.self, from: try await http.get(components.url!, headers: headers))
            skus += page.skus
            pageToken = page.nextPageToken ?? ""
        } while !pageToken.isEmpty
        return skus
    }

    /// vCPUs × the core SKU + GB × the RAM SKU (+ GPUs × the accelerator SKU), each the one
    /// whose `serviceRegions` holds `region`. Matching is by description: a custom,
    /// sole-tenancy or committed-use SKU shares the family's resource group and region, and
    /// only the description tells them apart.
    static func price(machineType: String, region: String, spot: Bool, skus: Data,
                      shapes: GCPMachineTypes) throws -> Double {
        try price(machineType: machineType, region: region, spot: spot,
                  skus: JSONDecoder().decode(SKUPage.self, from: skus).skus, shapes: shapes)
    }

    static func price(machineType: String, region: String, spot: Bool, skus: [SKU],
                      shapes: GCPMachineTypes) throws -> Double {
        guard let shape = shapes.shape(machineType), let stem = shapes.stem(machineType) else {
            throw PriceLookupError.noPrice("\(machineType) is not a predefined type Flight Deck can price")
        }
        let prefix = spot ? "Spot Preemptible \(stem)" : stem
        let cpu = try rate(region: region, in: skus, "\(prefix) Core running in ")
        let ram = try rate(region: region, in: skus, "\(prefix) Ram running in ")
        var total = Double(shape.vCPUs) * cpu + shape.memoryGB * ram
        if let model = shape.gpuModel {
            let gpu = spot ? "\(model) GPU attached to Spot Preemptible VMs running in " : "\(model) GPU running in "
            total += Double(shape.gpus) * (try rate(region: region, in: skus, gpu))
        }
        return total
    }

    /// The boot disk as pd-balanced, the default for every allowlisted family. Its SKU is
    /// per GB-month (`GiBy.mo`), prorated over the same 730-hour month as AWS.
    static func diskHourly(gb: Int, region: String, skus: [SKU]) throws -> Double {
        guard gb > 0 else { return 0 }
        return Double(gb) * (try rate(region: region, in: skus, "Balanced PD Capacity")) / AWSPriceSource.hoursPerMonth
    }

    private static func rate(region: String, in skus: [SKU], _ descriptionPrefix: String) throws -> Double {
        guard let sku = skus.first(where: { $0.description.hasPrefix(descriptionPrefix) && $0.serviceRegions.contains(region) }),
              let price = sku.pricingInfo.first?.pricingExpression.tieredRates.last?.unitPrice
        else { throw PriceLookupError.noPrice("no \"\(descriptionPrefix)…\" SKU in \(region)") }
        return price.dollars
    }

    struct SKUPage: Decodable {
        let skus: [SKU]
        let nextPageToken: String?
    }

    struct SKU: Decodable {
        let description: String
        let serviceRegions: [String]
        let pricingInfo: [PricingInfo]

        struct PricingInfo: Decodable { let pricingExpression: Expression }
        struct Expression: Decodable { let tieredRates: [TieredRate] }
        struct TieredRate: Decodable { let unitPrice: Money }
        /// `google.type.Money`: `units` is an int64, which the API sends as a JSON string.
        struct Money: Decodable {
            let units: String?
            let nanos: Int?
            var dollars: Double { Double(units ?? "0").map { $0 + Double(nanos ?? 0) / 1e9 } ?? 0 }
        }
    }
}

// MARK: - The catalog

/// Prices by cloud, cached on disk for `ttl` (a day): the price lists are large and slow,
/// and a day-old rate is as good an estimate as a fresh one.
///
/// A lookup that fails with no fresh cache entry is UNKNOWN (nil), never the expired figure:
/// `up` refuses an unknown price while a dollar cap is set, and an old rate that has since
/// risen would let it through.
final class PriceCatalog: @unchecked Sendable {
    private let sources: [String: PriceSource]
    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry]

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra")

    private struct Entry: Codable {
        let hourly: Double
        let fetchedAt: Date
    }

    private struct File: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    init(sources: [String: PriceSource], cacheURL: URL, now: @escaping @Sendable () -> Date = { Date() },
         ttl: TimeInterval = 86_400) {
        self.sources = sources
        self.cacheURL = cacheURL
        self.now = now
        self.ttl = ttl
        entries = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode(File.self, from: $0).entries } ?? [:]
    }

    /// nil = unknown: no source for the cloud, or no fresh cache and the lookup failed.
    func hourly(_ q: PriceQuery) async -> Double? {
        let key = Self.key(q)
        if let entry = lock.withLock({ entries[key] }), now().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.hourly
        }
        guard let source = sources[q.cloud] else { return nil }
        do {
            let hourly = try await source.hourly(q)
            store(Entry(hourly: hourly, fetchedAt: now()), for: key)
            return hourly
        } catch {
            Self.logger.error("price lookup failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func key(_ q: PriceQuery) -> String {
        "\(q.cloud)|\(q.region)|\(q.instanceType)|\(q.spot)|\(q.diskGB)"
    }

    private func store(_ entry: Entry, for key: String) {
        let snapshot = lock.withLock { () -> [String: Entry] in
            entries[key] = entry
            return entries
        }
        // The cache is only a speed-up: a failed write costs a re-fetch tomorrow, nothing more.
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(File(entries: snapshot)).write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.error("price cache write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
