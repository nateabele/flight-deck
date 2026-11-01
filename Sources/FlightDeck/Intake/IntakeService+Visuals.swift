import Foundation
import FleetKit
import IntakeKit

/// What a refused visual op says; `code` is the wire `err` code.
struct VisualRefusal: Error, Equatable, Sendable {
    let code: String
    /// Nonisolated, so `VisualFetch.serve` (off the main actor) can refuse with it.
    static let unavailable = VisualRefusal(code: "visuals_unavailable")
}

/// The visual blocks' entry points on the Mac (planning v2 §7, §10). The one op is
/// `VisualFetch.serve`; the detail's `visuals` flag tells the phone it may send it.
extension IntakeService {
    /// Whether this Mac serves visuals. The detail's `visuals` flag follows it.
    var visualsAvailable: Bool { VisualFetch.gateOpen }

    /// The intake's visuals on disk: always a disk store, even before the intake has a
    /// `visuals/` folder, in which case it serves nothing until the folder appears. Always
    /// non-nil on purpose: the editor's hook (`PlanEditHooks.visuals`) takes this, and
    /// `DocumentPlan.==` ignores the hooks, so a reader that was nil at first render would stay
    /// nil. The renderer reads through it and never reaches into `IntakeDetailView` or the
    /// service itself.
    func visualReader(_ id: UUID) -> any VisualStoreReading {
        DiskVisualStore(tape: tapeStore(id))
    }
}

// MARK: - Release export (spec §12, V-R4)

/// The plan release exports, read from disk off the main actor: the head plan checkpoint's
/// effective plan and the block states it recorded (falling back to `block.json`).
struct ReleasePlan: Sendable {
    let checkpoint: Int
    let markdown: String

    /// nil for an intake with no plan (Single-task fidelity). `tape` is the service's cached copy
    /// when it has one; otherwise it is read here.
    nonisolated static func read(_ tapes: TapeStore, cached tape: Tape?) -> ReleasePlan? {
        let tape = tape ?? tapes.loadTape()
        guard let head = tapes.headPlanCheckpoint(in: tape), let markdown = tapes.effectivePlan(checkpoint: head) else { return nil }
        return ReleasePlan(checkpoint: head, markdown: markdown)
    }
}

extension IntakeService {
    /// The tape store and whatever copy of the tape is already in memory, taken on the main actor
    /// so the disk work that follows can run off it.
    private func releaseSources(_ id: UUID) -> (TapeStore, Tape?, any VisualStoreReading) {
        (tapeStore(id), tapes[id] ?? latestTapes[id], visualReader(id))
    }

    /// The visuals `id`'s change set may cite, each with its states (`ChangeSetValidator`'s
    /// `knownVisuals` and `visualStates`), by the released checkpoint's block states: empty, never
    /// nil, for a plan with none or no plan.
    func knownVisuals(_ id: UUID) async -> [String: Set<String>] {
        let (tapes, cached, reader) = releaseSources(id)
        return await Task.detached {
            guard let plan = ReleasePlan.read(tapes, cached: cached) else { return [String: Set<String>]() }
            return PlanVisualFence.knownVisualStates(plan: plan.markdown, store: reader, checkpoint: plan.checkpoint)
        }.value
    }

    /// `cs` validated against `graph` with `id`'s visuals: refs to a removed visual or state are
    /// dropped with a warning (final review A-I2, A-M5).
    func validate(_ cs: ChangeSet, against graph: GraphSnapshot, visuals: [String: Set<String>]) -> Result<ValidatedChangeSet, ValidationErrors> {
        ChangeSetValidator.validate(cs, against: graph, knownVisuals: Set(visuals.keys), visualStates: visuals)
    }

