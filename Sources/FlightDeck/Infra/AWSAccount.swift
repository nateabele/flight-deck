import Foundation
import IntakeKit

/// An AWS account reached through `aws` and one named profile (SSO or static keys — the CLI's
/// credential chain decides). `profile == nil` means the CLI's default chain.
struct AWSAccount: CloudAccount {
    let cloud = "aws"
    let profile: String?
    private let cli: CloudCLI

    /// `environment` is the resolved tool's own (`ResolvedTool.environment`); `base` replaces
    /// the login-shell-repaired app environment only in tests.
    init(aws: URL, profile: String?, runner: CommandRunner, environment: [String: String] = [:],
         base: [String: String]? = nil) {
        self.profile = profile
        // An empty pager: CLI v2 pipes long output through `less` when it thinks it can.
        self.cli = CloudCLI(executable: aws, runner: runner,
                            extra: environment.merging(["AWS_PAGER": ""]) { _, new in new }, base: base)
    }

    private var profileArgs: [String] { profile.map { ["--profile", $0] } ?? [] }

    func status() async -> AccountStatus {
        let result: CommandResult
        do { result = try await cli.run(["sts", "get-caller-identity", "--output", "json"] + profileArgs) }
        catch { return .unavailable(error.localizedDescription) }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.lowercased()
            // An expired SSO token, a never-run `sso login`, or no credentials at all: each is
            // fixed by signing in, not by anything the user would find in the raw message.
            if ["sso", "expired", "unable to locate credentials"].contains(where: stderr.contains) {
                return .signedOut(fix: profile.map { "aws sso login --profile \($0)" } ?? "aws configure sso")
            }
            return .unavailable(CloudCLI.message(result))
        }
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        guard let account = object?["Account"] as? String else {
            return .unavailable("aws sts get-caller-identity returned no Account")
        }
        return .ready(identity: account)
    }

    /// `aws sso login` needs a profile that names an SSO session; with none there is nothing it
    /// could log into, so the user is pointed at creating one rather than shown its error.
    func signIn() async throws {
        guard profile != nil else {
            throw CloudAccountError.failed("No AWS profile is chosen. Run `aws configure sso` to create one, then pick it in Settings → Cloud.")
        }
        _ = try await cli.checked(["sso", "login"] + profileArgs)
    }

    func consoleOutput(instanceID: String, region: String) async -> String? {
        guard let result = try? await cli.checked(["ec2", "get-console-output", "--instance-id", instanceID, "--latest",
                                                    "--output", "text", "--region", region] + profileArgs) else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "None" ? nil : text
    }

    func moduleVars() -> [String: String] { [:] }

    // MARK: - Orphan scan (spec §7.3)

    /// The presets create one instance and one security group per machine (the security group
    /// rules are its children), so those two are what is asked for, in every region the account
    /// has enabled: an orphan is by definition one whose region nobody recorded. The region
    /// list itself is asked of us-east-1, which every commercial account can reach whether or
    /// not the profile names a region. A terminated instance is not an orphan, and one shutting
    /// down is already on its way out; the CLI filters both.
    func listOwned(owner: String) async throws -> [OwnedResource] {
        let listed = try await cli.checked(["ec2", "describe-regions", "--query", "Regions[].RegionName",
                                            "--output", "json", "--region", "us-east-1"] + profileArgs)
        guard let regions = (try? JSONSerialization.jsonObject(with: listed.stdout)) as? [String] else {
            throw CloudAccountError.failed("aws ec2 describe-regions did not return a list of regions")
        }
        let ownerFilter = "Name=tag:flightdeck-owner,Values=\(owner)"
        return try await withThrowingTaskGroup(of: [OwnedResource].self) { group in
            for region in regions {
                group.addTask {
                    let instances = try await cli.checked(["ec2", "describe-instances", "--filters", ownerFilter,
                                                           "Name=instance-state-name,Values=pending,running,stopping,stopped",
                                                           "--region", region, "--output", "json"] + profileArgs)
                    let groups = try await cli.checked(["ec2", "describe-security-groups", "--filters", ownerFilter,
                                                        "--region", region, "--output", "json"] + profileArgs)
                    return try Self.owned(instances: instances.stdout, securityGroups: groups.stdout, region: region)
                }
            }
            var found: [OwnedResource] = []
            for try await part in group { found += part }
            return found.sorted { ($0.region, $0.kind.rawValue, $0.id) < ($1.region, $1.kind.rawValue, $1.id) }
        }
    }

    /// A security group still referenced by a running instance cannot be deleted; that is the
    /// CLI's error to report, and terminating the instance first is the fix.
    func deleteOwned(_ resource: OwnedResource) async throws {
        switch resource.kind {
        case .instance:
            _ = try await cli.checked(["ec2", "terminate-instances", "--instance-ids", resource.id,
                                       "--region", resource.region, "--output", "json"] + profileArgs)
        case .securityGroup:
            _ = try await cli.checked(["ec2", "delete-security-group", "--group-id", resource.id,
                                       "--region", resource.region] + profileArgs)
        case .firewall:
            throw CloudAccountError.failed("AWS has no firewall resources; \(resource.id) is not an AWS resource")
        }
    }

    /// v1 compares this machine's vCPUs with the family's whole quota; vCPUs already running
    /// in the region are not subtracted (docs/FOLLOWUPS.md), so `ok` can be optimistic.
    func quota(region: String, instanceType: String) async throws -> QuotaCheck {
        guard let code = Self.quotaCode(instanceType: instanceType, spot: false) else {
            throw CloudAccountError.unsupportedInstanceType(instanceType)
        }
        let vcpus = try await cli.checked(["ec2", "describe-instance-types", "--instance-types", instanceType,
                                           "--query", "InstanceTypes[0].VCpuInfo.DefaultVCpus",
                                           "--region", region, "--output", "json"] + profileArgs)
        guard let need = Double(String(decoding: vcpus.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CloudAccountError.failed("\(instanceType) is not offered in \(region)")
        }
        let quota = try await cli.checked(["service-quotas", "get-service-quota", "--service-code", "ec2",
                                           "--quota-code", code, "--region", region, "--output", "json"] + profileArgs)
        let object = (try? JSONSerialization.jsonObject(with: quota.stdout)) as? [String: Any]
        guard let have = ((object?["Quota"] as? [String: Any])?["Value"] as? NSNumber)?.doubleValue else {
            throw CloudAccountError.failed("aws service-quotas returned no value for \(code)")
        }
        return QuotaCheck(ok: have >= need, have: have, need: need,
                          increaseURL: URL(string: "https://\(region).console.aws.amazon.com/servicequotas/home/services/ec2/quotas/\(code)"))
    }

    func providerEnvironment() -> [String: String] {
        profile.map { ["AWS_PROFILE": $0] } ?? [:]
    }

    // MARK: - pure

    /// `describe-instances` and `describe-security-groups` JSON as `OwnedResource`s, named by
    /// their `flightdeck-name` tag. Output without the expected top-level list throws: an
    /// error page or a changed format must never read as "nothing there".
    static func owned(instances: Data, securityGroups: Data, region: String) throws -> [OwnedResource] {
        func list(_ data: Data, _ key: String) throws -> [[String: Any]] {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = object[key] as? [[String: Any]] else {
                throw CloudAccountError.failed("aws returned no \(key) list for \(region)")
            }
            return items
        }
        func name(_ item: [String: Any]) -> String? {
            (item["Tags"] as? [[String: Any]])?.first { $0["Key"] as? String == "flightdeck-name" }?["Value"] as? String
        }
        let reservations = try list(instances, "Reservations")
        let found = reservations.flatMap { $0["Instances"] as? [[String: Any]] ?? [] }.compactMap { i in
            (i["InstanceId"] as? String).map { OwnedResource(cloud: "aws", kind: .instance, id: $0, region: region, name: name(i)) }
        }
        let groups = try list(securityGroups, "SecurityGroups").compactMap { g in
            (g["GroupId"] as? String).map { OwnedResource(cloud: "aws", kind: .securityGroup, id: $0, region: region, name: name(g)) }
        }
        return found + groups
    }

    /// The EC2 vCPU quota covering `instanceType`'s family, keyed by the family's leading
    /// letters (`g6.xlarge` → `g`, `vt1.3xlarge` → `vt`, `im4gn.large` → `im`). Nil for a
    /// family this table does not cover (mac, inf, trn, x, u-…), which the caller reports rather
    /// than guessing a quota that may not be the one AWS enforces.
    static func quotaCode(instanceType: String, spot: Bool) -> String? {
        let family = String(instanceType.prefix { $0.isLetter }).lowercased()
        let group: String
        switch family {
        case "a", "c", "d", "h", "i", "im", "is", "m", "r", "t", "z": group = "standard"
        case "g", "gr", "vt": group = "g"
        case "p": group = "p"
        default: return nil
        }
        let codes: [String: (onDemand: String, spot: String)] = [
            "standard": ("L-1216C47A", "L-34B43A08"),
            "g": ("L-DB2E81BA", "L-3819A6DF"),
            "p": ("L-417A185B", "L-7212CCBC"),
        ]
        return codes[group].map { spot ? $0.spot : $0.onDemand }
    }

    /// Profile names in `~/.aws/config`: `[default]` and every `[profile name]`. `[sso-session …]`
    /// and `[services …]` sections are not profiles and are skipped.
    static func profiles(configText: String) -> [String] {
        configText.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
            let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if header == "default" { return "default" }
            let parts = header.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == "profile" else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }
}
