import AVFoundation
import FleetKit
import SwiftUI
import UIKit

struct PairingScreen: View {
    let model: FleetModel

    /// The typed-code field's text and its two decisions — see `TypedCodeField`, which is
    /// where they live so they can be run by a test rather than only read.
    @State private var field = TypedCodeField()
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with your Mac")
                .font(.title2.weight(.semibold))
            Text("Open Flight Deck on your Mac, then Settings → Devices → Pair a Device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            QRScannerView { adopt($0) }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Not behind a `DisclosureGroup` any more. It was hidden because it asked for 300
            // characters of base64; twelve symbols are a peer of the QR, and on a simulator —
            // which has no camera — this is the only route that works at all.
            VStack(alignment: .leading, spacing: 8) {
                Text("Or type the code from your Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("XXXX-XXXX-XXXX", text: $field.text)
                    // `.characters`, not `.never`: the code is uppercase Crockford base32, and
                    // a lowercase keyboard makes the user shift twelve times. The modifier is
                    // a hint the software keyboard may honour — `TypedCodeField.reformat()` is
                    // what actually guarantees the case, for a paste or a hardware keyboard.
                    .textInputAutocapitalization(.characters)
                    // A twelve-symbol code is exactly the shape autocorrect turns into a word.
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: field.text) { _, _ in
                        field.reformat()
                        // Typing again clears a stale verdict; leaving it up next to a
                        // half-corrected code says the correction failed.
                        failure = nil
                    }

                Button("Pair") { pairByTyping() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    // Enabled only on a complete code, so the button cannot be pressed into a
                    // "that doesn't look right" the user has no way to act on yet.
                    .disabled(!field.canSubmit)

                Text("Both devices need to be on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress = model.pairingProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(Self.message(for: progress))
                        .foregroundStyle(.secondary)
                }
            } else if let message = failure ?? model.pairingFailure {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    private func adopt(_ code: String) {
        do {
            try model.adopt(code: code)
            failure = nil
        } catch let error as PairingPayloadError {
            failure = Self.message(for: error)
        } catch let error as PairedMacStoreError {
            failure = Self.message(for: error)
        } catch {
            failure = "That code could not be used."
        }
    }

    /// The typed path. The checksum decision is `TypedCodeField.submit()`'s — see there for
    /// why it is made before anything opens a socket — and this is the only thing that turns
    /// its verdict into either a pairing run or a line of red copy.
    private func pairByTyping() {
        switch field.submit() {
        case .pair(let code):
            failure = nil
            model.pair(code: code)
        case .rejected(let message):
            failure = message
        }
    }

    /// Progress copy. `searching` names the wait a Bonjour browse imposes, so a five-second
    /// spinner reads as work rather than as a hang; `trying` names the Mac so a user with two
    /// of them can see which one is being asked.
    static func message(for progress: PairingRunner.Progress) -> String {
        switch progress {
        case .searching: return "Looking for your Mac…"
        case .trying(let displayName): return "Trying \(displayName)…"
        // Never shown: each of these clears `pairingProgress` in the same update that sets
        // `pairingFailure`, so the view is on the other branch by the time it renders.
        case .noMacsFound, .failed, .paired: return ""
        }
    }

    /// Each failure says what to do next. "Invalid code" for all three would leave a user
    /// rescanning a code that will never work.
    static func message(for error: PairingPayloadError) -> String {
        switch error {
        case .notAPairingCode:
            return "That isn't a Flight Deck pairing code."
        case .unsupportedVersion:
            return "This code is from a newer version of Flight Deck. Update the app on your phone."
        case .malformed:
            return "That code is damaged. Show a new one on your Mac."
        }
    }

    /// The code scanned fine; the phone could not keep it. Deliberately does NOT say "try
    /// again" — rescanning runs the identical keychain write and fails identically, and the
    /// two causes seen in practice (an unsigned build with no access group, a device that has
    /// never been unlocked since boot) are neither of them fixed by another scan. The status
    /// is in the message because it is the only thing that distinguishes them, and this
    /// screen is the only place it will ever be seen.
    static func message(for error: PairedMacStoreError) -> String {
        switch error {
        case .encodingFailed:
            return "Couldn't save this pairing to the keychain."
        case .keychainWriteFailed(let status):
            return "Couldn't save this pairing to the keychain (error \(status))."
        }
    }
}

/// A `UIViewRepresentable` over `AVCaptureSession`, restricted to QR codes and calling
/// `onCode` once per distinct string seen — a fixed video feed of the same code must not
/// re-fire on every frame.
///
/// Not a separate file: the plan's file list for this task names only `PairingScreen.swift`
/// for the pairing screen, and this view has no reason to be reached from anywhere else.
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> QRScannerContainerView {
        QRScannerContainerView(onCode: onCode)
    }

    func updateUIView(_ uiView: QRScannerContainerView, context: Context) {
        // `onCode` is fixed for this view's lifetime — `updateUIView` never re-assigns it to
        // `uiView`. Latent but harmless today: the closure just forwards to `model.adopt`,
        // and `model` is a stable reference held by `PairingScreen`, so a later `body`
        // re-evaluation producing a new closure *value* still calls through to the same
        // model. Left as a comment rather than "fixed" because there is no reachable path
        // today where `onCode`'s behavior would actually need to change mid-lifetime.
    }

    /// The one hook SwiftUI documents for "this native view is going away": without it,
    /// nothing ever stops the capture session or clears its delegate — see
    /// `QRScannerContainerView.teardown()`.
    static func dismantleUIView(_ uiView: QRScannerContainerView, coordinator: ()) {
        uiView.teardown()
    }
}

/// Hosts the live preview and swaps in the denied-access message; owns no `AVCaptureSession`
/// state itself. That all lives in `QRScannerController`, confined to its own queue — see
/// that type's doc comment for why this split exists.
///
/// A simulator has no camera, so this is the one piece of the phone app that is
/// structurally unverifiable without hardware — see the task's own verification-gap note.
final class QRScannerContainerView: UIView {
    private let controller: QRScannerController
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let deniedLabel: UILabel = {
        let label = UILabel()
        label.text = "Flight Deck needs the camera to scan the code on your Mac. "
            + "You can enter the code by hand instead."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    init(onCode: @escaping (String) -> Void) {
        controller = QRScannerController(onCode: onCode)
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(deniedLabel)
        NSLayoutConstraint.activate([
            deniedLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            deniedLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            deniedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        controller.onSession = { [weak self] session in self?.attachPreview(session) }
        controller.onDenied = { [weak self] in self?.showDenied() }
        controller.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is only ever built by SwiftUI")
    }

    /// Called from SwiftUI's `dismantleUIView`. Everything that must stop — the running
    /// camera and the metadata delegate — lives on `controller`; this view has nothing of
    /// its own to tear down beyond releasing the preview layer, which happens for free when
    /// the view itself deallocates.
    func teardown() {
        controller.stop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func showDenied() {
        deniedLabel.isHidden = false
    }

    private func attachPreview(_ session: AVCaptureSession) {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
    }
}

/// The non-Sendable capture resources behind one `Sendable` reference, so every queue hop —
/// including `deinit`'s, which cannot use `self` — captures a `Sendable` value rather than an
/// `AVCaptureSession`/`AVCaptureMetadataOutput` directly. Confined to `queue`, same as the
/// controller that owns it.
///
/// `stopped` exists for a narrower reason than the rest: on `.notDetermined`,
/// `configureSession()` is enqueued from `AVCaptureDevice.requestAccess`'s completion, which
/// can land after the user has already paired by typing the code and the view has been
/// dismantled — `stop()` already ran, and nothing stops a `configureSession()` that lands
/// after it. `configureSession()` checks this flag before doing anything, on `queue`, so the
/// check and every mutation it guards share the same confinement as the rest of this class.
private final class CaptureResources: @unchecked Sendable {
    let session = AVCaptureSession()
    var output: AVCaptureMetadataOutput?
    var stopped = false
}

/// Owns `AVCaptureSession`/`AVCaptureMetadataOutput` and the metadata delegate conformance,
/// confined to `queue` — the same idiom `FleetClient`/`FleetSocketServer`/`FleetConnector`
/// use in `FleetKit`: every touch of the non-Sendable capture state happens on one queue, so
/// the mutable state is never actually shared across threads even though nothing here is
/// locked.
///
/// The capture state itself lives on `resources` (see that type's doc comment), not directly
/// on this class. An earlier version of this file kept `session`/`output` as properties here
/// and read them through `self` (`weak`) inside every queue block, including `deinit`'s. That
/// shape has a fatal flaw specific to `deinit`: by the time a `deinit` runs, the last strong
/// reference is already gone, so a `[weak self]` capture inside a closure that runs *later*
/// can never resolve — `deinit`'s cleanup silently did nothing, on every run, confirmed
/// empirically by reproducing the shape in isolation. The fix has to satisfy two constraints
/// that pull in opposite directions: cleanup that actually executes needs a *strong* capture
/// of something, but strongly capturing `session`/`output` directly (both non-Sendable Apple
/// types) into a `@Sendable` closure is exactly what `SendableClosureCaptures` warns about —
/// measured directly: six warnings, the same regression round 3 spent eliminating. Moving the
/// capture resources onto their own `@unchecked Sendable` reference type resolves both at
/// once: `[resources]` is a strong capture of a `Sendable` value, so it executes and keeps the
/// resources alive until the block runs, and captures no non-Sendable type across the closure
/// boundary. Blocks that call back into this controller (`onDenied`, `onSession`) still need
/// `[weak self]`, since those are genuinely optional and a dangling controller shouldn't be
/// kept alive just to fire them. `xcrun swiftc -typecheck -swift-version 6` on this shape
/// reports zero diagnostics.
final class QRScannerController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    /// Fires on the main queue once the session has a running preview to show.
    var onSession: ((AVCaptureSession) -> Void)?
    /// Fires on the main queue when access is unavailable, for any reason.
    var onDenied: (() -> Void)?

    private let onCode: (String) -> Void
    private var lastCode: String?

    // Apple documents `AVCaptureSession` configuration (`beginConfiguration`/add-input/
    // add-output/`commitConfiguration`) and `startRunning()`/`stopRunning()` as blocking
    // calls that must not run on the main thread — doing so risks a visible hitch, worst on a
    // cold first launch while the camera warms up. Every one of those calls happens on this
    // private serial queue.
    //
    // The metadata delegate's OWN callback queue, set in `configureSession()`, stays `.main`
    // — that is exactly what makes `metadataOutput(_:didOutput:from:)`'s
    // `MainActor.assumeIsolated` below sound, and moving it onto `queue` would turn a verified
    // premise into a runtime crash. Do not "tidy" that.
    private let queue = DispatchQueue(label: "com.flightdeck.mobile.qrscanner")
    private let resources = CaptureResources()

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
    }

    /// Called once, from the main queue, right after the container view wires up
    /// `onSession`/`onDenied`.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            // Apple does not document which queue this completion runs on, so the hop to
            // `.main` here is load-bearing rather than defensive.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    DispatchQueue.main.async { self.onDenied?() }
                }
            }
        case .denied, .restricted:
            onDenied?()
        @unknown default:
            onDenied?()
        }
    }

