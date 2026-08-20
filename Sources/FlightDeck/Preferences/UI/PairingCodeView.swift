import CoreImage
import CoreImage.CIFilterBuiltins
import FleetKit
import SwiftUI

enum PairingCodeImage {
    /// `.medium` error correction, not `.high`: the payload is near a QR version boundary
    /// and higher correction pushes it over, producing a denser code that scans *worse* on
    /// a phone held at arm's length. Scaled with nearest-neighbour so the modules stay
    /// crisp — an interpolated QR is a QR that takes three tries to read.
    static func cgImage(for code: String, size: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// The sheet "Pair a Device…" opens: the QR plus its manual-entry fallback, live for
/// `PairingArmer.window` and no longer.
///
/// The countdown reads the provisional device's `armedUntil` back out of `preferences`
/// rather than tracking a locally-computed deadline, because that timestamp — minted by
/// `PairingArmer.arm` — is the instant the listener itself will stop accepting this key. A
/// screen-only countdown that drifted from it would keep showing a live QR after the code
/// had already stopped working.
struct PairingCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: FleetService
    @ObservedObject var preferences: PreferencesStore
    let payload: PairingPayload

    /// Advanced only by the timer tick below, so the countdown text (and the expiry check
    /// that drives auto-dismiss) re-evaluates once a second without depending on
    /// `preferences` publishing on every tick.
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var armedUntil: Date? {
        preferences.pairedDevices.first { $0.slot == payload.key.slot }?.armedUntil
    }

    private var remainingSeconds: Int {
        guard let armedUntil else { return 0 }
        return max(0, Int(armedUntil.timeIntervalSince(now).rounded()))
    }

    private var countdownText: String {
        String(format: "Expires in %d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a device")
                .font(.title2.bold())

            Text(payload.macName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let cgImage = PairingCodeImage.cgImage(for: payload.encoded(), size: 320) {
                Image(decorative: cgImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .accessibilityIdentifier("pairing-code-image")
            }

            Text("Scan this in Flight Deck on your iPhone. Anyone who can see this code can control this Mac's sessions until you revoke the device. It expires in 2 minutes.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Text(countdownText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pairing-code-countdown")

            DisclosureGroup("Can't scan? Type this code instead") {
                Text(payload.encoded())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("pairing-code-text")
            }

            Button("Cancel") {
                // Explicit user cancel revokes right away — `cancelArming()` is
                // unconditional, unlike `expireArming()` below, which is a no-op until the
                // window has actually run out. Without this the provisional key would stay
                // live on the listener for the rest of the window after the user thought
                // they had backed out.
                Task { try? await service.cancelArming() }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("pairing-code-cancel")
        }
        .padding(24)
        .frame(width: 360)
        .onReceive(timer) { tick in
            now = tick
            Task { try? await service.expireArming() }
            // Covers both endings this sheet does not drive itself: the window running out,
            // and the phone completing the handshake (which clears `armedUntil` by turning
            // the slot from provisional to paired). Either way there is no code left worth
            // showing.
            if armedUntil == nil { dismiss() }
        }
        .onDisappear {
            // The window may still be open if the sheet is dismissed some way other than the
            // Cancel button (⌘W, clicking outside, quitting) — an expired code must stop
            // being a key, not merely stop being drawn.
            Task { try? await service.expireArming() }
        }
    }
}
