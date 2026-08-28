import Foundation
import Network

/// Finds Macs that are armed for pairing right now.
///
/// Browses `PairingChannel.bonjourType`, not the fleet's `_flightdeck._tcp`, and the
/// difference is the whole design: the pairing service exists only while a window is open, so
/// an empty result set means "no Mac on this network is offering to pair" rather than "no Mac
/// on this network", which are different sentences to put in front of a user.
///
/// `@unchecked Sendable`, state confined to `queue`, entry points asserting it — the same
/// idiom as `FleetConnector`, which browses the fleet's service the same way.
public final class PairingBrowser: @unchecked Sendable {
    public struct DiscoveredMac: Equatable, Sendable {
        /// The Bonjour instance name. This is the identifier that matters: the Mac advertises
        /// the *same* instance name on `_flightdeck._tcp`, so remembering it is what lets a
        /// phone that paired by typing find the same Mac again afterwards.
        public let serviceName: String
        /// From the TXT record, for display only. Unauthenticated text from the network until
        /// the seal delivers the Mac's real name — show it, never decide on it.
        public let displayName: String
        public let endpoint: NWEndpoint

        public init(serviceName: String, displayName: String, endpoint: NWEndpoint) {
            self.serviceName = serviceName
            self.displayName = displayName
            self.endpoint = endpoint
        }
    }

    /// Fired on `queue` with the *full* current set on every change, never a delta. A phone
    /// showing "2 Macs found" needs the set, and patching a local copy per event is how that
    /// count goes stale.
    public var onResults: (([DiscoveredMac]) -> Void)?

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        // `.bonjourWithTXTRecord`, not the plain `.bonjour` `FleetConnector` uses: the plain
        // descriptor never populates `result.metadata` at all, so `discovered(_:)`'s TXT
        // lookup would silently and permanently take its instance-name fallback. That is fine
        // for `FleetConnector`, which only ever compares the instance name — it is not fine
        // here, where the TXT record's display name is the whole point of browsing.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: PairingChannel.bonjourType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.onResults?(results.compactMap(Self.discovered))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        browser?.cancel()
        browser = nil
    }

    private static func discovered(_ result: NWBrowser.Result) -> DiscoveredMac? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        // The TXT record is optional in both directions: a Mac may advertise before the record
        // propagates, and a future Mac may add keys this one does not read. Fall back to the
        // instance name rather than dropping a Mac the user can see is armed.
        var displayName = name
        if case .bonjour(let txt) = result.metadata,
           let value = txt[PairingChannel.txtNameKey], !value.isEmpty {
            displayName = value
        }
        return DiscoveredMac(
            serviceName: name, displayName: displayName, endpoint: result.endpoint
        )
    }
}
