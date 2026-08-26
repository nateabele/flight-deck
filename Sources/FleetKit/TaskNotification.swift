import Foundation

/// A Claude Code `task-notification`, read.
///
/// Claude Code delivers a task's outcome as a `user` transcript record wrapped in
/// `<task-notification>…</task-notification>`. `ClaudeTimelineMapper.normalized` already
/// strips that outer wrapper and hands the inner text to a `.systemNotice` `TimelineItem`
/// verbatim — this type is what turns that inner text back into fields a screen can draw,
/// instead of the raw `<summary>…</summary><status>…</status>` a reader would otherwise see.
///
/// The inner text is not one XML document with a single root: it is a flat run of
/// `<label>value</label>` pairs, one after another, with no wrapper of its own. A real one
/// (`task-id`, `tool-use-id`, `output-file`, `status`, `summary`, `note`, `result`, `usage`)
/// is the shape every rule below exists to read; see the fixture inlined in
/// `TaskNotificationTests` for one captured whole.
public struct TaskNotification: Equatable, Sendable {
    /// One `<label>value</label>` pair that is not one of the three named fields.
    ///
    /// A struct rather than a `(String, String)` tuple: Swift does not conform tuples to
    /// `Equatable`, so `[(String, String)]` would block the synthesized `Equatable`
    /// conformance on `TaskNotification` itself.
    public struct Field: Equatable, Sendable {
        public let label: String
        public let value: String
        /// One level of `<label>value</label>` pairs found *inside* `value`, when `value` is
        /// nothing else — `usage`'s body is `<subagent_tokens>…</subagent_tokens><tool_uses>…
        /// </tool_uses><duration_ms>…</duration_ms>` and a renderer needs those three as their
        /// own rows under `usage`, not as a wall of tags in `usage`'s own row.
        ///
        /// Empty for a leaf, which is most fields. `value` is never cleared when this is
        /// populated: a renderer that never looks at `children` still has the raw text and
        /// loses nothing by ignoring this.
        public let children: [Field]

        public init(label: String, value: String, children: [Field] = []) {
            self.label = label
            self.value = value
            self.children = children
        }
    }

    /// The outcome headline — the `<summary>` field.
    public var summary: String?
    /// `<status>`, e.g. "completed".
    public var status: String?
    /// `<result>`. Markdown; rendering it through the existing markdown path is the caller's
    /// job, not this type's.
    public var result: String?
    /// Everything else, in document order: `task-id`, `tool-use-id`, `output-file`, `usage`,
    /// and any field a future harness adds.
    ///
    /// Kept by an allow-NOTHING rule rather than a whitelist of the labels seen so far — a
    /// label this build has never heard of still lands here instead of vanishing, which is
    /// the same "don't need to ship a new build to see a new field" reasoning
    /// `TimelineItem.Kind.unknown` and `WireSession.agent` already lean on elsewhere in this
    /// module.
    public var fields: [Field]

    public init(summary: String? = nil, status: String? = nil, result: String? = nil, fields: [Field] = []) {
        self.summary = summary
        self.status = status
        self.result = result
        self.fields = fields
    }

    /// The label characters this shape actually uses — letters, digits, `-`, `_` — kept as a
    /// single set rather than inlined at each call site.
    ///
    /// This is what stops a stray `<` in ordinary prose from being read as a tag: an email
    /// address, a "day <-> night" aside, or a genuine `<div>` the user typed all fail this
    /// check (space, `>` reached first, or a slash), so `tagOpen` reports no tag there and
    /// scanning moves on rather than misreading the rest of a person's message as XML.
    private static let labelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    /// The next `<label>` opening tag at or after `index`, or `nil` if nothing that looks
    /// like one appears again before the end of `text`.
    ///
    /// Only a bare `<label>` is recognised — no attributes, no self-closing slash — because
    /// that is the entire grammar a task-notification body uses. A `<` that does not resolve
    /// to one (no matching `>`, or something other than a label between them) is not "the
    /// closest thing to a tag": it is not a tag, so this keeps searching **past that `<`**
    /// for the next one rather than giving up the whole scan on the first character that
    /// merely resembles an opening bracket.
    private static func tagOpen(
        in text: Substring, after index: Substring.Index
    ) -> (label: String, range: Range<Substring.Index>)? {
        var searchStart = index
        while let open = text[searchStart...].firstIndex(of: "<") {
            let labelStart = text.index(after: open)
            guard labelStart < text.endIndex, let close = text[labelStart...].firstIndex(of: ">")
            else {
                // No `>` anywhere in the rest of the string, so no `<` from here on could
                // close either — there is nothing left to find, not just nothing at THIS `<`.
                return nil
            }
            let label = text[labelStart..<close]
            if !label.isEmpty, label.unicodeScalars.allSatisfy(labelCharacters.contains) {
                return (String(label), open..<text.index(after: close))
            }
            // This `<` opens nothing — a stray comparison, an unrelated bracket, prose the
            // harness inserted between fields. Resume just past IT, not past the `>` that
            // failed to pair with it: that `>` may belong to a different, later, genuine tag.
            searchStart = text.index(after: open)
        }
        return nil
    }

