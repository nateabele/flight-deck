import IntakeKit
import FleetKit

/// Whether an OpenCode turn that died on an API error is worth Flight Deck's own retry.
///
/// **OpenCode retries first, on its own, and that changes what is left to retry.** A
/// transient provider failure normally never reaches here: OpenCode reports it as
/// `session.status {type: "retry", attempt, next}` and tries again itself, which
/// `OpenCodeEventMapper` maps to `.busy`. A turn only ENDS on an `APIError` once OpenCode has
/// given up — so this is the second line, for the outage that outlasted OpenCode's own ladder.
///
/// An allowlist on OpenCode's own verdict, like the other two classifiers: only `APIError`
/// carries `isRetryable`, and only a `true` there retries. Every other member of OpenCode's
/// error union — `ProviderAuthError`, `ContextOverflowError`, `MessageOutputLengthError`,
/// `ContentFilterError`, `UnknownError` — is a condition typing "continue" cannot fix, and an
/// error kind added in a later OpenCode release is refused until someone classifies it.
struct OpenCodeTurnRecovery: AgentTurnRecovery {
    func retries(_ error: SessionAPIError) -> Bool {
        error.kind == "APIError" && error.isTransient
    }

    var resumeText: String { SessionStore.resumePrompt }
}
