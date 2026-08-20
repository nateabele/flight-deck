import AVFoundation
import FleetKit
import SwiftUI
import UIKit

struct PairingScreen: View {
    let model: FleetModel

    @State private var typed = ""
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

            DisclosureGroup("Can't scan? Type the code instead") {
                TextField("flightdeck1:…", text: $typed, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Button("Pair") { adopt(typed) }
                    .disabled(typed.isEmpty)
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
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
        } catch {
            failure = "That code could not be used."
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

/// Owns the capture session and swaps between the live preview and the denied-access
/// message, so `QRScannerView` itself stays a thin representable.
///
/// A simulator has no camera, so this is the one piece of the phone app that is
/// structurally unverifiable without hardware — see the task's own verification-gap note.
final class QRScannerContainerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var lastCode: String?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var output: AVCaptureMetadataOutput?

    // Apple documents `AVCaptureSession` configuration (`beginConfiguration`/add-input/
    // add-output/`commitConfiguration`) and `startRunning()`/`stopRunning()` as blocking
    // calls that must not run on the main thread — doing so risks a visible hitch, worst on a
    // cold first launch while the camera warms up. Every one of those calls below happens on
    // this private serial queue; only the preview layer, which is UIKit and must be touched
    // from the main thread, hops back to `.main`.
    //
    // The metadata delegate's OWN callback queue, set in `configureSession()`, stays `.main`
    // — that is exactly what makes `metadataOutput(_:didOutput:from:)`'s
    // `MainActor.assumeIsolated` below sound, and moving it onto `sessionQueue` would turn a
    // verified premise into a runtime crash. Do not "tidy" that.
    private let sessionQueue = DispatchQueue(label: "com.flightdeck.mobile.qrscanner")

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
        self.onCode = onCode
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(deniedLabel)
        NSLayoutConstraint.activate([
            deniedLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            deniedLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            deniedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        requestAccess()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is only ever built by SwiftUI")
    }

    /// Stops the camera and clears the delegate. `AVCaptureMetadataOutput.h` declares
    /// `metadataObjectsDelegate` `readonly, nullable` with no ownership qualifier and no
    /// "does not retain" note, so a strong `output → delegate (== self)` reference is
    /// plausible — paired with `session → output`, that is a retain cycle through `session`,
    /// which this view also holds strongly. Left uncleared, this view — and its running
    /// camera, in-use indicator included — would never deallocate. Called from SwiftUI's
    /// `dismantleUIView`; `deinit` below repeats the stop as belt and braces in case that
    /// hook is ever bypassed.
    func teardown() {
        output?.setMetadataObjectsDelegate(nil, queue: nil)
        sessionQueue.async { [session] in session.stopRunning() }
    }

    deinit {
        // Cannot call an instance method on `self` from `deinit`, so this repeats
        // `teardown()`'s stop by hand rather than calling it — capturing only `session`,
        // never `self`.
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func requestAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.showDenied()
                    }
                }
            }
        case .denied, .restricted:
            showDenied()
        @unknown default:
            showDenied()
        }
    }

    private func showDenied() {
        deniedLabel.isHidden = false
    }

    private func configureSession() {
        // `session` is captured by value into the closure below rather than read
        // repeatedly through `self.session` — both are the same object (`AVCaptureSession`
        // is a class), but capturing it once here, on the main actor where reading it is
        // unconditionally sound, means every subsequent use inside the closure is a plain
        // local reference rather than a fresh actor-isolated property access.
        let session = session
        sessionQueue.async { [weak self, session] in
            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                DispatchQueue.main.async { self?.showDenied() }
                return
            }
            session.beginConfiguration()
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self?.showDenied() }
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.output = output
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.videoGravity = .resizeAspectFill
                previewLayer.frame = self.bounds
                self.layer.insertSublayer(previewLayer, at: 0)
                self.previewLayer = previewLayer
            }

            session.startRunning()
        }
    }

    // `nonisolated` + `MainActor.assumeIsolated`, the same idiom `FleetModel` uses for
    // `FleetConnector`'s callbacks: `AVCaptureMetadataOutputObjectsDelegate` is a plain
    // nonisolated protocol requirement, but `setMetadataObjectsDelegate(self, queue: .main)`
    // above guarantees this fires on the main queue, so `assumeIsolated` states a fact the
    // compiler cannot see rather than hiding a real hazard.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        MainActor.assumeIsolated {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                object.type == .qr,
                let value = object.stringValue,
                value != lastCode
            else { return }
            lastCode = value
            onCode(value)
        }
    }
}
