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

    /// The Release Review's primary action (spec §10): "Release 1 Task" / "Release 14 Tasks",
    /// singular/plural on the count of ops release will actually write.
    static func releaseButton(_ n: Int) -> String {
        "Release \(n) Task" + (n == 1 ? "" : "s")
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

    /// "N of M selected" (spec §10) — the caption beside the title, `n` the ops release will
    /// actually write (ties to `releaseButton`'s own count), `of` every op the change set
    /// holds, dropped or impossible ones included.
    static func selectedCount(_ n: Int, of total: Int) -> String {
        "\(n) of \(total) selected"
    }

    /// "1 note carried into task notes" (spec §10) — the round's own annotations, once a
    /// checkpoint consumes them, ride along into the tasks it produced.
    static func notesCarried(_ n: Int) -> String {
        "\(n) \(n == 1 ? "note" : "notes") carried into task notes"
    }
}
