import FleetKit
import OSLog
import SwiftUI

/// Where the user arms pairing, sees who is attached, and revokes.
///
/// The list and the attached indicator are not polish: §11 of the fleet spec is explicit
/// that a paired phone is fully privileged, and these two controls are the only place the
/// user can see or undo that.
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

    /// Provisional slots are an open pairing window, not a paired device — they belong on
    /// the sheet's countdown, not in a list the user reads as "who can reach this Mac".
    private var devices: [PairedDevice] {
        preferences.pairedDevices.filter { !$0.isProvisional }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Pair a Device…") { arm() }
                    .accessibilityIdentifier("devices-pair-button")
                Spacer()
            }

            if let armError {
                Text(armError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if devices.isEmpty {
                Spacer()
                Text("No devices paired. Flight Deck is not reachable from any other device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("devices-empty")
                Spacer()
            } else {
                List(devices) { device in
                    DeviceRow(
                        device: device,
                        isConnected: service.attachedSlots.contains(device.slot),
                        onRename: { preferences.renameDevice(slot: device.slot, to: $0) },
                        onRevoke: { pendingRevocation = device }
                    )
                }
                .accessibilityIdentifier("devices-list")
            }
        }
        .padding(20)
        // `.sheet(item:)`, not `.sheet(isPresented:)` with a companion optional. The latter
        // presents on the boolean and renders whatever the optional happens to be at that
        // moment — which was `nil`, so the sheet opened as an empty 200pt box with no content
        // and no way out. Keying on the value makes "there is a payload" and "the sheet is up"
        // the same fact rather than two that can disagree.
        .sheet(item: $pairingPayload) { payload in
            PairingCodeSheet(service: service, preferences: preferences, payload: payload)
        }
        .alert(
            "Revoke \(pendingRevocation?.name ?? "")? It will stop receiving your sessions immediately and will have to be paired again.",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            presenting: pendingRevocation
        ) { device in
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
            Button("Revoke", role: .destructive) { revoke(device) }
        }
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

private struct DeviceRow: View {
    let device: PairedDevice
    let isConnected: Bool
    let onRename: (String) -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack {
            TextField(
                "Name",
                text: Binding(get: { device.name }, set: onRename)
            )
            .textFieldStyle(.plain)
            .frame(minWidth: 140, alignment: .leading)

            Spacer()

            if isConnected {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(lastSeenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Revoke", role: .destructive, action: onRevoke)
                .buttonStyle(.borderless)
        }
    }

    private var lastSeenText: String {
        guard let lastSeenAt = device.lastSeenAt else { return "Never connected" }
        return lastSeenAt.formatted(.relative(presentation: .named))
    }
}
