import Foundation

/// One cloud resource Flight Deck created: what an OpenTofu apply of its own `up` plan made,
/// read back from the state. `id` is the provider's `id` attribute, the one a destroy plan's
/// `before.id` names, so a resource is matched by `(cloud, type, id)` alone. The address and
/// the machine only explain a refusal.
struct ProvenanceRecord: Codable, Equatable, Sendable {
    let cloud: String
    let type: String
    let id: String
    let address: String
    let machine: String
    let createdAt: Date
}

/// Every cloud resource Flight Deck created, in `infra-provenance.json`, and the rule that
/// bounds every teardown by it: Flight Deck deletes only what this file says it created.
///
/// **Why not the OpenTofu state, or the owner tag.** A state can hold a resource that was
/// never created by Flight Deck: a repo's own module may `import` one. A tag is any string
/// anyone can set. A record here is written only from an `up` plan that `checkUp` proved
/// creates and nothing else, so it is the one thing that names exactly what Flight Deck made.
///
/// Records are never removed. A deleted resource's id is not reused by its cloud, so a stale
/// record permits nothing, and the file stays the full history of what was created.
@MainActor
final class ResourceProvenance {
    private(set) var records: [ProvenanceRecord]
    private let file: VersionedJSONFile<ProvenanceRecord>

    /// - Parameter seed: read only when the file does not exist yet: the resources of the
    ///   machines a build without this file created. `infra.json` lists only machines `up`
    ///   made, and nothing could import into their states, so they are Flight Deck's.
    init(fileURL: URL, seed: () -> [ProvenanceRecord] = { [] }) {
        file = VersionedJSONFile(url: fileURL, key: "resources")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            records = file.load()
        } else {
            records = seed()
            do { try file.write(records) } catch {
                // In memory only: the seed is read again next launch, from the same states.
            }
        }
    }

    /// Adds `new`, skipping any `(cloud, type, id)` already recorded. In-memory state changes
    /// only once the write succeeded.
    func record(_ new: [ProvenanceRecord]) throws {
        let fresh = new.filter { r in !records.contains { Self.same($0, r) } }
        guard !fresh.isEmpty else { return }
        let next = records + fresh
        try file.write(next)
        records = next
    }

    func created(cloud: String, type: String, id: String) -> Bool {
        records.contains { $0.cloud == cloud && $0.type == type && $0.id == id }
    }

    private static func same(_ a: ProvenanceRecord, _ b: ProvenanceRecord) -> Bool {
        a.cloud == b.cloud && a.type == b.type && a.id == b.id
    }

    // MARK: - The rule

    /// The resources an `up` plan may contain: new ones only. An import would adopt a
    /// resource someone else made (and a later destroy would delete it); an update or delete
    /// touches one that exists already. Data sources only read.
    static func checkUp(_ changes: [TofuChange], name: String) throws {
        let bad = changes.filter { c in
            c.managed && (c.importing || !c.actions.allSatisfy { $0 == "create" || $0 == "no-op" })
        }
        guard !bad.isEmpty else { return }
        let list = bad.map { "\($0.address) (\($0.importing ? "import" : $0.actions.joined(separator: "+")))" }
        throw InfraError.refused("\(name)'s plan would change resources Flight Deck did not create: \(list.joined(separator: ", ")). `up` only creates; remove the import or the existing resources from its module.")
    }

    /// The resources a destroy plan may delete: each one recorded as created here. Anything
    /// else refuses the whole destroy before it starts, so nothing is half done.
    func checkDestroy(_ changes: [TofuChange], cloud: String, name: String) throws {
        let unknown = outside(changes, cloud: cloud, allowed: ["delete", "no-op"])
        guard !unknown.isEmpty else { return }
        throw InfraError.refused("Flight Deck has no record of creating \(unknown.joined(separator: ", ")), so it will not destroy \(name). Delete what is yours in the cloud console, then `flightdeck infra down \(name)` again.")
    }

    /// The resources a re-apply of a running machine (its inbound rule following this Mac's
    /// address) may touch: it may create, and may update or delete only what was recorded.
    func checkChange(_ changes: [TofuChange], cloud: String, name: String) throws {
        let unknown = outside(changes, cloud: cloud, allowed: ["create", "update", "delete", "no-op"])
        guard !unknown.isEmpty else { return }
        throw InfraError.refused("\(name)'s change would touch resources Flight Deck has no record of creating: \(unknown.joined(separator: ", ")).")
    }

    /// Each change in `changes` beyond the rule: an import, an action outside `allowed`, or an
    /// update or delete of a resource with no record. Creates touch nothing that exists.
    private func outside(_ changes: [TofuChange], cloud: String, allowed: Set<String>) -> [String] {
        changes.filter(\.managed).compactMap { c in
            if c.importing || !c.actions.allSatisfy(allowed.contains) {
                return "\(c.address) (\(c.importing ? "import" : c.actions.joined(separator: "+")))"
            }
            guard c.actions.contains(where: { $0 == "update" || $0 == "delete" }) else { return nil }
            guard let id = c.id, created(cloud: cloud, type: c.type, id: id) else {
                return "\(c.address)\(c.id.map { " \($0)" } ?? "")"
            }
            return nil
        }
    }

    /// The records an apply of `up`'s plan earns: each resource now in the state at an
    /// address that plan created.
    static func created(by changes: [TofuChange], state: [TofuResource], cloud: String, machine: String,
                        at now: Date) -> [ProvenanceRecord] {
        let made = Set(changes.filter { $0.managed && $0.actions == ["create"] && !$0.importing }.map(\.address))
        return state.filter { made.contains($0.address) }.map {
            ProvenanceRecord(cloud: cloud, type: $0.type, id: $0.id, address: $0.address, machine: machine, createdAt: now)
        }
    }

    /// Whether an orphan the tag scan found is one Flight Deck created. The scan names a GCE
    /// instance or firewall rule by its bare name; OpenTofu's id is its path.
    func created(_ r: OwnedResource) -> Bool {
        let types: [String] = switch r.kind {
        case .instance: ["aws_instance", "google_compute_instance"]
        case .securityGroup: ["aws_security_group"]
        case .firewall: ["google_compute_firewall"]
        }
        return records.contains { rec in
            rec.cloud == r.cloud && types.contains(rec.type)
                && (rec.id == r.id || rec.id.split(separator: "/").last.map(String.init) == r.id)
        }
    }
}

extension ResourceProvenance {
    /// The managed resources in a local state file, `<workdir>/module/terraform.tfstate`, for
    /// the seed. A state elsewhere (a module's own backend) seeds nothing, so that machine's
    /// destroy is refused until its resources are deleted by hand.
    nonisolated static func stateResources(workdir: URL) -> [TofuResource] {
        let url = workdir.appendingPathComponent("module/terraform.tfstate")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let resources = object["resources"] as? [[String: Any]] else { return [] }
        return resources.flatMap { r -> [TofuResource] in
            guard r["mode"] as? String == "managed", let type = r["type"] as? String, let name = r["name"] as? String
            else { return [] }
            let base = [r["module"] as? String, "\(type).\(name)"].compactMap { $0 }.joined(separator: ".")
            return (r["instances"] as? [[String: Any]] ?? []).compactMap { i in
                guard let id = (i["attributes"] as? [String: Any])?["id"] as? String else { return nil }
                let key = i["index_key"].map { k in k is String ? "[\"\(k)\"]" : "[\(k)]" } ?? ""
                return TofuResource(address: base + key, type: type, id: id)
            }
        }
    }
}
