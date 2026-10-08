import Foundation
import HostKit

/// One line of `infra doctor`, and of the refusal `infra up` prints: what was checked, whether it
/// passed, what was found, and — for a failure — the exact thing to do about it.
struct PreflightCheck: Equatable, Sendable {
    let name: String
    let ok: Bool
    let detail: String
    let fix: String?
}

enum InfraError: Error, Equatable {
    /// At least one check failed; every check is listed, so one refusal names every fix.
    case preflight([PreflightCheck])
    /// The name is a paired host, another repo's machine, or this repo's machine in a state
    /// `up` cannot take over. Thrown before anything else is checked.
    case nameInUse(String)
    /// The machine never said hello. `console` is its boot console, when the cloud had one.
    case enrollTimeout(console: String?)
    case notFound(String)
    /// An `extend` (or other request) the rules forbid; the text says which rule and what to do.
    case refused(String)
}

/// What one `infra up` would launch, resolved once so every check reads the same values.
struct InfraLaunchPlan {
    let name: String
    let config: InfraConfig
    /// "aws" or "gcp"; nil when a user module does not say which.
    let cloud: String?
    let moduleSource: URL
    /// The price list's rate; nil when it has none (a user module, or a failed lookup).
    let catalogHourly: Double?
}

/// Spec §10: every check `infra up` makes before anything that creates a resource, in the
/// spec's order, each failure naming its fix. Pure apart from the tool, account and quota
/// lookups it is handed. The name check is not here: `InfraService` throws `nameInUse` before
/// running these at all, since no fix below helps a name that is taken.
enum InfraPreflight {
    struct Inputs {
        let plan: InfraLaunchPlan
        let resolveTofu: () async throws -> ResolvedTool
        let account: CloudAccount?
        let tailnetMode: TailnetMode
        let budget: BudgetSettings
        /// Machines not yet gone, this one excluded: what the concurrency guardrail counts.
        let running: Int
        let monthToDate: Double
    }

    static func run(_ i: Inputs) async -> [PreflightCheck] {
        var checks = [await tools(i.resolveTofu)]
        checks.append(config(i.plan, account: i.account))
        checks.append(budget(i.plan, running: i.running, monthToDate: i.monthToDate, settings: i.budget))
        let signedIn = await Self.account(cloud: i.plan.cloud, i.account)
        checks.append(signedIn)
        checks.append(await quota(i.plan, account: signedIn.ok ? i.account : nil))
        checks.append(network(i.tailnetMode))
        return checks
    }

    // MARK: - The checks

    static func tools(_ resolve: () async throws -> ResolvedTool) async -> PreflightCheck {
        do {
            let tofu = try await resolve()
            return PreflightCheck(name: "tools", ok: true,
                                  detail: "tofu \(tofu.version) at \(tofu.url.path) (\(tofu.source == .path ? "PATH" : "managed"))",
                                  fix: nil)
        } catch let ToolError.missing(_, why) {
            return PreflightCheck(name: "tools", ok: false, detail: why,
                                  fix: "Install OpenTofu 1.8 or later (brew install opentofu), or let Flight Deck download it in Settings → Cloud → Set up…")
        } catch {
            return PreflightCheck(name: "tools", ok: false, detail: "tofu: \(error)",
                                  fix: "Check this Mac's network, then try again; a checksum mismatch is never retried from another source.")
        }
    }

    static func config(_ plan: InfraLaunchPlan, account: CloudAccount?) -> PreflightCheck {
        guard let cloud = plan.cloud else {
            return PreflightCheck(name: "config", ok: false, detail: "can't tell which cloud the module in [infra.\(plan.name)] is for",
                                  fix: #"Add cloud = "aws" or "gcp" to [infra.\#(plan.name)].vars in .flightdeck/delegate.toml."#)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plan.moduleSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if case .preset(let preset) = plan.config.source {
                return PreflightCheck(name: "config", ok: false, detail: "this build has no \(preset) preset",
                                      fix: "Use one of \(InfraConfig.knownPresets.joined(separator: ", ")).")
            }
            return PreflightCheck(name: "config", ok: false, detail: "no module directory at \(plan.moduleSource.path)",
                                  fix: "Point [infra.\(plan.name)].module at a directory in the repo holding the OpenTofu module.")
        }
        // The GCP preset's `project` comes from the account, never the repo.
        if cloud == "gcp", case .preset = plan.config.source, account?.moduleVars()["project"] == nil {
            return PreflightCheck(name: "config", ok: false, detail: "no GCP project is chosen",
                                  fix: "Pick a project in Settings → Cloud.")
        }
        return PreflightCheck(name: "config", ok: true, detail: "\(cloud), \(describe(plan.config.source))", fix: nil)
    }

