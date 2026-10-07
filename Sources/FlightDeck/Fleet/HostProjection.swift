import FleetKit
import Foundation
import HostKit

/// Paired hosts, described for `flightdeck host …`.
///
/// Pure, and separate from `FleetService`, for the reason `ClosedSessionProjection` is: the
/// wording of every refusal can be tested without a socket or a live link. `@MainActor` because
/// `HostRegistry` is.
@MainActor
enum HostProjection {
    /// One `host ls` row. A host with no state yet — the service was never started, as under a
    /// UITest reset — reads as offline, which is what it is from here.
    static func row(_ record: HostRecord, _ state: HostLinkState?) -> WireHost {
        let status: String
        var detail: String?
        switch state ?? .offline(lastSeen: record.lastSeenAt) {
        case .online: status = "online"
        case .offline: status = "offline"
        case .connecting: status = "connecting"
        case .refused(let reason):
            status = "refused"
            detail = reason
        }
        return WireHost(name: record.name, platform: record.platform, status: status,
                        detail: detail, lastSeenAt: record.lastSeenAt)
    }

    static func info(_ record: HostRecord, _ info: HostInfo) -> WireHostInfo {
        WireHostInfo(name: record.name, hostName: info.hostName, platform: info.platform,
                     osVersion: info.osVersion, arch: info.arch, hostdVersion: info.hostdVersion,
                     xcode: info.xcode, docker: info.docker, diskFreeBytes: info.diskFreeBytes,
                     idleSince: info.idleSince)
    }

    /// The `err` a failed `host.info` answers with: a stable code for scripts, and a message
    /// that says what to do about it.
    ///
    /// `registry` and `state` are read AFTER the failure, so "last seen" is as fresh as the
    /// link's own last report. A link that is not online fails a request with `.offline`
    /// whatever the reason, so `state` is what tells a refused host — one that will never come
    /// back until the user acts — from one that is merely unreachable right now.
    static func refusal(for error: Error, name: String, registry: HostRegistry,
                        state: (UUID) -> HostLinkState?, now: Date) -> (code: String, message: String) {
        if case HostLookupError.unknown(let available) = error {
            // Every paired name, in registry order, never a guess at the nearest one: see
            // `HostRegistry.resolve` for why a CLI must not pick "mini-2" for "mini".
            return ("unknown_host", available.isEmpty
                ? "no host named \(name); no hosts are paired"
                : "no host named \(name); paired: \(available.joined(separator: ", "))")
        }
        let record = try? registry.resolve(name: name).get()
        let shown = record?.name ?? name
        switch error {
        case HostLinkError.offline:
            if let record, case .refused(let reason)? = state(record.slot) {
                return ("host_refused", reason)
            }
            let seen = record?.lastSeenAt.map { "last seen \(relative($0, now: now))" } ?? "never seen"
            return ("host_offline", "\(shown) is offline (\(seen))")
        case HostLinkError.timedOut:
            return ("host_timeout", "\(shown) did not answer within \(Int(HostLink.requestTimeout))s")
        case HostLinkError.remote(let code, let message):
            // The host's own code, verbatim, as `FleetConnector` carries a Mac's: a newer
            // hostd may invent codes this build has never heard of.
            return (code, "\(shown): \(message)")
        default:
            return ("host_failed", "\(shown): \(error.localizedDescription)")
        }
    }

    /// "4m ago", in a fixed locale: the message reaches a script's stderr, and its wording
    /// should not change with the user's language settings.
    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
