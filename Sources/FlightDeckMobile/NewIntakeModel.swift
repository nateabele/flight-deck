import FleetKit
import Foundation

/// The New Intake sheet's state (spec §4.10), and the send that turns it into an intake.
///
/// **Lives on the fleet, not in the sheet.** Triage closes the sheet at once and the answer
/// arrives later, over the intake's own screen; a model owned by the sheet would be gone when a
/// refusal needs to reopen it with the draft and the reason.
///
/// **The phone mints the intake's id.** That is what lets Triage push the intake's screen before
/// the Mac has answered: the screen shows a wait (`IntakeDetailModel.awaitingCreation`) until the
/// Mac's detail for that id arrives. A refusal pops it again and reopens the sheet.
@MainActor
@Observable
final class NewIntakeModel {
    var isPresented = false
    /// The project the intake will be made in. Always one that offers Flight Control while the
    /// sheet is up; a project's draft is saved under it as it is typed.
    private(set) var project: UUID?
    var text = "" {
        didSet {
            guard text != oldValue, let project else { return }
            drafts?.save(text, for: project)
        }
    }
    /// Why the last Triage did not take, in words; cleared by the next one.
    private(set) var refusal: String?

    @ObservationIgnored private weak var flightControl: FlightControlModel?
    @ObservationIgnored private let drafts: DraftStore?
    /// Pushes the intake's screen and returns the stack's depth before it, for `close`.
    @ObservationIgnored private let open: @MainActor (UUID) -> Int
    @ObservationIgnored private let close: @MainActor (Int) -> Void
    /// Stack depth before each open create's screen was pushed.
    @ObservationIgnored private var opened: [UUID: Int] = [:]
    /// The last create whose fate is unknown (a timeout, or the socket dropping mid-send). The
    /// next Triage of the same text in the same project reuses its id, so a create that did land
    /// is acked by the Mac as a repeat rather than made twice — the retry rule
    /// `IntakeCommandModel` keeps for tokens, applied to the id.
    @ObservationIgnored private var unsettled: (id: UUID, project: UUID, intent: String)?

    init(flightControl: FlightControlModel, drafts: DraftStore?,
         open: @escaping @MainActor (UUID) -> Int, close: @escaping @MainActor (Int) -> Void) {
        self.flightControl = flightControl
        self.drafts = drafts
        self.open = open
        self.close = close
    }

    /// Whether `project` can start an intake from the phone: Flight Control is on for it
    /// (`intakes` is non-nil) and the Mac says it handles the op. Without the second an older
    /// Mac would drop the socket on `intake.create`.
    static func offers(_ project: WireProject) -> Bool {
        project.intakes != nil && project.canCreateIntake == true
    }

    var canTriage: Bool {
        project != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Opens the sheet on `project` with its saved draft.
    func present(project: UUID) {
        refusal = nil
        select(project)
        isPresented = true
    }

    /// Switches the Project row: each project keeps its own draft.
    func select(_ project: UUID) {
        guard project != self.project else { return }
        self.project = project
        text = drafts?.draft(for: project) ?? ""
    }

    func triage() {
        guard canTriage, let project, let flightControl else { return }
        let intent = text
        let id = unsettled.flatMap { $0.project == project && $0.intent == intent ? $0.id : nil } ?? UUID()
        let commands = flightControl.commands(for: id)
        guard !commands.inFlight.contains(.create) else { return }
        refusal = nil
        let detail = flightControl.detailModel(for: id)
        detail.awaitingCreation = true
        var failedBeforeOpening = false
        commands.send(
            .create,
            command: { .intakeCreate(id: id, token: $0, project: project, intent: intent) },
            onAck: { [weak self] in
                detail.awaitingCreation = false
                self?.unsettled = nil
                self?.opened[id] = nil
                self?.drafts?.save("", for: project)
                if self?.project == project { self?.text = "" }
                detail.refresh()
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                detail.awaitingCreation = false
                // Only a definitive refusal settles the id; anything else may have landed.
                if case .server? = error { self.unsettled = nil } else { self.unsettled = (id, project, intent) }
                self.refusal = commands.message
                if let depth = self.opened.removeValue(forKey: id) {
                    self.close(depth)
                } else {
                    failedBeforeOpening = true
                }
                self.isPresented = true
            })
        // Answered before it returned (no socket): the sheet never closed, so there is no screen
        // to take back and nothing more to do.
        guard !failedBeforeOpening else { return }
        isPresented = false
        let depth = open(id)
        if commands.inFlight.contains(.create) { opened[id] = depth }
    }

    /// Unpair: nothing typed or in flight belongs to the next pairing.
    func reset() {
        isPresented = false
        project = nil
        text = ""
        refusal = nil
        opened = [:]
        unsettled = nil
    }
}
