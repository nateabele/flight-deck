import SwiftUI

/// Whether coming back to the app should redial the Mac.
///
/// **The obvious predicate is wrong, and it shipped.** The rule wanted is "redial when the app
/// returns from having been suspended, and not when a notification banner or the app switcher
/// merely passed over it". Written as `previous == .background && phase == .active`, that rule
/// never fires: iOS returns through `.inactive`, so the sequence is
///
///     background -> inactive
///     inactive   -> active
///
/// and at the moment `.active` arrives the previous phase is `.inactive`, never `.background`.
/// Confirmed by logging the transitions on a simulator, where the redial line never printed
/// across a real background-and-return cycle. The connector therefore stayed pointed at a
/// socket iOS had destroyed, with no retry and no backoff, until the app was force-quit — which
/// is the symptom that sent someone looking.
///
/// So the fact has to be *remembered* rather than read off one edge: `.background` sets a flag,
/// `.active` consumes it. `.inactive` deliberately decides nothing, which is what keeps a banner
/// from churning the socket — a banner goes `.active -> .inactive -> .active` and never touches
/// the flag.
struct RedialOnReturn {
    /// Whether the app has been backgrounded since the last redial.
    private(set) var sawBackground = false

    /// Feed every phase change here. Returns whether to redial now.
    mutating func phaseChanged(to phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            sawBackground = true
            return false
        case .active:
            guard sawBackground else { return false }
            // Consumed, so a second `.active` with no suspension between — which is what the
            // app switcher produces — does not dial a second time.
            sawBackground = false
            return true
        default:
            return false
        }
    }
}
