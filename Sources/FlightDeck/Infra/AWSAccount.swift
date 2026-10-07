import Foundation
import IntakeKit

/// An AWS account reached through `aws` and one named profile (SSO or static keys — the CLI's
/// credential chain decides). `profile == nil` means the CLI's default chain.
struct AWSAccount: CloudAccount {
    let cloud = "aws"
    let profile: String?
    private let cli: CloudCLI

    init(aws: URL, profile: String?, runner: CommandRunner) {
        self.profile = profile
        // An empty pager: CLI v2 pipes long output through `less` when it thinks it can.
        self.cli = CloudCLI(executable: aws, runner: runner, extra: ["AWS_PAGER": ""])
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

    func signIn() async throws {
        _ = try await cli.checked(["sso", "login"] + profileArgs)
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
