import HostKit
import XCTest
@testable import FlightDeck

/// Flight Deck deletes only the cloud resources it recorded creating (`ResourceProvenance`).
@MainActor
final class ResourceProvenanceTests: XCTestCase {
    var h: InfraHarness!
    override func setUp() async throws { h = try InfraHarness() }
    override func tearDown() async throws { h = nil }

    let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                          spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)

    private func change(_ address: String, _ actions: [String], id: String? = nil, importing: Bool = false) -> TofuChange {
        TofuChange(address: address, type: String(address.split(separator: ".")[0]), managed: true,
                   actions: actions, importing: importing, id: id)
    }

    func testUpRecordsWhatItCreatedAndDownDeletesIt() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-gpu", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }
        XCTAssertEqual(h.provenance.records.map(\.id), ["i-gpu", "sg-gpu"])
        XCTAssertEqual(Set(h.provenance.records.map(\.machine)), ["gpu"])
        try await h.service.down(name: "gpu") { _ in }
        XCTAssertEqual(h.tofu.destroyed, ["gpu"])
        XCTAssertEqual(h.provenance.records.count, 2, "kept: the history of what was created")
    }

    /// A module's `import` block would adopt a resource someone else made, and a later
    /// destroy would delete it: `up` refuses the plan before anything is applied or billed.
    func testAnUpPlanThatImportsIsRefusedBeforeTheApply() async throws {
        h.tofu.upChanges = [change("aws_instance.this", ["create"]),
                            change("aws_security_group.shared", ["no-op"], id: "sg-theirs", importing: true)]
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() }
        catch InfraError.refused(let why) { XCTAssertTrue(why.contains("aws_security_group.shared (import)"), why) }
        XCTAssertEqual(h.tofu.calls, ["init", "plan"], "nothing applied, so nothing to roll back")
        XCTAssertEqual(h.provenance.records, [])
        XCTAssertEqual(h.ledger.spent(name: "gpu", now: h.now.addingTimeInterval(3600)), 0)
        XCTAssertNil(h.registry.machine(named: "gpu"), "never applied, so no record to project or list")
        if case .success = h.hosts.registry.resolve(name: "gpu") { XCTFail("the enrolled host is forgotten") }
    }

    func testAnUpPlanThatChangesAnExistingResourceIsRefused() throws {
        for actions in [["update"], ["delete"], ["delete", "create"]] {
            XCTAssertThrowsError(try ResourceProvenance.checkUp([change("aws_instance.this", actions, id: "i-1")], name: "gpu"), "\(actions)")
        }
        XCTAssertNoThrow(try ResourceProvenance.checkUp([change("aws_instance.this", ["create"]),
                                                          TofuChange(address: "data.aws_ami.ubuntu", type: "aws_ami", managed: false,
                                                                     actions: ["read"], importing: false, id: nil)], name: "gpu"))
    }

    /// A destroy plan that would delete anything unrecorded deletes nothing at all.
    func testADestroyThatWouldDeleteAnUnrecordedResourceIsRefusedWhole() async throws {
        _ = try h.readyMachine("gpu")
        h.tofu.foreign["gpu"] = [change("aws_security_group.shared", ["delete"], id: "sg-theirs")]
        do { try await h.service.down(name: "gpu") { _ in }; XCTFail() }
        catch InfraError.refused(let why) {
            XCTAssertTrue(why.contains("no record of creating aws_security_group.shared sg-theirs"), why)
            XCTAssertFalse(why.contains("aws_instance"), "only the unrecorded resource is named: \(why)")
        }
        XCTAssertEqual(h.tofu.destroyed, [], "not even the recorded instance")
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .failed, "kept, so the machine is still found")
    }

    /// The same type and id on another cloud is not the same resource.
    func testARecordMatchesItsCloudTypeAndIDTogether() throws {
        try h.recordCreated("aws_instance", "i-1")
        let deletes = { (type: String, id: String) in [TofuChange(address: "\(type).this", type: type, managed: true, actions: ["delete"], importing: false, id: id)] }
        XCTAssertNoThrow(try h.provenance.checkDestroy(deletes("aws_instance", "i-1"), cloud: "aws", name: "gpu"))
        XCTAssertThrowsError(try h.provenance.checkDestroy(deletes("aws_instance", "i-2"), cloud: "aws", name: "gpu"))
        XCTAssertThrowsError(try h.provenance.checkDestroy(deletes("aws_ebs_volume", "i-1"), cloud: "aws", name: "gpu"))
        XCTAssertThrowsError(try h.provenance.checkDestroy(deletes("aws_instance", "i-1"), cloud: "gcp", name: "gpu"))
    }

    /// What a failed apply created is recorded first, so the rollback can delete it.
    func testAFailedApplyIsRolledBackThroughItsRecords() async throws {
        h.tofu.failApply = TofuError.failed(step: "apply", message: "InsufficientInstanceCapacity")
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo) { _ in }; XCTFail() } catch {}
        XCTAssertEqual(h.provenance.records.map(\.id), ["i-gpu", "sg-gpu"])
        XCTAssertEqual(h.tofu.destroyed, ["gpu"])
    }

    func testOnlyAddressesThePlanCreatedAreRecorded() {
        let changes = [change("aws_instance.this", ["create"]), change("aws_security_group.old", ["no-op"], id: "sg-old")]
        let state = [TofuResource(address: "aws_instance.this", type: "aws_instance", id: "i-1"),
                     TofuResource(address: "aws_security_group.old", type: "aws_security_group", id: "sg-old")]
        XCTAssertEqual(ResourceProvenance.created(by: changes, state: state, cloud: "aws", machine: "gpu", at: h.now).map(\.id), ["i-1"])
    }

    // MARK: - The file

    func testTheSeedIsReadOnlyWhenTheFileDoesNotExistYet() throws {
        let url = h.root.appendingPathComponent("seeded.json")
        let seed = [ProvenanceRecord(cloud: "aws", type: "aws_instance", id: "i-1", address: "aws_instance.this", machine: "gpu", createdAt: h.now)]
        XCTAssertEqual(ResourceProvenance(fileURL: url) { seed }.records, seed)
        XCTAssertEqual(ResourceProvenance(fileURL: url) { [] }.records, seed, "read back, not seeded again")
        XCTAssertEqual(ResourceProvenance(fileURL: url) { XCTFail("seeded twice"); return [] }.records, seed)
    }

    func testTheSeedReadsALocalStateFile() throws {
        let workdir = h.root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: workdir.appendingPathComponent("module"), withIntermediateDirectories: true)
        let state: [String: Any] = ["resources": [
            ["mode": "data", "type": "aws_ami", "name": "ubuntu", "instances": [["attributes": ["id": "ami-1"]]]],
            ["mode": "managed", "type": "aws_instance", "name": "this", "instances": [["attributes": ["id": "i-1"]]]],
            ["mode": "managed", "type": "aws_ec2_tag", "name": "eni", "module": "module.box",
             "instances": [["index_key": "flightdeck", "attributes": ["id": "eni-1,flightdeck"]]]],
        ]]
        try JSONSerialization.data(withJSONObject: state).write(to: workdir.appendingPathComponent("module/terraform.tfstate"))
        XCTAssertEqual(ResourceProvenance.stateResources(workdir: workdir), [
            TofuResource(address: "aws_instance.this", type: "aws_instance", id: "i-1"),
            TofuResource(address: "module.box.aws_ec2_tag.eni[\"flightdeck\"]", type: "aws_ec2_tag", id: "eni-1,flightdeck"),
        ])
        XCTAssertEqual(ResourceProvenance.stateResources(workdir: h.root.appendingPathComponent("none")), [])
    }

    // MARK: - OpenTofu's JSON

    func testPlanChangesParse() throws {
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"resource_changes": [
          {"address": "aws_instance.this", "mode": "managed", "type": "aws_instance",
           "change": {"actions": ["delete"], "before": {"id": "i-1"}}},
          {"address": "aws_security_group.x", "mode": "managed", "type": "aws_security_group",
           "change": {"actions": ["no-op"], "before": {"id": "sg-1"}, "importing": {"id": "sg-1"}}},
          {"address": "data.aws_ami.u", "mode": "data", "type": "aws_ami", "change": {"actions": ["read"]}}
        ]}
        """.utf8)) as? [String: Any])
        XCTAssertEqual(LiveTofuRunner.changes(plan), [
            TofuChange(address: "aws_instance.this", type: "aws_instance", managed: true, actions: ["delete"], importing: false, id: "i-1"),
            TofuChange(address: "aws_security_group.x", type: "aws_security_group", managed: true, actions: ["no-op"], importing: true, id: "sg-1"),
            TofuChange(address: "data.aws_ami.u", type: "aws_ami", managed: false, actions: ["read"], importing: false, id: nil),
        ])
    }

    func testStateResourcesParseChildModules() throws {
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"values": {"root_module": {
          "resources": [{"address": "aws_instance.this", "mode": "managed", "type": "aws_instance", "values": {"id": "i-1"}},
                        {"address": "data.aws_ami.u", "mode": "data", "type": "aws_ami", "values": {"id": "ami-1"}}],
          "child_modules": [{"resources": [{"address": "module.m.aws_security_group.s", "mode": "managed",
                                            "type": "aws_security_group", "values": {"id": "sg-1"}}]}]
        }}}
        """.utf8)) as? [String: Any])
        XCTAssertEqual(LiveTofuRunner.resources(state), [
            TofuResource(address: "aws_instance.this", type: "aws_instance", id: "i-1"),
            TofuResource(address: "module.m.aws_security_group.s", type: "aws_security_group", id: "sg-1"),
        ])
    }
}
