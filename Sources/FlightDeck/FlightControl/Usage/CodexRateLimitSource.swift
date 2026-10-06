import Foundation
import IntakeKit

/// One codex account's rate-limit buckets: the last `account/rateLimits/read`, with any
/// `account/rateLimits/updated` pushes merged in. One per account because a `CODEX_HOME` — and
/// so its app-server — answers for exactly one login.
@MainActor
final class CodexRateLimitSource {
    private(set) var buckets: [String: CodexRateBucket] = [:]

    /// An empty answer keeps what was known: it is not evidence the limits went away, and an
    /// account flipping to "no reading" between polls would make the popover flicker.
    func applyRead(_ result: [String: Any]) {
        let parsed = CodexRateLimitParser.readResponse(result)
        if !parsed.isEmpty { buckets = parsed }
    }

    func applyUpdate(_ params: [String: Any]) {
        buckets = CodexRateLimitParser.merge(update: params, into: buckets)
    }

    func reading(account: AccountRef, at: Date) -> UsageReading? {
        CodexRateLimitParser.reading(buckets, account: account, readAt: at)
    }
}
