import FleetKit
import OSLog
import SwiftUI

/// Where the user arms pairing, sees who is attached, and revokes.
///
/// The list and the attached indicator are not polish: §11 of the fleet spec is explicit
/// that a paired phone is fully privileged, and these two controls are the only place the
/// user can see or undo that.
///
/// Shaped like the rest of this window: a grouped `Form`, a section header, the list carrying
/// its own rows, and a caption beneath explaining what the list means. What it used to be was
/// a bare push button floating above a bare `List`, with the empty-state sentence centred in
/// the middle of an otherwise blank pane, which is a shape no other tab here uses.
///
/// Revoking is a per-row button and NOT a `−` under the list operating on `List` selection,
/// which is what it was for one revision and which shipped inert. The `−` was enabled, its
/// action ran, and `selectedDevice` was `nil` — the row highlighted, but `List(selection:)`
/// never delivered that to the binding, so the button assigned `nil` to `pendingRevocation`
/// and a dialog keyed on it being non-`nil` correctly presented nothing. Nothing about the
/// presentation was wrong; it was never asked to present.
///
/// The lesson taken is not "wire the selection up more carefully". It is that the most
/// security-relevant control in the app should not depend on a binding that can fail silently
/// while still looking right. A row's own button closes over its own `device`, so it cannot be
/// nil, and the failure mode is structurally unavailable rather than merely fixed. That is
/// also the shape `ShellSettingsTab` and `CodexOptionsForm` already use for removing a row
/// from a `Form` — a borderless `minus.circle` on the row — so it is the house pattern too.
struct DevicesSettingsTab: View {
    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var service: FleetService

    /// Both the sheet's presentation and its content. See the `.sheet(item:)` below.
    @State private var pairingWindow: ArmedPairing?
    @State private var armError: String?
    @State private var pendingRevocation: PairedDevice?
    @State private var editingSlot: UUID?
    @State private var editingName = ""

    /// Provisional slots are an open pairing window, not a paired device — they belong on
    /// the sheet's countdown, not in a list the user reads as "who can reach this Mac".
    private var devices: [PairedDevice] {
        preferences.pairedDevices.filter { !$0.isProvisional }
    }

