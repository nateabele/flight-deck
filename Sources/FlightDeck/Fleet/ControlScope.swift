import FleetKit
import Foundation

/// How much of the fleet a `flightdeck` CLI caller may reach, from a persisted preference.
///
/// `full` is the default — a plain `defaults` domain with nothing set, or a value this build
/// no longer recognises, both resolve to it — because that is the decision the user made:
/// full reach by default, with scoping as an option. Not because the socket is gated
/// elsewhere: it is ON by default (`ControlEnvironment.isEnabled`), so every tab can reach it
/// with no opt-in at all. The scope is a guardrail against an agent wandering into another
/// tab, not a sandbox: a caller that presents no token is a human shell and unscoped (see
/// `ControlScope.permits`), so it narrows well-behaved callers only. Scoping down is something the user chooses, not something a stale or mistyped
/// preference should silently impose.
enum ControlScopeLevel: String, CaseIterable, Identifiable {
    /// No restriction: any caller reaches any command or request.
    case full
    /// A session-scoped caller reaches only the tab its token names; a human shell is still
    /// unscoped (see `ControlScope.permits`).
    case ownSession
    /// A session-scoped caller reaches no writes at all, only requests.
    case readOnly

    var id: String { rawValue }
}

/// Who is asking: a human typing at a real terminal, a launched tab presenting a valid token
/// for itself, or a token that named no session this secret recognises.
enum ControlCaller: Equatable {
    /// No token was presented. A shell the user opened directly, not a tab Flight Deck
    /// launched — see `ControlScope.permits` for why this is never scoped.
    case human
    /// A tab launched under Flight Deck, proven by `ControlEnvironment.session(forToken:)`
    /// to be exactly this session and no other.
    case session(UUID)
    /// A token was presented but didn't resolve — malformed, forged, or minted under a
    /// different secret. Treated the same as a caller with no standing at all: scoped levels
    /// fail closed rather than falling back to `.human`'s trust.
    case invalid
}

/// A pure policy for whether a `flightdeck` CLI caller may issue a given fleet command or
/// request, at a chosen `ControlScopeLevel`.
///
/// **This is a guardrail, not a sandbox.** It stops a launched tab's own script from
/// accidentally reaching past itself — closing a sibling session, renaming another project's
/// tab — the same way `ControlEnvironment`'s HMAC stops a tab from typo'ing its way into a
/// different session's identity. Neither defends against a hostile process on the same
/// account: anything that can read this user's environment or `UserDefaults` can already see
/// the secret and mint any token it likes. The scope exists so a well-behaved automation
/// cannot overreach by mistake, not to withstand an adversary who already has a shell here.
///
/// **A human shell is never scoped, at any level.** `ControlCaller.human` means no token was
/// presented at all — the caller is not a tab Flight Deck launched, it's the maintainer at a terminal
/// who ran `flightdeck` directly. Scoping exists to bound what an *automated* tab can reach on
/// its own; it was never meant to lock the person sitting at the Mac out of their own fleet.
enum ControlScope {
    static let defaultsKey = "FlightDeckAgentControlScope"

    /// The persisted scope level, defaulting to `.full` — see the type's doc comment for why
    /// both "never set" and "no longer recognised" land there rather than on the strictest
    /// option.
    static func level(_ defaults: UserDefaults = .standard) -> ControlScopeLevel {
        guard let raw = defaults.string(forKey: defaultsKey),
              let level = ControlScopeLevel(rawValue: raw)
        else { return .full }
        return level
    }

    /// `nil` means no token was presented (`.human`); a token that fails to resolve is
    /// `.invalid` rather than `.human` — a forged or stale token should fail closed under a
    /// scoped level, not fall back to a human's unrestricted trust.
    static func caller(token: String?, secret: Data) -> ControlCaller {
        guard let token else { return .human }
        guard let session = ControlEnvironment.session(forToken: token, secret: secret) else {
            return .invalid
        }
        return .session(session)
    }

    /// Exhaustive with no `default`, so a new `FleetCommand` case cannot compile until someone
    /// here decides whether it is a write reachable only by its own session, or fleet-wide.
    static func permits(_ command: FleetCommand, level: ControlScopeLevel, caller: ControlCaller) -> Bool {
        if case .viewing = command { return true }
        if level == .full || caller == .human { return true }
        guard case .session(let me) = caller, level == .ownSession else { return false }

        switch command {
        case .markRead(let id), .markUnread(let id), .closeSession(let id):
            return id == me
        case .renameSession(let id, _):
            return id == me
        case .prompt(let id, _, _):
            return id == me
        case .answerPrompt(let id, _, _, _, _):
            return id == me
        case .annotatePlan(let id, _, _, _, _):
            return id == me
        case .resolvePlan(let id, _, _, _, _):
            return id == me
        case .abortPrompt(let id, _):
            return id == me
        case .viewing:
            return true
        case .intakeTape, .intakeDefaultPlay, .intakeNote, .intakeRemoveNote:
            // An intake is a project's, not the asking session's: no session id names it.
            return false
        case .newSession, .reopenClosed, .setProjectCollapsed:
            // Fleet-wide effects with no single session to scope to: opening or reopening a
            // tab, or collapsing a project's list, reach beyond whatever tab is asking.
            return false
        }
    }

    /// Exhaustive with no `default`, same reasoning as the command overload. `.openConversation`
    /// is a request that writes — it opens a tab — so it follows the fleet-wide command rule
    /// (`.full` or `.human` only). The delegation requests that write follow the own-session
    /// rule instead (see their arm). Every other request only reads and is always allowed.
    static func permits(_ request: FleetRequest, level: ControlScopeLevel, caller: ControlCaller) -> Bool {
        switch request {
        case .timeline, .newSessionOptions, .recentlyClosed, .macEndpoints, .conversations, .search,
             .intakeDetail, .intakePlan:
            return true
        case .hostList, .hostInfo:
            // Reads too: `host.info` crosses to the host, but asks it only for facts and
            // changes nothing there or here. An agent in any tab may need the toolchain.
            return true
        case .openConversation:
            return level == .full || caller == .human
        case .delegate(let delegate):
            // `ps`, `logs`, `diff`, `recipe ls` and `host ls --disk` only read. Every other delegation request
            // starts, stops or applies work, so it is a write — but one that belongs to the
            // asking session, the way `prompt` does, not a fleet-wide one like
            // `openConversation`: a run is owned by the tab whose token started it, and the
            // app reads that tab from the token, never from the request. So it is allowed
            // wherever a session may write to itself: `.full`, a human shell, and a valid
            // session token under `.ownSession`. `.readOnly` and an `.invalid` token refuse.
            //
            // Not checked here: whether a run named by id (`stop`, `wait`, `apply`) is the
            // caller's own. Only `DelegationService` knows a run's owner, so under
            // `.ownSession` it must refuse another tab's run itself.
            //
            // `host prune` is the exception: it deletes this Mac's whole workspace on a host,
            // every tab's checkouts with it, so no one session owns it. It follows the
            // fleet-wide rule, as `openConversation` does.
            if delegate.isReadOnly || level == .full || caller == .human { return true }
            if case .hostPrune = delegate { return false }
            guard case .session = caller else { return false }
            return level == .ownSession
        }
    }
}
