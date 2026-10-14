import Foundation

/// The fleet as the phone last held it, with the exact resume point it was folded to.
///
/// **One record, never three files.** A resume cursor is only meaningful against the fleet it
/// was folded to, and against the run of the Mac that counted it (`epoch`). Persisting them
/// separately is how a phone once resumed onto an empty list (`FleetModel.init`'s history):
/// any write that lands without the others pairs a cursor with the wrong base, and every
/// replayed delta then applies cleanly to it. One atomic file makes "all three or none" a
/// property of the filesystem rather than of the code that writes it.
public struct CachedFleet: Codable, Equatable, Sendable {
    /// Which Mac this is: `PairedMac.serviceName`. A cache for any other Mac is ignored, so a
    /// re-pair to a different Mac never opens on the last one's sessions.
    public var mac: String
    public var epoch: String
    public var seq: Int
    public var fleet: FleetSnapshot
    /// When this fleet was last known current — the last moment the phone was live. What the
    /// list's stale banner says "last live" about until the Mac answers.
    public var savedAt: Date

    public init(mac: String, epoch: String, seq: Int, fleet: FleetSnapshot, savedAt: Date) {
        self.mac = mac
        self.epoch = epoch
        self.seq = seq
        self.fleet = fleet
        self.savedAt = savedAt
    }
}

/// A session's conversation as the phone last held it, and which transcript file it indexes.
public struct CachedTimeline: Codable, Equatable, Sendable {
    /// `TimelinePage.source` of the pages this feed was built from. Required: without it a
    /// held cursor cannot be checked against the file it now lands in, so nothing is cached.
    public var source: String
    public var feed: TimelineFeed
    public var savedAt: Date

    public init(source: String, feed: TimelineFeed, savedAt: Date) {
        self.source = source
        self.feed = feed
        self.savedAt = savedAt
    }
}

/// Where the phone keeps what it can open on before the Mac answers: the fleet, and one
/// feed per session. Under `Caches`, because every byte here can be fetched again — a purged
/// file costs one full snapshot or one `.latest` page, never data.
///
/// **Writes are asynchronous and reads are not.** Saving runs on a serial queue so encoding a
/// fleet or a feed never lands on a frame the list is drawing; a read is what the first frame
/// needs, so it is synchronous — and because the queue is serial, a read issued after a
/// save on the same instance waits for that save (`sync` on the same queue), never sees a
/// half-written file (writes are `.atomic`), and never sees an older one.
///
/// Holds conversation text, so it goes with the pairing: `purgeAll()` on unpair and on
/// adopting a new pairing, the same as `TimelineSpillStore.purgeAll()`.
public final class PhoneCache: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "flightdeck.phone-cache")

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    public static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("FlightDeckPhoneCache", isDirectory: true)
    }

    private var fleetURL: URL { directory.appendingPathComponent("fleet.json") }
    private var timelinesURL: URL { directory.appendingPathComponent("timelines", isDirectory: true) }
    private func timelineURL(_ session: UUID) -> URL {
        timelinesURL.appendingPathComponent("\(session.uuidString).json")
    }

    // MARK: Fleet

    /// The cached fleet for `mac`, or nil when there is none, it is another Mac's, or it does
    /// not decode — a cache written by a different build is a miss, not an error.
    public func fleet(for mac: String) -> CachedFleet? {
        queue.sync {
            guard let data = try? Data(contentsOf: fleetURL),
                  let cached = try? Self.decoder.decode(CachedFleet.self, from: data),
                  cached.mac == mac
            else { return nil }
            return cached
        }
    }

    public func save(_ fleet: CachedFleet) {
        write(fleet, to: fleetURL)
    }

    // MARK: Timelines

    public func timeline(for session: UUID) -> CachedTimeline? {
        queue.sync {
            guard let data = try? Data(contentsOf: timelineURL(session)) else { return nil }
            return try? Self.decoder.decode(CachedTimeline.self, from: data)
        }
    }

    public func save(_ timeline: CachedTimeline, for session: UUID) {
        write(timeline, to: timelineURL(session))
    }

    public func removeTimeline(for session: UUID) {
        let url = timelineURL(session)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Drop every session's feed except `sessions`'. Run against a fresh snapshot, so a closed
    /// tab's conversation does not sit on the phone indefinitely after the Mac let it go.
    public func pruneTimelines(keeping sessions: Set<UUID>) {
        let folder = timelinesURL
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            for file in files {
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                if let id, sessions.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Everything, fleet and feeds. Synchronous, so a revocation is complete when it returns.
    public func purgeAll() {
        let folder = directory
        queue.sync { _ = try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Plumbing

    private func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? Self.encoder.encode(value) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    // Made per use rather than shared: neither coder is `Sendable`, and FleetKit builds in
    // Swift 6, where a shared static one is a compile error rather than a style choice.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
