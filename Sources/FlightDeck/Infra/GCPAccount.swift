import Foundation
import IntakeKit

/// A GCP project reached through `gcloud` and Application Default Credentials — the credentials
/// OpenTofu's google provider reads, which are separate from `gcloud auth login`'s. `project ==
/// nil` means gcloud's configured default project.
struct GCPAccount: CloudAccount {
    let cloud = "gcp"
    let project: String?
    private let cli: CloudCLI
    private let signInCLI: CloudCLI

    /// `environment` is the resolved tool's own (`CLOUDSDK_PYTHON`, which gcloud cannot start
    /// without); `base` replaces the login-shell-repaired app environment only in tests.
    init(gcloud: URL, project: String?, runner: CommandRunner, environment: [String: String] = [:],
         base: [String: String]? = nil) {
        self.project = project
        // A check must never sit on an interactive reauth prompt nobody can see; sign-in is
        // the one call that is meant to interact (it opens the browser).
        self.cli = CloudCLI(executable: gcloud, runner: runner,
                            extra: environment.merging(["CLOUDSDK_CORE_DISABLE_PROMPTS": "1"]) { _, new in new }, base: base)
        self.signInCLI = CloudCLI(executable: gcloud, runner: runner, extra: environment, base: base)
    }

    private var projectArgs: [String] { project.map { ["--project", $0] } ?? [] }

