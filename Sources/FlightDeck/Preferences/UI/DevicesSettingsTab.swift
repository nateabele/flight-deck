import FleetKit
import OSLog
import SwiftUI

/// Where the user arms pairing, sees who is attached, and revokes.
///
/// The list and the attached indicator are not polish: §11 of the fleet spec is explicit
/// that a paired phone is fully privileged, and these two controls are the only place the
/// user can see or undo that.
///
/// Shaped like `AccountsSection` and the Tools tab's list, because it is the same thing they
/// are: a listbox of records you add to and remove from, its two affordances in a `+`/`−` bar
/// directly under the list, and a caption beneath explaining the rule the list obeys — all of
/// it inside the one grouped `Form` a macOS settings pane is supposed to be. What it used to
/// be was a bare push button floating above a bare `List`, with the empty-state sentence
/// centred in the middle of an otherwise blank pane, which is a shape no other tab here uses.
struct DevicesSettingsTab: View {
    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var service: FleetService

    /// Both the sheet's presentation and its content. See the `.sheet(item:)` below.
    @State private var pairingPayload: PairingPayload?
    @State private var armError: String?
    @State private var pendingRevocation: PairedDevice?
    @State private var selection: UUID?
    @State private var editingSlot: UUID?
    @State private var editingName = ""

    /// Provisional slots are an open pairing window, not a paired device — they belong on
    /// the sheet's countdown, not in a list the user reads as "who can reach this Mac".
    private var devices: [PairedDevice] {
        preferences.pairedDevices.filter { !$0.isProvisional }
    }

    /// What `−` acts on. Read fresh from `devices` rather than held alongside the selection,
    /// so a slot revoked from under it — or one that went provisional — can never be the
    /// thing the button reports on.
    private var selectedDevice: PairedDevice? {
        devices.first { $0.slot == selection }
    }

    var body: some View {
        Form {
            Section("Paired Devices") {
                VStack(alignment: .leading, spacing: 4) {
                    List(selection: $selection) {
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
                                    .tag(device.slot)
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

                        // Revoking lives HERE, under the list, and not on the row. It is the
                        // destructive half of the same pair the `+` opens, which is where
                        // `AccountsSection` and the Tools tab both put it — and a red
                        // `Revoke` repeated down every row made the pane read as a list of
                        // things to delete rather than a list of who can reach this Mac. It
                        // also put a destructive control one stray click from a rename field.
                        Button {
                            pendingRevocation = selectedDevice
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedDevice == nil)
                        .help("Revoke the selected device")
                        .accessibilityIdentifier("devices-revoke")

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
        }
        .formStyle(.grouped)
        // `.sheet(item:)`, not `.sheet(isPresented:)` with a companion optional. The latter
        // presents on the boolean and renders whatever the optional happens to be at that
        // moment — which was `nil`, so the sheet opened as an empty 200pt box with no content
        // and no way out. Keying on the value makes "there is a payload" and "the sheet is up"
        // the same fact rather than two that can disagree.
        .sheet(item: $pairingPayload) { payload in
            PairingCodeSheet(service: service, preferences: preferences, payload: payload)
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

    /// Double-click to rename, the way an account renames. The name used to be a live
    /// `TextField` filling the row, which meant the row could not be *selected* by clicking
    /// the only part of it worth clicking — a problem it did not have while every row carried
    /// its own Revoke button, and one the `−` button would have inherited.
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
                pairingPayload = try await service.arm()
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
        if selection == device.slot { selection = nil }
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
