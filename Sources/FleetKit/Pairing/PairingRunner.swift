import Foundation
import Network

/// The typed path, from a validated code to a device key: browse, then try each armed Mac in
/// turn until one accepts.
///
/// **Sequential, where `FleetConnector` races in parallel**, and the difference is not a
/// preference. A fleet connection is authenticated by a key, so the first candidate to
/// complete a handshake is by definition the right Mac and racing costs nothing. Here every
/// wrong Mac tried *charges an attempt against that Mac's own three-guess budget* — so a
/// parallel fan-out would burn a guess on every armed Mac on the LAN simultaneously, for a
/// user who typed their code correctly. One at a time, stopping at the first success.
///
/// **It takes a `PairingCode`, never a `String`.** A code that failed its checksum cannot be
/// expressed as one, so there is no path from a typo to the network — which is what makes
/// "a failed checksum is not an attempt" (spec §7) structural rather than a rule someone has
/// to remember.
///
/// `@unchecked Sendable`, state confined to `queue`, entry points asserting it.
public final class PairingRunner: @unchecked Sendable {
    public enum Progress: Equatable, Sendable {
        case searching
        /// About to try this Mac. The name is the TXT record's, i.e. unauthenticated — it is
        /// for a progress line, not for a decision.
        case trying(displayName: String)
        /// Nothing on this network is offering to pair. Deliberately not a `failed`: the user
        /// needs "show the code on your Mac / use the QR", not "wrong code".
        case noMacsFound
        /// Every discovered Mac refused, and this is the last one's verdict.
        case failed(PairingInitiator.Failure)
        case paired
    }

    /// The most Macs one run will try, and the reason the walk is bounded at all: the
    /// candidate list comes from a Bonjour browse, so its length is chosen by the network. A
    /// peer publishing N `_flightdeck-pair._tcp` advertisements makes the phone spend
    /// N × `PairingInitiator.exchangeTimeout` behind a spinner, which is unbounded work driven
    /// by untrusted input even though it is not a cryptographic problem — SPAKE2 gives one
    /// online guess per exchange and there is no offline path, so flooding buys an attacker
    /// nothing but the phone's time.
    ///
    /// Eight, because eight attempts at the initiator's 8-second whole-exchange timeout is 64
    /// seconds, and with the 5-second discovery window in front of it that still fits inside
    /// the 120-second window a Mac's code is valid for (`PairingArmer.window`, in the app
    /// target). A ninth candidate would be tried, at the earliest, against a window that had
    /// already closed — so this is the point past which more walking cannot pair anything, not
    /// a taste in patience.
    ///
    /// It bounds *work*, not reachability: a flood can still push the real Mac out of the
    /// first eight, and no cap fixes that. What that user gets is the QR, which is why the
    /// typed path is documented as the fallback and not the primary.
    public static let maxCandidates = 8

    public var onProgress: ((Progress) -> Void)?
    /// `serviceName` is the Bonjour instance name of the Mac that accepted — what a phone
    /// stores so `FleetConnector` can find the same Mac again. `macName` comes out of the
    /// **seal**, so unlike the TXT record it is authenticated by the exchange.
    public var onPaired: ((_ key: FleetDeviceKey, _ serviceName: String, _ macName: String) -> Void)?

    /// How long to collect browse results before trying any of them. A Bonjour browse has no
    /// "that is all of them" signal, so this is the cost of finding the *second* Mac before
    /// spending an attempt on the first — paid once, behind a spinner, on a screen the user
    /// has just finished typing on.
    public var discoveryWindow: TimeInterval = 5

    private let queue: DispatchQueue
    private let browser: PairingBrowser
    private var initiator: PairingInitiator?
    private var code: PairingCode?
    private var remaining: [PairingBrowser.DiscoveredMac] = []
    private var discovered: [PairingBrowser.DiscoveredMac] = []
    private var running = false
    /// Same role as `FleetConnector.generation`, and bumped the same way — on EVERY
    /// transition, not only where a timer is scheduled. `DispatchQueue.asyncAfter` cannot be
    /// cancelled, so the discovery-window block has to recognise that it is stale rather than
    /// be stopped, and a counter bumped only at the scheduling site leaves the hole where a
    /// window opened, was cancelled, and reopened: the stale block would see a matching
    /// number and start walking a candidate list belonging to a run that no longer exists.
    /// `cancel()` bumping it is what closes that, and `start()` calls `cancel()` first.
    private var generation = 0

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        self.browser = PairingBrowser(queue: queue)
    }

    /// Browse, then try what was found.
    public func start(code: PairingCode) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        running = true
        self.code = code
        generation += 1
        let generation = self.generation
        report(.searching)

        discovered = []
        browser.onResults = { [weak self] macs in
            guard let self, self.running, generation == self.generation else { return }
            self.discovered = macs
        }
        browser.start()
        queue.asyncAfter(deadline: .now() + discoveryWindow) { [weak self] in
            guard let self, self.running, generation == self.generation else { return }
            // The browse stops before the first attempt: results arriving mid-walk would
            // reorder a list the user is already being shown progress against, and a Mac
            // discovered after its own window closed is not a candidate anyway.
            self.browser.stop()
            self.remaining = Array(self.discovered.prefix(Self.maxCandidates))
            self.tryNext()
        }
    }

    /// The same walk over a list somebody else assembled. Used by the tests, and available to
    /// a screen that already knows which Macs it found.
    public func start(code: PairingCode, candidates: [PairingBrowser.DiscoveredMac]) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        running = true
        self.code = code
        generation += 1
        report(.searching)
        // Capped here too, not only on the browse path: this entry point is public and its
        // caller is a screen holding a list it got from the same network.
        remaining = Array(candidates.prefix(Self.maxCandidates))
        tryNext()
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        running = false
        generation += 1
        browser.onResults = nil
        browser.stop()
        initiator?.cancel()
        initiator = nil
        remaining = []
        discovered = []
        code = nil
    }

    private func tryNext() {
        guard running, let code else { return }
        guard !remaining.isEmpty else {
            running = false
            report(.noMacsFound)
            return
        }
        let candidate = remaining.removeFirst()
        report(.trying(displayName: candidate.displayName))

        let initiator = PairingInitiator(queue: queue)
        self.initiator = initiator
        initiator.onPaired = { [weak self] key, macName in
            guard let self, self.running else { return }
            self.running = false
            self.initiator = nil
            self.onPaired?(key, candidate.serviceName, macName)
            self.report(.paired)
        }
        initiator.onFailure = { [weak self] failure in
            guard let self, self.running else { return }
            self.initiator = nil
            // EVERY failure walks on, `.attemptsExhausted` included. The budget is per Mac,
            // per window (spec §7), so one Mac's burned window says nothing about the next
            // one's — and treating it as terminal would let a stranger on the LAN, or the
            // user's own earlier typo, deny pairing to the Mac that is actually waiting.
            guard self.remaining.isEmpty else { return self.tryNext() }
            self.running = false
            // The last Mac's verdict, not a summarised one: "that Mac's window is burned" and
            // "wrong code" send the user to different places.
            self.report(.failed(failure))
        }
        initiator.start(code: code, endpoint: candidate.endpoint)
    }

    private func report(_ progress: Progress) {
        dispatchPrecondition(condition: .onQueue(queue))
        onProgress?(progress)
    }
}
