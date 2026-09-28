import Foundation

/// One changed region between two revisions of a plan: the lines it replaced (`oldLines`,
/// starting at 0-based line `oldStart` of the old text) and the lines that replaced them
/// (`newLines`, from `newStart` of the new text). A pure insertion has no `oldLines`, a pure
/// deletion no `newLines`. No context lines — the UI can pull those from either side.
public struct PlanHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldLines: [String]
    public var newStart: Int
    public var newLines: [String]
    public var section: String?
    public init(oldStart: Int, oldLines: [String], newStart: Int, newLines: [String], section: String?) {
        self.oldStart = oldStart; self.oldLines = oldLines
        self.newStart = newStart; self.newLines = newLines
        self.section = section
    }
}

/// A checkpoint's plan is two layers: `plan.md`, what the round generated (never modified
/// once written), and `plan.user.md`, the human's whole edited copy of it, when they have
/// edited it. The *effective* plan is the edited one if there is one — it is what the next
/// round reads, and what the human sees. Keeping the generated layer untouched is what lets
/// the UI show the edits as a diff over it, revert them one hunk at a time, and tell the next
/// round exactly what the human changed.
///
/// A draft checkpoint has no `plan.md`, only `drafts/<i>.md`; its generated layer is the first
/// surviving draft — the same one Sketch refines and synthesis builds on.
public enum PlanLayers {
    public static let generatedName = "plan.md"
    public static let userName = "plan.user.md"

    /// The generated layer: `plan.md`, else the lowest-numbered `drafts/<i>.md`. nil for a
    /// checkpoint with neither (or no directory at all).
    public static func generatedURL(_ checkpointDir: URL) -> URL? {
        let plan = checkpointDir.appendingPathComponent(generatedName)
        if FileManager.default.fileExists(atPath: plan.path) { return plan }
        let drafts = checkpointDir.appendingPathComponent("drafts", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasSuffix(".md"), let i = Int(name.dropLast(3)) else { return nil }
            return (i, drafts.appendingPathComponent(name))
        }.min { $0.0 < $1.0 }?.1
    }

    /// `plan.user.md` when the human has edited this checkpoint, else the generated layer.
    public static func effectiveURL(_ checkpointDir: URL) -> URL? {
        let user = checkpointDir.appendingPathComponent(userName)
        return FileManager.default.fileExists(atPath: user.path) ? user : generatedURL(checkpointDir)
    }

    public static func generatedPlan(_ checkpointDir: URL) -> String? {
        generatedURL(checkpointDir).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    public static func effectivePlan(_ checkpointDir: URL) -> String? {
        effectiveURL(checkpointDir).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The human's edits as hunks over the generated plan — what the UI renders as "your edits".
    public static func userDiff(generated: String, edited: String) -> [PlanHunk] {
        PlanMetrics.hunks(from: generated, to: edited)
    }

    /// `edited` with one hunk put back the way the generated plan had it — the new edited
    /// markdown for the app to send as a fresh `.editPlan`. nil when `hunk` no longer matches
    /// `edited` (it came from an older diff): splicing it in anyway would overwrite whatever
    /// the human has typed there since. Line endings come back as LF.
    public static func revert(_ hunk: PlanHunk, generated: String, edited: String) -> String? {
        var lines = planLines(edited).map(String.init)
        let end = hunk.newStart + hunk.newLines.count
        guard end <= lines.count, Array(lines[hunk.newStart..<end]) == hunk.newLines else { return nil }
        lines.replaceSubrange(hunk.newStart..<end, with: hunk.oldLines)
        return lines.joined(separator: "\n")
    }

    /// How many of the human's inserted lines (non-blank, compared trimmed) no longer appear
    /// anywhere in `plan` — the check after a refine or synthesis round that the integrator
    /// kept the edits it was told were authoritative. Anywhere, not in place: a round that
    /// moves an edited line into another section still kept it.
    public static func lostEditedLines(generated: String, edited: String, in plan: String) -> Int {
        let present = Set(planLines(plan).map { $0.trimmingCharacters(in: .whitespaces) })
        return userDiff(generated: generated, edited: edited)
            .flatMap(\.newLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !present.contains($0) }
            .count
    }

    /// The generated → edited unified diff a prompt carries, cut to `maxLines` with a note of
    /// how much was left out. The seat reads the full edited plan from its file either way, so
    /// a truncated diff loses only the "which lines were the human's" signal, not the edits.
    public static func promptDiff(generated: String, edited: String, maxLines: Int = 200) -> String {
        let lines = PlanMetrics.unifiedDiff(from: generated, to: edited).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return lines.joined(separator: "\n") }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n… (diff truncated: \(lines.count - maxLines) more lines; the plan file has every edit)"
    }
}
