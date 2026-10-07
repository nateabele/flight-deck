import Foundation
import HostKit

// The user-data a cloud machine boots with (spec §5.2): arm the TTL, install hostd, enroll it
// with the controller's slot and secret, close the metadata endpoint to workloads, and in tailnet
// mode join the tailnet.

/// What `CloudInitRenderer` needs beyond the payload. `installerBaseURL` and `installerSHA256`
/// are this build's `LinuxHostInstaller` values; `deadline` is the machine's absolute TTL.
struct CloudInitOptions: Equatable, Sendable {
    var installerBaseURL: String
    var installerSHA256: String
    /// An absolute time, not a duration: the timer it becomes must mean the same instant after a
    /// reboot, which a relative `shutdown -h +N` does not survive.
    var deadline: Date
    /// `"aws"` or `"gcp"`.
    var cloud: String
    /// Both set for tailnet mode, both nil for public mode.
    var tailscaleAuthKey: String?
    var tailscaleHostname: String?
}

/// Every value refused, by field, so a caller can say which input was bad.
enum CloudInitError: Error, Equatable {
    case invalid(field: String)
}

/// Renders cloud-init user-data. Pure: same inputs, same bytes, which is what the golden files
/// pin.
///
/// Every interpolated value is validated against a character set that cannot leave its YAML
/// double quotes or its `sh -c` string, because user-data runs as root on first boot: a hostname
/// of `x; rm -rf /` must be refused here, not escaped and hoped for.
enum CloudInitRenderer {
    static let enrollPath = "/run/flightdeck/enroll.json"

    static func render(_ p: EnrollmentPayload, _ o: CloudInitOptions) throws -> String {
        let base = o.installerBaseURL.hasSuffix("/") ? String(o.installerBaseURL.dropLast()) : o.installerBaseURL
        guard matches(base, #"^https://[A-Za-z0-9._~:/%-]+$"#) else { throw CloudInitError.invalid(field: "installerBaseURL") }
        guard matches(o.installerSHA256, "^[0-9a-fA-F]{64}$") else { throw CloudInitError.invalid(field: "installerSHA256") }
        guard o.cloud == "aws" || o.cloud == "gcp" else { throw CloudInitError.invalid(field: "cloud") }
        // A deadline at or before issue would power the machine off before it could enroll.
        guard o.deadline > p.issuedAt else { throw CloudInitError.invalid(field: "deadline") }
        let tailnet: (key: String, host: String)?
        switch (o.tailscaleAuthKey, o.tailscaleHostname) {
        case (nil, nil):
            tailnet = nil
        case let (key?, host?):
            guard matches(key, "^[A-Za-z0-9_-]+$") else { throw CloudInitError.invalid(field: "tailscaleAuthKey") }
            guard matches(host, "^[a-z0-9-]{1,63}$") else { throw CloudInitError.invalid(field: "tailscaleHostname") }
            tailnet = (key, host)
        default:
            // Half a tailnet config would boot a public machine the user asked to keep private.
            throw CloudInitError.invalid(field: o.tailscaleAuthKey == nil ? "tailscaleAuthKey" : "tailscaleHostname")
        }

        var lines = [
            "#cloud-config",
            "users:",
            "  - default",
            "  - name: flightdeck",
            "    shell: /bin/bash",
            "    lock_passwd: true",
            "write_files:",
        ]
        // The TTL is a persistent systemd timer on an absolute UTC deadline: a reboot clears a
        // pending `shutdown -h +N`, but an enabled timer is re-armed at boot, and `Persistent`
        // fires it at once if the deadline passed while the machine was stopped. Armed on GCP
        // too, as a harmless backstop to the preset's `max_run_duration`.
        lines += file("/etc/systemd/system/flightdeck-ttl.service", mode: "0644", [
            "[Unit]",
            "Description=Power off at the Flight Deck TTL",
            "",
            "[Service]",
            "Type=oneshot",
            "ExecStart=/usr/bin/systemctl poweroff",
        ])
        lines += file("/etc/systemd/system/flightdeck-ttl.timer", mode: "0644", [
            "[Unit]",
            "Description=Flight Deck TTL deadline",
            "",
            "[Timer]",
            "OnCalendar=\(calendar(o.deadline)) UTC",
            "Persistent=true",
            "",
            "[Install]",
            "WantedBy=timers.target",
        ])
        // root-owned until runcmd: write_files runs before the `flightdeck` user exists.
        lines += file(enrollPath, mode: "0600", [try json(p)])

        let hostd = "~/.local/bin/flightdeck-hostd"
        lines += [
            "runcmd:",
            // First, before anything that can fail: a machine whose install breaks still dies.
            "  - [ systemctl, enable, --now, flightdeck-ttl.timer ]",
            // `enroll` deletes the spent file, which takes write access to the directory too.
            #"  - [ chown, "flightdeck:flightdeck", /run/flightdeck, \#(enrollPath) ]"#,
            "  - [ loginctl, enable-linger, flightdeck ]",
            #"  - [ su, "-", flightdeck, "-c", "curl -fsSL \#(base)/hostd-install.sh | sh -s -- --sha256 \#(o.installerSHA256) --no-pair" ]"#,
            // Its own entry, never chained: runcmd carries on past a failing step, and the TTL
            // already covers a machine that never enrolls.
            #"  - [ su, "-", flightdeck, "-c", "\#(hostd) enroll --file \#(enrollPath)" ]"#,
        ]
        // User-data stays readable from the metadata service for the machine's whole life, and
        // it holds the PSK: once that is spent, only root may reach the endpoint. GCP's name
        // resolves to the same address; blocking it too costs a duplicate rule.
        let metadataHosts = o.cloud == "gcp" ? ["169.254.169.254", "metadata.google.internal"] : ["169.254.169.254"]
        lines += metadataHosts.map {
            #"  - [ iptables, -A, OUTPUT, -d, \#($0), -m, owner, "!", --uid-owner, "0", -j, REJECT ]"#
        }
        if let tailnet {
            lines += [
                #"  - [ sh, -c, "curl -fsSL https://tailscale.com/install.sh | sh" ]"#,
                #"  - [ tailscale, up, "--auth-key=\#(tailnet.key)", "--hostname=\#(tailnet.host)", "--advertise-tags=tag:flightdeck-cloud" ]"#,
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One `write_files` entry. Contents are a YAML literal block, so each line is indented and
    /// an empty line stays empty rather than becoming trailing whitespace.
    private static func file(_ path: String, mode: String, _ content: [String]) -> [String] {
        ["  - path: \(path)", "    owner: root:root", "    permissions: '\(mode)'", "    content: |"]
            + content.map { $0.isEmpty ? "" : "      \($0)" }
    }

    /// The payload as the single line hostd's `enroll` decodes: ISO-8601 dates, sorted keys.
    /// JSON escapes any newline in `controllerName`, so it cannot end the YAML block early.
    private static func json(_ p: EnrollmentPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(p), as: UTF8.self)
    }

    /// `OnCalendar`'s absolute form, to the whole second; the timer cannot take a fraction.
    private static func calendar(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
