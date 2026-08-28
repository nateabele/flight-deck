import CoreImage
import CoreImage.CIFilterBuiltins
import FleetKit
import SwiftUI

enum PairingCodeImage {
    /// `.medium` error correction, not `.high`: higher correction spends the extra capacity
    /// on redundancy rather than on the payload, pushing the code up a version or two and
    /// producing a denser grid that scans *worse* on a phone held at arm's length. That
    /// mattered acutely when the payload was v1's ~270 characters of base64url'd JSON and it
    /// still holds at v2's 161 packed ones. Scaled with nearest-neighbour so the modules stay
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

/// The sheet "Pair a Device…" opens: one armed window presented two ways — the QR for a phone
/// with a camera, the twelve typed symbols for one without — live for `PairingArmer.window`
/// and no longer.
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
    /// The whole window, not its payload. The QR and the typed code are two presentations of
    /// one armed pairing, and taking them as one value is what makes it structurally
    /// impossible for this sheet to draw one window's code beside another window's QR.
    let window: ArmedPairing

    /// Both halves of what is on screen, derived from one value.
    ///
    /// Static, and exposed, because this is the part worth testing: a sheet that drew a code
    /// from one window beside a QR from another would look completely normal, and the user
    /// would find out by typing a code that does not work.
    static func displayedCode(for window: ArmedPairing) -> String { window.code.formatted }
    static func qrCode(for window: ArmedPairing) -> String { window.payload.encoded() }

    /// Derived once, at init, rather than inside `body`.
    ///
    /// `body` re-runs every second — the countdown ticks — and both the QR and the typed code
    /// are derived from the window. Deriving them in `body` rebuilt a 320px QR bitmap on every
    /// tick and handed SwiftUI a fresh `CGImage` each time, which redraws the image for a code
    /// that has not changed. (It genuinely has not: `encoded()` is byte-stable, pinned by
    /// `testEncodingTheSamePayloadTwiceGivesTheSameString`.) The work is per-window, so it
    /// belongs where the window is decided, not where it is drawn.
    private let typedCode: String
    private let codeImage: CGImage?

    init(service: FleetService, preferences: PreferencesStore, window: ArmedPairing) {
        self.service = service
        self.preferences = preferences
        self.window = window
        self.typedCode = Self.displayedCode(for: window)
        self.codeImage = PairingCodeImage.cgImage(for: Self.qrCode(for: window), size: 320)
    }

    /// Advanced only by the timer tick below, so the countdown text (and the expiry check
    /// that drives auto-dismiss) re-evaluates once a second without depending on
    /// `preferences` publishing on every tick.
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var armedUntil: Date? {
        preferences.pairedDevices.first { $0.slot == window.payload.key.slot }?.armedUntil
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

            Text(window.payload.macName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let codeImage {
                Image(decorative: codeImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .accessibilityIdentifier("pairing-code-image")
            }

            // `.fixedSize(horizontal: false, vertical: true)` is load-bearing, and this is
            // the one sentence on the sheet where losing the tail is a security problem
            // rather than a cosmetic one: it is what tells the user that anyone who can see
            // the code can drive this Mac.
            //
            // A sheet is sized once, from its content's ideal height, and this `Text`'s ideal
            // height is one line — so the sheet came out 509pt where the wrapped text needs
            // 525, and SwiftUI resolved the 16pt shortfall the way it always does, by
            // truncating to "…can control this Mac's sessions unt…". Neither
            // `multilineTextAlignment` nor the `maxWidth` frame has any say in that; both
            // describe the width, and the height was already decided. Fixing the vertical
            // axis makes the ideal height the *wrapped* height, so the sheet asks for the
            // 525pt it needs. Same reason as the variable reference in `ToolsSettingsTab`.
            Text("Scan this in Flight Deck on your iPhone. Anyone who can see this code can control this Mac's sessions until you revoke the device. It expires in 2 minutes.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)

            Text(countdownText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pairing-code-countdown")

            Divider()
                .frame(maxWidth: 320)

            // Promoted out of a `DisclosureGroup`. The QR's payload was hidden because it was
            // 300 characters of base64 that nobody would type; twelve grouped symbols are a
            // peer of the QR, and burying the only route that works without a camera behind a
            // disclosure triangle is how a simulator user concludes the app cannot pair at all.
            VStack(spacing: 6) {
                Text("Or type this code")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Sized and spaced to be read off this screen and typed into another, often
                // from across a room: `.title` rather than body text, fixed-width so the three
                // groups line up under each other, and tracked apart so `8` and `B` are told
                // apart at a glance. The alphabet has already done the other half of that job
                // by omitting `I`, `L`, `O` and `U` — see `PairingCode`.
                //
                // Uppercase is not decoration either: Crockford base32 is only unambiguous in
                // one case, and lowercase `l` against `1` is precisely the substitution the
                // alphabet omits `L` to prevent. That is a reason about the *reader* — it buys
                // nothing in the QR, where `FD` and `fd` measure the same 39 modules.
                Text(typedCode)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .tracking(2)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .quaternarySystemFill))
                    )
                    .accessibilityIdentifier("pairing-typed-code")

                Text("Only works on this Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            // Same load-bearing fix as the paragraph above, for the same reason: a sheet is
            // sized once from its content's ideal height, and a wrapping label's ideal height
            // is one line, so without it the sheet comes out short and truncates.
            .fixedSize(horizontal: false, vertical: true)

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
