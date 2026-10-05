import SwiftUI

/// The machines this Mac can run agents on: every paired host, how its link is doing, and
/// "Add Host…". Shaped like `DevicesSettingsTab` — a grouped `Form`, the list carrying its own
/// rows and empty state, a `+` under it and a caption beneath.
struct HostsSettingsTab: View {
    @ObservedObject var hostService: HostService

    @State private var addingHost = false
    @State private var pendingForget: HostRecord?

    private static let rowHeight: CGFloat = 28

    var body: some View {
        // Read through `hostService`, which publishes on every link change, pairing and
        // forget: the registry itself is not observable.
        let hosts = hostService.registry.hosts
        Form {
            Section("Paired Hosts") {
                VStack(alignment: .leading, spacing: 4) {
                    List {
                        if hosts.isEmpty {
                            Text("No hosts paired. Agents run only on this Mac.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("hosts-empty")
                        } else {
                            ForEach(hosts) { host in
                                HostRow(record: host, status: hostService.statuses[host.slot])
                                    .contextMenu {
                                        Button("Forget “\(host.name)”…") { pendingForget = host }
                                    }
                            }
                        }
                    }
                    // Sized to its contents and capped, as `DevicesSettingsTab` sizes its own.
                    .frame(height: CGFloat(hosts.isEmpty ? 2 : min(hosts.count, 6)) * Self.rowHeight + 8)
                    .accessibilityIdentifier("hosts-list")

                    HStack(spacing: 4) {
                        Button {
                            addingHost = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add Host…")
                        .accessibilityIdentifier("hosts-add-button")

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)

                    Text("A paired host runs agents for this Mac. Control-click a host to forget it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingHost) {
            AddHostSheet(hostService: hostService)
        }
        .confirmationDialog(
            "Forget “\(pendingForget?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { host in
            Button("Forget", role: .destructive) {
                hostService.forget(slot: host.slot)
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: { host in
            // Says what forgetting does NOT do: the host keeps this Mac's slot until someone
            // revokes it there, and a user who thinks forgetting revoked it is wrong.
            Text("This Mac will stop connecting to \(host.name). To remove this Mac from \(host.name) as well, revoke it in that host's Hosting settings.")
        }
    }
}

/// One host: a status dot, its name and platform, and what the link last said.
struct HostRow: View {
    let record: HostRecord
    /// nil before `HostService.start()` has listed the host, which reads as offline.
    let status: HostLinkState?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(record.name)

            if let platform = record.platform {
                Text(platform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(detail)
                .font(.caption)
                .foregroundStyle(isRefused ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host-row-\(record.slot.uuidString)")
    }

    private var isRefused: Bool {
        if case .refused = status { return true }
        return false
    }

    private var dotColor: Color {
        switch status {
        case .online: return .green
        case .connecting: return .yellow
        case .refused: return .red
        case .offline, nil: return .gray
        }
    }

    private var detail: String {
        switch status {
        case .online: return "Connected"
        case .connecting: return "Connecting…"
        case .refused(let reason): return reason
        case .offline(let lastSeen): return Self.lastSeenText(lastSeen ?? record.lastSeenAt)
        case nil: return Self.lastSeenText(record.lastSeenAt)
        }
    }

    private static func lastSeenText(_ date: Date?) -> String {
        guard let date else { return "Never connected" }
        return "Last seen \(date.formatted(.relative(presentation: .named)))"
    }
}