    /// The caps and guardrails (spec §8): the recipe's own `max_hourly` first, then
    /// `CostModel.checkLaunch` at the price list's rate, else `max_hourly` as the bound.
    static func budget(_ plan: InfraLaunchPlan, running: Int, monthToDate: Double, settings: BudgetSettings) -> PreflightCheck {
        let fix = "Settings → Cloud → Budget"
        if let max = plan.config.maxHourly, let rate = plan.catalogHourly, rate > max + 1e-9 {
            return PreflightCheck(name: "budget", ok: false,
                                  detail: "\(usd(rate))/h est. is over this recipe's max_hourly of \(usd(max))",
                                  fix: "Raise max_hourly in [infra.\(plan.name)] or pick a smaller instance_type.")
        }
        let hourly = plan.catalogHourly ?? plan.config.maxHourly
        let verdict = CostModel.checkLaunch(hourly: hourly, ttl: plan.config.ttl, idle: plan.config.idle,
                                            instanceType: plan.config.instanceType ?? "(module)", cloud: plan.cloud ?? "",
                                            running: running, monthToDate: monthToDate, settings: settings)
        switch verdict {
        case .refused(let why):
            return PreflightCheck(name: "budget", ok: false, detail: why, fix: fix)
        case .allowed:
            let detail = hourly.map {
                "worst case \(usd(CostModel.worstCase(hourly: $0, ttl: plan.config.ttl))) (\(usd($0))/h est. for \(plan.config.ttl.formatted))"
            } ?? "price unknown; no dollar cap is set"
            return PreflightCheck(name: "budget", ok: true, detail: detail, fix: nil)
        }
    }

    /// `name` is "account" for `up`, "account <cloud>" in `doctor`'s list of every account.
    static func account(cloud: String?, _ account: CloudAccount?, name: String = "account") async -> PreflightCheck {
        guard let account else {
            return PreflightCheck(name: name, ok: false, detail: "no \(cloud ?? "cloud") account is set up",
                                  fix: "Settings → Cloud → Set up…")
        }
        switch await account.status() {
        case .ready(let identity):
            return PreflightCheck(name: name, ok: true, detail: "\(account.cloud) \(identity)", fix: nil)
        case .signedOut(let fix):
            return PreflightCheck(name: name, ok: false, detail: "\(account.cloud): signed out", fix: fix)
        case .unavailable(let why):
            return PreflightCheck(name: name, ok: false, detail: "\(account.cloud): \(why)", fix: "Settings → Cloud → Set up…")
        }
    }

    /// Region, instance type and quota in one call: a type the region does not offer fails
    /// here, naming both. Nil `account` means it was not signed in, so nothing can be asked.
    static func quota(_ plan: InfraLaunchPlan, account: CloudAccount?) async -> PreflightCheck {
        guard let region = plan.config.region, let type = plan.config.instanceType else {
            return PreflightCheck(name: "quota", ok: true, detail: "not checked: the module chooses its own machine", fix: nil)
        }
        guard let account else {
            return PreflightCheck(name: "quota", ok: false, detail: "not checked until the account is signed in", fix: nil)
        }
        do {
            let q = try await account.quota(region: region, instanceType: type)
            let detail = "\(type) in \(region): \(format(q.have)) available, \(format(q.need)) needed"
            return PreflightCheck(name: "quota", ok: q.ok, detail: detail,
                                  fix: q.ok ? nil : q.increaseURL.map { "Request more at \($0.absoluteString)" } ?? "Request a quota increase in the cloud console.")
        } catch CloudAccountError.unsupportedInstanceType {
            return PreflightCheck(name: "quota", ok: true, detail: "not checked: no known quota for \(type)", fix: nil)
        } catch CloudAccountError.failed(let why) {
            return PreflightCheck(name: "quota", ok: false, detail: why, fix: "Check region and instance_type in [infra.\(plan.name)].")
        } catch {
            return PreflightCheck(name: "quota", ok: false, detail: "\(error)", fix: nil)
        }
    }

    static func network(_ mode: TailnetMode) -> PreflightCheck {
        switch mode {
        case .available(let client):
            return PreflightCheck(name: "network", ok: true, detail: "tailnet mode on \(client.tailnet)", fix: nil)
        case .notRunning:
            return PreflightCheck(name: "network", ok: true, detail: "public mode: hostd's port open to this Mac's address only", fix: nil)
        case .notConfigured(let tailnet):
            return PreflightCheck(name: "network", ok: true,
                                  detail: "public mode: Tailscale is running on \(tailnet) but not set up for Flight Deck",
                                  fix: "Settings → Cloud → Set up… to use tailnet mode")
        case .mismatch(let local, let client):
            return PreflightCheck(name: "network", ok: false,
                                  detail: "this Mac is on \(local) but the stored Tailscale client is for \(client)",
                                  fix: "Switch Tailscale back to \(client), or set Tailscale up again in Settings → Cloud.")
        }
    }

    // MARK: - AWS permissions

    /// Every IAM action the AWS preset and the checks around it use: create and destroy, the
    /// data sources' lookups, the console on an enroll timeout, prices and quotas.
    static let awsIAMActions = [
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:Describe*", "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress", "ec2:CreateTags", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeSubnets",
        "ec2:DescribeVpcs", "ec2:GetConsoleOutput", "pricing:GetProducts", "servicequotas:GetServiceQuota",
    ]

    static var awsIAMFix: String {
        "Grant the AWS identity these IAM actions: \(awsIAMActions.joined(separator: ", "))."
    }

    /// The fix for a recorded failure: the IAM list when AWS refused for permissions.
    static func fix(forFailure failure: String) -> String? {
        ["UnauthorizedOperation", "AccessDenied", "is not authorized to perform"].contains(where: failure.contains)
            ? awsIAMFix : nil
    }

    // MARK: - Formatting

    static func usd(_ x: Double) -> String { String(format: "$%.2f", x) }

    private static func format(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }

    private static func describe(_ source: InfraConfig.Source) -> String {
        switch source {
        case .preset(let p): "preset \(p)"
        case .module(let m): "module \(m)"
        }
    }
}
