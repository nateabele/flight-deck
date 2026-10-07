import Foundation
import OSLog

/// `{version: 1, <key>: [Item]}` on disk: the one load / atomic-write / move-aside routine
/// behind `infra.json` and `infra-ledger.json`.
///
/// A missing file is empty. An unreadable one is moved aside (never deleted, never treated as
/// empty-and-overwritable) because the next write would otherwise erase machines or spend
/// history. If the move itself fails the file is still sitting there, so `write` throws until
/// it is dealt with: in-memory state stays empty, and nothing is written over the bad file.
final class VersionedJSONFile<Item: Codable> {
    private let url: URL
    private let key: String
    private var blocked: Error?

    private static var logger: Logger { Logger(subsystem: "dev.flightdeck.FlightDeck", category: "infra") }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Envelope: Codable {
        static var keyInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "key")! }
        var items: [Item]

        init(items: [Item]) { self.items = items }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            items = try c.decode([Item].self, forKey: Key(decoder.userInfo[Self.keyInfo] as! String))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(1, forKey: Key("version"))
            try c.encode(items, forKey: Key(encoder.userInfo[Self.keyInfo] as! String))
        }
    }

    init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    func load() -> [Item] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            moveAside(error)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[Envelope.keyInfo] = key
        do { return try decoder.decode(Envelope.self, from: data).items } catch {
            moveAside(error)
            return []
        }
    }

    func write(_ items: [Item]) throws {
        if let blocked { throw blocked }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[Envelope.keyInfo] = key
        try encoder.encode(Envelope(items: items)).write(to: url, options: .atomic)
    }

    private func moveAside(_ error: Error) {
        let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            blocked = error
            Self.logger.error("\(self.url.lastPathComponent, privacy: .public) unreadable and could not be moved aside: \(String(describing: error), privacy: .public)")
            return
        }
        Self.logger.error("\(self.url.lastPathComponent, privacy: .public) unreadable, moved aside: \(String(describing: error), privacy: .public)")
    }
}
