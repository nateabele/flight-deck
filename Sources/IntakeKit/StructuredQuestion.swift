import Foundation

/// A clarifying question the human answers by choosing, not typing. Sits beside the plain
/// `TriageExchange.questions` strings so an agent that only returns strings, and every intake
/// saved before this existed, still presents and answers as free text.
public struct StructuredQuestion: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case single, multi, toggle, text }

    public struct Option: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var detail: String?
        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    /// Estimated price of picking the question's recommended path. Unused until P2a.
    public struct Cost: Codable, Equatable, Sendable {
        public var seconds: Int
        public var tokens: Int
        public init(seconds: Int, tokens: Int) {
            self.seconds = seconds
            self.tokens = tokens
        }
    }

    public var id: String
    public var text: String
    public var kind: Kind
    public var options: [Option]
    public var recommended: [String]
    public var allowOther: Bool
    public var cost: Cost?

    public init(id: String, text: String, kind: Kind, options: [Option] = [], recommended: [String] = [],
                allowOther: Bool = false, cost: Cost? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.options = options
        self.recommended = recommended
        self.allowOther = allowOther
        self.cost = cost
    }

    /// The free-text question every legacy string maps to.
    public static func text(id: String, _ text: String) -> StructuredQuestion {
        StructuredQuestion(id: id, text: text, kind: .text)
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Whether the answer may be sent. Multi and toggle are always complete: "nothing ticked" and
    /// "off" are real answers, and blocking on them would stall the human on an optional choice.
    public func isComplete(_ a: StructuredAnswer) -> Bool {
        switch kind {
        case .text: Self.nonBlank(a.other) != nil
        case .single: a.selected.count == 1 || (a.selected.isEmpty && Self.nonBlank(a.other) != nil)
        case .multi, .toggle: true
        }
    }

    /// Whether `a` names only this question's own options, each once — the shape check
    /// `isComplete` does not make. Without it a stale or invented id (an option a retry
    /// replaced, a typo from a client) is stored as the answer and renders as the raw id, and a
    /// duplicate renders twice. A text question has no options, so any selection is wrong.
    public func accepts(_ a: StructuredAnswer) -> Bool {
        if kind == .text { return a.selected.isEmpty }
        let valid = Set(options.map(\.id))
        return Set(a.selected).count == a.selected.count && a.selected.allSatisfy(valid.contains)
    }

    /// The answer as the plain string the agent reads back, so the structured path feeds the
    /// same `answers: [String]` the text path always has.
    public func render(_ a: StructuredAnswer) -> String {
        let other = Self.nonBlank(a.other)
        switch kind {
        case .text:
            return other ?? ""
        case .toggle:
            // Only the toggle's own option means Yes; a stray id from a stale or invented answer
            // must not flip the agent's reading to Yes.
            return options.first.map { a.selected.contains($0.id) } == true ? "Yes" : "No"
        case .single:
            if let id = a.selected.first { return label(for: id) }
            return other.map { "Other: \($0)" } ?? ""
        case .multi:
            let labels = a.selected.map(label(for:)).joined(separator: ", ")
            switch (labels.isEmpty, other) {
            case (true, nil): return "None"
            case (true, let o?): return "Other: \(o)"
            case (false, nil): return labels
            case (false, let o?): return "\(labels); Other: \(o)"
            }
        }
    }

    /// Recommended options preselected so accepting the agent's advice is zero taps. A toggle is
    /// off unless recommended (its one option's id being selected means Yes).
    public var initialAnswer: StructuredAnswer {
        let valid = Set(options.map(\.id))
        var picked = recommended.filter { valid.contains($0) }
        if kind == .single || kind == .toggle { picked = Array(picked.prefix(1)) }
        if kind == .text { picked = [] }
        return StructuredAnswer(questionID: id, selected: picked, other: nil)
    }

    /// An id the agent invented falls back to itself rather than rendering blank.
    private func label(for optionID: String) -> String {
        options.first { $0.id == optionID }?.label ?? optionID
    }
}

/// `selected` holds option ids. For a text question the typed answer lives in `other`.
public struct StructuredAnswer: Codable, Equatable, Sendable {
    public var questionID: String
    public var selected: [String]
    public var other: String?
    public init(questionID: String, selected: [String] = [], other: String? = nil) {
        self.questionID = questionID
        self.selected = selected
        self.other = other
    }
}

extension TriageExchange {
    /// What the UI shows: the structured questions when the agent sent them, else the plain
    /// strings as free-text questions, so old intakes keep working unchanged.
    public var presentedQuestions: [StructuredQuestion] {
        structured ?? questions.enumerated().map { .text(id: "q\($0.offset + 1)", $0.element) }
    }

    /// Names this round by what it asks: the presented questions' ids, texts, kinds and option
    /// ids, in order. The round's index is not enough: `retry` clears the exchanges, so a fresh
    /// triage's first round reuses index 0 with different questions, and answers or drafts
    /// keyed by index alone would land on questions they were never typed against.
    ///
    /// FNV-1a 64 over a length-prefixed encoding, as 16 hex digits: IntakeKit is Foundation-only,
    /// and the value must be the same on every build and every launch (Swift's `Hasher` is
    /// seeded per process). Labels and details are left out: rewording an option does not
    /// change what its id means.
    public var questionsDigest: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ field: String) {
            // The byte count first, so ["ab", "c"] and ["a", "bc"] never encode alike.
            for byte in Array("\(field.utf8.count):".utf8) + Array(field.utf8) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        for q in presentedQuestions {
            mix(q.id); mix(q.text); mix(q.kind.rawValue)
            mix("\(q.options.count)")
            q.options.forEach { mix($0.id) }
        }
        return String(format: "%016llx", hash)
    }
}
