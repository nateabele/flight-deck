import FleetKit
import Foundation

/// What the phone knows about the gate it is showing.
///
/// **Splits with `PlanBlocks`, never its own rule** — the whole reason that type is in
/// `FleetKit`. The index this model sends is meaningful only because the Mac computes the
/// same list from the same text.
@MainActor
final class PlanReviewModel: ObservableObject {
    let session: UUID
    let gate: WirePlanGate
    let blocks: [PlanBlocks.Block]

    /// Typed into the box above the verdict buttons, and carried by whichever one is pressed.
    @Published var feedback: String = ""
    /// Comments already sent, by block index, so the row can show a marker.
    @Published private(set) var sent: [Int: [String]] = [:]
    @Published private(set) var globalSent: [String] = []
    @Published private(set) var resolved = false

    private let send: (FleetCommand) -> Void

    /// `transcriptPlan` is the `verdict` tier's source: there, the gate carries no plan and the
    /// phone reads `ExitPlanMode`'s own `input.plan` out of the timeline body it already holds.
    init(session: UUID, gate: WirePlanGate, transcriptPlan: String? = nil,
         send: @escaping (FleetCommand) -> Void) {
        self.session = session
        self.gate = gate
        self.send = send
        self.blocks = PlanBlocks.split(gate.plan ?? transcriptPlan ?? "").blocks
    }

    /// Inline pinning needs a live Plannotator gate. In the `verdict` tier the plan still
    /// renders — it just takes no taps, and the screen says why once.
    func canComment(on block: Int) -> Bool {
        guard gate.tier == "annotate", !resolved else { return false }
        return blocks.first { $0.index == block }?.isTarget == true
    }

    func comment(on block: Int?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !resolved else { return }
        if let block { guard canComment(on: block) else { return } }
        send(.annotatePlan(id: session, token: UUID(), call: gate.callID,
                           text: trimmed, block: block))
        if let block { sent[block, default: []].append(trimmed) }
        else { globalSent.append(trimmed) }
    }

    /// One tap, one verdict. Latched here as well as tokened on the Mac, because a double tap
    /// should not even reach the socket.
    func resolve(approve: Bool) {
        guard !resolved else { return }
        resolved = true
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.resolvePlan(id: session, token: UUID(), call: gate.callID,
                          approve: approve, feedback: trimmed.isEmpty ? nil : trimmed))
    }
}
