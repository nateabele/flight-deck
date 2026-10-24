import Foundation

enum PeerFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let text) = self { return text }; return "peer failure" }
}

enum PeerJSON {
    static let limit = 1024 * 1024
    static func data(_ value: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count < limit else { throw PeerFailure.invalid("peer frame exceeds 1 MiB") }
        return data
    }
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func line(_ value: Any) throws -> Data { var bytes = try data(value); bytes.append(10); return bytes }
    static var milliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func control(_ action: String, _ fields: [String: Any]) -> [String: Any] {
        fields.merging(["type": "control", "action": action, "msgV": 1, "msg_id": UUID().uuidString.lowercased()]) { _, new in new }
    }
    static func path(_ address: String) throws -> String {
        guard address.hasPrefix("uds:"), let path = String(address.dropFirst(4)).removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..")
        else { throw PeerFailure.invalid("expected an absolute uds: address") }
        return path
    }
    static func safeAttribute(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                && !"\"<>".unicodeScalars.contains($0) && $0.properties.generalCategory != .format
        }.prefix(200))
    }
    static func envelope(from: String, name: String, mode: String, text: String) -> String {
        "<cross-session-message from=\"\(from)\" from-name=\"\(safeAttribute(name))\" from-mode=\"\(mode)\">\n"
            + text.replacingOccurrences(of: "</cross-session-message", with: "<\\/cross-session-message")
            + "\n</cross-session-message>"
    }
    static func attributes(_ content: String) -> [String: String]? {
        guard content.hasPrefix("<cross-session-message "), let end = content.range(of: ">\n"),
              content.hasSuffix("\n</cross-session-message>") else { return nil }
        let header = String(content[content.index(content.startIndex, offsetBy: 22)..<end.lowerBound])
        let regex = try! NSRegularExpression(pattern: #" ([a-z-]+)="([^"<>\r\n]*)""#)
        let matches = regex.matches(in: header, range: NSRange(header.startIndex..., in: header))
        let order = ["from", "from-session", "hop-chain", "from-name", "from-mode", "from-plugin"]
        var result: [String: String] = [:], previous = -1, reconstructed = ""
        for match in matches {
            let key = (header as NSString).substring(with: match.range(at: 1))
            let value = (header as NSString).substring(with: match.range(at: 2))
            guard let index = order.firstIndex(of: key), index > previous else { return nil }
            previous = index; result[key] = value
            reconstructed += (header as NSString).substring(with: match.range)
        }
        guard reconstructed == header, let from = result["from"], (try? path(from)) != nil,
              result["from-mode"].map({ ["prompting", "bypass"].contains($0) }) ?? true else { return nil }
        return result
    }
}

/// Decode bytes, not String chunks: a socket read may split an emoji's UTF-8 sequence.
struct PeerFrameDecoder {
    private var pending = Data()
    mutating func push(_ bytes: Data, eof: Bool = false) throws -> [[String: Any]] {
        pending.append(bytes)
        var frames: [[String: Any]] = []
        while let end = pending.firstIndex(of: 10) {
            guard pending.distance(from: pending.startIndex, to: end) < PeerJSON.limit else {
                throw PeerFailure.invalid("oversized peer frame")
            }
            if let object = PeerJSON.object(Data(pending[..<end])) { frames.append(object) }
            pending.removeSubrange(...end)
        }
        guard pending.count < PeerJSON.limit else { throw PeerFailure.invalid("oversized incomplete peer frame") }
        if eof {
            if let object = PeerJSON.object(pending) { frames.append(object) }
            pending.removeAll()
        }
        return frames
    }
}
