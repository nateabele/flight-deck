import Network

/// A network path reduced to just what `RedialOnPathChange` needs to decide, kept independent
/// of `NWPath` itself — mirrors why `RedialOnReturn` is driven by `ScenePhase` values rather
/// than reading `UIApplication` state directly: the decision has to be constructible in a test
/// with no real network, camera, or scene behind it.
///
/// `NWPath.Status` is a three-way enum (`satisfied` / `unsatisfied` / `requiresConnection`),
/// but the decision this struct feeds only ever needs "is there a network to redial onto right
/// now", so `requiresConnection` — a path that exists but needs a captive-portal login or a VPN
/// prompt before it can carry traffic — collapses to `false` alongside `unsatisfied`: redialing
/// onto it would just hand the connector a socket it also cannot use.
struct PathFingerprint: Equatable {
    /// Whether the path can currently carry traffic. `false` for both `unsatisfied` and
    /// `requiresConnection` — see the type's doc comment for why the latter is not split out.
    var isSatisfied: Bool

    /// The available interface types, as stable names rather than `NWInterface.InterfaceType`
    /// directly (that enum is not `Hashable`-friendly for sorting and pulls `Network` into
    /// every call site that only wants to compare two fingerprints). Sorted on init so two
    /// fingerprints over the same interfaces compare equal regardless of the order
    /// `NWPath.availableInterfaces` happened to enumerate them in — the framework documents no
    /// ordering guarantee.
    let interfaces: [String]

    init(isSatisfied: Bool, interfaces: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces.sorted()
    }

    /// The only initializer `PathChangeWatcher` (the shell) uses. Kept separate from the
    /// memberwise form above so `RedialOnPathChangeTests` never has to construct a real
    /// `NWPath` — which, on a simulator, cannot be driven through an interface change at all.
    init(path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied,
            interfaces: path.availableInterfaces.map { Self.name(for: $0.type) }
        )
    }

    private static func name(for type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wiredEthernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "other"
        }
    }
}

/// Whether a network path change should redial the Mac.
///
/// **The gap `RedialOnReturn` does not cover.** That struct fixes the socket iOS tears down on
/// suspension, but the phone can also change networks — Wi-Fi to cellular walking out of the
/// house, Wi-Fi to a different Wi-Fi switching rooms — while it stays in the foreground the
/// whole time. Nothing in that path ever touches `scenePhase`, so `RedialOnReturn` never fires,
/// and the connector is left holding a socket bound to an interface that no longer routes
/// anywhere: not torn down (nothing told it to), not retried (nothing marks it stale), just
/// quietly dead until the up-to-30s backoff eventually notices or the user force-quits — the
/// same symptom `RedialOnReturn` exists for, with a different trigger.
///
/// **Conservative on purpose.** `reconnect()` is cheap to call but not free to watch: it tears
/// down and rebuilds the connector, which is a real handshake and a visible "searching" flicker
/// in the fleet list. `NWPathMonitor` can report a path update for reasons that do not warrant
/// either — DNS server changes, IPv6 renumbering — so this only fires on a transition a user
/// would recognize as "my connection changed", never on every delivery from the monitor.
///
/// The rule:
/// - The **first** fingerprint ever observed is recorded as a baseline and returns `false`.
///   Startup has no stale socket to redial — `FleetModel` dials fresh on launch, and the
///   fleet-list-appear / foreground triggers already cover the moment the UI first needs data.
/// - After that, an **unsatisfied** fingerprint is recorded (so the interface types it carried,
///   or lack of them, are on record for the next comparison) but always returns `false` — there
///   is no network to redial onto, so calling `reconnect()` here would just race the same dead
///   air the connector is already sitting in.
/// - A **satisfied** fingerprint returns `true` only when it differs from the last fingerprint
///   recorded — whether that last one was the baseline, another satisfied fingerprint, or an
///   unsatisfied one. An identical satisfied repeat (the monitor firing again with nothing
///   actually different, which it is documented to do) returns `false`.
///
/// **Known, accepted gap.** A Wi-Fi→Wi-Fi swap — leaving one access point's range and joining
/// another on the same SSID, or roaming between APs of the same network — can keep
/// `status == .satisfied` throughout and report the same interface type (`["wifi"]`) on both
/// sides, so this never dips through `unsatisfied` and the fingerprint never changes: no redial
/// fires, even though the underlying socket may be just as dead as a Wi-Fi→cellular switch.
/// Distinguishing that case needs comparing `NWPath` objects for finer-grained churn (or
/// resolving the actual SSID, which requires location permission on iOS) — YAGNI until it is a
/// confirmed complaint rather than a theoretical one; the interface-type fingerprint here is
/// the cheap 90% that needs no extra entitlement.
struct RedialOnPathChange {
    /// The last fingerprint recorded — the baseline on the first call, and thereafter whatever
    /// was last observed, satisfied or not. `nil` only before the first observation.
    private(set) var last: PathFingerprint?

