#if DEBUG
import AppKit
import SwiftUI
import IntakeKit

/// Fixture readings for the capacity UI test (L3-U §8). `-FlightControlUsageFixture YES` is
/// honored only together with `-FlightDeckResetState YES`, so it can never touch a real deck's
/// accounts. It *replaces* the seeded accounts: in reset mode those are read from `$HOME` and
/// carry real email addresses, which must never land in a screenshot.
@MainActor
enum UsageFixture {
    static let workID = UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!
    static let spareID = UUID(uuidString: "F1000000-0000-0000-0000-000000000002")!
    static let codexID = UUID(uuidString: "F1000000-0000-0000-0000-000000000003")!

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState") && UserDefaults.standard.bool(forKey: "FlightControlUsageFixture")
    }

    static var isGalleryRequested: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState") && UserDefaults.standard.bool(forKey: "FlightControlMeterGallery")
    }

    static func install(into usage: UsageService, preferences: PreferencesStore, now: Date = Date()) {
        let root = URL(fileURLWithPath: "/tmp/fd-usage-fixture", isDirectory: true)
        preferences.preferences.accounts = [
            AgentAccount(id: workID, agent: .claude, displayName: "Work", home: root.appendingPathComponent("claude-work")),
            AgentAccount(id: spareID, agent: .claude, displayName: "Spare", home: root.appendingPathComponent("claude-spare")),
            AgentAccount(id: codexID, agent: .codex, displayName: "Codex", home: root.appendingPathComponent("codex")),
        ]
        usage.reconfigure()
        let refs = preferences.preferences.accounts.map(CapacityPreferences.accountRef)
        usage.ingest(UsageReading(account: refs[0],
                                  windows: [UsageWindow(name: "five_hour", utilization: 0.82, resetsAt: now.addingTimeInterval(2 * 3600)),
                                            UsageWindow(name: "seven_day", utilization: 0.31, resetsAt: now.addingTimeInterval(3 * 86_400))],
                                  readAt: now.addingTimeInterval(-180), source: "claude status line", hardRejection: false))
        usage.ingest(UsageReading(account: refs[2],
                                  windows: [UsageWindow(name: "five_hour", utilization: 0.97, resetsAt: now.addingTimeInterval(3600)),
                                            UsageWindow(name: "seven_day", utilization: 0.40, resetsAt: now.addingTimeInterval(5 * 86_400))],
                                  readAt: now.addingTimeInterval(-60), source: "codex app-server", hardRejection: false))
        // Spare gets no reading: the grey "no reading" bar.
    }
}

/// The pool popover and the sidebar row meter, hosted on their own because L3-S mounts them in
/// the header and the row only at integration — the UI test still has to see them drawn.
struct MeterGallery: View {
    @ObservedObject var usage: UsageService

    var body: some View {
        let _ = usage.revision
        let now = Date()
        VStack(alignment: .leading, spacing: 16) {
            Text("Pool popover").font(.headline)
            PoolMeterList(pools: MeterFormatter.pools(usage.ledger, now: now))
                .padding(12).frame(width: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gallery-popover")
            Text("Sidebar rows").font(.headline)
            HStack { Text("Codex tab"); Spacer(); RowMiniMeter(model: MeterFormatter.rowMeter(account: UsageFixture.codexID, ledger: usage.ledger, now: now)) }
                .frame(width: 260)
            HStack { Text("Spare tab"); Spacer(); RowMiniMeter(model: MeterFormatter.rowMeter(account: UsageFixture.spareID, ledger: usage.ledger, now: now)) }
                .frame(width: 260)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 440)
    }
}

enum MeterGalleryWindow {
    @MainActor
    static func show(usage: UsageService) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Meter Gallery"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeterGallery(usage: usage))
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
#endif
