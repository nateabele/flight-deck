import Foundation

// `account.list` and `account.switch`: the local control socket's two requests for moving a
// live conversation to another account (`/switch-account`, `flightdeck account …`). Both act on
// one tab, named by id, and are answered synchronously — `account.switch` answers BEFORE the
// move starts, because the claude process that asked is the one the move kills.
//
//     op                request                         reply
//     account.list      {session}                       accountChoices {choices:{WireAccountChoices}}
//     account.switch    {session, target}               accountSwitched {switched:{WireAccountSwitchResult}}
//
// Local only, like `delegate.*`: a paired phone has no tab and no token.

/// One account as the picker shows it.
public struct WireAccountChoice: Codable, Equatable, Sendable {
    /// The account's id (a UUID string). Accepted back as `account.switch`'s target.
    public var id: String
    public var displayName: String
    /// From the account's cached identity; nil when it has never been read.
    public var email: String?
    /// "underSoft" | "overSoft" | "overHard" | "unknown", a `String` like `WireSession.agent`
    /// so a newer Mac inventing a state leaves an older client showing it verbatim.
    public var state: String
    public var isCurrent: Bool

    public init(id: String, displayName: String, email: String?, state: String, isCurrent: Bool) {
        self.id = id; self.displayName = displayName; self.email = email
        self.state = state; self.isCurrent = isCurrent
    }
}

/// A pool and its members, in lease order.
public struct WireAccountPoolChoice: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// This tab's project assigns this pool.
    public var isAssigned: Bool
    public var members: [WireAccountChoice]

    public init(id: String, label: String, isAssigned: Bool, members: [WireAccountChoice]) {
        self.id = id; self.label = label; self.isAssigned = isAssigned; self.members = members
    }
}

/// Everything a tab's agent offers to move to.
public struct WireAccountChoices: Codable, Equatable, Sendable {
    public var agent: String
    /// The account the tab runs as; nil when it runs in the agent's built-in home with none on file.
    public var current: String?
    /// The pool the tab's project assigns, if any.
    public var assignedPool: String?
    public var pools: [WireAccountPoolChoice]
    /// Accounts in no pool, in list order.
    public var accounts: [WireAccountChoice]

    public init(agent: String, current: String?, assignedPool: String?,
                pools: [WireAccountPoolChoice], accounts: [WireAccountChoice]) {
        self.agent = agent; self.current = current; self.assignedPool = assignedPool
        self.pools = pools; self.accounts = accounts
    }
}

/// The answer to `account.switch`. `ok` false is a refusal and nothing was or will be done;
/// `ok` true with no `to` is "already there"; `to` is the display name the tab is moving to.
public struct WireAccountSwitchResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var to: String?

    public init(ok: Bool, message: String, to: String? = nil) {
        self.ok = ok; self.message = message; self.to = to
    }
}
