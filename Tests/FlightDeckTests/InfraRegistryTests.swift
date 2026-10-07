import HostKit
import XCTest
@testable import FlightDeck

@MainActor
final class InfraRegistryTests: XCTestCase {
    func testUpsertPersistsAndReloads() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ir-\(UUID())")
        let m = InfraMachine(name: "gpu", repoRoot: "/repo", cloud: "aws", instanceType: "g6.xlarge", region: "us-east-1",
            slot: UUID(), state: .provisioning, failure: nil, network: .public, createdAt: Date(timeIntervalSince1970: 1),
            deadline: Date(timeIntervalSince1970: 3601), idle: .init(seconds: 1800), allowCIDR: "198.51.100.7/32",
            instanceID: nil, address: nil, hourlyUSD: 0.8)
        try InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp).upsert(m)
        XCTAssertEqual(InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp).machine(named: "gpu"), m)
    }

    func testRemoveAndWorkdir() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ir-\(UUID())")
        let r = InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp)
        let m = InfraMachine(name: "a", repoRoot: "/repo", cloud: "aws", instanceType: "t", region: "r",
            slot: nil, state: .planned, failure: nil, network: .tailnet, createdAt: Date(timeIntervalSince1970: 1),
            deadline: Date(timeIntervalSince1970: 2), idle: .init(seconds: 60), allowCIDR: nil,
            instanceID: nil, address: nil, hourlyUSD: nil)
        try r.upsert(m)
        try r.remove(name: "a")
        XCTAssertNil(InfraRegistry(fileURL: tmp.appendingPathComponent("infra.json"), workRoot: tmp).machine(named: "a"))
        XCTAssertEqual(r.workdir(for: "a"), tmp.appendingPathComponent("a", isDirectory: true))
    }
}
