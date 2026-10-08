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

    /// A file deleted from the source module must not survive in the copy: OpenTofu reads every
    /// `.tf` in the directory, so a stale one would still be applied.
    func testRecopyDropsFilesDeletedFromTheSource() throws {
        let (tmp, module) = try makeModule()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "resource {}".write(to: module.appendingPathComponent("extra.tf"), atomically: true, encoding: .utf8)
        let wd = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        let copy = wd.appendingPathComponent("module")
        try "state".write(to: copy.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
        try "backup".write(to: copy.appendingPathComponent("terraform.tfstate.backup"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
        try "lock".write(to: copy.appendingPathComponent(".terraform.lock.hcl"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: module.appendingPathComponent("extra.tf"))
        _ = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent("extra.tf").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("main.tf").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("terraform.tfstate").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("terraform.tfstate.backup").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent(".terraform").path))
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent(".terraform.lock.hcl")), "lock",
                       "the lock tofu wrote is kept while the source has none")
        try "pinned".write(to: module.appendingPathComponent(".terraform.lock.hcl"), atomically: true, encoding: .utf8)
        _ = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: [:])
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent(".terraform.lock.hcl")), "pinned",
                       "a source with its own lock wins")
    }

    /// The vars file carries the enrollment PSK and any Tailscale auth key: owner-only.
    func testVarsFileIsOwnerOnly() throws {
        let (tmp, module) = try makeModule()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for _ in 0..<2 {
            let wd = try InfraWorkdir.prepare(root: tmp, name: "x", moduleSource: module, vars: ["fd_user_data": .string("secret")])
            let attributes = try FileManager.default.attributesOfItem(atPath: wd.appendingPathComponent("module/fd.auto.tfvars.json").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
