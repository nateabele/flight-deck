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
}
