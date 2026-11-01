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
    /// The change from `base` to `ours`, put onto `theirs` without `git` — for the edit `git
    /// merge-file` calls a conflict only because the two sides touch adjacent lines (typing at the
    /// end of the paragraph a thread's accept just reworded). The change is taken as ONE span of
    /// whole lines (the lines that differ between `base` and `ours`); it applies when `theirs`
    /// still holds those lines exactly once, untouched. Nil otherwise — a real conflict, or a
    /// change that is only an insertion, with no old lines to find.
    public static func replay(base: String, ours: String, onto theirs: String) -> String? {
        guard base != ours else { return theirs }
        let b = lines(base), o = lines(ours)
        var prefix = 0
        while prefix < b.count, prefix < o.count, b[prefix] == o[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < b.count - prefix, suffix < o.count - prefix, b[b.count - 1 - suffix] == o[o.count - 1 - suffix] { suffix += 1 }
        let old = b[prefix..<(b.count - suffix)].joined()
        let new = o[prefix..<(o.count - suffix)].joined()
        guard !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Whole lines only: an occurrence that starts mid-line is some other line.
        var starts: [Range<String.Index>] = []
        var from = theirs.startIndex
        while let range = theirs.range(of: old, range: from..<theirs.endIndex) {
            let startsLine = range.lowerBound == theirs.startIndex || theirs[theirs.index(before: range.lowerBound)].isNewline
            // A last line with no break must end where its line ends, or "The plan" would match "The planner".
            let endsLine = old.last?.isNewline == true || range.upperBound == theirs.endIndex || theirs[range.upperBound].isNewline
            if startsLine && endsLine { starts.append(range) }
            from = theirs.index(after: range.lowerBound)
        }
        guard starts.count == 1, let range = starts.first else { return nil }
        return theirs.replacingCharacters(in: range, with: new)
    }

    /// `text`'s lines, each with its line break, so joining them gives `text` back.
    private static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var line = ""
        for c in text {
            line.append(c)
            if c == "\n" || c == "\r\n" { out.append(line); line = "" }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