    /// Stops the camera and clears the delegate, both on `queue` — including the delegate
    /// clear itself, which used to race `output` being handed off on `.main`. Confining both
    /// the read and the write of `output` to this one queue means a `stop()` landing here can
    /// never observe `output` as `nil` while the delegate is still registered: the two are set
    /// together, in the same queue hop, inside `configureSession()`. Also marks `resources` as
    /// `stopped`, so a `configureSession()` still in flight from a late `.notDetermined` grant
    /// finds out and does nothing rather than starting a camera nobody is looking at. Called
    /// from `QRScannerContainerView.teardown()`; `deinit` below repeats the stop as belt and
    /// braces in case that hook is ever bypassed.
    func stop() {
        queue.async { [resources] in
            resources.stopped = true
            resources.output?.setMetadataObjectsDelegate(nil, queue: nil)
            resources.output = nil
            resources.session.stopRunning()
        }
    }

    deinit {
        // Cannot call an instance method on `self` from `deinit`, so this repeats `stop()`'s
        // body by hand. `[resources]` is a *strong* capture of `Sendable` state, not `self` —
        // see `resources`' and this type's doc comments for why a `[weak self]` capture here
        // would silently never run.
        queue.async { [resources] in
            resources.output?.setMetadataObjectsDelegate(nil, queue: nil)
            resources.session.stopRunning()
        }
    }

