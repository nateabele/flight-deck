/// Sequencing for a screen that re-fetches on a toggle: each fetch takes a token, and only the
/// latest token's reply may be applied. Without it a slow reply to an earlier request lands after
/// a newer one and puts the screen out of step with the control that asked.
struct LatestRequest {
    private var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func accepts(_ token: Int) -> Bool { token == current }
}
