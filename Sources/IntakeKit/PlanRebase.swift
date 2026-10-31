import Foundation

/// Carrying a plan edit made on one checkpoint onto a newer head (R4). It was `EditLayer.retarget`
/// in the app; it lives here now so ThreadRunner, which links IntakeKit and nothing else, can
/// rebase a pending thread diff by the same rule the editor uses for a stale edit. `EditLayer`
/// forwards to it.
public enum PlanRebase {
    /// What to send for an edit committed after its checkpoint stopped being the plan head.
    public struct Retarget: Equatable, Sendable {
        public var command: TapeCommand
        /// Set when the edit could not be carried: it stays on its checkpoint, and the banner
        /// points the human at it.
        public var conflict: EditConflict?

        public init(command: TapeCommand, conflict: EditConflict?) {
            self.command = command
            self.conflict = conflict
        }
    }

    /// The runner's own carry rule (`PlanLayers.carryForward`), for the one case it can't see:
    /// an edit committed after the new head already exists. Kept on the old checkpoint it
    /// would feed nothing (`TapeStore.headPlanCheckpoint`), so it is three-way merged onto the
    /// head — ours = the head's plan, base = the text the edit was typed on, theirs = the edit —
    /// and sent for the head. A conflict keeps it where it was typed, as before.
    ///
    /// Nonisolated and async, so `git` runs off the main actor. The caller's own environment is
    /// enough: `git` is `/usr/bin/git`, on every PATH, and a login-shell lookup here would
    /// block for seconds.
    public static func retarget(markdown: String, typedOn: Int, base: String, head: Int, headPlan: String,
                                runner: CommandRunner) async -> Retarget {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("flightdeck-carry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        switch await PlanLayers.carryForward(ours: headPlan, base: base, theirs: markdown, runner: runner,
                                             environment: ProcessInfo.processInfo.environment, scratch: scratch) {
        case .merged(let plan):
            return Retarget(command: .editPlan(checkpoint: head, markdown: plan), conflict: nil)
        case .conflicted:
            return Retarget(command: .editPlan(checkpoint: typedOn, markdown: markdown),
                            conflict: EditConflict(edits: typedOn, landedIn: head))
        }
    }
}
