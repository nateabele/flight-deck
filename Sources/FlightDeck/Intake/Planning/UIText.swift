import IntakeKit

/// The renamed strings the planning-UI redesign builds on: one place that says "task", never
/// "bead" (spec `2026-09-27-planning-ui-redesign-design.md` §2), so the Release Review (§10)
/// and fidelity picker (§9) — and every later task that touches either — share a single
/// source of wording instead of each re-deriving it. `Preset` itself, and its `.bead` case,
/// keep their internal name; only what a human reads changes here.
enum UIText {
    /// `.bead` reads "Single task" everywhere it's shown — the fidelity preset a user picks
    /// never says "bead" (spec §2).
    static func presetName(_ preset: Preset) -> String {
        switch preset {
        case .bead: return "Single task"
        case .sketch: return "Sketch"
        case .featurePlan: return "Feature plan"
        case .fullPlan: return "Full plan"
        }
    }

    /// The Release Review's primary action (spec §10): "Release 3 New Tasks" — the same count
    /// the summary line beside it opens with (`ReleaseCounts.phrase`), so the two can't read
    /// different numbers. Counting every op here once put "Release 7 Tasks" over a summary of
    /// 3 new tasks, 2 edits and 2 dependencies. With no new task it says what it does without
    /// a zero; with nothing at all it is just "Release" (and disabled by the sheet).
    static func releaseButton(_ counts: ReleaseCounts) -> String {
        if counts.newTasks > 0 { return "Release \(counts.newTasks) New Task" + (counts.newTasks == 1 ? "" : "s") }
        return counts.isEmpty ? "Release" : "Release Changes"
    }

    /// The Release Review's creates section (spec §10) — was "New beads".
    static let newTasksSection = "New tasks"

    /// The Release Review's edits section (spec §10) — field changes and reopens grouped
    /// together, since both mutate a bead that already exists.
    static let editsSection = "Edits"

    /// The Release Review's edge section (spec §10) — was "Edges"; renamed so the word a user
    /// reads matches what the row shows (a new dependency between two tasks).
    static let dependenciesSection = "Dependencies"

    /// The Release Review's sheet title (spec §10) — was "Release Review".
    static let releaseSheetTitle = "Release plan as tasks"

    /// "2 dropped" — the header caption beside the title, shown only once something is left
    /// out (dropped by hand, or impossible). It was "N of M selected", but rows can only be
    /// dropped, never selected, so it claimed a selection the sheet doesn't have.
    static func droppedCount(_ n: Int) -> String { "\(n) dropped" }

    /// The badge on a dependency that is only written once its new task exists (an existing
    /// task waiting on a new one — `ChangeSetValidator`'s held edge; "held" is the engine's word).
    static let waitsForRelease = "waits for release"

    /// "1 note carried into task notes" (spec §10) — the round's own annotations, once a
    /// checkpoint consumes them, ride along into the tasks it produced.
    static func notesCarried(_ n: Int) -> String {
        "\(n) \(n == 1 ? "note" : "notes") carried into task notes"
    }

    /// A `SlotOutcome.role` as a human reads it. `"crossReviewer"` is the engine's internal seat
    /// name (coverage spec §3) — a second reviewer, not a different kind of work — so it reads
    /// "cross-check agent" everywhere a role is shown; every other role is already the public word.
    static func roleName(_ role: String) -> String {
        role == "crossReviewer" ? "cross-check agent" : role
    }

    /// First letter up, the rest untouched — `String.capitalized` title-cases every word, which
    /// turns "cross-check agent" into "Cross-Check Agent"; a role name is a phrase, not a title.
    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
