import HostKit
import ServiceManagement
import SwiftUI

/// Lets other Flight Decks run agents on this Mac: the hostd LaunchAgent's switch, its
/// status, pairing a controller, and the controllers already paired. Shaped like
/// `DevicesSettingsTab`, which is the same job for phones.
struct HostingSettingsTab: View {
    @ObservedObject var controller: HostingController

    @State private var pendingRevocation: AdminController?

    private static let rowHeight: CGFloat = 24

    var body: some View {
        Form {
            Section("This Mac as a Host") {
                Toggle("Let other Macs use this Mac", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .accessibilityIdentifier("hosting-enabled")

                statusLine

                Text("The host runs while you're logged in. It stops when you log out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Controllers") {
                VStack(alignment: .leading, spacing: 4) {
                    List {
                        if controller.controllers.isEmpty {
                            Text("No controllers paired. No other Mac can run agents here.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("hosting-controllers-empty")
                        } else {
                            ForEach(controller.controllers, id: \.slot) { row(for: $0) }
                        }
                    }
                    .frame(height: listHeight)
                    .accessibilityIdentifier("hosting-controllers")

                    HStack(spacing: 4) {
                        Button {
                            controller.arm()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Pair a Controller…")
                        .disabled(!isRunning)
                        .accessibilityIdentifier("hosting-pair-button")

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)

                    if let error = controller.actionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("hosting-action-error")
                    }

                    Text("A paired controller can run agents on this Mac as you, in any folder you can open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        // `.task` rather than a `Timer.publish`, because it is cancelled when the tab goes
        // away: the 2 s admin poll runs only while someone is looking at it, never behind a
        // closed Settings window.
        .task {
            while !Task.isCancelled {
                await controller.refresh().value
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: Binding(
            get: { controller.armed != nil },
            set: { if !$0 { controller.cancelArm() } }
        )) {
            if let armed = controller.armed {
                ControllerPairingSheet(controller: controller, code: armed.code,
                                       expiresAt: armed.expiresAt)
            }
        }
        .confirmationDialog(
            "Revoke “\(pendingRevocation?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            presenting: pendingRevocation
        ) { paired in
            Button("Revoke", role: .destructive) {
                controller.revoke(slot: paired.slot)
                pendingRevocation = nil
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: { paired in
            Text("\(paired.name) will be disconnected immediately and will have to be paired again.")
        }
    }

    private var isRunning: Bool {
        if case .on = controller.state { return true }
        return false
    }

    private var listHeight: CGFloat {
        let rows = controller.controllers.isEmpty ? 2 : min(controller.controllers.count, 6)
        return CGFloat(rows) * Self.rowHeight + 8
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.state {
        case .off:
            status("Off. Other Macs cannot reach this Mac.", color: .secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                status("Starting…", color: .secondary)
            }
        case .on(let paired, let port):
            status(Self.runningText(paired: paired, port: port), color: .secondary)
        case .needsApproval:
            HStack(spacing: 8) {
                status("Waiting for approval in System Settings → General → Login Items", color: .orange)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .accessibilityIdentifier("hosting-open-login-items")
            }
        case .notRunning:
            status("Host service is not running", color: .red)
        case .failed(let message):
            status(message, color: .red)
        }
    }

    private func status(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("hosting-status")
    }

    /// "Running on port 47410 · 2 controllers".
    static func runningText(paired: Int, port: Int?) -> String {
        let count = paired == 1 ? "1 controller" : "\(paired) controllers"
        guard let port else { return "Running · \(count)" }
        return "Running on port \(port) · \(count)"
    }

    @ViewBuilder
    private func row(for paired: AdminController) -> some View {
        HStack(spacing: 6) {
            Text(paired.name)
            Spacer()
            Text("Paired \(paired.pairedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The row's own button, closing over its own controller — see
            // `DevicesSettingsTab.row(for:)` for why revoke never reads `List` selection.
            Button {
                pendingRevocation = paired
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Revoke \(paired.name)")
            .accessibilityIdentifier("hosting-revoke-\(paired.slot.uuidString)")
        }
    }
}

/// The code a controller types into its own Add Host sheet, and its countdown.
///
/// Closes itself when the controller clears `armed`: a controller that paired grows the
/// host's count, and a window that expired or was taken stops being held — either way the
/// code on screen no longer works.
struct ControllerPairingSheet: View {
    @ObservedObject var controller: HostingController
    let code: String
    let expiresAt: Date

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remainingSeconds: Int { max(0, Int(expiresAt.timeIntervalSince(now).rounded())) }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a controller")
                .font(.title2.bold())

            if let name = controller.hostName {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Load-bearing `.fixedSize`, as on `PairingCodeSheet`: a sheet is sized once from
            // its content's ideal height, and a wrapping label's is one line, so the security
            // half of this sentence would be the half truncated.
            Text("On the other Mac, open Settings → Hosts, click + under Paired Hosts, and type this code. Anyone who can see it can run agents on this Mac until you revoke them.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)

            // Same treatment as the phone code: large, fixed-width so the groups line up,
            // and tracked apart so `8` and `B` read apart from across a room.
            Text(code)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .tracking(2)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
                .accessibilityIdentifier("hosting-pairing-code")

            Text(String(format: "Expires in %d:%02d", remainingSeconds / 60, remainingSeconds % 60))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("hosting-pairing-countdown")

            Button("Cancel") { controller.cancelArm() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hosting-pairing-cancel")
        }
        .padding(24)
        .frame(width: 380)
        .onReceive(timer) { tick in
            now = tick
            // The hostd stops answering at `expiresAt` on its own; this only stops showing it.
            if remainingSeconds == 0 { controller.cancelArm() }
        }
    }
}