    func status() async -> AccountStatus {
        let result: CommandResult
        do { result = try await cli.run(["auth", "application-default", "print-access-token"]) }
        catch { return .unavailable(error.localizedDescription) }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.lowercased()
            if ["credentials were not found", "reauthenticat", "invalid_grant", "expired", "login"]
                .contains(where: stderr.contains) {
                return .signedOut(fix: "gcloud auth application-default login")
            }
            return .unavailable(CloudCLI.message(result))
        }
        return .ready(identity: project ?? "application default credentials")
    }

    func signIn() async throws {
        _ = try await signInCLI.checked(["auth", "application-default", "login"])
    }

    /// The family's regional vCPU quota and, for a machine type with GPUs attached (g2, a2,
    /// a3), the GPU model's quota. Unlike EC2's Service Quotas, the region description carries
    /// current usage, so `have` is the headroom left (limit − usage). The first failing check
    /// is the one returned; when both pass, the vCPU one.
    func quota(region: String, instanceType: String) async throws -> QuotaCheck {
        let types = try await cli.checked(["compute", "machine-types", "list",
                                           "--filter", "name=\(instanceType) AND zone~^\(region)-",
                                           "--limit", "1", "--format", "json"] + projectArgs)
        guard let machine = ((try? JSONSerialization.jsonObject(with: types.stdout)) as? [[String: Any]])?.first,
              let cpus = (machine["guestCpus"] as? NSNumber)?.doubleValue else {
            throw CloudAccountError.failed("\(instanceType) is not offered in \(region)")
        }
        var needs: [(metric: String, count: Double)] = [(Self.cpuMetric(machineType: instanceType), cpus)]
        for accelerator in machine["accelerators"] as? [[String: Any]] ?? [] {
            guard let type = accelerator["guestAcceleratorType"] as? String,
                  let count = (accelerator["guestAcceleratorCount"] as? NSNumber)?.doubleValue else { continue }
            needs.append((Self.gpuMetric(acceleratorType: type), count))
        }

        let described = try await cli.checked(["compute", "regions", "describe", region, "--format", "json"] + projectArgs)
        let quotas = ((try? JSONSerialization.jsonObject(with: described.stdout)) as? [String: Any])?["quotas"] as? [[String: Any]] ?? []
        let checks = try needs.map { need -> QuotaCheck in
            guard let entry = quotas.first(where: { $0["metric"] as? String == need.metric }),
                  let limit = (entry["limit"] as? NSNumber)?.doubleValue else {
                throw CloudAccountError.failed("\(region) has no \(need.metric) quota")
            }
            let have = limit - ((entry["usage"] as? NSNumber)?.doubleValue ?? 0)
            return QuotaCheck(ok: have >= need.count, have: have, need: need.count, increaseURL: increaseURL)
        }
        return checks.first { !$0.ok } ?? checks[0]
    }

    /// The project's quotas page. The console's per-metric filter lives in an undocumented
    /// `pageState` blob, so the link stops at the project rather than risk a filter that
    /// silently shows nothing.
    private var increaseURL: URL? {
        var parts = URLComponents(string: "https://console.cloud.google.com/iam-admin/quotas")
        if let project { parts?.queryItems = [URLQueryItem(name: "project", value: project)] }
        return parts?.url
    }

    func providerEnvironment() -> [String: String] {
        project.map { ["GOOGLE_CLOUD_PROJECT": $0, "CLOUDSDK_CORE_PROJECT": $0] } ?? [:]
    }

    func moduleVars() -> [String: String] {
        project.map { ["project": $0] } ?? [:]
    }

    /// `instanceID` is the preset's `fd_instance_id`, the instance's relative resource name
    /// (`projects/<p>/zones/<z>/instances/<n>`); the serial port wants the name and zone. A bare
    /// name falls back to `<region>-a`, only a guess: the preset now picks the region's first UP
    /// zone, so a module that outputs a bare name may land elsewhere and get no console.
    func consoleOutput(instanceID: String, region: String) async -> String? {
        let parts = instanceID.split(separator: "/").map(String.init)
        let zone = parts.firstIndex(of: "zones").flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil } ?? "\(region)-a"
        guard let name = parts.last,
              let result = try? await cli.checked(["compute", "instances", "get-serial-port-output", name,
                                                    "--zone", zone] + projectArgs) else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Orphan scan (spec §7.3)

    /// The presets create one instance and two firewall rules per machine. Instances carry the
    /// owner as a label and are listed across every zone; firewall rules cannot carry labels,
    /// so the preset writes `flightdeck-owner=<owner> flightdeck-name=<name>` into their
    /// description instead. The filter's regex is a substring match, so the description is
    /// checked again here word for word: owner `abc` must not claim owner `abcd`'s rules.
    func listOwned(owner: String) async throws -> [OwnedResource] {
        let instances = try await cli.checked(["compute", "instances", "list", "--filter", "labels.flightdeck-owner=\(owner)",
                                               "--format", "json"] + projectArgs)
        let rules = try await cli.checked(["compute", "firewall-rules", "list", "--filter", "description~flightdeck-owner=\(owner)",
                                           "--format", "json"] + projectArgs)
        return try Self.owned(instances: instances.stdout, firewalls: rules.stdout, owner: owner)
    }

    func deleteOwned(_ resource: OwnedResource) async throws {
        switch resource.kind {
        case .instance:
            _ = try await cli.checked(["compute", "instances", "delete", resource.id, "--zone", resource.region, "--quiet"] + projectArgs)
        case .firewall:
            _ = try await cli.checked(["compute", "firewall-rules", "delete", resource.id, "--quiet"] + projectArgs)
        case .securityGroup:
            throw CloudAccountError.failed("GCP has no security groups; \(resource.id) is not a GCP resource")
        }
    }

    // MARK: - pure

    /// `instances list` and `firewall-rules list` JSON as `OwnedResource`s. An instance's
    /// region is its zone, the last part of its `zone` URL, which is what deleting it needs.
    /// Output that is not a JSON list throws: it must never read as "nothing there".
    static func owned(instances: Data, firewalls: Data, owner: String) throws -> [OwnedResource] {
        func array(_ data: Data, _ what: String) throws -> [[String: Any]] {
            guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                throw CloudAccountError.failed("gcloud did not return a list of \(what)")
            }
            return items
        }
        let found = try array(instances, "instances").compactMap { i -> OwnedResource? in
            guard let name = i["name"] as? String, let zone = (i["zone"] as? String)?.split(separator: "/").last else { return nil }
            return OwnedResource(cloud: "gcp", kind: .instance, id: name, region: String(zone),
                                 name: (i["labels"] as? [String: String])?["flightdeck-name"])
        }
        let rules = try array(firewalls, "firewall rules").compactMap { f -> OwnedResource? in
            guard let name = f["name"] as? String else { return nil }
            let words = ((f["description"] as? String) ?? "").split(separator: " ").map(String.init)
            guard words.contains("flightdeck-owner=\(owner)") else { return nil }
            let host = words.first { $0.hasPrefix("flightdeck-name=") }.map { String($0.dropFirst("flightdeck-name=".count)) }
            return OwnedResource(cloud: "gcp", kind: .firewall, id: name, region: "global", name: host)
        }
        return found + rules
    }

    /// The regional vCPU metric for a machine type's family: E2, N1 and the shared-core
    /// f1/g1 count against plain `CPUS`; every other family has its own (`N2_CPUS`, `G2_CPUS`…).
    static func cpuMetric(machineType: String) -> String {
        let family = machineType.split(separator: "-").first.map(String.init)?.lowercased() ?? machineType
        return ["e2", "n1", "f1", "g1"].contains(family) ? "CPUS" : "\(family.uppercased())_CPUS"
    }

    /// The regional GPU metric for an accelerator type: `nvidia-l4` → `NVIDIA_L4_GPUS`,
    /// `nvidia-tesla-t4` → `NVIDIA_T4_GPUS`. The H100's metric drops its memory suffix.
    static func gpuMetric(acceleratorType: String) -> String {
        if acceleratorType == "nvidia-h100-80gb" { return "NVIDIA_H100_GPUS" }
        let model = acceleratorType.replacingOccurrences(of: "nvidia-tesla-", with: "nvidia-")
        return model.uppercased().replacingOccurrences(of: "-", with: "_") + "_GPUS"
    }
}
