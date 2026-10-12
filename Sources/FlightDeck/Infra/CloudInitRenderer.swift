import Foundation
import HostKit

// The user-data a cloud machine boots with (spec §5.2): close the metadata endpoint to workloads
// on every boot, arm the TTL on AWS, install hostd, enroll it with the controller's slot and
// secret, and in tailnet mode join the tailnet.

/// What `CloudInitRenderer` needs beyond the payload. `installerBaseURL` and `installerSHA256`
/// are this build's `LinuxHostInstaller` values; `deadline` is the machine's absolute TTL.
struct CloudInitOptions: Equatable, Sendable {
    var installerBaseURL: String
    var installerSHA256: String
    /// An absolute time, not a duration: the timer it becomes must mean the same instant after a
    /// reboot, which a relative `shutdown -h +N` does not survive. Rendered on AWS only.
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
        // JSON escapes these, but a name that needs them is not a name; refusing them keeps the
        // enroll line and hostd's own logs free of them.
        guard !p.controllerName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw CloudInitError.invalid(field: "controllerName")
        }
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
            // The enrollment secret is the controller's long-term PSK for this host, and user-data
            // stays readable from the metadata service for the machine's whole life, so only root
            // may reach that endpoint. bootcmd, not runcmd: firewall rules do not survive a reboot
            // and runcmd runs once per instance, while bootcmd runs as root early on every boot.
            // Nothing non-root needs the endpoint (cloud-init is root; enroll reads a file), so
            // blocking before enroll costs nothing. `|| true` keeps a missing address family (no
            // IPv6) from failing the module.
            "bootcmd:",
        ]
        lines += metadataAddresses(cloud: o.cloud).map { tool, address in
            #"  - [ sh, -c, "\#(tool) -A OUTPUT -d \#(address) -m owner ! --uid-owner 0 -j REJECT || true" ]"#
        }
        lines.append("write_files:")
        // On AWS the TTL is a persistent systemd timer on an absolute UTC deadline: a reboot
        // clears a pending `shutdown -h +N`, but an enabled timer is re-armed at boot, and
        // `Persistent` fires it at once if the deadline passed while the machine was stopped. The
        // preset turns the poweroff into a termination. Never on GCP: a guest poweroff only
        // STOPS a GCE VM (its disk keeps billing) and halts `max_run_duration`, and this deadline
        // falls before that expiry, so a timer would turn the preset's guaranteed DELETE into a
        // leak.
        let ttlTimer = o.cloud == "aws"
        if ttlTimer {
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
        }
        // root-owned until runcmd: write_files runs before the `flightdeck` user exists.
        lines += file(enrollPath, mode: "0600", [try json(p)])

        let hostd = "~/.local/bin/flightdeck-hostd"
        // `su -` from cloud-final may carry no XDG_RUNTIME_DIR, without which the installer's
        // `systemctl --user` cannot find the user manager. The uid is resolved on the machine.
        let asUser = "export XDG_RUNTIME_DIR=/run/user/$(id -u flightdeck); "
        lines.append("runcmd:")
        if ttlTimer {
            // First, before anything that can fail: a machine whose install breaks still dies.
            lines.append("  - [ systemctl, enable, --now, flightdeck-ttl.timer ]")
        }
        lines += [
            // `enroll` deletes the spent file, which takes write access to the directory too.
            #"  - [ chown, "flightdeck:flightdeck", /run/flightdeck, \#(enrollPath) ]"#,
            "  - [ loginctl, enable-linger, flightdeck ]",
            // enable-linger returns before `user@UID` is up; `start` waits for it (Type=notify),
            // so the installer's `systemctl --user` never races the manager's startup.
            #"  - [ sh, -c, "systemctl start user@$(id -u flightdeck).service" ]"#,
            #"  - [ su, "-", flightdeck, "-c", "\#(asUser)curl -fsSL \#(base)/hostd-install.sh | sh -s -- --sha256 \#(o.installerSHA256) --no-pair" ]"#,
            // Its own entry, never chained: runcmd carries on past a failing step, and the TTL
            // (AWS's timer, GCP's `max_run_duration`) covers a machine that never enrolls.
            #"  - [ su, "-", flightdeck, "-c", "\#(asUser)\#(hostd) enroll --file \#(enrollPath)" ]"#,
        ]
        if let tailnet {
            lines += [
                #"  - [ sh, -c, "curl -fsSL https://tailscale.com/install.sh | sh" ]"#,
                #"  - [ tailscale, up, "--auth-key=\#(tailnet.key)", "--hostname=\#(tailnet.host)", "--advertise-tags=tag:flightdeck-cloud" ]"#,
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The metadata endpoint's addresses, with the tool that firewalls each. AWS also serves it
    /// on IPv6 when the instance enables that; GCP's `metadata.google.internal` is the same IPv4
    /// address, so the IP rule already covers it.
    private static func metadataAddresses(cloud: String) -> [(tool: String, address: String)] {
        cloud == "gcp"
            ? [("iptables", "169.254.169.254")]
            : [("iptables", "169.254.169.254"), ("ip6tables", "fd00:ec2::254")]
    }

    /// One `write_files` entry. Contents are a YAML literal block, so each line is indented and
    /// an empty line stays empty rather than becoming trailing whitespace.
    private static func file(_ path: String, mode: String, _ content: [String]) -> [String] {
        ["  - path: \(path)", "    owner: root:root", "    permissions: '\(mode)'", "    content: |"]
            + content.map { $0.isEmpty ? "" : "      \($0)" }
    }

    /// The payload as the single line hostd's `enroll` decodes: ISO-8601 dates, sorted keys,
    /// pure ASCII. `JSONEncoder` escapes C0 controls but leaves U+0085 and U+2028/9 raw, and YAML
    /// reads those as line breaks: left alone, a controller name could end the block scalar and
    /// add keys to user-data that runs as root. So every non-ASCII scalar becomes `\uXXXX` (a
    /// surrogate pair above U+FFFF), which any JSON decoder reads back to the same string. Safe
    /// to do on the encoded text because non-ASCII can only occur inside a JSON string there.
    private static func json(_ p: EnrollmentPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = ""
        for scalar in String(decoding: try encoder.encode(p), as: UTF8.self).unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else {
                for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
            }
        }
        return out
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
