import Foundation

/// Something the **Mac** asks the **phone** — the one thing on this socket that travels that
/// way round.
///
/// **Why it exists at all.** The Mac has `~/Library/Logs/flight-deck-answer.log` and
/// `~/Library/Logs/flight-deck-prompt.log`, so half of every phone-side failure is already
/// written down. The other half was not written anywhere: when a handset showed a card for a
/// dialog the Mac had left, the only evidence was a person reading their screen out loud, and
/// two full days went on round trips to a pocket. This is the fetch that ends that.
///
/// **Pulled, never pushed.** The phone streams nothing on its own: it answers this frame and
/// is otherwise silent, so a paired phone cannot spend a person's battery or their data
/// shipping diagnostics nobody asked for. The only thing that starts a fetch is a developer
/// typing `scripts/answer-trigger.sh logs`, behind the same `FlightDeckAnswerTrigger` gate as
/// the answer drive — pulling logs off a phone belongs behind the gate that drives a terminal.
///
/// **A request, in `FleetRequest`'s sense, and not a command.** Its whole point is the data
/// carried back, correlated by `cid` — see `FleetRequest`'s own doc comment for the line
/// between the two verbs. It gets no `seq`, for the reason `ServerFrame.page` gives: a log
/// fetch is not fleet state, and moving a client's resume point with one would cost it real
/// history on its next `hello`.
public enum PhoneRequest: Codable, Equatable, Sendable {
    /// Everything the phone logged in the last `seconds` seconds, newest last, at most
    /// `limit` entries.
    ///
    /// **A duration rather than an instant, and that is not a style choice.** A `Date` on this
    /// wire would be the Mac's clock asking a question about the phone's, and the two are
    /// independently set — a handset an hour out would answer with nothing at all and give no
    /// hint why. A duration is evaluated entirely on the phone, against the same clock that
    /// stamped the entries, so skew cannot silently empty the answer.
    ///
    /// Both values are clamped **by the phone** (`PhoneLogLimits`) rather than refused here,
    /// the same contract `FleetRequest.timeline`'s `limit` keeps: a caller asking for more
    /// than the ceiling gets the ceiling, not an error it has to learn to parse.
    case logs(seconds: Int, limit: Int)

    enum CodingKeys: String, CodingKey { case op, seconds, limit }

    private enum Op: String, Codable {
        case logs = "phone.logs"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .logs(let seconds, let limit):
            try c.encode(Op.logs, forKey: .op)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(limit, forKey: .limit)
        }
    }

    /// An unrecognised `op` throws, exactly as `FleetRequest`'s does and for the same reason:
    /// a request that cannot be understood cannot be answered, and guessing at it answers the
    /// wrong question.
    ///
    /// What keeps that throw from taking the socket down is the salvage path — see
    /// `FleetSocket.CorrelatedFrame` and `FleetClient.connect`, which refuse one unparseable
    /// `ask` on its own `cid` and read the next frame. That is the same arrangement
    /// `FleetSocketServer` already has for a `req` it cannot parse, now mirrored on the half
    /// of the wire that just gained a request.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .logs:
            self = .logs(
                seconds: try c.decode(Int.self, forKey: .seconds),
                limit: try c.decode(Int.self, forKey: .limit)
            )
        }
    }
}

/// Why a phone would not answer a `PhoneRequest`.
///
/// A wrapped `String` rather than an enum, and that is the decode-unknown rule in this
/// direction: the code travels phone → Mac and is *printed*, so a newer phone inventing one
/// must leave an older Mac showing "the phone said no" rather than failing to parse. Same
/// reasoning `FleetRequestError.server` gives for the other half of this wire, and the same
/// reason `WireSession.agent` is a `String`.
public struct PhoneRequestRefusal: Error, Equatable, Sendable {
    /// Goes onto the wire verbatim, as `ClientFrame.refused`'s `code`. See that case for the
    /// ones this app produces.
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// What a log fetch may cost, on both ends.
///
/// Stated here rather than on either side so the phone and the Mac clamp to one number — the
/// same arrangement `TimelineLimits` and `SearchLimits` have, and for the same reason: two
/// constants of the same name disagreeing about the same job is how a bound ends up being
/// whichever one the reader happened to find.
public enum PhoneLogLimits {
    /// The most entries one reply may carry.
    ///
    /// **500, and the number is sized against the message cap rather than guessed.** A phone
    /// entry is a category, a level, a timestamp and a short structural line — call it 300
    /// bytes encoded, generously — so 500 of them is ~150 KB against
    /// `TimelineLimits.maximumMessageSize` of 4 MB. There is room for far more; the cap is
    /// this low because a diagnostic that returns an hour of scrollback is one nobody reads.
    /// The phone reports `truncated` when it bites, so a short answer is never mistaken for a
    /// quiet phone.
    public static let maxEntries = 500

