import Foundation

/// Every Flight Control screen reachable from the Sessions list's `NavigationPath`. One
/// `Hashable` enum beside the existing `UUID` destination, so a session id and an intake id
/// can never be confused on the path.
enum IntakeRoute: Hashable {
    case intake(UUID)
    case round(intake: UUID, checkpoint: Int)
    case plan(intake: UUID, checkpoint: Int?)
    case reader(intake: UUID, checkpoint: Int?, block: Int?, changes: Bool)
    case clarifications(UUID)
}
