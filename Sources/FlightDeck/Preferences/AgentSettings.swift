import Foundation
import IntakeKit

/// One agent's row in the Agents preferences list.
///
/// The array's ORDER is semantic, not cosmetic: index 0 is ⌘N, index 1 ⌘⇧N, index 2 ⌘⇧⌥N.
/// Reordering the list rebinds the shortcuts, which is the whole interaction — see
/// `NewSessionAffordance`.
struct AgentSettings: Codable, Equatable {
    var id: AgentID
    var options: AgentOptions
}

extension AgentOptions: Codable {
    private enum CodingKeys: String, CodingKey { case agent, flags, codex, grok, gemini }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(AgentID.self, forKey: .agent) {
        case .claude: self = .claude(try c.decode(FlagSet.self, forKey: .flags))
        case .codex:  self = .codex(try c.decode(CodexThreadOptions.self, forKey: .codex))
        // Optional on read: both payloads are empty today, and a row written by a build that
        // only knew the bare agent name must still decode.
        case .grok:   self = .grok(try c.decodeIfPresent(GrokOptions.self, forKey: .grok) ?? GrokOptions())
        case .gemini: self = .gemini(try c.decodeIfPresent(GeminiOptions.self, forKey: .gemini) ?? GeminiOptions())
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        switch self {
        case .claude(let f): try c.encode(f, forKey: .flags)
        case .codex(let o):  try c.encode(o, forKey: .codex)
        case .grok(let o):   try c.encode(o, forKey: .grok)
        case .gemini(let o): try c.encode(o, forKey: .gemini)
        }
    }
}
