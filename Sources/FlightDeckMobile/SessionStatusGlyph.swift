import FleetKit
import SwiftUI

/// The sidebar's status vocabulary, on the phone.
///
/// `nil` activity renders **nothing**, which is not the same as idle: no glyph means no
/// agent process is registered for that tab, while a dot means one is running and quiet.
/// Collapsing the two would make every dead tab look alive.
struct SessionStatusGlyph: View {
    let session: WireSession

    var body: some View {
        switch session.activity {
        case nil:
            Color.clear.frame(width: 14, height: 14)
        case "idle":
            Circle().fill(.secondary).frame(width: 6, height: 6).frame(width: 14)
        case "busy":
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                if session.subagentCount > 0 {
                    Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                }
            }
        case "shell":
            Image(systemName: "terminal.fill").font(.caption)
        case "waiting":
            Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
        default:
            // An activity this build does not know about still renders as *something*,
            // for the same reason `WireSession.agent` is a String: the Mac may be newer.
            Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}
