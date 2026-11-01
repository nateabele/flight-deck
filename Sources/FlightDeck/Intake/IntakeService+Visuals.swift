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

extension IntakeService {
    /// The plan release exports and encode validated against: the head plan checkpoint's
    /// effective plan. nil for an intake with no plan (Single-task fidelity).
    func releasePlan(_ id: UUID) -> (checkpoint: Int, markdown: String)? {
        let tapes = tapeStore(id)
        guard let head = tapes.headPlanCheckpoint(in: storedTape(id)), let markdown = tapes.effectivePlan(checkpoint: head)
        else { return nil }
        return (head, markdown)
    }

    /// The visual ids `id`'s change set may cite (`ChangeSetValidator`'s `knownVisuals`): `Set()`,
    /// never nil, for a plan with none, or for no plan at all.
    func knownVisuals(_ id: UUID) -> Set<String> {
        PlanVisualFence.knownVisuals(plan: releasePlan(id)?.markdown, store: visualReader(id))
    }

    /// What release writes to `docs/plans/<slug>/`, or nil when it writes nothing: a plan with no
    /// `fd-visual` block and no task citing one is not exported, so a release without visuals
    /// never touches the user's repo. Built off the main actor: it reads every exported byte.
    func releaseExport(_ i: Intake) async -> Result<PlanExport, ReleaseExportRefusal>? {
        let cites = i.changeSet?.ops.contains { op in
            if case .createBead(let b) = op { return !(b.visualRefs ?? []).isEmpty }
            return false
        } ?? false
        guard let plan = releasePlan(i.id), cites || !PlanVisualFence.blocks(in: plan.markdown).isEmpty else { return nil }
        let reader = visualReader(i.id)
        var states: [VisualID: BlockState] = [:]
        for block in PlanVisualFence.blocks(in: plan.markdown) {
            states[block.id] = reader.blockState(block.id, checkpoint: plan.checkpoint)
        }
        let repo = URL(fileURLWithPath: i.projectPath, isDirectory: true)
        let intakeID = i.id.uuidString
        let slug = PlanExporter.resolveSlug(title: IntakeTitle(intent: i.intent).title, intakeID: intakeID) {
            RepoCommitter.owner(of: $0, repo: repo)
        }
        let markdown = plan.markdown, blockStates = states
        return await Task.detached {
            do {
                return .success(try PlanExporter.export(plan: markdown, slug: slug, intakeID: intakeID, store: reader,
                                                        blockStates: blockStates))
            } catch {
                return .failure(ReleaseExportRefusal(message: IntakeService.exportMessage(error)))
            }
        }.value
    }

    /// What release would write and commit, for the sheet: the files, the commit, and what a
    /// re-release removes. Without git's answer (not a repo yet) the files and commit still show.
    func releasePreview(_ i: Intake) async -> PlanExportPreview? {
        guard case .success(let export)? = await releaseExport(i) else { return nil }
        let repo = URL(fileURLWithPath: i.projectPath, isDirectory: true)
        return (try? await RepoCommitter().preview(export, repo: repo)) ?? export.preview
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
            case .notRepoRoot(let top):
                return "The project is not the root of its git repo (git says \(top.isEmpty ? "none" : top)), so the plan cannot be exported."
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