    var body: some View {
        Form {
            Section("Paired Devices") {
                VStack(alignment: .leading, spacing: 4) {
                    List {
                        if devices.isEmpty {
                            // In the list rather than centred in the pane: the box is the
                            // thing that is empty, and this is the sentence that says so.
                            Text("No devices paired. Flight Deck is not reachable from any other device.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("devices-empty")
                        } else {
                            ForEach(devices) { device in
                                row(for: device)
                            }
                        }
                    }
                    .frame(height: listHeight)
                    .accessibilityIdentifier("devices-list")

                    HStack(spacing: 4) {
                        Button {
                            arm()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Pair a Device…")
                        .accessibilityIdentifier("devices-pair-button")

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)

                    if let armError {
                        Text(armError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("devices-arm-error")
                    }

                    Text("A paired device can see every session on this Mac and act on it. Double-click a name to rename it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Blocked Prompts") {
                // Off by default — see `PreferencesStore.allowsBlockedPromptAbort`. This is
                // the only place the switch is surfaced; nothing reads it yet, so turning it
                // on today changes nothing until a later build ships the command it gates.
                Toggle(
                    "Allow phones to dismiss unreadable dialogs",
                    isOn: Binding(
                        get: { preferences.allowsBlockedPromptAbort },
                        set: { preferences.allowsBlockedPromptAbort = $0 }
                    )
                )
                .accessibilityIdentifier("prefs-allows-blocked-prompt-abort")

                Text("When Flight Deck cannot tell what a session is waiting on, a paired phone may send Escape without knowing which prompt it is answering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // `.sheet(item:)`, not `.sheet(isPresented:)` with a companion optional. The latter
        // presents on the boolean and renders whatever the optional happens to be at that
        // moment — which was `nil`, so the sheet opened as an empty 200pt box with no content
        // and no way out. Keying on the value makes "there is a window" and "the sheet is up"
        // the same fact rather than two that can disagree.
        .sheet(item: $pairingWindow) { window in
            PairingCodeSheet(service: service, preferences: preferences, window: window)
        }
        // Title, then message — the shape every other confirmation in this window uses. The
        // whole consequence used to be crammed into the title, where macOS renders it as a
        // wall of bold text with no question in it.
        .confirmationDialog(
            "Revoke “\(pendingRevocation?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            presenting: pendingRevocation
        ) { device in
            Button("Revoke", role: .destructive) { revoke(device) }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: { device in
            Text("\(device.name) will stop receiving your sessions immediately and will have to be paired again.")
        }
    }

    /// Sized to its contents, capped, exactly as `AccountsSection` sizes its own listbox: one
    /// paired phone is the common case and a fixed box left most of it empty, while a fleet of
    /// them scrolls rather than pushing the caption out of the section.
    private static let rowHeight: CGFloat = 24

    private var listHeight: CGFloat {
        // Two rows' worth when empty — the empty-state sentence wraps, and a one-row box
        // would truncate the half of it that names the consequence.
        let rows = devices.isEmpty ? 2 : min(devices.count, 6)
        return CGFloat(rows) * Self.rowHeight + 8
    }

    /// Double-click to rename, the way an account renames — and it can be that now, because
    /// nothing on this row competes with a click any more. While revoking read `List`
    /// selection, this gesture and the selection it needed were after the same click.
    ///
    /// The revoke button closes over `device`. That is the whole point of it being here: there
    /// is no intermediate binding to be out of date, empty, or quietly not wired, so the
    /// button either runs with this row's device or does not run at all. `minus.circle` rather
    /// than a red `Revoke`, matching `ShellSettingsTab` and `CodexOptionsForm`, so the pane
    /// still reads as a list of who can reach this Mac rather than a column of delete buttons.
    @ViewBuilder
    private func row(for device: PairedDevice) -> some View {
        HStack(spacing: 6) {
            if editingSlot == device.slot {
                TextField("Name", text: $editingName, onCommit: { commitRename(device) })
                    .textFieldStyle(.plain)
                    .onExitCommand { editingSlot = nil }
            } else {
                Text(device.name)
                    .onTapGesture(count: 2) { beginRename(device) }
            }

            Spacer()

            if service.attachedSlots.contains(device.slot) {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(lastSeenText(for: device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                pendingRevocation = device
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Revoke \(device.name)")
            .accessibilityIdentifier("device-revoke-\(device.slot.uuidString)")
        }
    }

    private func lastSeenText(for device: PairedDevice) -> String {
        guard let lastSeenAt = device.lastSeenAt else { return "Never connected" }
        return lastSeenAt.formatted(.relative(presentation: .named))
    }

    private func beginRename(_ device: PairedDevice) {
        editingSlot = device.slot
        editingName = device.name
    }

    private func commitRename(_ device: PairedDevice) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            preferences.renameDevice(slot: device.slot, to: trimmed)
        }
        editingSlot = nil
    }

    private func arm() {
        armError = nil
        Task {
            do {
                pairingWindow = try await service.arm()
            } catch {
                // `arm()` refuses rather than handing out a code with `host:0` endpoints —
                // see `FleetService.arm`. Say so instead of the sheet silently not opening.
                armError = "Flight Deck could not open a listener, so this Mac cannot be paired right now."
            }
        }
    }

    private func revoke(_ device: PairedDevice) {
        preferences.revokeDevice(slot: device.slot)
        pendingRevocation = nil
        if editingSlot == device.slot { editingSlot = nil }
        armError = nil
        Task {
            do {
                try await service.reloadKeys()
            } catch {
                // The device is already gone from `preferences.pairedDevices`, so the list is
                // correct — but a listener that failed to restart is still running with its
                // old key set, which means it may keep accepting this device until relaunch.
                // Silently swallowing that (the old `try?`) let the UI claim revocation was
                // total when it might not have been.
                Self.logger.error(
                    "revoke failed to reload the listener's key set: \(error.localizedDescription, privacy: .public)"
                )
                armError =
                    "\(device.name) was removed from the list, but Flight Deck could not restart its listener — this Mac may still accept it until Flight Deck restarts."
            }
        }
    }
}
