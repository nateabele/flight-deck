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
// `account.switch` is local only, like `delegate.*`: a paired phone has no tab and no token. A
// phone may send `account.list` (it only reads), and moves a tab by typing `/switch-account
// <id>` into it, so the move is still asked for by the tab itself.

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
    /// The account's newest rate-limit windows, from the usage ledger. nil when it has none
    /// (never read, or a Mac built before this field).
    public var windows: [WireUsageWindow]?
    /// When the reading behind `windows` was written.
    public var readAt: Date?

    public init(id: String, displayName: String, email: String?, state: String, isCurrent: Bool,
                windows: [WireUsageWindow]? = nil, readAt: Date? = nil) {
        self.id = id; self.displayName = displayName; self.email = email
        self.state = state; self.isCurrent = isCurrent
        self.windows = windows; self.readAt = readAt
    }
}

/// One rate-limit window of an account ("five_hour", "seven_day", …).
public struct WireUsageWindow: Codable, Equatable, Sendable {
    /// The vendor's name for the window, verbatim.
    public var name: String
    /// 0...1; may exceed 1 on an exceeded limit.
    public var utilization: Double
    public var resetsAt: Date?

    public init(name: String, utilization: Double, resetsAt: Date?) {
        self.name = name; self.utilization = utilization; self.resetsAt = resetsAt
    }
}

/// How full a tab's context window is, from its agent's own status line.
public struct WireContextUsage: Codable, Equatable, Sendable {
    /// 0...100.
    public var usedPercent: Double
    /// The window's size in tokens, when the agent reports it.
    public var windowSize: Int?
    public var readAt: Date

    public init(usedPercent: Double, windowSize: Int?, readAt: Date) {
        self.usedPercent = usedPercent; self.windowSize = windowSize; self.readAt = readAt
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
    /// The pool the tab's project assigns, if any. When set, `pools` holds only that pool and
    /// `accounts` is empty: a pooled project moves only within its pool.
    public var assignedPool: String?
    public var pools: [WireAccountPoolChoice]
    /// Accounts in no pool, in list order.
    public var accounts: [WireAccountChoice]
    /// The account the tab runs as, with its usage, even when it is not among the choices (an
    /// account outside the project's pool). nil when `current` is.
    public var currentAccount: WireAccountChoice?
    /// The tab's context window, when its agent has reported one. Carried here because the
    /// phone's session sheet asks for both at once.
    public var context: WireContextUsage?

    public init(agent: String, current: String?, assignedPool: String?,
                pools: [WireAccountPoolChoice], accounts: [WireAccountChoice],
                currentAccount: WireAccountChoice? = nil, context: WireContextUsage? = nil) {
        self.agent = agent; self.current = current; self.assignedPool = assignedPool
        self.pools = pools; self.accounts = accounts
        self.currentAccount = currentAccount; self.context = context
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
