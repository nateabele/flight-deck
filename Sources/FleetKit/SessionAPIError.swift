import Foundation

/// Why a session's last turn stopped, when it stopped because the API said no.
///
/// Lives in FleetKit rather than in `Sources/FlightDeck` so the Mac and the phone share the
/// type *and* `label` instead of re-pinning the same strings twice.
/// `SessionStatusGlyph.swift` on iOS hand-copies the Mac's tooltip literals today, and its own
/// doc comment records why that is dangerous: a VoiceOver user hearing a different word than
/// the Mac's tooltip for the identical state is as bad as a mismatched symbol. Sharing the
/// code means this state cannot drift that way at all.
///
/// Every field is optional or defaulted because `claude` sets them independently: a
/// client-side failure raises `isApiErrorMessage` carrying neither a status nor a kind.
public struct SessionAPIError: Equatable, Sendable, Codable {
    /// The HTTP status, from the record's `apiErrorStatus` — 529 for an overloaded API.
    public var status: Int?
    /// The CLI's own error kind, from the record's `error` key — "overloaded", "rate_limit",
    /// "server_error", "invalid_request". Read verbatim and never matched against an enum:
    /// the vocabulary is the CLI's and it will grow, so an unrecognised kind must still reach
    /// the sidebar as text rather than be dropped on the floor.
    public var kind: String?
    /// Whether `claude` considered this failure a transient one. Evaluated at parse time
    /// using the CLI's own predicate, so the rule lives at the one place holding the record.
    ///
    /// Carried but not yet rendered: nothing distinguishes a transient failure from a
    /// permanent one in the UI today. It is here because it is free at parse time and
    /// impossible to recover later — the record is long gone by the time anyone wants it.
    public var isTransient: Bool

    public init(status: Int? = nil, kind: String? = nil, isTransient: Bool = false) {
        self.status = status
        self.kind = kind
        self.isTransient = isTransient
    }

    /// The tooltip, the accessibility label, and the phone's VoiceOver string — one function
    /// so the three cannot disagree.
    public var label: String {
        var out = "Stopped — API error"
        if let status { out += " \(status)" }
        if let kind, !kind.isEmpty { out += " (\(kind))" }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case status, kind, isTransient
    }

    /// Hand-written rather than synthesized, because `isTransient` is the field written by the
    /// parser, carried on the wire, persisted, and read by nothing today — the one a future
    /// encoder is most likely to stop writing without anyone noticing, since nothing downstream
    /// would catch the omission. The synthesized decoder does `try decode(Bool.self, …)`, which
    /// throws on an absent key rather than defaulting it; for `apiError` that throw propagates
    /// out of `WireSession.init(from:)` and tears down the socket, exactly the failure
    /// `Wire.swift`'s `decodeIfPresent(Bool.self, …) ?? false` comment for `hasBackgroundWork`
    /// already guards against one file over. `status` and `kind` are `decodeIfPresent` too,
    /// matching the synthesized behavior for `Int?`/`String?`, so this changes nothing for them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        isTransient = try c.decodeIfPresent(Bool.self, forKey: .isTransient) ?? false
    }
}
