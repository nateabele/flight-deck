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

/// Owns `AVCaptureSession`/`AVCaptureMetadataOutput` and the metadata delegate conformance,
/// confined to `queue` — the same idiom `FleetClient`/`FleetSocketServer`/`FleetConnector`
/// use in `FleetKit`: every touch of the non-Sendable capture state happens on one queue, so
/// the mutable state is never actually shared across threads even though nothing here is
/// locked.
///
/// This replaces an earlier version that kept the session directly on
/// `QRScannerContainerView` and captured it (and `output`) by value into `sessionQueue`
/// closures. That produced two problems, not one: three `SendableClosureCaptures` warnings
/// (capturing a non-Sendable Apple type into a `@Sendable` closure), and a real race — `output`
/// was assigned on `.main`, asynchronously, *after* the delegate had already been registered on
/// `sessionQueue`, so a `teardown()` landing in that gap found `output` still `nil` and silently
/// failed to clear a delegate that was already live, with no second `dismantleUIView` call ever
/// coming to retry it. Routing every read and write of `session`/`output` through `self`
/// (`weak`, and `@unchecked Sendable`) instead of capturing them directly, and keeping the
/// delegate's registration and `output`'s assignment in the same queue hop, fixes both at once:
/// there is no window where the delegate is live but `output` doesn't yet know about it, and
/// `xcrun swiftc -typecheck -swift-version 6` on this shape reports zero diagnostics.
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
    private let session = AVCaptureSession()
    private var output: AVCaptureMetadataOutput?

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
    /// together, in the same queue hop, inside `configureSession()`. Called from
    /// `QRScannerContainerView.teardown()`; `deinit` below repeats the stop as belt and braces
    /// in case that hook is ever bypassed.
    func stop() {
        queue.async { [weak self] in
            self?.output?.setMetadataObjectsDelegate(nil, queue: nil)
            self?.output = nil
            self?.session.stopRunning()
        }
    }

    deinit {
        // Cannot call an instance method on `self` from `deinit`, so this repeats `stop()`'s
        // body by hand — `[weak self]` here is really just documentation, since a `deinit`
        // already means the last strong reference is gone, but it keeps this line identical
        // in shape to every other queue hop in this type.
        queue.async { [weak self] in
            self?.output?.setMetadataObjectsDelegate(nil, queue: nil)
            self?.session.stopRunning()
        }
    }

    private func configureSession() {
        queue.async { [weak self] in
            guard let self else { return }
            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                DispatchQueue.main.async { self.onDenied?() }
                return
            }
            self.session.beginConfiguration()
            self.session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.onDenied?() }
                return
            }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            self.session.commitConfiguration()
            // Assigned in the same queue hop that just registered the delegate above — see
            // this type's doc comment for the race this closes.
            self.output = output

            self.session.startRunning()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onSession?(self.session)
            }
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