    /// Feed every path update here. Returns whether to redial now.
    mutating func pathChanged(to fingerprint: PathFingerprint) -> Bool {
        defer { last = fingerprint }
        guard let last else {
            // First observation: nothing to compare against yet, and nothing to redial —
            // see the type's doc comment for why startup is already covered elsewhere.
            return false
        }
        guard fingerprint.isSatisfied else {
            // Recorded above via `defer`, but no network is worth redialing onto.
            return false
        }
        return fingerprint != last
    }
}

/// Watches the device's network path and calls `onRedial` when it changes in a way
/// `RedialOnPathChange` judges worth a redial. The `QRScannerController` idiom: a thin,
/// `final class` shell around a non-Sendable Apple type, confined to its own private serial
/// queue, that turns Apple's callback into a plain closure hop to `.main`.
///
/// **Verification gap, by design.** `NWPathMonitor` observes the host machine's real network
/// stack. A simulator's virtualized networking does not reproduce an interface transition
/// truthfully, and no unit test can toggle a device's Wi-Fi or cellular radio — so, exactly
/// like `QRScannerController`'s camera, this shell is structurally unverifiable in automation.
/// Only the pure decision it wraps, `RedialOnPathChange`, is unit tested (see
/// `RedialOnPathChangeTests`); this class itself is verified by hand on a device — toggle
/// Wi-Fi/cellular while the fleet list is open and confirm the list recovers without leaving
/// the screen or force-quitting.
final class PathChangeWatcher: @unchecked Sendable {
    /// Fires on the main queue when a path change should redial the Mac. Assign before
    /// `start()`; the monitor does not buffer updates from before a handler was set.
    var onRedial: (() -> Void)?

    private let monitor = NWPathMonitor()
    // `NWPathMonitor` requires a queue to deliver `pathUpdateHandler` on and never uses
    // `.main` itself, so — same rationale as `QRScannerController.queue` for `AVCaptureSession`
    // — `decision` below is confined to this one private serial queue rather than protected by
    // a lock: every touch of it happens inside `pathUpdateHandler`, which only ever runs here.
    private let queue = DispatchQueue(label: "com.flightdeck.mobile.pathmonitor")
    private var decision = RedialOnPathChange()
    // Main-confined, not queue-confined like `decision` above: written only from `start()`/
    // `stop()`, both of which are only ever called on the main thread from SwiftUI.
    private var started = false

    /// Begins observing path changes. Idempotent: SwiftUI can re-run the `.onAppear` that calls
    /// this (e.g. after a view identity change), and a second `NWPathMonitor` handed the same
    /// work would double-evaluate every transition against two independent `decision` copies —
    /// each missing the history the other has, deciding "different" through parallel baselines
    /// where a single watcher would correctly say "no change".
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let fingerprint = PathFingerprint(path: path)
            guard self.decision.pathChanged(to: fingerprint) else { return }
            DispatchQueue.main.async {
                // `onRedial` is set from `FlightDeckMobileApp.body`, which SwiftUI isolates to
                // `@MainActor` as a whole (the same fact that lets that file's existing
                // `.onChange(of: scenePhase)` closure call `model.reconnect()` directly) — so
                // the closure carries MainActor isolation the plain `() -> Void` type here has
                // erased. `assumeIsolated` states that fact rather than hiding it, exactly as
                // `QRScannerController.metadataOutput` does for `onCode` — see its doc comment.
                MainActor.assumeIsolated {
                    self.onRedial?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Cancels the monitor. Not currently called from anywhere in the app (the watcher lives
    /// for the process's lifetime, same as `FleetModel`). One-shot: `NWPathMonitor.cancel()` is
    /// terminal — a cancelled monitor cannot be resumed by calling `monitor.start()` again, it
    /// silently never delivers another update. `started` only makes repeated `stop()` calls
    /// idempotent; it does not make this instance restartable. A future screen that needs a
    /// narrower-lived watcher should allocate a fresh `PathChangeWatcher`, not call `start()`
    /// again on one that has been stopped.
    func stop() {
        monitor.cancel()
        started = false
    }

    deinit {
        // Belt and braces, mirroring `QRScannerController.deinit`: repeats `stop()`'s cancel in
        // case that method is never called. `monitor.cancel()` is documented safe to call on an
        // already-cancelled monitor.
        monitor.cancel()
    }
}