    /// The furthest back a fetch may reach: one day.
    ///
    /// Generous against what actually survives, which is the point of not making it smaller.
    /// `OSLogStore(scope: .currentProcessIdentifier)` — the only scope an iOS app may open
    /// without an entitlement — holds this process's entries and nothing from before the last
    /// launch, so the real horizon is usually far shorter than a day. A ceiling that pretended
    /// otherwise would invite a caller to read "empty" as "nothing happened" rather than as
    /// "the app was relaunched".
    public static let maxSeconds = 86_400

    /// The window a caller gets when it names none. Ten minutes: long enough to hold the
    /// connect, the card and the tap that a report is about, short enough to read.
    public static let defaultSeconds = 600
}

/// One line the phone logged.
///
/// **Structural only, and that is a boundary rather than a preference.** These entries cross a
/// device boundary and land in a file on someone's Mac, so nothing here carries prompt option
/// text, transcript content, or anything a person typed. Ids, counts, states and timings —
/// see `PhoneLog` in the phone app, which is the only thing that writes what this carries.
public struct WirePhoneLogEntry: Codable, Equatable, Sendable {
    /// ISO-8601, formatted by the phone in its own offset.
    ///
    /// A `String` rather than a `Date`, following `TimelineItem.at`'s rule: a `Date` drags
    /// `JSONEncoder`'s date strategy into the wire contract, and the only consumer is a text
    /// file a human reads. Formatting it on the phone also keeps the stamp in the phone's
    /// timezone, which is what makes a line here comparable by eye against the Mac's own
    /// `flight-deck-prompt.log`.
    public let at: String
    /// `debug`, `info`, `notice`, `error` or `fault` — `OSLogEntryLog.Level`, spelled out.
    public let level: String
    /// The `os.Logger` category the line was written to: `connection`, `prompt` or `answer`.
    public let category: String
    /// The formatted line. Structural by construction — see the type's doc comment.
    public let message: String

    public init(at: String, level: String, category: String, message: String) {
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }
}

/// The phone's answer to `PhoneRequest.logs`.
public struct WirePhoneLogs: Codable, Equatable, Sendable {
    /// Oldest first, so the file this is appended to reads in the order things happened.
    public let entries: [WirePhoneLogEntry]
    /// Whether `PhoneLogLimits.maxEntries` cut the answer short — the oldest entries in the
    /// window were dropped, not the newest.
    ///
    /// Carried because a short answer and a truncated one look identical otherwise, and they
    /// mean opposite things: one says the phone was quiet, the other says the window was too
    /// wide. A reader that cannot tell them apart will draw the wrong conclusion from the
    /// first line of the file.
    public let truncated: Bool

    public init(entries: [WirePhoneLogEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// What a peer says it can answer, sent in `ClientFrame.hello`.
///
/// **This is what keeps a new Mac from stranding an old phone.** A `ServerFrame` tag a phone
/// has no case for falls through its decoder to the `event` arm, fails to find a `seq`, and
/// throws — and a throw on that side takes the socket with it (`FleetSocket.receive`), so a
/// Mac that sent a log request blind to a phone built before this feature would hang up on
/// every already-paired handset it has. The Mac therefore asks nobody who did not first say
/// it could answer.
///
/// A list of strings rather than a version number, and not `FleetKitVersion.wire`: a phone and
/// a Mac are updated on separate schedules by separate mechanisms, so "newer than" is a fact
/// neither can act on usefully, while "answers log requests" is.
public enum FleetCapability {
    /// This peer answers `PhoneRequest.logs`.
    public static let logs = "logs"

    /// Everything this build of FleetKit can answer when asked. Sent verbatim in `hello`.
    ///
    /// Claimed by the FleetKit half rather than by the app, because the frame handling is
    /// what is actually being advertised: a phone whose app forgot to install a log provider
    /// still answers, with `unhandled`, which is a refusal the Mac can print rather than a
    /// request that never comes back.
    public static let supported = [logs]
}