    /// The one level of `<label>value</label>` pairs inside a field's own value, or `nil`
    /// when the value is not ENTIRELY that — `usage`'s only, so far.
    ///
    /// Deliberately stricter than `tagOpen`/`parse` above: no skipping past junk to find the
    /// next tag, and an unclosed tag fails the whole thing rather than taking the remainder.
    /// `<result>` is markdown, routinely holding a stray `<` or `>` (a generic type, "a < b"),
    /// and the leniency that lets the TOP level shrug off surrounding noise is exactly what
    /// would make a `<result>` full of prose-with-angle-brackets look like a nested field by
    /// accident. A value only earns `children` by being *nothing but* tags, start to finish.
    private static func nestedFields(in value: Substring) -> [Field]? {
        var index = value.startIndex
        var fields: [Field] = []
        while true {
            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }
            if index == value.endIndex { break }
            guard value[index] == "<" else { return nil }

            let labelStart = value.index(after: index)
            guard labelStart < value.endIndex,
                  let closeAngle = value[labelStart...].firstIndex(of: ">")
            else { return nil }
            let label = value[labelStart..<closeAngle]
            guard !label.isEmpty, label.unicodeScalars.allSatisfy(labelCharacters.contains)
            else { return nil }

            let contentStart = value.index(after: closeAngle)
            guard let closeRange = value.range(
                of: "</\(label)>", range: contentStart..<value.endIndex
            ) else { return nil }  // unclosed: not this shape when nested

            let fieldValue = value[contentStart..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append(Field(label: String(label), value: fieldValue))
            index = closeRange.upperBound
        }
        // Whitespace alone is not "a run of pairs" — there has to be at least one.
        return fields.isEmpty ? nil : fields
    }

    /// Reads a task-notification body: the inner text of `<task-notification>…</…>`, already
    /// unwrapped and trimmed by `ClaudeTimelineMapper.normalized`.
    ///
    /// Returns `nil` for anything that is not this shape — most importantly for the bodies
    /// `normalized` emits under every OTHER wrapper name (`system-reminder`,
    /// `local-command-stdout`, and the rest of `harnessWrappers`), which are ordinary prose
    /// and must keep rendering exactly as they do today. `nil` is also what a caller gets for
    /// a body that is only `<note>…</note>` boilerplate with nothing else in it — see the
    /// guard at the end — because a `TaskNotification` with every field empty is not
    /// distinguishable from "parsing found nothing", and the caller needs that distinction to
    /// fall back to plain text.
    public static func parse(_ body: String) -> TaskNotification? {
        let text = Substring(body)
        guard let first = tagOpen(in: text, after: text.startIndex) else { return nil }

        // Text before the first tag is either nothing (the ordinary case) or whitespace left
        // over from trimming — anything else means this string opens with a person's own
        // words and a `<...>` shows up later in it by coincidence, which is exactly the shape
        // of a normal message and must fall through to prose rendering, not be spliced with
        // fields read out of its tail.
        let leading = text[text.startIndex..<first.range.lowerBound]
        guard leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var rawFields: [Field] = []
        var current = first
        while true {
            let label = current.label
            let contentStart = current.range.upperBound
            let closeTag = "</\(label)>"
            // Matched by the LITERAL closing tag, not by the next `<` — `<result>` routinely
            // holds markdown full of backticks and angle brackets (code spans, generic types,
            // "a < b"), and splitting on the first `<` inside it would cut the value off
            // partway through its own text.
            if let closeRange = text.range(of: closeTag, range: contentStart..<text.endIndex) {
                let value = text[contentStart..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                rawFields.append(Field(label: label, value: value))
                guard let next = tagOpen(in: text, after: closeRange.upperBound) else { break }
                current = next
            } else {
                // An unclosed final tag — `normalized` treats an unclosed wrapper the same
                // way, taking the remainder as the body rather than dropping it — so a
                // notification cut off mid-field (a body cut at a byte cap, same as anywhere
                // else in this pipeline) still reports what it has instead of reporting
                // nothing.
                let value = text[contentStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                rawFields.append(Field(label: label, value: value))
                break
            }
        }

        var notification = TaskNotification()
        for field in rawFields {
            switch field.label {
            case "summary": notification.summary = field.value
            case "status": notification.status = field.value
            case "result": notification.result = field.value
            // Identical boilerplate on every notification ("A task-notification fires each
            // time this agent stops…") — it says nothing about THIS task, so it is dropped
            // rather than shown as a fourth unlabelled field nobody asked for.
            case "note": continue
            default:
                let children = nestedFields(in: Substring(field.value)) ?? []
                notification.fields.append(Field(label: field.label, value: field.value, children: children))
            }
        }

        // A body that resolved to nothing recognisable — every tag present was `note`, or (in
        // principle) some future wrapper this scan cannot yet name — is the same failure as
        // finding no tag at all: the caller distinguishes "there is a notification here" from
        // "there is not" by `nil`, and a `TaskNotification` with everything empty would lie
        // about which one this was.
        guard notification.summary != nil || notification.status != nil
            || notification.result != nil || !notification.fields.isEmpty
        else { return nil }

        return notification
    }
}
