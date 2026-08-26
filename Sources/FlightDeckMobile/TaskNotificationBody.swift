import FleetKit
import MarkdownUI
import SwiftUI

/// A task notification, drawn as structure rather than as the markup it arrived in.
///
/// **What this replaces is the whole reason it exists.** Claude Code delivers a task
/// notification as a `user` record wrapped in `<task-notification>`, and
/// `ClaudeTimelineMapper.normalized` strips that wrapper and hands the row the inner text
/// verbatim. That inner text is a run of `<task-id>…</task-id><status>…</status>…` pairs, and
/// the row drew it as prose — so a reader on the phone got a wall of angle brackets where a
/// sentence about a finished agent should have been.
///
/// The parse is `FleetKit.TaskNotification`, shared rather than done here for the reason
/// `OpenPrompt` is shared: the Mac and the phone must not drift on what a transcript means.
struct TaskNotificationBody: View {
    let notification: TaskNotification
    let expanded: Bool
    /// Passed through to the result's prose so a reader can quote an agent's report back into
    /// the composer, exactly as they can from any other prose row.
    var onReply: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if !notification.fields.isEmpty { fieldTable }
            if let result = notification.result, !result.isEmpty {
                Divider()
                resultProse(result)
            }
        }
    }

    /// The outcome, as a sentence.
    ///
    /// `<summary>` is the one field that already reads as one — "Agent "…" finished" — so it
    /// leads.
    ///
    /// **The status is NOT here**, and that is the correction rather than an omission: the
    /// approved layout puts it at the trailing edge of the heading row, beside "Task
    /// notification", so it is drawn by `TimelineRow.header` (and by the detail screen's own
    /// header). A reader scanning a column of these looks down one edge for "did it work?", and
    /// a status indented under each summary is not on that edge.
    @ViewBuilder
    private var headline: some View {
        if let summary = notification.summary, !summary.isEmpty {
            Text(summary)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The plumbing fields, as a two-column table.
    ///
    /// **Values truncate in the MIDDLE, and that is not a style choice.** The longest of these
    /// is `output-file`, an absolute path whose only useful part is the filename on the end —
    /// `.tail`, the default, cuts off precisely the part worth reading.
    private var fieldTable: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(notification.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TaskNotificationFormat.label(for: field.label))
                        .font(.caption)
                        .frame(width: 58, alignment: .leading)
                        .foregroundStyle(.secondary)
                    // Monospaced on the VALUE alone. These are ids and paths, where a column
                    // that lines up is the difference between comparing two of them and
                    // reading two of them; a label is a word and reads better as one.
                    Text(TaskNotificationFormat.displayValue(for: field))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// The agent's own report, which is markdown and is drawn by the same renderer every other
    /// prose row uses — a report cannot be an essay in one row and a wall of asterisks in the
    /// next.
    ///
    /// Clamped by the same budget the raw body used to be clamped by, but applied to the
    /// RESULT alone: the headline and the fields are bounded and always worth drawing, and a
    /// line count spent on markup was never measuring anything a reader cared about.
    @ViewBuilder
    private func resultProse(_ result: String) -> some View {
        let clamped = TaskNotificationFormat.clampedResult(result, expanded: expanded)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(clamped.segments.enumerated()), id: \.offset) { _, segment in
                TimelineSegmentView(segment: segment, onReply: onReply)
            }
        }
    }
}

/// The pure decisions behind the view above, separated so they can be asserted.
///
/// A unit test in this process has no window — `docs/MOBILE.md` is explicit that SwiftUI
/// layout is unreachable here — so everything worth pinning lives in these functions rather
/// than in the view.
enum TaskNotificationFormat {
    /// How many lines of a notification's RESULT a collapsed row draws.
    ///
    /// The same 14 `TimelineStyle.proseLineLimit` has always returned for a `.systemNotice`,
    /// kept deliberately: what changed is not the budget but what it is spent on. It used to
    /// be spent counting `<tool-use-id>` lines.
    static let resultLines = 14

    /// The label a field is drawn under.
    ///
    /// The three known ones get short names because they sit in a fixed-width column beside
    /// values that need the room, and because "tool use id" is three words for a thing the
    /// reader thinks of as the call. Anything unrecognised falls back to its own label with the
    /// hyphens opened out — a field the harness adds next month appears, readable, with no
    /// build here.
    static func label(for raw: String) -> String {
        switch raw {
        case "task-id": return "task"
        case "tool-use-id": return "call"
        case "output-file": return "output"
        default: return raw.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// What a field's value shows.
    ///
    /// **A field with children must never draw its `value`.** `usage` arrives as
    /// `<subagent_tokens>65202</subagent_tokens><tool_uses>36</tool_uses>…`, and its `value` is
    /// that string verbatim — so drawing it would print raw markup inside the very row built to
    /// stop printing raw markup. The parser already unpacked those into `children`; this is the
    /// half that uses them.
    static func displayValue(for field: TaskNotification.Field) -> String {
        guard !field.children.isEmpty else { return field.value }
        return field.children.map(child(_:)).joined(separator: " · ")
    }

    /// One nested value, in words.
    ///
    /// A `switch` over the three labels this format is known to carry, and a fallback that
    /// simply says what it got. Deliberately not a units framework: the set is small, the
    /// harness owns it, and the fallback keeps an unknown child readable rather than hiding it.
    static func child(_ field: TaskNotification.Field) -> String {
        switch field.label {
        case "subagent_tokens":
            guard let n = Int(field.value) else { return field.value }
            return "\(grouped(n)) tokens"
        case "tool_uses":
            guard let n = Int(field.value) else { return field.value }
            return n == 1 ? "1 tool" : "\(grouped(n)) tools"
        case "duration_ms":
            guard let ms = Int(field.value) else { return field.value }
            return duration(milliseconds: ms)
        default:
            return "\(label(for: field.label).replacingOccurrences(of: "_", with: " ")) \(field.value)"
        }
    }

    /// Milliseconds as a person would say them. Rounded to the second, because a task
    /// notification's duration is a fact about minutes of work and the milliseconds are noise.
    static func duration(milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        guard minutes >= 60 else { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Thousands separators, from the reader's own locale rather than a hard-coded comma.
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A notification as one spoken sentence, in the order the row draws it.
    ///
    /// The markup is the whole reason this exists: `body.text` read aloud is
    /// "less-than task-id greater-than acff…", which is the defect the row was fixed for,
    /// surviving in the one modality a reader cannot skim past.
    static func spoken(_ notification: TaskNotification) -> String {
        var parts: [String] = []
        if let summary = notification.summary, !summary.isEmpty { parts.append(summary) }
        if let status = notification.status, !status.isEmpty { parts.append(status) }
        for field in notification.fields {
            parts.append("\(label(for: field.label)): \(displayValue(for: field))")
        }
        if let result = notification.result, !result.isEmpty { parts.append(result) }
        return parts.joined(separator: ". ")
    }

    /// The result's segments, clamped for a collapsed row and whole for an expanded one.
    ///
    /// Routed through `TimelineSegmenter` rather than a line-cutting of its own, so a fenced
    /// block inside an agent's report is drawn whole here exactly as it is everywhere else.
    static func clampedResult(_ result: String, expanded: Bool) -> TimelineSegmenter.Clamped {
        guard !expanded, TimelineStyle.exceeds(resultLines, result) else {
            return .init(segments: TimelineSegmenter.segments(of: result), hasMore: false)
        }
        return TimelineSegmenter.clamp(result, budget: resultLines)
    }
}
