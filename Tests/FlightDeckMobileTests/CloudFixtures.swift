import FleetKit
import Foundation

/// Seeded clouds for the cloud pane's tests and render harness. All times hang off one `now`,
/// so the extrapolated figures are exact.
enum CloudFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func machine(
        _ name: String, state: String = "ready", cloud: String = "aws", type: String = "g5.xlarge",
        region: String = "us-east-1", network: String = "tailnet", hourly: Double? = 1.2, spent: Double = 3.0,
        up: TimeInterval = 2.5 * 3600, left: TimeInterval = 5.5 * 3600, own: TimeInterval? = nil, failure: String? = nil
    ) -> WireCloudMachine {
        WireCloudMachine(
            name: name, cloud: cloud, instanceType: type, region: region, state: state, network: network,
            hourlyUsd: hourly, spentUsd: spent, createdAt: now.addingTimeInterval(-up),
            deadline: now.addingTimeInterval(left), machineDeadline: own.map { now.addingTimeInterval($0) },
            failure: failure)
    }

    /// Two machines (one ready, one provisioning), the budget 72% used.
    static var healthy: WireSessionCloud {
        WireSessionCloud(
            asOf: now, machines: [
                machine("gpu-train", own: 9 * 3600),
                machine("build-box", state: "provisioning", type: "c7i.2xlarge", region: "eu-west-1",
                        network: "public", hourly: 0.36, spent: 0.1, up: 240, left: 2 * 3600, own: 2 * 3600 + 60),
            ],
            spentUsd: 3.1, hourlyUsd: 1.56, budgetCapUsd: 4.3,
            budgetSince: now.addingTimeInterval(-3 * 3600), budgetExhaustsAt: now.addingTimeInterval(45 * 60),
            monthUsd: 41.5, monthCapUsd: 200)
    }

    /// One failed machine, the budget used up, no monthly cap.
    static var failed: WireSessionCloud {
        WireSessionCloud(
            asOf: now, machines: [
                machine("gpu-train", state: "failed", hourly: 1.2, spent: 5.4, up: 5 * 3600, left: 600,
                        failure: "enrolling timed out: the machine never said hello. Run `flightdeck infra down gpu-train`."),
            ],
            spentUsd: 5.4, hourlyUsd: 0, budgetCapUsd: 5, budgetSince: now.addingTimeInterval(-5 * 3600),
            budgetExhaustsAt: now.addingTimeInterval(-60), monthUsd: 88.2)
    }

    /// Machines but no budget.
    static var unbudgeted: WireSessionCloud {
        WireSessionCloud(asOf: now, machines: [machine("scratch")], spentUsd: 0.5, hourlyUsd: 1.2,
                         monthUsd: 12, monthCapUsd: 100)
    }
}
