import Foundation
import HostKit

/// Settings → Cloud (spec §3.2): which account each cloud uses, the region the setup sheet's
/// quota check and test machine use, and the budget and guardrails of §8. Never in a repo: a
/// repo asks, these decide.
///
/// Stored as `Preferences.cloud`, so it rides the one `preferences.v1` blob every other tab
/// uses. Every field decodes leniently: a blob written by a build with fewer fields here must
/// keep the user's budget rather than reset it to the defaults.
struct CloudPreferences: Codable, Equatable {
    /// nil is the AWS CLI's default credential chain.
    var awsProfile: String?
    /// nil is gcloud's configured default project.
    var gcpProject: String?
    var awsRegion: String
    var gcpRegion: String
    var budget: BudgetSettings

    static let defaultAWSRegion = "us-east-1"
    static let defaultGCPRegion = "us-central1"

    init(awsProfile: String? = nil, gcpProject: String? = nil, awsRegion: String = Self.defaultAWSRegion,
         gcpRegion: String = Self.defaultGCPRegion, budget: BudgetSettings = .default) {
        self.awsProfile = awsProfile
        self.gcpProject = gcpProject
        self.awsRegion = awsRegion
        self.gcpRegion = gcpRegion
        self.budget = budget
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(awsProfile: try c.decodeIfPresent(String.self, forKey: .awsProfile),
                  gcpProject: try c.decodeIfPresent(String.self, forKey: .gcpProject),
                  awsRegion: try c.decodeIfPresent(String.self, forKey: .awsRegion) ?? Self.defaultAWSRegion,
                  gcpRegion: try c.decodeIfPresent(String.self, forKey: .gcpRegion) ?? Self.defaultGCPRegion,
                  budget: (try? c.decodeIfPresent(BudgetSettings.self, forKey: .budget)) ?? .default)
    }

    /// By cloud, as the setup sheet asks for them.
    var regions: [String: String] { ["aws": awsRegion, "gcp": gcpRegion] }
}
