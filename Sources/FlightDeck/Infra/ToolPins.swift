import Foundation

/// The external CLIs cloud infra drives. Each is used from the user's own install when that is
/// a compatible version, and otherwise (except Tailscale) from a pinned copy Flight Deck fetches
/// itself — spec §4.
enum InfraTool: String, CaseIterable, Sendable {
    case tofu, aws, gcloud, tailscale
}

/// `major.minor[.patch]`, enough to compare tool versions. A missing patch reads as 0, because
/// Tailscale and gcloud have both printed two-component versions in the past.
struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major, minor, patch: Int

    /// `"v1.8.3"`, `"495.0.0"`, `"1.70"`. Anything else — including a bare major — is nil, so a
    /// banner the extractor misread can never pass as a version.
    static func parse(_ s: String) -> SemVer? {
        var text = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard numbers.count == parts.count else { return nil }
        return SemVer(major: numbers[0], minor: numbers[1], patch: numbers.count == 3 ? numbers[2] : 0)
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// One tool's compatible range and, where Flight Deck may provision it, the exact release to
/// fetch and the checksum it must match.
struct ToolPin: Sendable {
    let tool: InfraTool
    /// Inclusive lower bound.
    let minimum: SemVer
    /// Exclusive upper bound on the major version (`2` means `< 2.0.0`), or nil for none.
    let belowMajor: Int?
    /// The managed copy's version, which is also its directory under `tools/<tool>/`. Nil means
    /// Flight Deck never provisions this tool.
    let managedVersion: String?
    /// A versioned release URL, never a "latest" alias: a moving target would break the
    /// checksum on the vendor's next release.
    let assetURL: URL?
    /// Lowercase hex SHA-256 of the asset at `assetURL`, verified by downloading it once.
    let sha256: String?
    /// What prints the version banner `ToolResolver.version(in:of:)` parses.
    let versionArgs: [String]
    /// The executable's path inside the unpacked version directory.
    var managedBinary: String? = nil
    /// The managed copy must live on a path with no spaces — AWS's per-user pkg install refuses
    /// one, and "Application Support" has one — so it goes under `ToolResolver`'s
    /// `spaceFreeRoot` instead of `managedRoot`.
    var requiresSpaceFreePath = false

    func accepts(_ version: SemVer) -> Bool {
        version >= minimum && belowMajor.map { version.major < $0 } ?? true
    }

    /// `>= 1.8.0, < 2` — the wording a `.missing` message uses.
    var rangeDescription: String {
        ">= \(minimum)" + (belowMajor.map { ", < \($0)" } ?? "")
    }
}

/// Every pin, in one table so an app release updates them together (spec §4).
///
/// Each checksum below was computed with `shasum -a 256` over the asset downloaded from the
/// URL beside it on 2026-10-07; tofu's also matches the release's own `SHA256SUMS`. Never edit
/// a hash without downloading the asset: a guessed one fails every managed install, and a
/// copied-from-elsewhere one defeats the point of pinning.
enum ToolPins {
    static let all: [InfraTool: ToolPin] = [
        // The newest 1.8.x: the floor of the compatible range, so a preset written against the
        // managed copy also runs on any user install the range accepts.
        .tofu: ToolPin(
            tool: .tofu, minimum: SemVer(major: 1, minor: 8, patch: 0), belowMajor: 2,
            managedVersion: "1.8.11",
            assetURL: URL(string: "https://github.com/opentofu/opentofu/releases/download/v1.8.11/tofu_1.8.11_darwin_arm64.zip"),
            sha256: "e269244d1db1acca75d1ca813c8ddd9a419ff4f01ff3a37dff8dc0b825b3c58c",
            versionArgs: ["--version"], managedBinary: "tofu"),
        // The versioned pkg name (`AWSCLIV2-<ver>.pkg`); plain `AWSCLIV2.pkg` is always the latest.
        // Installed per user with a `customLocation` choice, which lands it in `aws-cli/` and
        // creates no symlinks: it is only ever run by the absolute path the resolver records.
        .aws: ToolPin(
            tool: .aws, minimum: SemVer(major: 2, minor: 15, patch: 0), belowMajor: 3,
            managedVersion: "2.37.10",
            assetURL: URL(string: "https://awscli.amazonaws.com/AWSCLIV2-2.37.10.pkg"),
            sha256: "6de7835fd806a86069509578b7e5a7135c803cf2e88349e7e10d6e681b89b9db",
            versionArgs: ["--version"], managedBinary: "aws-cli/aws", requiresSpaceFreePath: true),
        // The darwin-arm tarball bundles no Python, and macOS's own 3.9 is too old: the resolver
        // finds a 3.10+ one and hands it over as `CLOUDSDK_PYTHON` (`ResolvedTool.environment`).
        .gcloud: ToolPin(
            tool: .gcloud, minimum: SemVer(major: 480, minor: 0, patch: 0), belowMajor: nil,
            managedVersion: "588.0.0",
            assetURL: URL(string: "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-588.0.0-darwin-arm.tar.gz"),
            sha256: "0f580f1323d0465b11d1d7c506e701c27729e9c5ea0e1d0f855a4dc3e665db89",
            versionArgs: ["--version"], managedBinary: "google-cloud-sdk/bin/gcloud"),
        // Never provisioned: it is a system network extension the user installs themselves.
        .tailscale: ToolPin(
            tool: .tailscale, minimum: SemVer(major: 1, minor: 70, patch: 0), belowMajor: nil,
            managedVersion: nil, assetURL: nil, sha256: nil, versionArgs: ["version"]),
    ]
}