    /// What release writes to `docs/plans/<slug>/` (D14, §12: every plan), or nil for an intake
    /// with no plan. A block with nothing stored refuses, naming its id, so no task is written
    /// beside a plan that says its visual is missing. Everything here, the slug's folder checks
    /// included, runs off the main actor.
    func releaseExport(_ i: Intake) async -> Result<PlanExport, ReleaseExportRefusal>? {
        let (tapes, cached, reader) = releaseSources(i.id)
        let repo = URL(fileURLWithPath: i.projectPath, isDirectory: true)
        let intakeID = i.id.uuidString
        let title = IntakeTitle(intent: i.intent).title
        return await Task.detached { () -> Result<PlanExport, ReleaseExportRefusal>? in
            guard let plan = ReleasePlan.read(tapes, cached: cached) else { return nil }
            var states: [VisualID: BlockState] = [:]
            for block in PlanVisualFence.blocks(in: plan.markdown) {
                states[block.id] = reader.blockState(block.id, checkpoint: plan.checkpoint)
            }
            let slug = PlanExporter.resolveSlug(title: title, intakeID: intakeID) { RepoCommitter.owner(of: $0, repo: repo) }
            do {
                let export = try PlanExporter.export(plan: plan.markdown, slug: slug, intakeID: intakeID, store: reader,
                                                     blockStates: states)
                guard export.missing.isEmpty else {
                    let ids = export.missing.map { "`\($0)`" }.joined(separator: ", ")
                    return .failure(ReleaseExportRefusal(message: "The plan names visuals with nothing stored (\(ids)). "
                        + "Release would leave tasks citing folders it cannot write; make or remove them, then release again."))
                }
                return .success(export)
            } catch {
                return .failure(ReleaseExportRefusal(message: IntakeService.exportMessage(error)))
            }
        }.value
    }

    /// What release would write and commit, for the sheet: the files, the commit, and what a
    /// re-release removes; or why it would refuse (A-M4), so the sheet says so before Release is
    /// pressed. Without git's answer (not a repo yet) the files and commit still show. nil for an
    /// intake with no plan.
    func releasePreview(_ i: Intake) async -> Result<PlanExportPreview, ReleaseExportRefusal>? {
        switch await releaseExport(i) {
        case nil: return nil
        case .failure(let refusal)?: return .failure(refusal)
        case .success(let export)?:
            let repo = URL(fileURLWithPath: i.projectPath, isDirectory: true)
            return .success((try? await RepoCommitter().preview(export, repo: repo)) ?? export.preview)
        }
    }

    /// A release export or commit failure in the human's words, naming the path.
    nonisolated static func exportMessage(_ error: Error) -> String {
        switch error {
        case let f as RepoCommitter.Failure:
            switch f {
            case .dirty(let path, _):
                return "\(path)/ has changes that are not committed. Commit or remove them, then release again; nothing was written."
            case .git(let step, let stderr):
                let words = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(step) failed while exporting the plan" + (words.isEmpty ? "." : ": \(words)")
            case .unsafePath(let p): return "The plan export has an unsafe path (\(p)); nothing was written."
            case .symlink(let p): return "\(p) is a symbolic link, so the plan export will not write through it."
            case .notOwned(let p): return "\(p)/ is not this plan's folder, so release will not overwrite it."
            case .ignored(let paths): return "git ignores files the export must commit: " + paths.joined(separator: ", ")
            case .badSlug(let s): return "\"\(s)\" is not a usable folder name for the plan export."
            case .notARepo(let path):
                return "\(path) is not in a git repo, so release cannot commit the plan there. Run git init (or open the project inside its repo), then release again."
            case .notRepoRoot(let top):
                return "The project is not inside the git repo git reports (\(top.isEmpty ? "none" : top)), so the plan cannot be exported."
            case .timeout(let step): return "git \(step) did not finish while exporting the plan (a hook may be stuck)."
            case .io(let detail): return "Writing the plan export failed: \(detail)"
            }
        case let f as PlanExporter.Failure:
            switch f {
            case .unreadable(let visual, let path): return "The visual \(visual)'s file \(path) could not be read for export."
            case .unsafePath(let p): return "A visual lists an unsafe path (\(p)), so the plan was not exported."
            }
        default:
            return "The plan export failed: \(error)"
        }
    }
}

/// Why release would not export the plan, in the human's words.
struct ReleaseExportRefusal: Error, Equatable, Sendable {
    let message: String
}