    private func configureSession() {
        queue.async { [weak self, resources] in
            guard let self, !resources.stopped else { return }
            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                resources.session.canAddInput(input)
            else {
                DispatchQueue.main.async { self.onDenied?() }
                return
            }
            resources.session.beginConfiguration()
            resources.session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard resources.session.canAddOutput(output) else {
                resources.session.commitConfiguration()
                DispatchQueue.main.async { self.onDenied?() }
                return
            }
            resources.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            resources.session.commitConfiguration()
            // Assigned in the same queue hop that just registered the delegate above — see
            // `resources`' doc comment for the race this closes.
            resources.output = output

            resources.session.startRunning()

            DispatchQueue.main.async { [weak self, resources] in
                self?.onSession?(resources.session)
            }
        }
    }

    // `nonisolated` + `MainActor.assumeIsolated`, the same idiom `FleetModel` uses for
    // `FleetConnector`'s callbacks: `AVCaptureMetadataOutputObjectsDelegate` is a plain
    // nonisolated protocol requirement, but `setMetadataObjectsDelegate(self, queue: .main)`
    // above guarantees this fires on the main queue, so `assumeIsolated` states a fact the
    // compiler cannot see rather than hiding a real hazard.
    //
    // The unwrap happens BEFORE the hop, and has to: `metadataObjects` is a non-Sendable
    // `[AVMetadataObject]` arriving on a nonisolated parameter, so reaching into it from
    // inside a `@MainActor` closure is "sending 'metadataObjects' risks causing data races"
    // — a hard error in Swift 6. Only `value`, a `String`, crosses into the closure. This
    // error is invisible to `swiftc -typecheck`, which is all scripts/build-ios.sh could run
    // before an iOS runtime existed: region-based isolation is a SIL pass, so it only fires
    // on a real build. It was the first thing the first real build of this target found.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let value = object.stringValue
        else { return }
        MainActor.assumeIsolated {
            guard value != lastCode else { return }
            lastCode = value
            onCode(value)
        }
    }
}
