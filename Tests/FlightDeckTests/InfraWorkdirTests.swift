import XCTest
@testable import FlightDeck

final class InfraWorkdirTests: XCTestCase {
    private func makeModule() throws -> (tmp: URL, module: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        let module = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "resource {}".write(to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        return (tmp, module)
    }

    func testCopiesModuleAndWritesVars() throws {
        let (tmp, module) = try makeModule()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wd = try InfraWorkdir.prepare(root: tmp.appendingPathComponent("infra"), name: "gpu", moduleSource: module,
                                          vars: ["fd_name": .string("gpu"), "disk_gb": .number(100), "spot": .bool(false),
                                                 "tags": .map(["a": "b"])])
        XCTAssertTrue(FileManager.default.fileExists(atPath: wd.appendingPathComponent("module/main.tf").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: wd.appendingPathComponent("module/fd.auto.tfvars.json"))) as! [String: Any]
        XCTAssertEqual(json["fd_name"] as? String, "gpu")
        XCTAssertEqual(json["disk_gb"] as? Double, 100)
        XCTAssertEqual(json["spot"] as? Bool, false)
        XCTAssertEqual(json["tags"] as? [String: String], ["a": "b"])
    }

    func testRecopyKeepsState() throws {
        let (tmp, module) = try makeModule()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wd = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        try "state".write(to: wd.appendingPathComponent("module/terraform.tfstate"), atomically: true, encoding: .utf8)
        try "changed".write(to: module.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
        _ = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        XCTAssertEqual(try String(contentsOf: wd.appendingPathComponent("module/terraform.tfstate")), "state")
        XCTAssertEqual(try String(contentsOf: wd.appendingPathComponent("module/main.tf")), "changed")
    }

    func testSourceStateIsNotCopied() throws {
        let (tmp, module) = try makeModule()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "foreign".write(to: module.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        let wd = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: wd.appendingPathComponent("module/terraform.tfstate").path))
    }
}
