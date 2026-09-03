// Sources/FlightDeck/SessionStore.swift
import AppKit
import FleetKit
import Foundation
import OSLog
import SwiftUI

/// One session's status edge across a single registry tick.
///
/// Three things act on these edges — the unread mark, notifications, and the auto-resume
/// prompt — and each used to re-walk the before/after maps itself. Computing the edges once
/// and handing them out means "what changed" has a single definition. A proper state machine
/// over `SessionActivity` is the next step and is recorded in docs/FOLLOWUPS.md; this is the
/// seam it would slot into.
struct StatusTransition: Equatable {
    let id: UUID
    let old: SessionStatus?
    let new: SessionStatus?
}

/// Single source of truth for repos, sessions, selection, and live surfaces.
/// The sidebar and terminal pane render this and nothing else; only this type
/// creates or frees surfaces.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []

    /// Live activity per session, merged from two sources: the status registry supplies
    /// `activity`/`waitingFor`, the transcript watchers supply `subagentCount`.
    /// A session with no entry is absent from the map — that renders no icon, which is
    /// deliberately distinct from `.idle`.
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]
    /// Tabs with a background task running under their agent.
    ///
    /// A **decoration**, orthogonal to `statuses` — the same shape and lifetime as
    /// `FleetService.phoneActiveSessions`, and for the same reason: it is a fact *about* a
    /// tab, not a state the tab is in. Kept beside `statuses` rather than inside
    /// `SessionStatus` so that no consumer has to switch on it, and so the activity enum
    /// stays a total ordering of one axis.
    ///
    /// Latched. Upstream reports this only while idle (see `ClaudeStatusFile.Entry
    /// .reportsBackgroundWork`), so a `busy` tick carries the last known value forward and
    /// only a plain `idle` — or a vanished agent — clears it.
    @Published private(set) var backgroundWorkSessions: Set<UUID> = []

    /// Which dialog each blocked tab is on, by the blocked call's `tool_use_id`. Absent for
    /// every tab this Mac cannot name a dialog for, which is nearly all of them.
    ///
    /// **The third axis of `commitStatuses`, and the reason it exists.** `activity` was the
    /// only thing a client was ever told about a dialog, so one prompt superseded by another
    /// while the session stayed `waiting` moved nothing on the wire and a phone went on
    /// drawing — and offering buttons for — a dialog this Mac had already left. This is
    /// projected into `WireSession.openPromptCall`, so a change of dialog is itself a change
    /// a client can see.
    ///
    /// Not `@Published`: nothing on the desktop renders it. The sidebar shows *that* a tab is
    /// waiting, which `statuses` already says, and publishing a value that moves on a tick
    /// nothing else moved on would invalidate the whole sidebar for no visible difference.
    ///
    /// Rebuilt wholesale by every commit, like `statuses`, so an entry cannot outlive the tab
    /// it names or the dialog it describes.
    private(set) var openPromptCalls: [UUID: String] = [:]

    /// How this store learns which dialog a tab is blocked on.
    ///
    /// A closure rather than a call into `PromptService`, for two reasons. That service holds
    /// *this* store, so naming it here would be a cycle; and the derivation it runs is
    /// transcript grammar (`OpenPrompt.find` over a tail) that this file has no business
    /// learning a second copy of. `FleetService` installs the real one over the same
    /// `PromptService` an inbound answer is judged against, so what is pushed and what a tap
    /// is refused against are one object reading one transcript.
    ///
    /// Nil by default: a store with no fleet behind it reports no dialogs, which is what the
    /// hundred-odd tests that never open a socket want, and costs them no transcript reads.
    var openPromptCallReader: (UUID) -> String? = { _ in nil }

    /// `didSet` persists every change, including one made through `SessionSidebar`'s
    /// `List(selection:)` binding — the only way selection actually changes in
    /// production, since that binding writes here directly rather than through
    /// `selectSession(_:)`. `persist()` never re-assigns `selectedSessionID`, so this
    /// cannot recurse.
    @Published var selectedSessionID: UUID? {
        didSet {
            if let id = selectedSessionID, let at = locate(id) {
                lastActiveProjectURL = URL(
                    fileURLWithPath: repos[at.repo].sessions[at.session].workingDirectory,
                    isDirectory: true
                )
            }
            // Activating a tab is what marks it read. Deliberately not gated on
            // `appIsActive()`: selecting a row is an explicit act, so it counts as looking
            // at it even if the window is not frontmost at that instant.
            if let id = selectedSessionID { setUnread(id, false) }
            // Safety net against a stranded `renameRequest`: `SessionSidebar`'s Return
            // handler only sets it for a session with a rendered row, but the selection
            // it was issued for can still move out from under it afterward — collapsing
            // the project that owns the selected session, `cycleSelection` (⌘⇧[/⌘⇧])
            // landing on a session inside a collapsed project, or simply the user
            // clicking a different row before the request is consumed. Any selection
            // change, including one that reassigns the same id, clears the request, so
            // it can never outlive the selection state it was issued for. Swift fires
            // `didSet` on every assignment, not only on a change, which is exactly the
            // guarantee this leans on.
            renameRequest = nil
            persist()
        }
    }

    /// Sessions that finished while the user was not looking at them, rendered as the unread
    /// dot in the sidebar. See `SessionReadPolicy`.
    ///
    /// Held here rather than on `SessionStatus` for the same reason as `subagentCounts`:
    /// `applyRegistry` rebuilds every `SessionStatus` wholesale from the registry, so a field
    /// on that type would be clobbered on the next poll. This is view state about the user,
    /// not state `claude` reports.
    ///
    /// Persisted, as of the auto-resume work: what finished while you were away is exactly
    /// what you want to find when you come back, and quitting for the day is the longest
    /// "away" there is. Written by `persist()`, seeded by `restore()`.
    @Published private(set) var unreadIdle: Set<UUID> = []

    /// One-shot request channel for the keyboard rename path: the sidebar's `List` sets this
    /// on Return (it has the selection but no way to reach a specific row's private `@State`),
    /// the matching `SessionRow` observes it via `.onChange`, starts editing, and clears it
    /// back to `nil`. Double-click and the context menu skip this entirely — they already hold
    /// the row and call `beginRename()` directly.
    ///
    /// Transient signal, not durable state: never persisted, and deliberately absent from
    /// `SessionSnapshot`, so it does not appear in what `persist()` writes or `restore()` reads.
    @Published var renameRequest: UUID?

    /// The session whose rename field is currently open, or nil.
    ///
    /// Exists to stop the sidebar's Return-to-rename handler from eating the Return that
    /// COMMITS a rename. Measured: without it, typing a new name and pressing Return left the
    /// title unchanged, because the sidebar's Return handler claimed the key before the field's
    /// `onSubmit` ever saw it, and the smoke test's context-menu rename failed.
    ///
    /// The first-responder check in `SidebarInputMonitor` covers most of this on its own (an
    /// open field editor is not an `NSTableView`), but this flag is what makes the intent
    /// explicit and survives a focus state that has not settled yet. `SessionRow` clears it on
    /// commit, on Esc, on focus loss, and on teardown — all four matter, because a stranded
    /// value disables Return-to-rename for the rest of the process.
    ///
    /// Transient, like `renameRequest`: never persisted, never in the snapshot.
    @Published var renamingSessionID: UUID?

    /// Weak: `GhosttyApp.shared` is a process-wide static that owns itself for the life of
    /// the process (see `GhosttyApp.shared`'s doc comment); the store must not co-own it.
    private weak var provider: SurfaceProvider?

    /// Live surfaces retained here (not by the SwiftUI view tree) so switching
    /// sessions re-parents rather than recreates. Dropping an entry frees it.
    private var surfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// Which OS process each tab owns, for teardown. See `SurfaceProcessRegistry`.
    let processRegistry = SurfaceProcessRegistry()

    /// The process table the orphan sweep reads. Settable so tests can script it.
    var processInspector: ProcessInspecting = ProcessTree()

    /// Injected for the reason `processInspector` is — see `DisplayInspecting`. Defaults to
    /// `AlwaysDrawableDisplay()`, NOT the real `DisplayState()` (see that type's doc comment
    /// for why the default is inverted from `processInspector`'s). `convenience init(ghostty:...)`
    /// below assigns the real probe immediately after `self.init(provider:...)`, before
    /// `seedInitialSession()` can run; that injection is what makes `canCreateTerminal` mean
    /// anything outside tests — removing it silently disables the guard.
    var display: DisplayInspecting = AlwaysDrawableDisplay()

    /// How a sleeping display is brought back before a terminal is created. Injected on the
    /// same seam and for the same reason as `display`, but defaulting to the **inert**
    /// `NeverWakingDisplay()`: a real waker in a test would physically wake the developer's
    /// screen. `convenience init(ghostty:...)` assigns the real one.
    var displayWaker: DisplayWaking = NeverWakingDisplay()

    /// When the last wake attempt failed, so a display that cannot wake is not re-attempted on
    /// every tap. **Only ever consulted when `canCreateTerminal` is already false**, so a
    /// display that comes back is never suppressed by it — it short-circuits first.
    private var lastFailedWake: Date?
    /// Long enough that a burst of taps costs one timeout, short enough that plugging a display
    /// in is noticed almost immediately. Only matters while creation is failing anyway.
    static let wakeRetryCooldown: TimeInterval = 10

    /// This run's own identity, stamped into every snapshot as `owner`. Computed once: it
    /// cannot change for the life of the process, and `persist()` runs on every mutation —
    /// every tab switch, every rename, every registry tick.
    ///
    /// **It must read the real process table, never `processInspector`.** That property is a
    /// test seam, and `owner` is the interlock the launch sweep gates on: a snapshot whose
    /// `owner` is reported alive is left entirely alone. Routing this through the seam would
    /// let a test (or a future refactor tidying "duplicate" inspector use) stamp a fabricated
    /// owner into a real `sessions.json`, and the next launch would then either decline to
    /// sweep real orphans or — worse, if the fake identity is one that happens to be dead —
    /// sweep somebody else's live children. The one value in this file that must come from
    /// the operating system and nowhere else.
    private static let selfIdentity: ProcessIdentity? = ProcessTree().identity(of: getpid())

    /// The most recently constructed store.
    ///
    /// A fallback for `AppDelegate`, which normally learns about the store through
    /// `.flightDeckStoreReady`. That notification only reaches the delegate because
    /// `FlightDeckApp` happens to build the store inside a SwiftUI `@autoclosure`, deferred for
    /// an entirely unrelated reason (`NSApp` does not exist during `App.init`). Constructing it
    /// eagerly instead — a plausible "cleanup" — would post the notification before the
    /// delegate's observer exists, turning `applicationShouldTerminate` into an immediate
    /// `.terminateNow` that reaps nothing at all, silently, with no test failing. Weak so the
    /// store's lifetime is still owned by the `@StateObject` that holds it.
    static weak var current: SessionStore?

    /// Off-main-actor process teardown. See `SessionReaper`.
    private let reaper: SessionReaper
    var reapReporter: ReapReporting? = LoggingReapReporter()

    /// Surfaces whose tab is gone but whose process is still being killed.
    ///
    /// Holding the view here is what orders the teardown correctly: releasing it runs
    /// `ghostty_surface_free`, which joins libghostty's IO thread and spins in its own
    /// `killpg` loop *on the main actor*. Reaping first means that loop finds a dead child
    /// and returns at once instead of blocking the UI.
    private var parkedSurfaces: [UUID: Ghostty.SurfaceView] = [:]

    /// What one tab is currently observing, and through which agent-as-account.
    ///
    /// The instance is carried here rather than looked up from `repos` on demand because
    /// `closeSession` removes the session before it detaches, so by then there is nothing
    /// left to ask. The account half matters as much as the agent half: the runtime holding
    /// this attachment is one account's, and `detach` on another account's would silently
    /// leave the watcher running.
    private struct TabAttachment {
        let instance: AgentInstance
        let binding: AgentBinding
        let token: AttachmentToken
    }

    /// One agent attachment per tab, torn down with the tab. Replaces the per-session
    /// `TranscriptWatcher` this used to hold: the watcher now lives inside `ClaudeRuntime`,
    /// and what the store keeps here is keyed by tab only. Nothing scans this table to
    /// decide which tabs an event belongs to — that routing is decided entirely by the
    /// `AttachmentToken` the runtime hands back from `attach`, which names the tab directly.
    private var attachments: [UUID: TabAttachment] = [:]

    /// The agent integrations, one per `AgentInstance` — an agent *as an account*, not per
    /// agent. Two logins are two adapters: what binds a process to a login is a home
    /// directory, so one adapter answering for both would have to be told which on every
    /// call, and would be exactly one forgotten argument away from running a tab as the
    /// wrong user.
    ///
    /// Built on first request rather than from a `lazy` literal, so a store that never
    /// creates a tab still builds nothing and no account is assumed at construction time.
    /// Options are chosen alongside the adapter in `options(for:)`, which is what makes
    /// `ClaudeAdapter`'s "a codex payload here is a programming error" true by construction
    /// rather than by convention.
    private var adapters: [AgentInstance: any AgentAdapter] = [:]

    /// The observation half, also one per instance: both agents multiplex a single per-account
    /// source across every tab *of one account*, so a runtime per tab would re-scan claude's
    /// registry once per tab, while a runtime per agent would have one attachment table
    /// standing for two homes. See `AgentRuntime`.
    private var runtimes: [AgentInstance: any AgentRuntime] = [:]

    /// Reports live conversation text to ⌘K search as it streams in, so a session need not
    /// wait for the next backfill to become searchable. Set by `AppDelegate` once the index
    /// exists — nil in every test and for the very start of a real launch, so a `ClaudeRuntime`
    /// built before then, or in any test, carries no dependency on search at all.
    var searchIndex: SearchIndex?

    /// The settings payload that goes with an agent, chosen from the same `AgentID` the
    /// adapter is. Pairing them here — rather than letting a call site pass whichever it
    /// happens to hold — is what makes handing `ClaudeAdapter` a `.codex` payload (which it
    /// degrades from rather than traps on) unreachable by construction.
    ///
    /// `project` is a path, not a session: preferences are resolved from the project a tab is
    /// *filed under*, which is not where `claude` is necessarily writing. See `restore`.
    ///
    /// One resolution path for both agents: `PreferencesStore.resolvedOptions(for:project:)`
    /// merges the project's per-agent override over the global row, claude and codex alike.
    /// This used to hand codex a hardcoded `CodexThreadOptions()`, which made every control in
    /// the Codex pane inert — a user who chose the `read-only` sandbox silently got codex's
    /// default.
    private func options(for agent: AgentID, project: String) -> AgentOptions {
        switch agent {
        case .claude: return preferences?.resolvedOptions(for: agent, project: project) ?? .claude(FlagSet())
        case .codex:  return preferences?.resolvedOptions(for: agent, project: project) ?? .codex(CodexThreadOptions())
        }
    }

    /// Codex's half of the two dictionaries above, held together rather than as four fields
    /// because the four are inseparable: the adapter and the runtime are only usable through
    /// the one `CodexRPC` that speaks to the one app-server process they share.
    ///
    /// A class so the transport's termination hook can be wired to the client it belongs to
    /// while both are being constructed. `@MainActor` explicitly: a nested type does not
    /// inherit its enclosing type's isolation, and every piece it holds is main-actor bound.
    @MainActor
    private final class CodexStack {
        let transport: CodexProcessTransport
        let rpc: CodexRPC
        var adapter: CodexAdapter
        let runtime: CodexRuntime

        /// `home` and `indexURL` are two views of one account and must agree: the app-server
        /// spawned in that home is the process that *writes* the index the runtime tails, so
        /// a stack whose two halves named different homes would watch a file nothing writes.
        init(clock: WatchClock?, home: URL, indexURL: URL) {
            transport = CodexProcessTransport(home: home)
            rpc = CodexRPC(transport: transport)
            adapter = CodexAdapter(rpc: rpc)
            runtime = CodexRuntime(clock: clock, indexURL: indexURL)
            // The hook `CodexProcessTransport` exposes exists for exactly this. Without it a
            // mid-session app-server crash leaves every in-flight request suspended forever —
            // a tab waiting on a dead process is indistinguishable from a hung agent, which is
            // the failure mode `CodexRPC` documents as the worst it can have. Weak so the
            // transport's callback does not retain the client that already owns it.
            transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        }
    }

    /// Codex's stacks, one per account, each built on first use and dropped with that
    /// account's last codex tab.
    ///
    /// Empty until something actually needs codex: a user who never opens a codex tab must
    /// never have `codex app-server` spawned behind their back, so neither an entry here nor
    /// the process it eventually holds is created at launch. Building one spawns nothing
    /// either — `startCodex()` is the only thing that runs a process, and only
    /// `createSession` and `resumeRestoredCodex` reach it.
    ///
    /// One per account rather than one outright, because a `CODEX_HOME` is chosen when the
    /// process is spawned: a single app-server can only ever answer for a single login. The
    /// key is `AgentInstance.account`, nil included — see there for why a nil key and an id
    /// key can never both stand for the same home, which is what keeps two app-servers off
    /// one `session_index.jsonl`.
    private var codexStacks: [UUID?: CodexStack] = [:]

    /// Serialises spawn + handshake so N tabs created at once produce one app-server per
    /// account — and so a second account's first tab does not queue behind the first
    /// account's `initialize`.
    ///
    /// A `Task` rather than a `Bool` because the handshake is `async`: a second creation
    /// racing the first has to *wait* for the same `initialize` to be answered, not proceed
    /// against a process that has not spoken yet.
    private var codexHandshake: [UUID?: Task<Void, Error>] = [:]

    /// Test seam. Proves the app-server's lifetime — lazy on first codex use, gone with the
    /// last codex tab or with its process — without spawning a process to observe it.
    var hasCodexStackForTesting: Bool { !codexStacks.isEmpty }

    /// Test seam. The per-account half of the above: "one home, one app-server" is a count,
    /// not a boolean, and only a count can catch a second stack on a home that already had
    /// one.
    var codexStackCountForTesting: Int { codexStacks.count }

    /// Test seams for the same fact about the other two registries. Sizes rather than
    /// identities because `ClaudeAdapter` is a struct: there is nothing to compare two
    /// adapters by, so how many were built is the only thing observable from outside.
    var adapterCountForTesting: Int { adapters.count }
    var runtimeCountForTesting: Int { runtimes.count }

    /// Test seam. Counts how many times a path asked for a *started* app-server, which is
    /// the thing a restored codex tab was missing and the thing no committed test may let
    /// actually happen. `hasCodexStackForTesting` cannot stand in for it: building the stack
    /// spawns nothing, and `restore` built one long before it started one.
    private(set) var codexServerRequestsForTesting = 0

    /// Test seam. The restore path's codex work is asynchronous by necessity — it starts an
    /// app-server and asks it whether a thread still exists — but `restore` itself must stay
    /// synchronous for `SessionStore.init`. Exposing the task is what lets a test await that
    /// work instead of polling for it. `reopenLastClosed` reuses it for the same reason.
    private(set) var codexRestoreTask: Task<Void, Never>?

    /// What ⌘⇧T walks back through. Not `@Published` and never persisted: nothing renders it,
    /// and a relaunch already restores the deck you left — a stack that survived one would
    /// offer to reopen tabs from a run you have since replaced. See `ClosedSessionHistory`.
    private var closedSessions = ClosedSessionHistory()

    /// Test seam. Drives the exact path a crashed `codex app-server` takes, which can
    /// otherwise only be produced by killing a real process the committed suite may not spawn.
    /// Takes the account explicitly rather than terminating whatever is running: a test that
    /// means to crash one login's app-server must not silently crash the other's.
    func simulateCodexTerminationForTesting(account: UUID?) {
        codexStacks[account]?.transport.simulateProcessTerminationForTesting()
    }

    /// Test seam. The home this account's app-server *would* be spawned in — the one fact
    /// about the spawn that has to be checkable without spawning, since a process launched in
    /// the wrong home is indistinguishable from a working one until its renames never arrive.
    func codexTransportHomeForTesting(account: UUID?) -> URL? {
        codexStacks[account]?.transport.home
    }

    /// Builds this account's stack on first ask and memoizes it. Starts no process; see
    /// `startCodex`.
    private func makeCodexStackIfNeeded(account: UUID?) -> CodexStack {
        if let existing = codexStacks[account] { return existing }
        // This account's index, not the app's: the stack's name watcher tails the file that
        // this login's `CODEX_HOME` indexes, which is the only place its renames appear. The
        // home goes with it, because the app-server this stack spawns has to be the process
        // writing that file — see `CodexStack.init`.
        let stack = CodexStack(
            clock: clock,
            home: home(ofAccount: account, agent: .codex),
            indexURL: codexIndexURL(for: account)
        )
        // Composed on top of the stack's own hook rather than replacing it: failing every
        // in-flight request is the stack's job, forgetting the stack is the store's, and both
        // have to happen for the same event.
        //
        // Forgetting is what keeps a crash from wedging codex for the rest of the run.
        // `transportClosed()` resumes what is pending at that moment and latches nothing, so
        // a `codexStacks`/`codexHandshake` entry left standing means the next creation on
        // that account returns the already-succeeded handshake without re-probing, writes
        // `thread/start` into a dead pipe (`send` swallows the failure), and suspends on a
        // continuation nothing will ever resume — the same hang one session later, with no
        // alert and no failed `Result`.
        let failInFlightRequests = stack.transport.onTerminate
        stack.transport.onTerminate = { [weak self, weak stack] in
            failInFlightRequests?()
            // Identity-checked, and against this account's entry only: a late termination
            // from a *replaced* stack must not tear down the live one that succeeded it, and
            // one login's crash must not forget another login's healthy server.
            guard let self, let stack, self.codexStacks[account] === stack else { return }
            self.codexStacks[account] = nil
            self.codexHandshake[account] = nil
        }
        codexStacks[account] = stack
        return stack
    }

    /// Stops one account's app-server once that account's last codex tab is gone.
    ///
    /// Safe to do, and not merely tidy: `thread/start` + `thread/name/set` committed every
    /// thread to codex's own storage, which is exactly what makes `codex resume <id>` work
    /// across processes — so nothing is lost, and the next codex session spawns a fresh
    /// server. Keeping it alive instead would leave a process running for the rest of the
    /// run on the strength of a tab the user closed. True under the `legacy` history
    /// contract `CodexAdapter.historyMode` pins — see `prepare`'s doc comment for what
    /// changes under `paginated`.
    ///
    /// Narrowed from "no codex tabs remain anywhere" to "no tabs remain on *this* account":
    /// the wider predicate would keep one login's app-server alive for the whole run because
    /// a different login still had a tab open, which is precisely the leak this exists to
    /// prevent. Only the closing tab's own account is examined, because it is the only one
    /// whose tab count can have just dropped.
    private func stopCodexIfUnused(account: UUID?) {
        guard let stack = codexStacks[account] else { return }
        // A codex creation that has not inserted its tab yet is invisible to the check
        // below, and killing the app-server out from under it between `thread/start` and
        // `thread/name/set` EVAPORATES the thread — naming is what commits it, under the
        // `legacy` history contract `CodexAdapter.historyMode` pins. So a tab closed
        // mid-creation defers the teardown rather than skipping it: `createSession`
        // re-runs this on its way out. Per account, like everything else here: a creation on
        // one login must not pin another login's server open.
        guard codexCreationsInFlight[account, default: 0] == 0 else { return }
        let live = AgentInstance(agent: .codex, account: account)
        guard !repos.flatMap(\.sessions).contains(where: { instance(for: $0) == live }) else { return }
        stopCodex(account: account, expected: stack)
    }

    /// How many codex creations are between "asked for an app-server" and "tab inserted",
    /// per account.
    ///
    /// A counter and not a `Bool`: two tabs can be created at once, and the second finishing
    /// must not clear a guard the first still needs.
    private var codexCreationsInFlight: [UUID?: Int] = [:]

    /// Tears down the stack the caller meant, whatever the reason. `stop()` funnels into the
    /// transport's termination hook, so every request still in flight fails rather than
    /// hanging its caller — the same guarantee a crash gets, and by the same route: that hook
    /// is also what nils the two fields below. They are cleared again here rather than left
    /// to it, because `stop()` on a transport whose process never ran is a no-op the hook may
    /// have already consumed.
    ///
    /// `expected` is the same identity check the crash hook has had all along, and for the
    /// same reason: a failure path that started before the current stack existed must not
    /// stop the one a concurrent creation just built. `stopCodex()` had no such guard, so a
    /// stale `startCodex` failure could tear down a healthy successor.
    private func stopCodex(account: UUID?, expected: CodexStack?) {
        guard let expected, codexStacks[account] === expected else { return }
        expected.transport.stop()
        codexStacks[account] = nil
        codexHandshake[account] = nil
    }

    /// The registry key a tab runs under: its agent, as the account it is signed in with.
    ///
    /// One place, so that no call site invents its own normalisation. `Session.accountID` is
    /// *storage* — nil there means the agent's built-in home, not "no account" — and
    /// `PreferencesStore.resolvedAccountID(for:in:)` is what turns it into the identity every
    /// registry is keyed by. Two call sites disagreeing about that is exactly how one home
    /// ends up with two `CodexStack`s on one `session_index.jsonl`.
    ///
    /// The account comes back nil whenever preferences hold no **isBuiltIn** account for the
    /// agent to name — a store with no `PreferencesStore` at all, and equally one whose
    /// built-in account has been relocated away or was migrated against a root that is not
    /// `$HOME`. Either way there is no id-keyed instance for that home either, so the nil key
    /// serves it alone; see `AgentInstance` for why that can never coexist with an id key for
    /// the same home.
    private func instance(for session: Session) -> AgentInstance {
        AgentInstance(
            agent: session.agent,
            account: preferences?.resolvedAccountID(for: session.agent, in: session.accountID)
        )
    }

    /// The login a tab already runs as, as an account rather than a key — what a *launch*
    /// needs, since the shell is bound to a home by path, not by id. Follows `instance(for:)`
    /// exactly, so the account a tab is observed under and the account it is launched under
    /// can never be two different things.
    ///
    /// nil for a tab with no account to name AND for a tab whose stored account has been
    /// deleted, because `resolvedAccountID` collapses both to nil. Those two are not the same
    /// thing and must never be treated as one — `accountIsMissing(for:)` is what tells them
    /// apart, and every caller that could *launch* something asks it first.
    private func account(for session: Session) -> AgentAccount? {
        guard let preferences,
              let id = preferences.resolvedAccountID(for: session.agent, in: session.accountID)
        else { return nil }
        return preferences.account(id: id)
    }

    /// Whether this tab names a login that no longer exists.
    ///
    /// The restore-time twin of `launchAccount`'s `.accountMissing` branch, and it exists
    /// because removing an account does not rewrite the tabs that ran as it: `markAccountRemoved`
    /// tombstones the record and clears every *project assignment* naming the id, but
    /// `Session.accountID` is history — it records where this tab's conversation was actually
    /// written, and rewriting it would be a lie. A tombstone still resolves by id, which is the
    /// point of it, so a restored tab only names an id nothing resolves once that tombstone has
    /// been purged at launch, or the id never existed at all — and the only safe reading of
    /// that is BROKEN. Relaunching it in the built-in home would resume a conversation
    /// that lives in the deleted account's directory, find nothing there, and quietly start a
    /// fresh one — the silent wrong-login failure this whole feature exists to remove.
    ///
    /// Only the *dangling id* counts, deliberately: unlike creation, this does not also check
    /// that the home still exists on disk. A launch happens when the user asks for it and can
    /// be refused with a fix; a restore happens at every startup, and an account homed on a
    /// network volume that has not mounted yet is not a deleted account. `restore` already
    /// declines to prune projects for the same reason (see its doc comment).
    ///
    /// False whenever there is no `PreferencesStore` to check against: a store built by a test
    /// or a fixture has no accounts and nothing to contradict.
    private func accountIsMissing(for session: Session) -> Bool {
        guard let preferences, let stored = session.accountID else { return false }
        return preferences.account(id: stored) == nil
    }

    /// The login a *new* tab for `agent` in `project` would run as, or why it cannot run.
    ///
    /// The one resolution both creation paths share, and the only place the distinction that
    /// matters is drawn: `PreferencesStore.account(for:project:)` answers nil for two very
    /// different situations, and conflating them is precisely the silent wrong-login bug.
    ///
    /// - `.success(nil)` — there is no account to name. A store with no `PreferencesStore`, or
    ///   preferences holding no account for this agent at all. The tab launches with no
    ///   variable set, which is the agent's built-in home and exactly what it did before
    ///   accounts existed.
    /// - `.failure(.accountMissing)` — this project *names* a login, and that id no longer
    ///   resolves. Never a fallback to the top of the list: resuming under another login finds
    ///   none of this tab's conversations and quietly starts a fresh one, with no error
    ///   anywhere. A tab that cannot launch as itself must not launch at all.
    /// - `.failure(.accountHomeMissing)` — the login resolves but its directory is gone. Also
    ///   refused, for a sharper reason: pointing an agent at a missing config home does not
    ///   fail, it *creates* the directory and starts a logged-out session in it.
    ///
    /// The home check exempts the built-in home deliberately. `~/.claude` and `~/.codex` are
    /// derived, not stored — there is nothing to relocate — and a user who has installed an
    /// agent but never run it legitimately has no such directory yet; refusing there would
    /// mean the app could not create the very first tab that creates the home.
    ///
    /// `choosing` is the New Session dropdown's escape hatch (Task 14): a caller that already
    /// knows exactly which account it wants — because the user clicked it — names it directly
    /// and skips `PreferencesStore.account(for:project:)` entirely. It still runs through the
    /// same home check below, because a dropdown built moments ago can still be one relocate
    /// or one deletion stale by the time it is clicked.
    private func launchAccount(
        for agent: AgentID, project: String, choosing explicit: UUID? = nil
    ) -> Result<AgentAccount?, AgentLaunchError> {
        guard let preferences else { return .success(nil) }
        let account: AgentAccount?
        if let explicit {
            guard let named = preferences.account(id: explicit) else {
                return .failure(.accountMissing(agent.displayName))
            }
            account = named
        } else {
            // A tombstoned assignment counts as missing. This asked `account(id:) == nil`,
            // which a tombstone answers non-nil — so the guard passed and the very next line
            // called `account(for:project:)`, which answers nil for exactly that case. The
            // `guard let account` below then read that nil as "no account to name", set no
            // home variable, and launched the agent in its built-in home: the silent
            // wrong-login substitution this whole method exists to refuse. Both readers of an
            // assignment have to agree about a tombstone, and the answer that is safe is
            // `.accountMissing`. (`markAccountRemoved` clears these assignments, so this is
            // defence in depth, matching `account(for:project:)`'s own comment.)
            if let assigned = preferences.projectSettings(project).accounts[agent],
               preferences.account(id: assigned)?.isRemoved ?? true {
                return .failure(.accountMissing(agent.displayName))
            }
            account = preferences.account(for: agent, project: project)
        }
        guard let account else { return .success(nil) }
        guard account.isBuiltIn || FileManager.default.fileExists(atPath: account.home.path) else {
            return .failure(.accountHomeMissing(account.displayName))
        }
        return .success(account)
    }

    /// Claude's adapter with this store's wiring on it.
    ///
    /// A builder rather than a stored literal now that there is one per account, but the
    /// wiring is the point: a bare `ClaudeAdapter()` carries neither this account's
    /// transcripts root — a test would then derive transcript paths under the developer's real
    /// `~/.claude/projects`, and a second login would read the first login's transcripts.
    ///
    /// The account is captured as an id and resolved on every derivation, not baked into a
    /// URL here: `projectsRoot` is a closure precisely so a home that moves (a relocated
    /// account, a fixture root assigned after construction) is picked up rather than frozen
    /// at the moment the adapter happened to be built.
    private func makeClaudeAdapter(account: UUID?) -> ClaudeAdapter {
        ClaudeAdapter(
            projectsRoot: { [weak self] in
                guard let self else { return ClaudeSession.defaultProjectsRoot }
                return self.transcriptsRoot(forAccount: account)
            }
        )
    }

    /// The adapter for one agent-as-account, memoized on a miss.
    ///
    /// An agent this store has no case for degrades to claude's adapter, wiring and all —
    /// `restore` rebuilds whatever `agent` a snapshot names, so an unregistered agent is a
    /// *data* possibility rather than only a future-code one, and a hand-edited
    /// `sessions.json` must not become a launch crash.
    ///
    /// Codex is answered from its account's stack rather than from `adapters`, so that an
    /// override installed through `overrideAdapter` keeps winning and the stack stays
    /// droppable in one place. `adapters` therefore holds only the claude entries built here
    /// and whatever a caller injected.
    func adapter(for instance: AgentInstance) -> any AgentAdapter {
        if let existing = adapters[instance] { return existing }
        if instance.agent == .codex {
            return makeCodexStackIfNeeded(account: instance.account).adapter
        }
        let adapter = makeClaudeAdapter(account: instance.account)
        adapters[instance] = adapter
        return adapter
    }

    func adapter(for agent: AgentID, account: UUID?) -> any AgentAdapter {
        adapter(for: AgentInstance(agent: agent, account: account))
    }

    /// Memoized on a miss, never freshly built per call.
    ///
    /// A runtime is stateful — it holds the attachment `detach` has to find — so answering
    /// two calls for one key with two instances starts a `TranscriptWatcher` nothing can ever
    /// stop and makes `detach` a no-op on an empty object. Adding the account to the key does
    /// not soften that: it splits the keyspace, it does not license a second answer within
    /// one key. The miss is reachable without a line of new code, for the reason
    /// `adapter(for:)` above gives, and degrading to a claude runtime keeps a mislabelled tab
    /// working.
    ///
    /// Codex gets its own real runtime, not that degraded fallback: a `ClaudeRuntime` here
    /// would sit on a codex tab tailing a transcript nothing writes, and the notifications the
    /// app-server does send would reach nobody.
    func runtime(for instance: AgentInstance) -> any AgentRuntime {
        if let existing = runtimes[instance] { return existing }
        if instance.agent == .codex {
            return makeCodexStackIfNeeded(account: instance.account).runtime
        }
        // `searchIndex` and `projectPath` are closures, re-read on every message batch rather
        // than resolved once here — see `ClaudeRuntime.init` — so a runtime built before
        // `AppDelegate` wires up search (or in any test, where it is never wired up at all)
        // still gets live indexing the moment it is. `projectPath` looks the session up by
        // its pinned conversation id rather than closing over one path, because a tab can be
        // moved to another project while its watcher is still running, and a project moved
        // out from under a stale closure would keep crediting the project it left.
        let runtime = ClaudeRuntime(clock: clock, searchIndex: { [weak self] in self?.searchIndex },
            projectPath: { [weak self] conversationID in
                self?.repos.flatMap(\.sessions)
                    .first { $0.pinnedConversationID == conversationID }?.workingDirectory
            })
        runtimes[instance] = runtime
        return runtime
    }

    func runtime(for agent: AgentID, account: UUID?) -> any AgentRuntime {
        runtime(for: AgentInstance(agent: agent, account: account))
    }

    /// Test seams, in the style of `injectorOverride`. Both are needed: runtime tests fake
    /// the event source, adapter tests fake identity negotiation and command construction.
    ///
    /// Scoped to one account, because that is what production looks up: an override installed
    /// against the wrong one is not found, silently, and for codex "not found" means building
    /// a real stack and eventually spawning a real `codex app-server`. A store built without
    /// preferences resolves every tab to `nil`, which is the account those tests name.
    func overrideRuntime(_ runtime: any AgentRuntime, for agent: AgentID, account: UUID?) {
        runtimes[AgentInstance(agent: agent, account: account)] = runtime
    }

    func overrideAdapter(_ adapter: any AgentAdapter, for agent: AgentID, account: UUID?) {
        adapters[AgentInstance(agent: agent, account: account)] = adapter
    }

    /// The one timer behind every watcher above, plus `statusWatchers`. Created lazily so a
    /// store built by a test that never starts watching never schedules anything; see
    /// `WatchClock` for why the app polls from a single coalesced source.
    ///
    /// It reads the store's `appIsActive` seam rather than `NSApplication` directly, so a
    /// test that needs the foreground (500 ms) cadence gets it from the same switch that
    /// already governs notification delivery. The closure re-reads the seam on every
    /// activation change, so assigning `appIsActive` after construction still takes effect.
    private lazy var clock = WatchClock(appIsActive: { [weak self] in
        self?.appIsActive() ?? false
    })

    /// The three observation seams, all nil by default, all meaning "derive it from the
    /// account". Injectable so a test or a fixture can point at a temp directory.
    ///
    /// Overrides rather than values, and consulted by the three accessors below rather than
    /// read directly, because of what an override has to guarantee: it must win for EVERY
    /// account. `SessionFixture` exists to keep a screenshot run out of the developer's real
    /// `~/.claude`, and an override that retargeted only the login the fixture happened to
    /// know about would let a second account's watcher — or worse, a second account's
    /// `claude` — reach the live registry anyway. One nil check per root, in one place, is
    /// what makes that property checkable; see `AccountObservationRootTests`.
    var transcriptsRootOverride: URL?
    var statusRootOverride: URL?
    var codexIndexURLOverride: URL?

    /// Where this account's claude transcripts live.
    func transcriptsRoot(for account: AgentAccount) -> URL { transcriptsRoot(forHome: account.home) }

    /// Where this account's claude status registry lives.
    func statusRoot(for account: AgentAccount) -> URL { statusRoot(forHome: account.home) }

    /// The index this account's codex stack tails. Keyed by account id rather than by
    /// `AgentAccount`, because that is what every codex registry here is keyed by.
    func codexIndexURL(for account: UUID?) -> URL {
        codexIndexURLOverride
            ?? CodexNameWatcher.indexURL(forHome: home(ofAccount: account, agent: .codex))
    }

    /// The same two roots keyed the way every registry here is — by account id, nil meaning
    /// the one home a store with no accounts configured serves. This is the form the adapter
    /// and the registry watchers use, since an id is what an `AgentInstance` carries; the
    /// `AgentAccount` overloads above are for callers holding the account itself.
    func transcriptsRoot(forAccount account: UUID?) -> URL {
        transcriptsRoot(forHome: home(ofAccount: account, agent: .claude))
    }

    func statusRoot(forAccount account: UUID?) -> URL {
        statusRoot(forHome: home(ofAccount: account, agent: .claude))
    }

    private func transcriptsRoot(forHome home: URL) -> URL {
        transcriptsRootOverride ?? home.appendingPathComponent("projects", isDirectory: true)
    }

    private func statusRoot(forHome home: URL) -> URL {
        statusRootOverride ?? home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The home an instance key stands for, resolved on every use rather than cached.
    ///
    /// Nil answers the agent's built-in home, which is exactly what a nil key means: a store
    /// with no `PreferencesStore` has no account to name and one home to serve (see
    /// `AgentInstance`).
    ///
    /// A key naming an account preferences no longer holds falls there too, and that answer
    /// is a fallback of last resort rather than a policy: no tab reaches it, because both
    /// paths that could launch one refuse first — `launchAccount` at creation, and
    /// `accountIsMissing(for:)` at restore, which also declines to start the watcher that
    /// would ask this question. What is left is a registry keyed before the user deleted its
    /// account mid-run, where answering with a path is preferable to trapping while a watcher
    /// asks where to look.
    private func home(ofAccount account: UUID?, agent: AgentID) -> URL {
        account.flatMap { preferences?.account(id: $0)?.home } ?? agent.builtInHome
    }

    /// Liveness predicate for registry entries. Nil means the real one — a status file is
    /// believed only while its process is running. `SessionFixture` overrides it, because a
    /// posed deck's status files name pids that were never spawned; without this the watcher
    /// discards every row and the sidebar reports nothing.
    var statusIsAlive: ((pid_t) -> Bool)?

    /// Sub-agent counts kept separately so one arriving before the registry has been
    /// read is not lost, and so a registry refresh never clobbers it.
    private var subagentCounts: [UUID: Int] = [:]

    /// One registry watcher per account with a live claude tab, keyed like every other
    /// registry here.
    ///
    /// Per account because the registry is a directory inside `CLAUDE_CONFIG_DIR`: a second
    /// login writes its status files somewhere the first login's watcher never looks, so a
    /// single watcher leaves those tabs with no glyph at all — silently, since an unwatched
    /// registry is indistinguishable from an idle one.
    private var statusWatchers: [UUID?: SessionStatusWatcher] = [:]

    /// The last scan from each account's registry, merged before it reaches `applyRegistry`.
    ///
    /// Merged, not applied one watcher at a time, because `applyRegistry` rebuilds `statuses`
    /// for EVERY claude tab out of the rows it is handed: a second account's tick carries only
    /// its own pids, so the first account's tabs would find no row and be reported as exited —
    /// a fabricated `busy → gone` edge per tab per tick, with the unread marks and withdrawn
    /// banners that edge produces. Pids are machine-wide, so the union is itself a well-formed
    /// registry.
    private var registryRows: [UUID?: [pid_t: ClaudeStatusFile.Entry]] = [:]

    /// Whether registry polling has been switched on at all. Only the production convenience
    /// init calls `startStatusWatching()`, and watchers are now also built on the tab path —
    /// so without this flag a store built by a test would start scanning the developer's real
    /// `~/.claude/sessions` the moment it made a claude tab.
    private var isStatusWatchingEnabled = false

    /// Test seam. Which accounts are currently scanning a registry — a missing key is a login
    /// whose tabs have no glyphs.
    var statusWatcherAccountsForTesting: Set<UUID?> { Set(statusWatchers.keys) }

    /// Test seam. The watcher object itself, so a test can assert the *same* one survived.
    ///
    /// Keys cannot see the hazard this exists for: rebuilding a watcher for an account that
    /// already had one overwrites the entry, leaving the map exactly the size it was, while
    /// the replaced object's registration on the shared `WatchClock` — keyed by
    /// `ObjectIdentifier`, so a new object never replaces it — polls alongside the new one.
    /// Only identity can fail that assertion.
    func statusWatcherForTesting(account: UUID?) -> AnyObject? { statusWatchers[account] }

    /// Set the instant `reapAllForQuit` begins, before its first `await`. Nothing stops
    /// a `statusWatchers` poll or the `WatchClock` timer while that reap is in flight — there
    /// is no `applicationWillTerminate` — so a tick can land mid-reap and see every tracked
    /// `claude` already gone. Every session's transition would then read `old != nil, new ==
    /// nil`, and the `persist()` at the end of `applyRegistry` would write `activity: nil`
    /// for every tab — erasing exactly the state the next launch's auto-resume needs to read
    /// back. `applyRegistry` returns immediately once this is set, so the state on disk is
    /// whatever the last real tick before quit left there.
    private var isTerminating = false

    /// Which process each tab is following, keyed by tab id. Established the first time a
    /// registry row carries the tab's conversation, and thereafter the only thing consulted
    /// — see `ConversationPin.resolve`.
    private var anchors: [UUID: ConversationPin.Anchor] = [:]

    private var sessionCounter = 0

    /// The project of the most recently activated tab, used as ⌘N's target when there is
    /// no selection. Deliberately not cleared when the selection goes nil or when the
    /// project empties — surviving the tab leaving is the entire point.
    private(set) var lastActiveProjectURL: URL?

    private let persistence: SessionPersisting?

    /// Read at session-creation time only. Preferences configure *new* sessions; a
    /// running `claude` is never reconfigured, because its command line is already spent.
    /// Not `private`: `AppDelegate` reads this to wire the Tools menu to the same store.
    let preferences: PreferencesStore?

    /// Test seam. Production sets this from the convenience init.
    var notifier: Notifying?

    /// Where plan gates come from. Nil by default, like `notifier` and `replicator`: most
    /// tests build a store with no phone-facing services attached. Assigned once by
    /// `FleetService.init`, then driven by `applyRegistry`'s existing tick — see
    /// `pollPlanGates()`. Not `private`: `FleetService` reads it to thread the same instance
    /// into every `FleetProjection` call site, so the oracle snapshot and the event-fold
    /// mirror never disagree about a gate.
    var planGates: PlanGateService?

    /// What each session's gate looked like last time `pollPlanGates()` ran, so
    /// `deliverPlanGateNotifications` can tell a re-poll of the same gate from a closed one or
    /// a revised one — the same job `statuses` does for `commitStatuses`, but plan gates never
    /// touch `statuses` (that is the defect this feature exists to fix), so they need their
    /// own remembered "before."
    private var previousPlanGates: [UUID: WirePlanGate] = [:]

    /// Where fleet changes are reported for replication to paired devices. Optional and nil
    /// by default, exactly like `notifier`: nearly every test builds a store with no client
    /// attached and must not be made to care.
    ///
    /// **If you add a mutation to `repos`, `statuses` or `unreadIdle`, it must `emit` its
    /// event.** Forgetting leaves every connected phone silently wrong until it reconnects —
    /// nothing crashes and no existing test fails. `FleetReplicator`'s DEBUG drift check is
    /// what turns that omission into a failure; see
    /// docs/superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md for the
    /// structural fix that will eventually make it unwriteable.
    var replicator: (any FleetRecording)?

    private func emit(_ events: [FleetEvent]) {
        guard let replicator, !events.isEmpty else { return }
        replicator.record(events)
    }

    private func emit(_ events: FleetEvent...) { emit(events) }

    /// The only writer of `unreadIdle`.
    ///
    /// Not style. There were seven `insert`/`remove` sites — a selection `didSet`, restore,
    /// `markUnread`, `closeSession`, `applyReadState`, app activation, and a test seam — and
    /// each one having to remember an event is the omission this whole mechanism is trying
    /// to make impossible. Returning early on an unchanged flag also keeps a client from
    /// receiving an event per poll for a session that has been unread for an hour.
    @discardableResult
    private func setUnread(_ id: UUID, _ isUnread: Bool) -> Bool {
        let changed = isUnread
            ? unreadIdle.insert(id).inserted
            : unreadIdle.remove(id) != nil
        guard changed else { return false }
        emit(.unreadChanged(id: id, isUnread: isUnread))
        return true
    }

    /// The wire form of a session as it stands right now.
    private func wire(_ session: Session) -> WireSession {
        FleetProjection.project(
            session, status: statuses[session.id], unread: unreadIdle,
            hasBackgroundWork: backgroundWorkSessions.contains(session.id),
            openPromptCall: openPromptCalls[session.id],
            planGates: planGates
        )
    }

    /// How a refused session creation reaches the user. Defaulted rather than injected
    /// because every caller wants the same alert, and overridable so no test ever puts a
    /// panel on screen. See `AgentLaunchFailureReporting`.
    var launchFailureReporter: AgentLaunchFailureReporting = NSAlertAgentLaunchFailureReporter()

    /// Whether a terminal can be created *right now*. A precondition, deliberately: creating
    /// and then discovering the failure is what produced tabs that looked real on the sidebar
    /// and on the phone while being permanently inert.
    ///
    /// **Gated on having a provider, and that is load-bearing, not a convenience.** The
    /// drawable is a requirement of *libghostty*, which is only involved when a provider
    /// exists. Nearly every fixture in the suite builds a store with `provider: nil`, and those
    /// fixtures create sessions and assert on them; without this clause a suite run that
    /// happened to start while the display was asleep would refuse every one of them and fail
    /// wholesale — the same shape of self-inflicted breakage that the `Session?` return type
    /// caused in the superseded plan, arriving by a different route.
    var canCreateTerminal: Bool { provider == nil || display.isDrawable }

    /// Whether the wake should be attempted, for callers where it would be wrong.
    enum DisplayWakePolicy { case wakeIfNeeded, never }

    /// How long to block waiting for a woken display. 1.5s is more than four times the
    /// slowest wake measured on this hardware (0.342s); past that the display is not coming
    /// (clamshell, none attached) and blocking the main actor further buys nothing.
    static let wakeTimeout: TimeInterval = 1.5

    /// `canCreateTerminal`, but allowed to *make* it true.
    ///
    /// The four creation paths call this instead of reading `canCreateTerminal` directly, so
    /// the wake happens in exactly one place. `canCreateTerminal` itself stays a pure query —
    /// it is read in contexts that must not light up a screen, and a property getter with a
    /// 350ms side effect would be a trap.
    ///
    /// **Blocking is deliberate.** Three of the four callers are synchronous and widely used;
    /// `newSession(in:)`'s own comment records that changing its shape broke 340 tests. The
    /// block only ever happens where the code currently fails outright, and only while the
    /// display is asleep — which is to say, while nobody is looking at this Mac.
    func ensureTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) -> Bool {
        if canCreateTerminal { lastFailedWake = nil; return true }
        // Reaching here means `provider != nil` (see `canCreateTerminal`), so the waker is
        // only ever consulted on a path that genuinely needs libghostty.
        guard policy == .wakeIfNeeded else { return false }
        if let last = lastFailedWake, now().timeIntervalSince(last) < Self.wakeRetryCooldown {
            return false
        }
        let woken = displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
        lastFailedWake = woken ? nil : now()
        return woken
    }

    /// `ensureTerminalCreatable`, for a caller that can afford to await instead of blocking.
    /// The phone's `.newSession` is the only one. Behaviour is identical in every other
    /// respect, including the `provider == nil` short-circuit inherited from `canCreateTerminal`.
    func awaitTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) async -> Bool {
        if canCreateTerminal { lastFailedWake = nil; return true }
        guard policy == .wakeIfNeeded else { return false }
        if let last = lastFailedWake, now().timeIntervalSince(last) < Self.wakeRetryCooldown {
            return false
        }
        let woken = await displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
        lastFailedWake = woken ? nil : now()
        return woken
    }

    /// Whether this tab's terminal actually forked a shell.
    ///
    /// **Not `surfaces[id] != nil`.** `makeSurfaceView` returns a non-optional and its init is
    /// non-failable, so a surface always exists — including for a tab that is inert because the
    /// display was asleep when it was born. The registry is what knows a child was forked, and
    /// it discriminates every observed case correctly.
    func hasShellProcess(for id: UUID) -> Bool { processRegistry.process(for: id) != nil }

    /// The outcome of trying to give an existing tab a working terminal. Distinguished rather
    /// than boolean because each sends the reader somewhere different, and plan 2 maps them
    /// onto HTTP statuses.
    enum RespawnOutcome: Equatable {
        case respawned, alreadyRunning, displayAsleep, unknownSession, failed
    }

    /// Replaces an inert terminal with a working one.
    ///
    /// *Replaces*, not fills: the broken tab already holds a `SurfaceView`: it just has no
    /// drawable behind it and never forked a child. Discarding it is safe precisely because
    /// there is no child process to orphan.
    @discardableResult
    func respawnSurface(for id: UUID) -> RespawnOutcome {
        guard let at = locate(id) else { return .unknownSession }
        let session = repos[at.repo].sessions[at.session]
        // Ordered before the display check deliberately: "it is already working" is true and
        // more useful regardless of what the display is doing.
        guard !hasShellProcess(for: id) else { return .alreadyRunning }
        guard ensureTerminalCreatable() else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: true))
            return .displayAsleep
        }

        // Drop the inert view and its (absent) registry record before rebuilding, so the new
        // fork is contested by exactly one claimant.
        surfaces[id] = nil
        _ = processRegistry.forget(id)

        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = session.transcriptDirectory
        // `nil` when unset: `withCValue` already maps that to `0`, meaning "inherit
        // libghostty's configured default" — the same thing a never-touched size means.
        config.fontSize = preferences?.preferences.terminalFontSize
        // Adapter and options resolved exactly as `newSession(in:)` does: `launchCommand` takes
        // a NON-optional `AgentOptions`, and the adapter comes from the tab's instance, not
        // from `AgentID`.
        let adapter = adapter(for: instance(for: session))
        let options = options(for: session.agent, project: session.workingDirectory)
        config.initialInput = adapter.launchCommand(adapter.binding(for: session), session, options)
        let orphaned = accountIsMissing(for: session)
        config.environmentVariables =
            preferences?.sessionEnvironment(for: orphaned ? nil : account(for: session)) ?? [:]

        guard let surface = processRegistry.record(for: id, around: { provider?.makeSurface(config) })
        else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: false))
            return .failed
        }
        surfaces[id] = surface
        // Same ordering and reason as `insertSession`: before anything is typed, so the child
        // is not left talking to libghostty's placeholder 800x600 grid.
        report(terminalSize, to: id)
        provider?.tick()
        if !orphaned { startWatching(tabID: id) }
        return .respawned
    }

    /// Test seam for frontmost-ness; production reads `NSApplication`.
    var appIsActive: () -> Bool = { NSApplication.shared.isActive }

    private var activationObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    /// Renames typed into the sidebar but not yet typed into `claude`, one per tab.
    /// See `flushPendingRename` for why an injection waits.
    private var pendingRenames: [UUID: String] = [:]

    /// Read-only view of the rename queue, so `AccountSignInTests` can assert that signing in
    /// puts nothing in it. Sign-in used to queue `/login` *as a rename*, and the only way to
    /// pin that regression is to look at this from outside.
    var pendingRenamesForTesting: [UUID: String] { pendingRenames }

    /// One queued injection per tab: what to type, and when it stops being worth typing.
    ///
    /// Carries its text rather than assuming one, because two callers now share this queue —
    /// `restore` queues "Keep going" for a resumed session, and `openSignInSession` queues an
    /// agent's `LoginInvocation.inject` (`/login`). Before it carried text, sign-in had
    /// nowhere correct to go and was routed through the *rename* channel instead, which typed
    /// `/rename /login` at the tab.
    struct DeferredPrompt: Equatable {
        let text: String
        let deadline: Date
    }

    /// Internal rather than private so tests can observe the queue without scripting a whole
    /// surface; nothing outside this type writes it.
    private(set) var pendingPrompts: [UUID: DeferredPrompt] = [:]

    /// Tabs with a `sendKillLine()` already out and a settle still pending. Guarding here,
    /// inside `inject` itself, rather than in each caller is load-bearing: `rename()` calls
    /// `flushPendingRename` straight off the user's keystroke with no interval to race
    /// against, unlike the registry tick's ~500ms poll against a 120ms settle. Without this a
    /// rename landing inside a prompt's settle window sends a second Ctrl+U into a viewport
    /// the first settle is still comparing against, and the prompt's settle then lands into a
    /// session the rename just made busy — exactly what the idle gate above exists to
    /// prevent, because it was evaluated before that second send, not after.
    private var injecting: Set<UUID> = []

    /// Test seam, in the style of `appIsActive` and `injectionSettle`. Production reads the
    /// wall clock.
    var now: () -> Date = { Date() }

    /// Test seam. Production pauses between killing the input line and reading the screen
    /// back, because Claude Code repaints asynchronously; tests run the continuation inline.
    var injectionSettle: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The terminal pane's content size in points — the single source of truth for how big
    /// every surface's grid should be.
    ///
    /// It exists because there is nowhere else to ask. `restore()` runs inside
    /// `SessionStore.init`, which is a `@StateObject` initializer, so every session's shell is
    /// forked before SwiftUI has built the scene body: at spawn time there is no window to
    /// measure. Seeded from the snapshot, updated by `TerminalHostView`, and handed to each
    /// surface the moment it is created.
    private(set) var terminalSize: CGSize = SessionStore.defaultTerminalSize

    /// What to use on a first-ever launch, when no snapshot has a size to offer.
    ///
    /// Derived from the geometry `RootWindow` declares — `.defaultSize(width: 1000, height:
    /// 700)` less the sidebar's 240pt ideal and the title bar. An estimate, and deliberately
    /// so: it is only ever wrong for one launch, after which a real layout has been recorded.
    static let defaultTerminalSize = CGSize(width: 760, height: 672)

    /// What a persisted dimension has to fall inside for `restore()` to believe it, rather than
    /// falling back to `defaultTerminalSize`.
    ///
    /// `sessions.json` is deliberately kept human-readable, which is another way of saying
    /// humans edit it. A zero, negative, or NaN value there would be permanent and silent: every
    /// `report(_:to:)` would fail its own positive-size guard, so every surface in every future
    /// launch would sit at libghostty's 800x600 placeholder — the exact bug this feature exists
    /// to fix — and nothing downstream re-validates the seed. The upper bound is not decoration
    /// either: `sizeDidChange` ends at `UInt32(scaledSize.width)`, which *traps* rather than
    /// saturates once the scaled value passes `UInt32.max`.
    ///
    /// Membership is tested rather than the failures being tested for, and that is load-bearing:
    /// NaN compares false against every operator, so `contains` rejects it, while the negated
    /// form (`width <= 0 || width > max`) would wave it straight through.
    private static let plausibleTerminalDimension: ClosedRange<Double> = 1...100_000

    /// Test seam. Production leaves this nil and sizing goes to the live surface — the same
    /// arrangement as `injectorOverride`, and for the same reason: `SurfaceProvider` stubs
    /// return nil surfaces, so there would otherwise be nothing to assert against.
    var sizeReporterOverride: ((UUID, CGSize) -> Void)?

    /// The one place a size reaches a surface.
    ///
    /// A zero-sized report is a normal transient state (a container added early, or to a
    /// hierarchy that is not on screen yet); upstream Ghostty guards the same call the same
    /// way in `SurfaceScrollView.synchronizeCoreSurface`.
    private func report(_ size: CGSize, to id: UUID) {
        guard size.width > 0, size.height > 0 else { return }
        if let sizeReporterOverride {
            sizeReporterOverride(id, size)
            return
        }
        surfaces[id]?.sizeDidChange(size)
    }

    /// Applies a new global terminal font size to every live surface.
    func applyTerminalFontSize(_ points: Float) {
        let action = TerminalFontSize.action(points: points)
        for surface in surfaces.values { surface.performBindingAction(action) }
    }

    /// Test seam. Production waits for a drag to settle before touching background surfaces;
    /// tests capture the continuation and run it when they choose. Mirrors `injectionSettle`.
    var resizeSettle: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Bumped on every accepted resize so a superseded settle can identify itself and bow out.
    /// A counter rather than a cancellable `DispatchWorkItem` because it keeps working
    /// unchanged when a test substitutes a `resizeSettle` that runs inline.
    private var resizeGeneration = 0

    /// The terminal pane was laid out at a new size.
    ///
    /// The selected surface is told straight away — it is the one being watched, and its
    /// reflow is the one the user is waiting to see. Every other live surface is told once,
    /// after the drag settles. Telling them all per frame would cost one
    /// `ghostty_surface_set_size` — a grid *and* scrollback reflow — per surface per frame,
    /// and `setSurfaceSize`'s deduplication cannot help, because no two frames of a drag carry
    /// the same size.
    func terminalSizeDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != terminalSize else { return }
        terminalSize = size
        if let selectedSessionID { report(size, to: selectedSessionID) }

        resizeGeneration &+= 1
        let generation = resizeGeneration
        resizeSettle { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            // Every live session, not "every surface except the selected one": selection can
            // change between the resize and the settle, and `setSurfaceSize` already discards
            // a repeat of an unchanged pixel size, so the redundant call costs nothing.
            //
            // Walks `repos`, not `surfaces.keys`: a session whose surface has not been created
            // yet (or was never given one, as in tests) still belongs on the size, and
            // `report(_:to:)` is a safe no-op for it either way.
            for id in self.repos.flatMap(\.sessions).map(\.id) {
                self.report(self.terminalSize, to: id)
            }
            // Persisted here rather than left to the next mutation, because "launch, resize the
            // window, quit" contains no mutation — and once per drag gesture is cheap.
            self.persist()
        }
    }

    /// A tab was selected, so its surface may be carrying a grid from whenever it was last on
    /// screen — or, for a tab restored and never opened, from its creation.
    ///
    /// Deliberately not routed through `terminalSizeDidChange`: that method dedupes against
    /// the stored size, and here the stored size is exactly what has *not* changed.
    func activateTerminalSize(for id: UUID) {
        report(terminalSize, to: id)
    }

    init(
        provider: SurfaceProvider?,
        persistence: SessionPersisting? = nil,
        preferences: PreferencesStore? = nil,
        reaper: SessionReaper = SessionReaper(
            inspector: ProcessTree(), signals: PosixSignals(), sleeper: RealSleeper()
        )
    ) {
        self.provider = provider
        self.persistence = persistence
        self.preferences = preferences
        self.reaper = reaper
        // Shell records land asynchronously, up to half a second after the tab they belong to
        // (see `SurfaceProcessRegistry`), so the `persist()` that `newSession`/`restore` already
        // ran is too early to contain them. Without this the snapshot names no shell for any
        // tab until some unrelated mutation happens to save again — and a crash before that
        // leaves the next launch's orphan sweep nothing to find.
        processRegistry.onChange = { [weak self] in self?.persist() }
        observeActivationRequests()
        observeSurfaceClose()
        observeAppActivation()
        // Two independent ways for `AppDelegate` to find the store it does not own, because
        // quit reaping silently does nothing if it finds neither — see `.flightDeckStoreReady`
        // and `SessionStore.current`.
        Self.current = self
        NotificationCenter.default.post(name: .flightDeckStoreReady, object: self)
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    /// `resetState` comes from the `-FlightDeckResetState YES` launch argument. The UITest
    /// bundle launches the app once per test case, so a session persisted by an earlier case
    /// would otherwise survive into a later one and make tests order-dependent. This argument
    /// is the *only* thing keeping the UI tests hermetic with respect to session state —
    /// `smoke.sh` deliberately no longer deletes stored state to achieve it, because doing so
    /// destroyed the user's real sessions on every run.
    /// `notifier` is assigned before `startStatusWatching()` runs, deliberately: the
    /// watcher's first drain is what can reach `deliverNotifications`, and that must never
    /// see a nil notifier land on a live `waiting` session at launch. It happens to be
    /// safe today even when the caller assigns `notifier` after construction (as
    /// `FlightDeckApp.makeStore()` used to) — `startStatusWatching()`'s first fire is an
    /// async main-queue hop that lands after this initializer returns — but that safety
    /// is incidental to the timer's current implementation, not guaranteed by this
    /// method's contract. Taking `notifier` as a parameter here removes the dependency on
    /// that timing.
    ///
    /// `preferences` is a parameter for a stricter reason: `restore()` below resolves each
    /// restored session's flags as it rebuilds it, so the store must already be readable by
    /// the time this initializer runs — assigning it afterwards would launch every restored
    /// session unconfigured.
    ///
    /// `persistence` is deliberately **not** defaulted: every caller has to say where state
    /// goes. This initializer seeds *and persists*, and `resetState` only suppresses the
    /// restore — so a caller that quietly got the real `FileSessionPersistence` would
    /// overwrite the developer's own `sessions.json` with a test seed. Passing `nil` means
    /// read nothing and write nothing, which is what a reset/UITest run wants.
    convenience init(
        ghostty: GhosttyApp?,
        resetState: Bool = false,
        preferences: PreferencesStore? = nil,
        notifier: Notifying? = nil,
        reapReporter: ReapReporting? = nil,
        persistence: SessionPersisting?,
        statusRoot: URL? = nil,
        transcriptsRoot: URL? = nil,
        statusIsAlive: ((pid_t) -> Bool)? = nil
    ) {
        self.init(
            provider: ghostty,
            persistence: persistence,
            preferences: preferences
        )
        // Load-bearing: `display` defaults to the always-permissive `AlwaysDrawableDisplay()`
        // so tests that construct a `SessionStore` don't have to stub it (see that type's doc
        // comment). This line is what makes `canCreateTerminal` real outside tests, and it
        // must run before `seedInitialSession()` below — that call creates a tab through this
        // same store, so assigning the real probe any later (e.g. after this initializer
        // returns, as `FlightDeckApp` used to) would let a cold launch seed an inert tab
        // while the display is asleep, reintroducing the original bug. Removing this line
        // silently disables the guard for every session this store ever creates.
        display = DisplayState()
        // Beside `display` and load-bearing in the same way: the default waker is inert, so
        // without this line every sleeping display is a refusal again and no test notices.
        // `DisplayWakerTests` covers the waker; `testTheRealWakerIsWiredIn` covers this line.
        // Built around the probe just assigned on principle, not because a different one
        // could disagree — `DisplayState` is a stateless struct that reads only CoreGraphics,
        // so any instance of it answers identically to any other.
        displayWaker = DisplayWaker(display: display)
        self.notifier = notifier
        // Both assigned before `startStatusWatching()` below, which reads them when it builds
        // each account's watcher — setting either afterwards would leave those watchers
        // pointed at the real registry for the life of the run. Nil for every caller except a
        // fixture launch, and an override rather than a value, so a fixture retargets every
        // account rather than whichever one it knew to name.
        if let statusRoot { statusRootOverride = statusRoot }
        // Before `restore()`, which attaches a transcript watcher per restored session.
        if let transcriptsRoot { transcriptsRootOverride = transcriptsRoot }
        self.statusIsAlive = statusIsAlive
        // Before the sweep below, which reports through it.
        if let reapReporter { self.reapReporter = reapReporter }
        // Captured BEFORE `restore()`, which persists at the end and would otherwise replace
        // the previous run's records with this one's. The sweep itself is async and may land
        // well after that write; it works from this snapshot, not from disk.
        let previousRun = persistence?.load()
        if resetState || !restore() { seedInitialSession() }
        startStatusWatching()
        if let previousRun {
            Task { [weak self] in await self?.sweepOrphans(from: previousRun) }
        }
    }

    func seedInitialSession(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard repos.isEmpty else { return }
        // `.never`: this runs inline inside `SessionStore.init`, so waking here would light
        // the screen up on every unattended relaunch and block app startup while it waited.
        // Seeding is the app starting, not someone asking for a terminal.
        newSession(in: homeURL, waking: .never)
    }

    /// Claude's creation path, synchronous.
    ///
    /// Stays synchronous deliberately: `seedInitialSession` runs inline inside
    /// `SessionStore.init`, so an `await` here would mean the first tab appearing after the
    /// initializer returns. It reaches `binding(for:)` legally because claude *mints* its own
    /// conversation id — the session already holds the identity, and there is nothing to
    /// negotiate. An agent whose identity comes back from a server cannot be created here at
    /// all: this takes no agent, `Session` defaults to `.claude`, and codex goes through
    /// `createSession(agent:in:)`.
    ///
    /// No longer *infallible*, and the shape of that is a deliberate compromise. A project
    /// whose claude account no longer resolves cannot have a tab (see `launchAccount`), but
    /// this method is `-> Session` at some 140 call sites that treat it as total, and widening
    /// it to `Session?` would say nothing those call sites act on. So the refusal takes the
    /// channel `createSession` already uses — `launchFailureReporter`, which is what the user
    /// actually sees — and the returned value is the draft that was never filed: nothing is in
    /// `repos`, no surface exists, and no project was created to hold one. A caller that needs
    /// to *know* uses `createSession(agent:in:)`, which returns a `Result`; every caller here
    /// either discards the value or hands it to something that looks it up and finds nothing.
    ///
    /// `account`, when given, names the login directly — the New Session dropdown's chosen
    /// account (Task 14) rather than whatever `launchAccount` would otherwise resolve from
    /// project settings. Every other caller leaves it nil and gets the resolved default,
    /// unchanged.
    ///
    /// - Parameter selecting: whether this creation may move the Mac's selected tab. Defaults
    ///   to true, preserving every existing desk caller's behaviour; `createSession` threads a
    ///   client's `false` through this same parameter for its claude branch. See
    ///   `select(_:selecting:)`.
    @discardableResult
    func newSession(
        in url: URL, at index: Int? = nil, account explicit: UUID? = nil,
        waking: DisplayWakePolicy = .wakeIfNeeded, selecting: Bool = true
    ) -> Session {
        guard ensureTerminalCreatable(waking) else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: true))
            // Un-inserted, exactly as the `launchAccount` failure path below does. The return
            // type stays non-optional on purpose: making it `Session?` broke 340 tests, because
            // nearly every fixture in the suite builds a store with a nil-returning provider.
            return Session(title: "", workingDirectory: url.path)
        }
        // Resolved before the title is minted, so a refusal does not burn a session number.
        let account: AgentAccount?
        switch launchAccount(for: .claude, project: url.path, choosing: explicit) {
        case .success(let resolved): account = resolved
        case .failure(let error):
            launchFailureReporter.report(error)
            return Session(title: "", workingDirectory: url.path)
        }
        // Stamped at birth, not left nil to be re-resolved later. nil would mean "the built-in
        // home" forever — correct only by accident today, and wrong the moment the user adds a
        // second login or reassigns this project's default, which would silently move every
        // existing tab's conversation to a home it was never written in.
        let session = Session(
            title: nextSessionTitle(), workingDirectory: url.path, accountID: account?.id
        )
        let adapter = adapter(for: instance(for: session))
        let options = options(for: session.agent, project: url.path)
        return addSession(
            session,
            in: url,
            initialInput: adapter.launchCommand(adapter.binding(for: session), session, options),
            at: index,
            selecting: selecting
        )
    }

    /// Creates a tab for any agent, negotiating conversation identity first for the agents
    /// that need it, and refusing to create one at all when that negotiation fails.
    ///
    /// `async` and fallible for exactly one agent. Codex assigns thread ids itself and does
    /// not persist a thread until it has also been named, so identity here is a round trip
    /// that can fail — and a tab bound to a thread that was never committed looks fine until
    /// its terminal reports `No saved session found with ID …`. Claude cannot fail and must
    /// not be made to await: it keeps `newSession`'s synchronous path untouched.
    ///
    /// Both reports the failure and returns it: the alert is what the user sees (a failed
    /// creation leaves no tab on which to notice anything), and the `Result` is what a caller
    /// that wants to react — a test, a menu action selecting the new tab — reads.
    ///
    /// `account`, when given, bypasses `launchAccount`'s project-settings resolution the same
    /// way `newSession`'s does — the New Session dropdown's chosen account, not the default.
    ///
    /// - Parameter selecting: whether this creation may move the Mac's selected tab. Defaults
    ///   to true, matching every menu/dropdown caller. `FleetService` passes `false` for a
    ///   phone `+` tap on an agent/account row — a client's creation must not move the desk's
    ///   selection off whatever is on screen. Threaded to both the claude branch (which
    ///   delegates to `newSession(in:)`) and the codex branch's own `addSession` call below.
    @discardableResult
    func createSession(
        agent: AgentID, in directory: String, at index: Int? = nil, account explicit: UUID? = nil,
        selecting: Bool = true
    ) async -> Result<UUID, AgentLaunchError> {
        // Before anything else, covering both branches below: the codex branch calls
        // `addSession` directly rather than routing through `newSession(in:)`, so it does not
        // get that guard for free, and a codex tab created with the display asleep would
        // otherwise be born just as inert as the bug this exists to fix. Reported through
        // `launchFailureReporter` exactly as the neighbouring `launchAccount` failure branch
        // does, just below.
        guard ensureTerminalCreatable() else {
            let error = AgentLaunchError.terminalUnavailable(displayAsleep: true)
            launchFailureReporter.report(error)
            return .failure(error)
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        // FIRST, before a draft exists and before anything codex-shaped is touched. A login
        // that cannot launch must not mint a title, must not spawn an app-server to negotiate
        // against, and must not leave a `codexCreationsInFlight` count behind — and the user
        // has to be told which choice is broken rather than watching a tab appear as somebody
        // else. Claude's path is checked here too, by falling through this switch before it
        // delegates: `newSession` reports the same refusal, but only this shape can return it.
        let account: AgentAccount?
        switch launchAccount(for: agent, project: directory, choosing: explicit) {
        case .success(let resolved): account = resolved
        case .failure(let error):
            launchFailureReporter.report(error)
            return .failure(error)
        }
        // An agent that mints its own conversation id has nothing to negotiate, so it takes
        // the synchronous path and never touches anything this method builds below.
        guard agent.negotiatesIdentity else {
            return .success(
                newSession(in: url, at: index, account: explicit, selecting: selecting).id
            )
        }

        // Named before `prepare`, not after: `thread/name/set` is what commits the thread,
        // and it sends this title. A failed creation therefore burns a number — "session 4"
        // following "session 2" is a far smaller cost than a tab whose codex thread is
        // called something else.
        //
        // Stamped with its account here, which is also what keys the app-server this
        // negotiation runs against — see `instance` below and `newSession` for why the stamp
        // cannot be deferred.
        let draft = Session(
            title: nextSessionTitle(), workingDirectory: directory, agent: agent,
            accountID: account?.id
        )
        let options = options(for: agent, project: directory)
        // Resolved once, from the draft, and used for every registry the creation touches:
        // the adapter it prepares against, the app-server it holds open, and the teardown it
        // defers all have to name the same account, or the creation guards a stack nobody is
        // building.
        let instance = instance(for: draft)

        // Held across the whole negotiation, not just `prepare`. `closeSession` on the last
        // remaining codex tab runs `stopCodexIfUnused`, which counts tabs in `repos` — and
        // this one is not in `repos` until `addSession` below. Without this the app-server
        // could be killed between `thread/start` and `thread/name/set`, which evaporates the
        // thread, because naming is what commits it — under the `legacy` history contract
        // `CodexAdapter.historyMode` pins.
        codexCreationsInFlight[instance.account, default: 0] += 1
        defer {
            codexCreationsInFlight[instance.account, default: 0] -= 1
            // Deferred, not skipped. A tab closed while this was in flight had its teardown
            // declined above; if this creation failed, nothing else will ever run it, and the
            // app-server would outlive every codex tab. A creation that SUCCEEDED inserted
            // its tab already, so the tab count below refuses the teardown by itself.
            stopCodexIfUnused(account: instance.account)
        }

        let binding: AgentBinding
        do {
            binding = try await preparedAdapter(for: instance).prepare(for: draft, options: options)
        } catch {
            let failure = launchError(from: error)
            launchFailureReporter.report(failure)
            return .failure(failure)
        }

        // Rebuilt rather than mutated so the tab is pinned to what codex actually named,
        // including the rollout path it reported. `id` is carried over so the title minted
        // above still belongs to this tab.
        let session = Session(
            id: draft.id,
            title: draft.title,
            workingDirectory: directory,
            pinnedConversationID: binding.conversationID,
            agent: agent,
            // Carried over from the draft, like `id`: the tab has to keep the account its
            // app-server was started for, or its next lookup keys a different instance.
            accountID: draft.accountID,
            transcriptPath: binding.transcriptURL?.path
        )
        let adapter = adapter(for: instance)
        addSession(
            session,
            in: url,
            initialInput: adapter.launchCommand(binding, session, options),
            at: index,
            selecting: selecting
        )
        return .success(session.id)
    }

    /// The Accounts pane's "Sign In" / "Sign In Again" path: an ordinary tab, bound to a
    /// specific account the caller names outright rather than one `launchAccount` would
    /// resolve from project settings — a login is not the project's default agent, it is
    /// whichever account the user just clicked.
    ///
    /// Deliberately bypasses `createSession`'s negotiation entirely rather than routing
    /// through it with an override: a login has no conversation to resume and no title to
    /// give codex, so the ordinary `--session-id … --name …` shape is wrong for it, and
    /// negotiating a codex thread before the account has even authenticated would be actively
    /// harmful — `thread/start` is not what `codex login` is.
    ///
    /// `invocation` is the agent's own `LoginInvocation`: its `command` (`"claude"`,
    /// `"codex login"`) is newline-terminated and typed at the shell, and its `inject`
    /// (`/login`, or nil) is queued for the agent once it is up. The store owns both halves so
    /// no caller has to know which agent it is holding.
    @discardableResult
    func openSignInSession(
        for account: AgentAccount, in directory: String, using invocation: LoginInvocation
    ) -> Session {
        guard ensureTerminalCreatable() else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: true))
            // Same un-inserted-`Session` convention as `newSession(in:)`: this bypasses
            // `createSession` entirely (see the doc comment above), so it needs its own guard
            // rather than inheriting one — R1 missed this path.
            return Session(title: "", workingDirectory: directory)
        }
        let session = Session(
            title: nextSessionTitle(), workingDirectory: directory, agent: account.agent,
            accountID: account.id
        )
        let created = addSession(
            session, in: URL(fileURLWithPath: directory, isDirectory: true),
            initialInput: Self.terminated(invocation.command)
        )
        // Queued rather than sent: `inject` needs an idle status and a readable one-row
        // InputBar, and this tab is a bare shell that has not even started the agent yet. The
        // registry scan retries it until the agent is up, or the deadline passes.
        //
        // Deliberately NOT routed through claude's rename channel, which is what this used
        // to do via `ClaudeAdapter.injectRename` (deleted as dead code once nothing reached
        // it): that channel typed `/rename /login` at the tab, and login is not a rename.
        if let inject = invocation.inject {
            pendingPrompts[created.id] = DeferredPrompt(
                text: inject, deadline: now().addingTimeInterval(Self.resumePromptWindow)
            )
        }
        return created
    }

    /// Terminates a command so the shell actually runs it.
    ///
    /// `initial_input` reaches the pty as typed characters and nothing downstream presses
    /// Return — which is why every other producer ends its own string with a newline
    /// (`ClaudeSession.launchCommand`, `resumeCommand`). `LoginInvocation` does not, and the
    /// symptom was a sign-in tab sitting at a prompt with `claude` typed into it forever.
    ///
    /// Normalized here rather than in each adapter's `LoginInvocation` deliberately: an
    /// adapter is asked *what to run*, and a future agent's author has no reason to know the
    /// answer is fed to a pty rather than to `Process`. One consumer cannot forget.
    static func terminated(_ command: String) -> String {
        command.hasSuffix("\n") ? command : command + "\n"
    }

    /// Applies a selection write under the client-selection rule, and the one chokepoint every
    /// `selecting:` parameter in this file funnels through.
    ///
    /// **A command or request arriving from a client must never move the Mac's selected tab.**
    /// Reopening, resuming or creating a tab from the phone is right for ⌘⇧T, ⌘K and ⌘N — the
    /// user is sitting at the desk and asked for exactly that — but a client acting on its own
    /// initiative has no business yanking the desk's focus off whatever is on screen. The
    /// phone's presence badge (`FleetCommand.viewing`) already exists to say "I'm looking at
    /// this one"; that is the channel for a client's own attention, not the desk's selection.
    ///
    /// The one exception this method makes: `selectedSessionID == nil`. With nothing selected
    /// there is no focus to steal, and the alternative is a sidebar showing tabs over an empty
    /// pane — so a client action resolves that exactly as a desk action would.
    ///
    /// One more exception exists outside this method's control: `closeSession` relocates the
    /// selection to `repos.flatMap(\.sessions).first` when a client closes the tab that was
    /// selected — something must be selected once the selected tab is gone, and there is no
    /// meaningful "whatever was on screen" left to preserve. Pre-existing, unavoidable, and out
    /// of scope here; named so the rule above is read against what actually holds rather than
    /// only what this one chokepoint enforces.
    private func select(_ id: UUID, selecting: Bool) {
        guard selecting || selectedSessionID == nil else { return }
        selectedSessionID = id
    }

    /// The tail every creation shares: file the tab, reveal it, select it, save.
    ///
    /// Split from `insertSession` rather than folded into it because `restore` calls that one
    /// directly — for the reason the un-collapse below spells out.
    ///
    /// - Parameter selecting: whether this creation may move the Mac's selected tab. Defaults
    ///   to today's behaviour — every creation path selects what it just made — because a
    ///   caller at the desk (⌘N, ⌘⇧A, a folder drop) explicitly asked for a new tab and expects
    ///   to land on it. `false` is for a creation a client asked for (the phone's `+`): the
    ///   desk's selection is not this caller's to move. See `select(_:selecting:)`.
    @discardableResult
    private func addSession(
        _ session: Session, in url: URL, initialInput: String, at index: Int? = nil,
        selecting: Bool = true
    ) -> Session {
        insertSession(session, in: url, initialInput: initialInput, at: index)
        // A session landing in a collapsed project is otherwise invisible: `SidebarRow.rows`
        // renders only the header for a collapsed repo, so the new row exists in `repos` but
        // nothing in the sidebar shows it happened. Un-collapsing here — not in
        // `insertSession` — is deliberate: `restore()` calls `insertSession` directly rather
        // than going through `newSession`, precisely so a project's persisted collapsed state
        // survives relaunch undisturbed. Moving this expansion down into `insertSession` would
        // spring every restored collapsed project open on the next launch.
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
        select(session.id, selecting: selecting)
        persist()
        return session
    }

    /// The next default tab name. One counter for every agent: the number is the tab's
    /// position in this run's history, not the agent's.
    private func nextSessionTitle() -> String {
        sessionCounter += 1
        return "session \(sessionCounter)"
    }

    /// The adapter to create a session with, with whatever has to be running behind it
    /// running.
    ///
    /// A caller that installed its own adapter through `overrideAdapter` owns the transport
    /// behind it, so nothing is spawned for it — which is also what keeps the committed test
    /// suite from ever running `codex`.
    private func preparedAdapter(for instance: AgentInstance) async throws -> any AgentAdapter {
        // Counted before the override check, deliberately: what the tests need to assert is
        // that a path *asked* for a running app-server, and a test that let it actually start
        // one would spawn `codex`. One ask is one account's — two logins asking is two.
        if instance.agent.needsRuntimeStart { codexServerRequestsForTesting += 1 }
        if let registered = adapters[instance] { return registered }
        guard instance.agent.needsRuntimeStart else { return adapter(for: instance) }
        try await startCodex(account: instance.account)
        return makeCodexStackIfNeeded(account: instance.account).adapter
    }

    /// Probes the installed `codex`, spawns its app-server and completes the handshake —
    /// once, however many tabs ask at the same time.
    ///
    /// The version probe runs off the main actor because it spawns `codex --version` and
    /// waits for it, which is a visible hitch where the UI lives. Everything after it is
    /// main-actor work by construction: the transport and the client both are.
    private func startCodex(account: UUID?) async throws {
        if let handshake = codexHandshake[account] { return try await handshake.value }
        let stack = makeCodexStackIfNeeded(account: account)
        let task = Task { @MainActor in
            // Bounded, and that matters more here than anywhere else in this method: this
            // task is memoized in `codexHandshake`, so an unbounded probe would hang not
            // just this creation but every codex creation on this account for the rest of
            // the run, all of them awaiting the same wedged task. `verifyHandshake` below was
            // already bounded; the step in front of it was not. See `checkOffMainActor`.
            //
            // The mode is set on `stack.adapter` before `verifyHandshake` runs, not after —
            // every caller of `adapter(for:)` reads `stack.adapter` fresh once this task
            // completes (see the comment there), so there is no window where a caller could
            // observe the stack with the probe done but the mode unset.
            let version = try await CodexVersionProbe.checkOffMainActor()
            stack.adapter.historyMode = CodexVersionProbe.supportsHistoryMode(version) ? "legacy" : nil
            try stack.transport.start()
            try await CodexProcessTransport.verifyHandshake(stack.rpc)
        }
        codexHandshake[account] = task
        do {
            try await task.value
        } catch {
            // A failed launch must not poison the store: tearing the stack down means the
            // next attempt — after the user installs or upgrades codex — probes again instead
            // of replaying this failure for the rest of the run.
            //
            // `stopCodex()` rather than nilling the two fields, because the failure can come
            // from `verifyHandshake` — by which point a process is already running. Relying on
            // `CodexProcessTransport.deinit` to reap it would be correctness by retention
            // reasoning two files away, and would break the moment anything took a second
            // strong reference to the transport. `ClaudeRuntime.attach` refuses to lean on
            // exactly that; so does this.
            // The stack THIS attempt built, not whatever is current: a slow failure here can
            // land after a later creation has already replaced it.
            stopCodex(account: account, expected: stack)
            throw error
        }
    }

    /// Names the cause for the alert, in words rather than in case names.
    ///
    /// Neither default is usable as it stands: `localizedDescription` on a plain Swift error
    /// is "The operation couldn't be completed. (FlightDeck.CodexRPCError error 2.)", and
    /// `String(describing:)` is `transportClosed` — an alert that shows either has told the
    /// user nothing. The one exception is a remote error, whose message comes from codex and
    /// is the most specific thing anyone knows about the failure ("cwd is not trusted").
    private func launchError(from error: Error) -> AgentLaunchError {
        switch error {
        case let launch as AgentLaunchError:
            return launch
        case CodexRPCError.transportClosed:
            return .prepareFailed("the Codex app-server stopped before it answered.")
        case CodexRPCError.timeout:
            return .prepareFailed("the Codex app-server did not answer in time.")
        case CodexRPCError.remote(_, let message):
            return .prepareFailed(message)
        case CodexRPCError.malformed(let what):
            return .prepareFailed("Codex sent something unusable (\(what)).")
        default:
            return .prepareFailed(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    /// ⌘N. Creates a session in the ACTIVE session's project, directly below it, and
    /// activates it. Returns nil when nothing is active — the caller routes that case to
    /// `addProject` instead (see `SessionCreateAction`).
    @discardableResult
    func newSessionBelowActive() -> Session? {
        guard let activeID = selectedSessionID, let at = locate(activeID) else { return nil }
        let active = repos[at.repo].sessions[at.session]
        let url = URL(fileURLWithPath: active.workingDirectory, isDirectory: true)
        return newSession(in: url, at: at.session + 1)
    }

    /// ⌘⇧A and folder drops. A new folder becomes a project; a known one gains another
    /// session. Either way the new session is appended to its project and activated.
    ///
    /// - Parameter selecting: whether the new session may become the Mac's selection.
    ///   Defaults to true, unaffected for every desk caller here (⌘⇧A, a folder drop,
    ///   `createFromMenu`'s fallbacks). `openConversation`'s project-row branch passes its own
    ///   `selecting` through when it lands here for a project new to the sidebar — without
    ///   this, that branch would only be half-gated: the existing-repo side already honours
    ///   `selecting`, but this side would still select unconditionally through `newSession`'s
    ///   own default. See `select(_:selecting:)`.
    @discardableResult
    func addProject(at url: URL, selecting: Bool = true) -> Session {
        newSession(in: url, selecting: selecting)
    }

    /// The ⌘N / sidebar-button action. Routes to Add Project when nothing is open, which is
    /// why the menu item can stay enabled in both states.
    @discardableResult
    func createFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        switch SessionCreateAction.forState(hasProjects: !repos.isEmpty) {
        case .newSession:
            if let created = newSessionBelowActive() {
                return created
            }
            // `newSessionBelowActive` needs a selection, not just a non-empty `repos` — and
            // selection can be nil with sessions still present (e.g. clicking below the last
            // row in the sidebar's List clears it). Prefer the project the user was last
            // working in, *including* when it is now empty; only fall back to an arbitrary
            // project if we have never had one, and only prompt when nothing is open.
            if let url = lastActiveProjectURL, indexOfRepo(for: url) != nil {
                return addProject(at: url)
            }
            if let first = repos.first {
                return addProject(at: first.url)
            }
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        case .addProject:
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        }
    }

    /// The per-agent ⌘N action Task 12's per-slot menu items and the sidebar button both
    /// call. Mirrors `createFromMenu()`'s routing (the active session's project, else the
    /// last active project, else the first, else a chosen folder) but goes through the async
    /// `createSession(agent:in:)` rather than the synchronous claude-only `newSession`,
    /// because that is the only path able to start codex. Kept separate from the plain
    /// `createFromMenu()` above rather than folding an `agent` parameter into it, so every
    /// existing claude-only call site — and the regression suite pinning it — is untouched.
    ///
    /// `account`, when given, is the New Session dropdown's chosen login (Task 14) rather than
    /// this project's resolved default — threaded straight through to `create`/`createSession`,
    /// which is where it actually overrides `launchAccount`'s resolution.
    @discardableResult
    func createFromMenu(
        agent: AgentID, chooseFolder: () -> URL? = { FolderPicker.choose() }, account: UUID? = nil
    ) async -> Session? {
        switch SessionCreateAction.forState(hasProjects: !repos.isEmpty) {
        case .newSession:
            if let activeID = selectedSessionID, let at = locate(activeID) {
                let active = repos[at.repo].sessions[at.session]
                return await create(agent, in: active.workingDirectory, at: at.session + 1, account: account)
            }
            if let url = lastActiveProjectURL, indexOfRepo(for: url) != nil {
                return await create(agent, in: url.path, account: account)
            }
            if let first = repos.first {
                return await create(agent, in: first.url.path, account: account)
            }
            guard let url = chooseFolder() else { return nil }
            return await create(agent, in: url.path, account: account)
        case .addProject:
            guard let url = chooseFolder() else { return nil }
            return await create(agent, in: url.path, account: account)
        }
    }

    /// `createSession`'s `Result` collapsed to the `Session?` shape the menu/button want —
    /// a failure already reported itself through `launchFailureReporter` inside
    /// `createSession`, so there is nothing left for the caller to do with it but stop.
    private func create(
        _ agent: AgentID, in path: String, at index: Int? = nil, account: UUID? = nil
    ) async -> Session? {
        guard case .success(let id) = await createSession(agent: agent, in: path, at: index, account: account)
        else { return nil }
        return session(for: id)
    }

    /// ⌘⇧A. Always prompts, regardless of what is open.
    @discardableResult
    func addProjectFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        guard let url = chooseFolder() else { return nil }
        return addProject(at: url)
    }

    /// Folder drop. Each URL becomes a project with one session; the last is activated.
    /// A file resolves to its containing folder, so dropping a file out of a repo adds
    /// that repo — see `SessionCreateAction.projectDirectory(for:)`.
    @discardableResult
    func acceptDroppedURLs(_ urls: [URL]) -> Session? {
        var last: Session?
        for url in urls {
            last = addProject(at: SessionCreateAction.projectDirectory(for: url))
        }
        return last
    }

    /// Shared by `newSession` and `restore`. `initialInput` is the only difference:
    /// a fresh session starts `claude`, a restored one resumes it.
    ///
    /// `url` decides only which project the tab is filed under. Both the shell's cwd and the
    /// watcher come from `session.transcriptDirectory`, and deliberately from the same field:
    /// `ClaudeSession.resumeCommand` runs `claude --resume <id>` in the shell's cwd and
    /// `claude` derives the transcript path from that same cwd, so the two disagreeing means
    /// watching a file the process it just started will never write. They differ from `url`
    /// for one caller — `restore`, rebuilding a tab that was last writing somewhere other
    /// than its project, a worktree being the usual reason — where
    /// starting the shell at the project would make `--resume` find no conversation and fall
    /// through to its `|| claude --session-id <id>` branch, losing the history.
    @discardableResult
    private func insertSession(
        _ session: Session, in url: URL, initialInput: String, at index: Int? = nil
    ) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
            // Emitted here, before the session goes in, so a client never receives a
            // `sessionAdded` naming a project it has not been told about.
            emit(.projectAdded(
                FleetProjection.project(
                    repos[repoIndex], statuses: statuses, unread: unreadIdle,
                    backgroundWork: backgroundWorkSessions,
                    openPromptCalls: openPromptCalls, planGates: planGates
                ),
                at: repoIndex
            ))
        }
        // `index` is a position within this repo's sessions; out-of-range falls back to
        // appending so a stale index can never trap.
        let insertedAt: Int
        if let index, index >= 0, index <= repos[repoIndex].sessions.count {
            repos[repoIndex].sessions.insert(session, at: index)
            insertedAt = index
        } else {
            repos[repoIndex].sessions.append(session)
            insertedAt = repos[repoIndex].sessions.count - 1
        }
        emit(.sessionAdded(wire(session), project: repos[repoIndex].id, at: insertedAt))

        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = session.transcriptDirectory
        // `nil` when unset: `withCValue` already maps that to `0`, meaning "inherit
        // libghostty's configured default" — the same thing a never-touched size means.
        config.fontSize = preferences?.preferences.terminalFontSize
        config.initialInput = initialInput
        // The account is what actually makes this tab run as its login: the shell libghostty
        // forks below inherits these, and the agent reads its home out of one of them. Every
        // creation path and `restore` funnel through here, so a restored tab is relaunched as
        // the account it was created with rather than as today's default.
        //
        // A tab whose login has been deleted gets no variable at all, rather than the
        // built-in home `account(for:)` would otherwise collapse its dangling id to. Nothing
        // is typed into it either (`restore` passes an empty `initialInput`), so this shell
        // starts no agent — and a surface configuration can only *set* a variable, never
        // unset one, so "no variable" is the strongest refusal available here.
        let orphaned = accountIsMissing(for: session)
        config.environmentVariables =
            preferences?.sessionEnvironment(for: orphaned ? nil : account(for: session)) ?? [:]
        // Wrapped so the registry can identify the shell libghostty forks for this surface;
        // libghostty exposes no pid of its own. The identification finishes asynchronously,
        // after `makeSurface` returns — see `SurfaceProcessRegistry`.
        let created = processRegistry.record(for: session.id) { provider?.makeSurface(config) }
        if let surface = created {
            surfaces[session.id] = surface
        }
        // Before `tick()`, and before anything can be typed at the shell: `ghostty_surface_new`
        // has already forked the child, and until this lands it is talking to libghostty's
        // placeholder 800x600 *pixel* grid — about 50 columns on a 2x display. Anything the
        // child prints in that window is hard-wrapped there for good, because reflow can only
        // rejoin rows the terminal soft-wrapped, not rows the program broke itself.
        //
        // That reasoning covers the case where a surface was actually created. The call is left
        // outside the `if let surface` above anyway: when `makeSurface` returns nil — no provider
        // at all, or a creation that failed — there is no forked child to protect, and `report`
        // finds no surface for this id and does nothing. Keeping it unconditional costs a
        // dictionary lookup and keeps `report(_:to:)` the single place a size leaves this class,
        // which is also what lets `sizeReporterOverride` observe creation-time sizing in tests,
        // where every surface is nil.
        report(terminalSize, to: session.id)
        provider?.tick()

        // Not for an orphaned tab: observation has to agree with the launch, and this one was
        // not launched. Watching would attach it to the built-in account's registry and
        // transcripts — the very substitution refused two dozen lines up — and report a status
        // glyph and a title for a shell running nothing.
        if !orphaned { startWatching(tabID: session.id) }
        return session
    }

    /// Rebuilds sessions from the last run. Returns false when there was nothing to
    /// restore, which is the caller's signal to seed a first session instead.
    /// Sessions whose working directory has since disappeared are dropped rather
    /// than resurrected as broken terminals.
    ///
    /// That drop is harsher for a project than for a session: a session with a missing
    /// directory is just not rebuilt, but an *empty* project (nothing left in it but its own
    /// record in `SessionSnapshot.projects`) whose directory is missing is skipped entirely in
    /// pass one below, and the `persist()` at the end of this method then writes a snapshot
    /// that no longer mentions it. A project on an unmounted external or network volume is
    /// therefore not merely hidden until the volume returns — it is permanently forgotten by a
    /// single launch that happens to occur while the volume is offline. This matches the
    /// long-standing behavior for sessions and is not being changed here; a future fix would
    /// need to distinguish "genuinely deleted" from "temporarily unreachable" before pruning an
    /// empty project.
    ///
    /// Kept internal rather than `private`: `SessionPersistenceTests` calls it directly
    /// to exercise restore in isolation, and `@testable import` only lifts `internal`
    /// access — a `private` method stays invisible even to `@testable` callers outside
    /// this file. Idempotency is guarded instead, on `repos.isEmpty`: a second call
    /// (there is no production path that makes one, but nothing stops a test or a
    /// future caller from trying) would otherwise re-insert every restored session on
    /// top of the ones already there.
    @discardableResult
    func restore(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard repos.isEmpty else { return false }
        guard let snapshot = persistence?.load() else { return false }

        // Above the emptiness guard on purpose. That guard returns early when the last run ended
        // with every session closed, and `SessionStore.init` answers a false return by calling
        // `seedInitialSession()` — which creates a surface that needs this size just as much as a
        // restored one does.
        if let size = snapshot.terminalSize,
           Self.plausibleTerminalDimension.contains(size.width),
           Self.plausibleTerminalDimension.contains(size.height) {
            terminalSize = CGSize(width: size.width, height: size.height)
        }

        // Projects outlive their sessions, so a snapshot can legitimately carry projects and
        // no sessions — the state you get after closing every session but no project. The
        // old "no sessions means nothing to restore" guard would have discarded it.
        let recorded = snapshot.projects ?? []
        guard !snapshot.sessions.isEmpty || !recorded.isEmpty else { return false }

        sessionCounter = snapshot.sessionCounter

        // One deadline for the whole restore, not one per session: they all resume together,
        // and staggering them by loop position would be noise.
        let autoResume = preferences?.autoResumesRunningSessions ?? false
        let promptDeadline = now().addingTimeInterval(Self.resumePromptWindow)

        // Pass one: seed the projects, in the recorded order, so the sessions below land in
        // existing repos rather than conjuring them in encounter order.
        for project in recorded where directoryExists(project.path) {
            let url = URL(fileURLWithPath: project.path, isDirectory: true)
            guard indexOfRepo(for: url) == nil else { continue }
            repos.append(Repo(url: url, isCollapsed: project.isCollapsed))
        }

        // Codex tabs whose resume command has not been typed yet. Collected rather than
        // handled in the loop because settling each one is `async` and this is not.
        var deferredCodexResumes: [UUID] = []

        // The agents that lost at least one tab to a deleted login. Collected rather than
        // reported in the loop so a login that took six tabs with it raises one alert.
        var orphanedAgents: Set<AgentID> = []

        // Pass two: file the sessions. `insertSession` appends a repo for any working
        // directory pass one did not cover, which is what keeps a v1 snapshot working.
        for entry in snapshot.sessions where directoryExists(entry.workingDirectory) {
            let url = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
            let conversationID = entry.pinnedConversationID ?? entry.id
            // Absent means the snapshot predates the split, when the one field meant both.
            let recorded = entry.transcriptDirectory ?? entry.workingDirectory
            // A worktree deleted between runs takes the tab's transcript directory with it.
            // The resumed `claude` is started in the project instead (see `insertSession`)
            // and will write its transcript there, so the tab has to be rebuilt as a
            // project-directory session outright — leaving the dead path in place would
            // start the watcher on a transcript nobody writes, persist it back out, and
            // leave the tab without titles or sub-agent counts until the first registry
            // tick happened to retarget it.
            let transcriptDirectory = directoryExists(recorded) ? recorded : entry.workingDirectory
            let session = Session(
                id: entry.id,
                title: entry.title,
                workingDirectory: entry.workingDirectory,
                transcriptDirectory: transcriptDirectory,
                pinnedConversationID: conversationID,
                agent: entry.agent ?? .claude,
                accountID: entry.accountID,
                transcriptPath: entry.transcriptPath
            )
            // A tab whose login has been deleted since the last run. Rebuilt, but never
            // resumed — see `accountIsMissing`. The tab still appears, because a tab that
            // vanishes at relaunch is its own bug: the user has to be able to see which tabs
            // this affected, read their titles, and close them. What it does not get is a
            // resume command typed into its shell, an account variable naming somebody else's
            // home, a watcher, or an auto-resume prompt — `insertSession` asks the same
            // question for the last two, so every one of those refusals is made from one
            // predicate rather than from a flag passed around.
            let orphaned = accountIsMissing(for: session)
            if orphaned { orphanedAgents.insert(session.agent) }
            // Codex's resume text is deferred, and only codex's. `binding(for:)` is a pure
            // read of the pin — codex's own doc calls its contract "identity already
            // settled" — so it cannot tell a thread that still exists from one the user
            // deleted or archived between launches, and typing `codex resume <gone>` here
            // would open the tab onto an error instead of a session. `resumeRestoredCodex`
            // settles that against the app-server and types the command afterwards. Claude
            // needs none of it: its resume command carries `--resume || --session-id`.
            //
            // An orphaned codex tab is left out of that list rather than deferred into it:
            // settling it would spawn an app-server for a login that no longer exists.
            let deferred = session.agent.negotiatesIdentity
            if deferred, !orphaned { deferredCodexResumes.append(session.id) }
            let initialInput: String
            if orphaned || deferred {
                initialInput = ""
            } else {
                // Built here rather than above the branch so an orphaned tab does not
                // memoize an adapter — and a status watcher behind it — for the built-in
                // account its stored id wrongly collapses to.
                let adapter = adapter(for: instance(for: session))
                initialInput = adapter.resumeCommand(
                    // The binding carries the pinned conversation, not the tab's own id — a
                    // tab that resumed an existing conversation must keep following that one
                    // across relaunches.
                    adapter.binding(for: session),
                    session,
                    // Resolved per entry, from that entry's own *project* directory rather
                    // than from wherever `claude` was writing, so a restored session picks
                    // up its project's overrides rather than the first repo's — and a
                    // session restored inside a worktree still gets its project's, which
                    // resolving from the transcript directory would silently lose.
                    options(for: session.agent, project: entry.workingDirectory)
                )
            }
            insertSession(session, in: url, initialInput: initialInput)
            // Seeded here rather than after the loop so it covers exactly the sessions that
            // were actually rebuilt — a session whose directory has gone has no row to draw a
            // mark on. Before the `selectedSessionID` assignment below on purpose: its
            // `didSet` clears the mark for the tab you land on, which is correct.
            if entry.unread == true { setUnread(entry.id, true) }

            // Migrates the pre-decomposition `"shell"` string, and prefers the explicit new
            // field when the file has one — see `restoredActivity` and `isResumable`.
            let restored = Self.restoredActivity(fromPersisted: entry.activity)
            let hasBackgroundWork = entry.hasBackgroundWork ?? restored.hasBackgroundWork
            // Seeded here rather than waiting for the next registry tick, so the sidebar
            // badge survives a relaunch — but NOT for `setUnread`'s reason just above. This
            // insert emits nothing and self-corrects nothing; it is safe only because
            // `emit()` early-returns while `replicator == nil`, and `FleetService` attaches
            // the replicator after `SessionStore.init` — and therefore after this whole
            // `restore()` — has already run. Moving this insert to run after that wiring
            // would need it to emit like `setUnread` does.
            if hasBackgroundWork { backgroundWorkSessions.insert(entry.id) }

            // `!orphaned`: offering to continue a tab that cannot be launched at all would
            // put the wrong-login resume one click behind a prompt the app raised itself.
            //
            // `textChannel`: this queue ends at `inject`, which types into a live TUI, so a
            // tab whose terminal this build cannot read must never get an entry in it. That is
            // the same failure `rename` records as the near-miss which justifies the codex
            // caution everywhere else — text queued against a pty, retried every registry
            // tick, waiting to match something and paste itself into a live session — and this
            // path simply predates the caution. It is reachable, not theoretical: codex emits
            // `.busy` on `task_started` and `.idle` on `task_complete`, and the 120-second
            // window is driven by the claude registry tick.
            //
            // After `!orphaned` on purpose: the ordering costs an orphaned codex tab nothing,
            // and it keeps this gate from being the thing that first asks about an agent.
            if autoResume, !orphaned, session.agent.textChannel != nil,
               let activity = restored.activity,
               Self.isResumable(activity: activity, hasBackgroundWork: hasBackgroundWork) {
                pendingPrompts[entry.id] = DeferredPrompt(
                    text: Self.resumePrompt, deadline: promptDeadline
                )
            }
        }

        // One alert per agent, not per tab: a deleted login usually takes several tabs with
        // it, and five identical sheets is not five times the information. Ordered by
        // `allCases` so two agents produce the same two alerts in the same order every run.
        for agent in AgentID.allCases where orphanedAgents.contains(agent) {
            launchFailureReporter.report(.accountMissing(agent.displayName))
        }

        let restoredIDs = repos.flatMap(\.sessions).map(\.id)
        selectedSessionID = snapshot.selectedSessionID.flatMap {
            restoredIDs.contains($0) ? $0 : nil
        } ?? restoredIDs.first
        persist()
        // Started only when a codex tab actually came back, which is what keeps the app-server
        // lazy: a user who restores nothing but claude tabs must never have `codex` spawned
        // behind their back at launch. See `resumeRestoredCodex`.
        if !deferredCodexResumes.isEmpty {
            codexRestoreTask = Task { [weak self] in
                await self?.resumeRestoredCodex(deferredCodexResumes)
            }
        }
        // Projects count as "restored something": `SessionStore.init` reads this as
        // `if resetState || !restore() { seedInitialSession() }`, and seeding a home-directory
        // session on top of a restored project list would be wrong. (`seedInitialSession`
        // guards on `repos.isEmpty` too, so this is belt and braces — but the return value is
        // also read by tests, and it should mean what it says.)
        // The fleet was replaced, not changed. There is no event sequence that describes
        // that, and emitting one per restored row would be a lie about what happened — so
        // the replicator re-reads and anyone behind is sent back for a snapshot.
        replicator?.reset()
        return !restoredIDs.isEmpty || !repos.isEmpty
    }

    /// Settles every restored codex tab against the app-server, then types its resume
    /// command. The asynchronous tail of `restore`.
    ///
    /// Three things happen here that a restored claude tab needs none of:
    ///
    /// - **The app-server is started.** A restored codex tab used to get a `CodexRuntime`
    ///   attached to a transport nobody had ever started: it reported no activity and never
    ///   marked unread until the user happened to create a *new* codex tab, which started the
    ///   memoized stack and incidentally revived it. `preparedAdapter` is what starts it, and
    ///   this method only runs when a codex tab came back, so the laziness holds.
    /// - **Identity is settled** with `rebind` rather than read off the pin, and the tab is
    ///   re-pinned when codex answers with a different thread. See `CodexAdapter.rebind`.
    /// - **The resume command is typed afterwards**, which is why `restore` left
    ///   `initialInput` empty for these tabs.
    ///
    /// Degrades to the pinned thread whenever it cannot ask — no app-server, or one that will
    /// not answer. Not knowing whether a thread is gone is not the same as knowing it is, and
    /// the command this types then is exactly the one restore used to type unconditionally.
    private func resumeRestoredCodex(_ tabIDs: [UUID]) async {
        // One prepare per account, not per tab. `startCodex` already memoizes the handshake,
        // so a second ask would not spawn a second app-server — but it would count as a
        // second ask (see `codexServerRequestsForTesting`) and re-await a settled task for
        // every restored tab. Restoring two accounts' tabs starts two servers, neither
        // waiting on the other's `initialize`.
        var preparedPerAccount: [AgentInstance: (any AgentAdapter)?] = [:]

        for tabID in tabIDs {
            // A tab the user closed while the app-server was starting has nothing to resume,
            // and re-pinning it would file state against a row that no longer exists.
            guard let session = session(for: tabID) else { continue }
            let instance = instance(for: session)
            let prepared: (any AgentAdapter)?
            if let already = preparedPerAccount[instance] {
                prepared = already
            } else {
                prepared = try? await preparedAdapter(for: instance)
                preparedPerAccount[instance] = prepared
            }
            let adapter = prepared ?? self.adapter(for: instance)
            let options = options(for: .codex, project: session.workingDirectory)

            // A failed probe or handshake tore the stack down — `startCodex` calls
            // `stopCodex` so the next attempt re-probes rather than replaying the failure —
            // and that orphaned the attachment `insertSession` made: it names a `CodexRuntime`
            // belonging to a stack the store has already forgotten, so `runtime(for:)` now
            // answers from a *new* one and this tab's events would arrive at an object nobody
            // is listening to. Re-attaching is the same fix requirement 3 exists for, on the
            // path where codex is missing or broken and the tab most needs to behave sanely.
            if prepared == nil {
                stopWatching(tabID)
                startWatching(tabID: tabID)
            }

            var binding = adapter.binding(for: session)
            if prepared != nil,
               let settled = try? await adapter.rebind(for: session, options: options) {
                binding = settled
            }
            if binding.conversationID != session.pinnedConversationID {
                repinRestoredCodex(tabID, to: binding)
            }
            // Re-read: the re-pin above rewrote the row, and the command names the session.
            guard let repinned = self.session(for: tabID) else { continue }

            // Both watchers start at end-of-file (§2.5, §4), so a rename made while Flight
            // Deck was closed is invisible to them. This read is the only thing that can
            // still recover it. Only when an app-server was actually prepared — on the
            // degraded path there is nothing to ask — and title only: `thread/read` reports
            // `notLoaded` for a thread a TUI drives, so its activity is meaningless here, and
            // applying it would flick the tab's status off nothing. Non-fatal: a restore that
            // cannot reach the app-server must still produce a usable tab.
            if prepared != nil, let codexAdapter = adapter as? CodexAdapter,
               let read = try? await codexAdapter.read(binding), let title = read.title {
                apply(.title(title), to: tabID)
            }

            sendToShell(adapter.resumeCommand(binding, repinned, options), into: tabID)
        }
    }

    /// The restored tab's thread was gone and codex started it a new one.
    ///
    /// Deliberately not `repin`: that one is claude's in-session `/resume`, and every step it
    /// takes past the pin describes an agent this is not — a transcript *directory* codex
    /// does not derive paths from, a sub-agent count no registry feeds, a title read out of a
    /// transcript file that has just been created empty. What has to happen here is narrower:
    /// follow the new thread, keep the rollout path codex reported for it, and repoint the
    /// runtime, because the attachment `insertSession` made names the dead thread and no
    /// notification will ever arrive on it.
    private func repinRestoredCodex(_ tabID: UUID, to binding: AgentBinding) {
        guard let at = locate(tabID) else { return }
        repos[at.repo].sessions[at.session].pinnedConversationID = binding.conversationID
        repos[at.repo].sessions[at.session].transcriptPath = binding.transcriptURL?.path
        stopWatching(tabID)
        startWatching(tabID: tabID)
        persist()
    }

    /// Types a command at a tab's *shell*, the way `initialInput` would have — just later.
    ///
    /// `inject` is the wrong tool and is deliberately not reused: every gate it applies
    /// (an idle status, a readable one-row `InputBar`, the kill-and-yank draft dance)
    /// describes Claude Code's TUI, and none of it exists at the bare shell prompt a restored
    /// tab is sitting at. The text/Return split is kept, though, and for the reason
    /// `TextInjecting.sendReturn()` gives: `sendText` is a paste, and a newline inside a
    /// bracketed paste is inserted rather than submitted.
    private func sendToShell(_ command: String, into tabID: UUID) {
        guard let injector = injector(for: tabID) else { return }
        injector.sendText(command.trimmingCharacters(in: .newlines))
        injector.sendReturn()
    }

    /// Saved on every mutation rather than at terminate, so a crash cannot lose the list.
    private func persist() {
        // `var`, because the process table and owner stamp below are assigned after
        // construction. `projects` carries the sidebar order and collapse state, which the
        // session list alone cannot express.
        var snapshot = SessionSnapshot(
            sessions: repos.flatMap(\.sessions).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    // Written on every entry, not just the diverging ones: absence is
                    // reserved for pre-split snapshots, and a file that names each tab's
                    // transcript directory outright shows which sessions are running
                    // somewhere other than the project they are filed under — the state this
                    // whole split exists for.
                    transcriptDirectory: $0.transcriptDirectory,
                    pinnedConversationID: $0.pinnedConversationID,
                    // `nil` rather than a sentinel when no `claude` is registered: restore
                    // has to distinguish "was not running" from "was running and idle".
                    activity: statuses[$0.id]?.activity.rawValue,
                    // `nil` rather than `false` so the common case adds no noise, matching
                    // `unread` directly below.
                    hasBackgroundWork: backgroundWorkSessions.contains($0.id) ? true : nil,
                    // `nil` rather than `false` so the common case adds no noise to a file
                    // that is meant to stay readable.
                    unread: unreadIdle.contains($0.id) ? true : nil,
                    agent: $0.agent,
                    accountID: $0.accountID,
                    transcriptPath: $0.transcriptPath
                )
            },
            projects: repos.map { .init(path: $0.url.path, isCollapsed: $0.isCollapsed) },
            selectedSessionID: selectedSessionID,
            sessionCounter: sessionCounter,
            // Written on every save rather than only when it changes: it is one small object, and
            // the alternative is tracking dirtiness for a value whose whole job is to be present at
            // the next launch.
            terminalSize: .init(width: terminalSize.width, height: terminalSize.height)
        )
        let processes = Dictionary(
            uniqueKeysWithValues: processRegistry.all.map { ($0.key.uuidString, $0.value) }
        )
        // `nil` rather than `{}` when there is nothing recorded. Equivalent in effect —
        // `sweepOrphans` returns early on either — and this file is meant to stay readable by
        // a human, which an empty object in every snapshot works against.
        snapshot.processes = processes.isEmpty ? nil : processes
        // Stamped on every save so the next launch can tell "this run is still going" from
        // "this run died and left its children behind".
        snapshot.owner = Self.selfIdentity
        persistence?.save(snapshot)
    }

    /// No `persist()` call here: assigning `selectedSessionID` runs its `didSet`, which
    /// persists. Swift fires `didSet` on every assignment rather than only on a change, so
    /// this is covered even when re-selecting the already-selected tab. The explicit call
    /// that used to follow made every tab switch encode the snapshot twice and perform two
    /// synchronous atomic write-and-rename cycles on the main thread.
    func selectSession(_ id: UUID) {
        guard locate(id) != nil else { return }
        selectedSessionID = id
    }

    /// ⌘⇧] — moves the selection one session down the sidebar's visual order, wrapping to the
    /// top. ⌘⇧[ is the mirror image.
    func selectNextSession() { cycleSelection(forward: true) }

    /// ⌘⇧[. See `selectNextSession()`.
    func selectPreviousSession() { cycleSelection(forward: false) }

    /// Context-menu "Mark as Unread". `unreadIdle` is `private(set)`, so this is the sidebar's
    /// only way in.
    ///
    /// Deliberately does not special-case the *currently selected* session: `selectedSessionID`
    /// already removes an id from `unreadIdle` in its `didSet`, but only when that property is
    /// next assigned. Marking the active tab unread inserts it right back, and the dot
    /// typically stays up — even though the user is looking at that tab right now — until
    /// they navigate away and return, which reassigns `selectedSessionID` and clears it. That
    /// is not the *only* way it clears, though: `applyReadState` can also clear it sooner, if
    /// this session's status edges from working back to idle while it is still selected and
    /// the app is active — `SessionReadPolicy.change` returns `.clear` rather than `.mark` for
    /// exactly that edge when `isViewed` is true, because a running `claude` reporting it
    /// finished counts as the user having seen it too. Either way, marking here without a
    /// guard is intentional and matches Mail, where marking the open message unread sticks
    /// until something counts as having read it again; do not "fix" it by adding a guard here.
    ///
    /// Persists immediately, same as `rename(_:to:)`: unread marks are meant to survive a
    /// relaunch (see `unreadIdle`'s doc comment), so there is no "mark now, save later" here.
    func markUnread(_ id: UUID) {
        setUnread(id, true)
        persist()
    }

    /// The counterpart to `markUnread`, and the store method the phone's `markRead` command
    /// lands on.
    ///
    /// Added here rather than special-cased in the replicator on purpose: anything the phone
    /// can do, the Mac's own UI should be able to do, and a command with no store method
    /// behind it is a feature that exists on one device only. Writes through `setUnread`, so
    /// `unreadIdle` keeps its single writer.
    func markRead(_ id: UUID) {
        setUnread(id, false)
        persist()
    }

    /// The order is `repos.flatMap(\.sessions)` — the sidebar top to bottom, crossing project
    /// sections. Flattening is not a convenience: both `closeSession` and `moveSession`
    /// deliberately leave an emptied project standing rather than pruning it, so the first repo
    /// can hold no sessions while live tabs sit in a later section, and anything reading through
    /// `repos.first` would walk off the live list.
    ///
    /// No-ops on an empty list, and a lone session wraps to itself. A `selectedSessionID` that
    /// names no live session is treated as no selection at all, which lands on the first
    /// session going forward and the last going backward — the same place a nil selection goes.
    ///
    /// Assigning `selectedSessionID` is the whole effect: its `didSet` persists the change and
    /// updates `lastActiveProjectURL`, so ⌘N after a tab switch already targets the newly
    /// active session's project.
    private func cycleSelection(forward: Bool) {
        let ordered = repos.flatMap(\.sessions)
        guard !ordered.isEmpty else { return }

        guard
            let current = selectedSessionID,
            let index = ordered.firstIndex(where: { $0.id == current })
        else {
            selectedSessionID = forward ? ordered.first?.id : ordered.last?.id
            return
        }

        let destination = forward
            ? ordered.indexWrapping(after: index)
            : ordered.indexWrapping(before: index)
        selectedSessionID = ordered[destination].id
    }

    /// - Parameter recordingHistory: whether this close is offered to ⌘⇧T. Only
    ///   `closeProject` passes false, because it records one grouped entry of its own rather
    ///   than one per child — see `closeProject`.
    func closeSession(_ id: UUID, recordingHistory: Bool = true) {
        guard let (repoIndex, sessionIndex) = locate(id) else { return }
        // Read before the removal below: codex teardown is per account, and once the row is
        // gone there is nothing left to ask which account this tab was running as.
        let closed = instance(for: repos[repoIndex].sessions[sessionIndex])
        // Recorded before the removal, for the same reason and from the same row. The whole
        // `Session` value goes in, not a copy of its fields: reopening reuses its `id` and
        // `pinnedConversationID`, which is what makes the rebuilt tab resume this
        // conversation rather than start a new one.
        if recordingHistory {
            closedSessions.record(.session(ClosedSessionHistory.ClosedSession(
                session: repos[repoIndex].sessions[sessionIndex],
                projectPath: repos[repoIndex].url.path,
                indexInProject: sessionIndex
            )))
        }
        repos[repoIndex].sessions.remove(at: sessionIndex)
        emit(.sessionRemoved(id: id))

        // Detach and park rather than release. Two reasons this is not just `= nil`:
        //
        // 1. `closeSession` never removed the view from its superview, so a *selected*
        //    tab's surface stayed retained by `TerminalHostView` until SwiftUI's next
        //    `updateNSView` pass (`TerminalPane.swift:40-42`). Detaching here makes the
        //    close immediate and independent of that pass.
        // 2. Releasing the view runs `ghostty_surface_free` on the main actor, which joins
        //    the IO thread and spins in libghostty's SIGHUP-only `killpg` loop
        //    (`vendor/ghostty/src/termio/Exec.zig:1152-1185`). We hold the view until our
        //    own reap has killed the tree, so that loop finds a dead child and returns.
        if let surface = surfaces.removeValue(forKey: id) {
            surface.removeFromSuperview()
            parkedSurfaces[id] = surface
        }
        // Read, don't remove: the record has to survive until `reapSession` below has
        // actually confirmed the process is gone. See `reapSession`'s doc comment for why
        // forgetting it here — before the reap has even started — is the bug.
        let doomed = processRegistry.process(for: id)

        stopWatching(id)
        // After `stopWatching`, which still needs the runtime this may drop. Only the closed
        // tab's own account is considered: no other account's tab count changed here. A
        // claude tab's account keys no codex stack, so this is a no-op for it — except in a
        // store with no accounts configured at all, where the one nil key serves everything
        // and closing any tab runs exactly the check it always did.
        stopCodexIfUnused(account: closed.account)
        // The claude half of the same rule: an account whose last claude tab just closed has
        // no reason to keep scanning its registry, and a watcher left registered on the
        // `WatchClock` outlives every tab that justified it.
        stopStatusWatchingIfUnused(account: closed.account)
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
        // A queued prompt for a tab that no longer exists is the most literal case of "text
        // that will never be typed", and its tokens go with it: `acceptedPromptTokens` is
        // keyed by tab, so a reopened tab reusing this id starts with a clean dedupe window
        // rather than inheriting one from a session that is over.
        promptQueue.removeValue(forKey: id)
        acceptedPromptTokens.removeValue(forKey: id)
        answeredPromptTokens.removeValue(forKey: id)
        anchors.removeValue(forKey: id)
        // `applyReadState` no longer clears a mark when a session's status disappears — a
        // mark now outlives its process. But closing a tab removes its id from `repos`
        // entirely, so no future tick will ever see it again; leaving the mark in
        // `unreadIdle` here would leak it forever rather than merely have it persist.
        // Runs after `emit(.sessionRemoved(id:))` above, so a session that was unread emits
        // a real `.unreadChanged` for an id the mirror has already dropped. That is not
        // drift: `.unreadChanged` for an unknown id is a no-op by contract on the receiving
        // side, and the store's own projection has no such session either — both sides
        // agree once the batch settles.
        setUnread(id, false)
        // Closing the row is the most literal case of "a prompt that will never resolve",
        // and applyRegistry cannot observe the waiting -> gone edge here because both its
        // before and after snapshots already lack this id.
        notifier?.withdraw(sessionID: id)
        // The project deliberately stays, even emptied. A project's lifetime is explicit:
        // it appears when added or when a session lands in it, and is removed only by
        // `closeProject` — the sidebar's project close button. That also settles a
        // long-standing disagreement with `moveSession`, which has always left an emptied
        // source project standing.
        if selectedSessionID == id {
            // The first *session*, not the first repo's first session: this method just above
            // may have emptied `repos[repoIndex]` without removing it, and `moveSession` leaves
            // an emptied source project standing the same way — so `repos.first` can be empty
            // while live tabs sit in a later section. Reading through it would clear the
            // selection and drop the whole app to the "No Session" empty state.
            selectedSessionID = repos.flatMap(\.sessions).first?.id
        }
        persist()

        Task { [weak self] in
            await self?.reapSession(id, process: doomed, context: "tab close")
        }
    }

    /// Kill a tab's process tree, then release its parked surface. Shared by tab close and
    /// app quit, which differ only in their budget and in who waits for them.
    ///
    /// `processRegistry.forget` and the `persist()` that makes it stick happen here, only
    /// after the reap has run — never synchronously inside `closeSession`. `closeSession`
    /// used to forget the record immediately, which opened a window (up to the reap's own
    /// budget, worst case ~10 s) during which the doomed process existed in *no* record at
    /// all: gone from `processRegistry.all`, so `reapAllForQuit` would skip it, and already
    /// absent from the snapshot `closeSession`'s own `persist()` had just written, so the next
    /// launch's orphan sweep could not find it either. A quit or crash inside that window
    /// leaked the process permanently and invisibly — forgetting has to happen *after* the
    /// window closes, not before it opens.
    ///
    /// A consequence worth naming rather than hiding: quit and a tab's own close reap can now
    /// race the same session concurrently (quit sees the record because close hasn't forgotten
    /// it yet). That redundancy is benign, not invariant-violating — `SessionReaper.reap`'s
    /// `isAlive` gate makes a second reap of an already-dead target return `.clean` without
    /// signalling anything, and a second `forget`/`parkedSurfaces.removeValue` is a plain
    /// no-op. But the two ladders are genuinely independent: the actor serializes the calls,
    /// it does not deduplicate targets, so a session still alive when both race *can* receive
    /// the same signal twice from two separate `deliver` calls. That is fine because POSIX
    /// signals are idempotent, not because it cannot happen.
    ///
    /// The group to signal is re-derived here, from the live process table, exactly as
    /// `sweepOrphans` does — it is never carried on the record. Reading a pgid at record time
    /// races the child's own `setsid()`, and a read that wins that race captures Flight Deck's
    /// *own* process group and pins it to the session for the rest of its life: the self-group
    /// rail then downgrades every one of that session's signals to per-pid, silently, forever.
    /// A live process that has just passed the identity gate is the authority on its own group;
    /// nothing else is. That is why `SessionProcess` no longer carries a `pgid` at all.
    ///
    /// `forget` only fires on a confirmed-clean outcome. A budget expiry or an unkillable
    /// process reports `.survivors` — see this method's `if handled` below — and the
    /// record must stay exactly where it is, because "clean" here is the *only* signal this
    /// method has that the process is actually gone. Forgetting on `.survivors` would erase a
    /// still-live process from the one place (`processRegistry`, and therefore the persisted
    /// snapshot) that gives the next launch's orphan sweep a chance at it — reopening the same
    /// hole this method's window-closing fix above was written to close. `persist()` always
    /// runs regardless, because the snapshot must reflect whichever registry state is current
    /// — including "still recorded, because still alive" — not just the forgetting case.
    func reapSession(_ id: UUID, process: SessionProcess?, context: String) async {
        var handled = true
        if let process {
            let livePgid = processInspector.pgid(of: process.identity.pid)
            let outcome = await reaper.reap(shell: process.identity, pgid: livePgid)
            reapReporter?.report(outcome, context: context)
            handled = (outcome == .clean)
        }
        if handled { processRegistry.forget(id) }
        persist()
        // Releasing last: the deferred `ghostty_surface_free` this triggers now has nothing
        // left to wait for.
        parkedSurfaces.removeValue(forKey: id)
    }

    /// Terminate processes recorded by a previous run that outlived it.
    ///
    /// Gated twice over: the recording instance must be gone (otherwise these are somebody
    /// else's live children, and killing them would be a second Flight Deck instance
    /// sabotaging the first), and each identity's start time must still match (otherwise the
    /// pid has been recycled and now belongs to an unrelated process).
    ///
    /// The pgid used to signal is re-derived from the live process table. A number carried on
    /// the record would be evidence about some previous boot's process table, not this one —
    /// which is why `SessionProcess` carries none at all any more, and why `reapSession`
    /// re-derives on the live path too. A process whose identity has just been confirmed to
    /// match is authoritative about its own process group; nothing else is. Re-deriving only
    /// after `isAlive` has passed means this is asking a process we have positively identified,
    /// not a stranger that happens to share a pid.
    func sweepOrphans(from snapshot: SessionSnapshot) async {
        guard let recorded = snapshot.processes, !recorded.isEmpty else { return }
        // Fails closed, not open: a snapshot whose provenance cannot be established (no
        // `owner`, e.g. a truncated/hand-edited file, a nil read at write time, or a future
        // writer that skips `persist()`) is left alone rather than swept. The identity gate
        // below cannot substitute for this — a live instance's own recorded children pass
        // `isAlive` by design, so matching identity is exactly what would make them killable
        // if this fell through.
        guard let owner = snapshot.owner else { return }
        if processInspector.isAlive(owner) { return }

        var cleaned = 0
        var survived = false
        // The map's keys are deliberately dropped. They are *previous-run tab ids*, and
        // `restore()` has already recreated this run's tabs under those very same UUIDs, each
        // with a live shell of its own recorded against them. Re-keying a survivor under its
        // old id would overwrite one of those live records — discarding a live process without
        // proof of death, and leaving it unreaped on close and on quit.
        for process in recorded.values where processInspector.isAlive(process.identity) {
            // `pgid` is the live process's own answer — see this method's doc comment above.
            // `reap` takes it as an `Optional` all the way through so "we could not ask" and
            // "killpg some sentinel group" are never conflated; `nil` here makes
            // `SessionReaper.deliver` signal the pid directly instead of guessing.
            let livePgid = processInspector.pgid(of: process.identity.pid)
            let outcome = await reaper.reap(shell: process.identity, pgid: livePgid)
            reapReporter?.report(outcome, context: "orphan sweep")
            if outcome == .clean {
                cleaned += 1
            } else {
                // A survivor of the *previous* run's sweep must not vanish once this run's
                // first unrelated `persist()` fires. `processRegistry` starts this run empty
                // (nothing here forked these children), so unless the survivor is put back
                // into it, the very next save anywhere in the app would silently drop the
                // one record that gives the *next* launch's sweep a chance at it.
                //
                // Under a fresh id: this is an orphan, not a tab. Nothing downstream reads the
                // key except `reapSession`'s `forget`, and a collision with a live tab's id
                // would be a live record destroyed. See the loop header above.
                processRegistry.keep(UUID(), as: process)
                survived = true
            }
        }
        if cleaned > 0 { reapReporter?.reportSweep(cleaned: cleaned) }
        if survived { persist() }
    }

    /// Total wall-clock budget for reaping every session at quit. Not per-session: quitting
    /// with twelve tabs open must not take twelve times as long. `nonisolated` because it is
    /// a plain `Sendable` constant referenced from `reapAllForQuit`'s default parameter value,
    /// which Swift evaluates outside this type's actor isolation — without this, the compiler
    /// warns (and Swift 6 mode errors) that a main-actor-isolated property cannot be read from
    /// that nonisolated context.
    nonisolated static let quitBudget: Double = 8.0

    /// What a resumed session is told. A constant rather than a preference: if the fixed
    /// string turns out to be wrong in practice, making it configurable is a smaller change
    /// than un-shipping a setting nobody wanted.
    static let resumePrompt = "Keep going"

    /// How long after a restore a pending prompt is still worth sending. Without a deadline
    /// an entry that never met its gates would sit in the queue and fire hours later, into a
    /// session the user has long since been working in.
    static let resumePromptWindow: TimeInterval = 120

    /// Whether a restored tab was working when we went away.
    ///
    /// `waiting` is excluded: what it was blocked on does not survive the restart. Background
    /// work counts even at `.idle`, and that is not a special case — it is the same rule as
    /// before, now that `shell` is decomposed. A tab with a dev server up *was* working.
    static func isResumable(activity: SessionActivity, hasBackgroundWork: Bool) -> Bool {
        activity != .waiting && (activity == .busy || hasBackgroundWork)
    }

    /// Reads a persisted `activity` string, migrating the pre-decomposition `"shell"`.
    ///
    /// Permanent, not transitional: every `sessions.json` on every machine holds `"shell"`
    /// today, and `SessionActivity(rawValue:)` returns nil for it now. Dropping this read
    /// would blank the status of every backgrounded tab on first launch after the upgrade.
    static func restoredActivity(
        fromPersisted raw: String?
    ) -> (activity: SessionActivity?, hasBackgroundWork: Bool) {
        guard let raw else { return (nil, false) }
        if raw == "shell" { return (.idle, true) }
        return (SessionActivity(rawValue: raw), false)
    }

    /// Reap every live session concurrently, returning when they are all done or the budget
    /// expires — whichever comes first. Survivors are left for the next launch's sweep: each
    /// `reapSession` call already forgets its own record on `.clean` and keeps it on
    /// `.survivors`, so there is nothing left for this method to do about the registry once
    /// the group above returns. It must not do anything either — a blanket
    /// `processRegistry.restore([:])` here would erase precisely the records a budget expiry
    /// (or an unkillable process) needs kept, undoing `reapSession`'s own bookkeeping the
    /// instant it finishes.
    ///
    /// The deadline races the *aggregate* of every reap, not the fastest one: the fan-out
    /// lives in a single child task nested inside its own group, so `group.next()` above it
    /// only resolves once every reap inside has finished (or the sibling deadline task wins
    /// first). An earlier draft raced the deadline against each reap individually — the first
    /// session to finish would win the outer `group.next()`, and the `cancelAll()` that
    /// followed cancelled every reap still in flight, so quitting with several tabs open
    /// reaped only one of them.
    func reapAllForQuit(budget: Double = SessionStore.quitBudget) async {
        // Before any `await` — see `isTerminating`'s doc comment for the race this closes.
        isTerminating = true
        // The app-servers are our children too, and unlike a tab's shell nothing else will
        // ever come looking for them: they have no entry in `processRegistry`, so a quit that
        // skipped this would leave `codex app-server` running with nobody left to talk to it.
        // Above the `live.isEmpty` return below, deliberately — quitting with no tabs still
        // has to stop them. Every account's, and each `expected:` is that account's own live
        // stack: on quit there is no successor to protect, so the identity guard is a
        // formality here and this is the one caller that sweeps the whole map.
        for (account, stack) in codexStacks { stopCodex(account: account, expected: stack) }
        let live = processRegistry.all
        guard !live.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withTaskGroup(of: Void.self) { inner in
                    for (id, process) in live {
                        inner.addTask { await self?.reapSession(id, process: process, context: "app quit") }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Closes every session in a project, then removes the project.
    ///
    /// Deliberately routed through `closeSession` per child rather than reimplementing the
    /// teardown: that method is where surface release, watcher shutdown, status and
    /// subagent-count removal, anchor removal, and notification withdrawal all live, and a
    /// second copy of that list would rot.
    /// ⌘⇧T. Brings back the most recently closed tab — or, if a whole project was closed, the
    /// project and everything that was in it — and walks further back on each press until the
    /// history runs out.
    ///
    /// A reopened tab is rebuilt exactly the way `restore` rebuilds a persisted one, through
    /// `reinsertClosed`: same resume command, same missing-login refusal, same codex
    /// deferral. The two are the same operation on different inputs, and anything that
    /// diverges here is a bug in one of them.
    ///
    /// No-ops on an empty history, which is also what the menu item relies on: it stays
    /// enabled in every state (a disabled `NSMenuItem` does not fire its key equivalent) and
    /// guards here instead.
    /// ⌘W. Closes the selected session, reporting whether there was one.
    ///
    /// The menu item binds here rather than to AppKit's `performClose:` because that route
    /// only works while focus is inside the terminal. `TerminalHostView` implements
    /// `performClose:` and sits below the terminal pane, so the responder chain reaches it
    /// from a focused surface — but from a focused *sidebar* there is nothing between the
    /// sidebar and the window, `NSWindow` implements `performClose:` itself, and the window
    /// claims the key. In a single-window app whose window closing quits
    /// (`applicationShouldTerminateAfterLastWindowClosed`), that turned ⌘W into ⌘Q.
    ///
    /// The `Bool` is what keeps the empty state honest: with no session there is nothing to
    /// close, and the caller falls back to closing the window rather than swallowing the key.
    @discardableResult
    func closeSelectedSession() -> Bool {
        guard let id = selectedSessionID else { return false }
        closeSession(id)
        return true
    }
    func reopenLastClosed(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        guard let entry = closedSessions.takeLast() else { return }

        // Same collection-then-launch shape as `restore`: settling a codex thread is `async`
        // and this is not.
        var deferredCodexResumes: [UUID] = []

        switch entry {
        case .session(let closed):
            reopenSession(closed, directoryExists: directoryExists,
                          deferredCodexResumes: &deferredCodexResumes)

        case .project(let closed):
            let url = URL(fileURLWithPath: closed.path, isDirectory: true)
            // Seeded at its recorded sidebar position before the sessions go in, so they land
            // in it rather than making `insertSession` append a fresh repo at the end. Skipped
            // when the project is already back — a session closed before the project was, then
            // reopened first, recreates it.
            if indexOfRepo(for: url) == nil {
                let repo = Repo(url: url, isCollapsed: closed.isCollapsed)
                // Clamped: sessions may have been closed or projects added since, so the
                // recorded index can be past the end of a shorter sidebar.
                let at = min(max(closed.indexInSidebar, 0), repos.count)
                repos.insert(repo, at: at)
                emit(.projectAdded(
                    FleetProjection.project(
                        repo, statuses: statuses, unread: unreadIdle,
                        backgroundWork: backgroundWorkSessions,
                        openPromptCalls: openPromptCalls, planGates: planGates
                    ), at: at
                ))
            }
            for child in closed.sessions {
                if reinsertClosed(child, directoryExists: directoryExists) {
                    deferredCodexResumes.append(child.session.id)
                }
            }
            // The top row of what just came back, which is where the eye goes. A project
            // records no "active tab" of its own to return to.
            if let first = closed.sessions.first { selectedSessionID = first.session.id }
        }

        settleReopen(deferredCodexResumes)
    }

    /// Rebuilds one recorded tab and un-collapses its project. The body ⌘⇧T's `.session` case
    /// and the phone's `reopenClosedSession` both run, so the two surfaces cannot disagree
    /// about what a reopen resurrects — only about whether it may also move the desk's
    /// selection, which `selecting:` below is for.
    ///
    /// Appends to `deferredCodexResumes` rather than settling anything itself: a caller
    /// reopening a whole project has several of these to collect before it starts one task.
    ///
    /// - Parameter selecting: whether this reopen may move the Mac's selected tab. Defaults to
    ///   true — ⌘⇧T is pressed at the desk and expects to land on what it just brought back.
    ///   `reopenClosedSession` passes `false`: the phone's reopen is a client request, and
    ///   under the client-selection rule it must not yank the desk's focus off whatever is on
    ///   screen. See `select(_:selecting:)`.
    private func reopenSession(
        _ closed: ClosedSessionHistory.ClosedSession,
        directoryExists: (String) -> Bool,
        deferredCodexResumes: inout [UUID],
        selecting: Bool = true
    ) {
        if reinsertClosed(closed, directoryExists: directoryExists) {
            deferredCodexResumes.append(closed.session.id)
        }
        // Matching `addSession` rather than `insertSession`: a tab reopened into a collapsed
        // project would otherwise come back invisible, since `SidebarRow.rows` renders only
        // the header for a collapsed repo. The `.project` case deliberately does not do this —
        // a project that was collapsed when it was closed is restored collapsed, because that
        // is the state being undone.
        let url = URL(fileURLWithPath: closed.projectPath, isDirectory: true)
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
        select(closed.session.id, selecting: selecting)
    }

    /// Persist, then start any codex tab whose resume text still has to be settled.
    ///
    /// Reuses `restore`'s task handle rather than adding a second one: the two never run
    /// concurrently in production — `restore` happens once at launch, before any tab can be
    /// closed — and sharing it keeps one place to await a settling codex tab.
    private func settleReopen(_ deferredCodexResumes: [UUID]) {
        persist()
        if !deferredCodexResumes.isEmpty {
            codexRestoreTask = Task { [weak self] in
                await self?.resumeRestoredCodex(deferredCodexResumes)
            }
        }
    }

    /// The top-level closed tabs, most recent first — what `FleetService` projects onto the
    /// wire for the phone's Recently Closed section.
    var recentlyClosedSessions: [ClosedSessionHistory.ClosedSession] {
        closedSessions.sessionEntries
    }

    /// Reopen one recorded tab by id, rather than whatever is on top of the stack.
    ///
    /// The phone's counterpart to ⌘⇧T. A no-op when the id is not in the history — ⌘⇧T got
    /// there first, or it aged past `depth`. Deliberately silent: the tab is in the fleet list
    /// either way, so there is nothing to tell the phone that it cannot already see.
    ///
    /// Hardcodes `selecting: false` rather than taking a parameter of its own: this is a
    /// phone-only entry point — only `FleetService` calls it, ⌘⇧T goes through
    /// `reopenLastClosed` instead — so there is no caller that would ever want `true` here. A
    /// client's reopen must not move the desk's selection off whatever is on screen; see
    /// `select(_:selecting:)`.
    func reopenClosedSession(
        id: UUID,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        guard let closed = closedSessions.takeSession(id: id) else { return }
        var deferredCodexResumes: [UUID] = []
        reopenSession(closed, directoryExists: directoryExists,
                      deferredCodexResumes: &deferredCodexResumes, selecting: false)
        settleReopen(deferredCodexResumes)
    }

    /// Rebuilds one tab onto an existing conversation and starts it resuming.
    ///
    /// Extracted from `reinsertClosed` so ⌘⇧T and ⌘K search share one implementation. Every
    /// rule here is `restore`'s and is documented there: a transcript directory that has
    /// gone (a deleted worktree, usually) falls back to the project so `--resume` runs where
    /// claude actually wrote; a tab whose login was deleted is rebuilt but never launched;
    /// codex is typed at only after `resumeRestoredCodex` confirms its thread still exists.
    ///
    /// Returns true when it is a codex tab whose resume text still has to be settled.
    @discardableResult
    private func resumeExisting(
        _ session: Session,
        inProjectAt projectPath: String,
        at index: Int?,
        directoryExists: (String) -> Bool
    ) -> Bool {
        var session = session
        if !directoryExists(session.transcriptDirectory) {
            session.transcriptDirectory = session.workingDirectory
        }

        let orphaned = accountIsMissing(for: session)
        let deferred = session.agent.negotiatesIdentity
        let initialInput: String
        if orphaned || deferred {
            initialInput = ""
        } else {
            // Built inside the else, as in `restore`, so an orphaned tab does not memoize an
            // adapter — and a status watcher behind it — for the built-in account its
            // dangling id would otherwise collapse to.
            let adapter = adapter(for: instance(for: session))
            initialInput = adapter.resumeCommand(
                adapter.binding(for: session),
                session,
                // From the tab's *project*, not from wherever it was last writing, so a tab
                // reopened inside a worktree still gets its project's overrides.
                options(for: session.agent, project: session.workingDirectory)
            )
        }

        insertSession(
            session,
            in: URL(fileURLWithPath: projectPath, isDirectory: true),
            initialInput: initialInput,
            at: index
        )
        return deferred && !orphaned
    }

    /// Rebuilds one recorded tab. Returns true when it is a codex tab whose resume text still
    /// has to be settled against the app-server and typed afterwards. All the actual rules
    /// live on `resumeExisting`, which this and `openConversation` share.
    @discardableResult
    private func reinsertClosed(
        _ closed: ClosedSessionHistory.ClosedSession,
        directoryExists: (String) -> Bool
    ) -> Bool {
        resumeExisting(
            closed.session,
            inProjectAt: closed.projectPath,
            at: closed.indexInProject,
            directoryExists: directoryExists
        )
    }

    /// The literal directory a past conversation should resume into: the project itself, or
    /// one of its worktrees, whichever one's *encoded* `~/.claude/projects` directory
    /// actually holds `<conversationID>.jsonl`.
    ///
    /// `SearchResult.projectPath` only ever names the sidebar project — nothing in a search
    /// result identifies which literal worktree a conversation ran in, because
    /// `SearchCorpus`'s encoding is one-way (see its doc comment) — so this re-derives the
    /// answer independently rather than trusting anything upstream. Falls back to the
    /// project path when no candidate's transcript exists: a conversation whose worktree was
    /// deleted since it last ran resumes at the project root rather than not resuming at all,
    /// same fallback shape as `resumeExisting`'s own "directory gone" rule below.
    /// `nonisolated`, not merely `private`: it is called from `openConversation`'s default
    /// argument, which is evaluated at the call site and is not itself actor-isolated even
    /// though `SessionStore` is — and the function touches no actor state anyway, only its
    /// own injected closures.
    ///
    /// Internal rather than `private` so `OpenConversationTests` can drive the resolution
    /// algorithm directly against a real temp-directory fixture, independent of whether
    /// `openConversation`'s default argument still calls it at all — that second question is
    /// what the wiring test asserts instead.
    nonisolated static func resolvedTranscriptDirectory(
        projectPath: String,
        conversationID: UUID,
        listing: (String) -> [String] = SearchCorpus.defaultListing,
        projectsRoot: URL = ClaudeSession.defaultProjectsRoot,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let candidates = SearchCorpus.candidateWorkingDirectories(
            forProjectAt: projectPath, listing: listing
        )
        return candidates.first {
            exists(ClaudeSession.transcriptURL(
                sessionID: conversationID, workingDirectory: $0, projectsRoot: projectsRoot
            ).path)
        } ?? projectPath
    }

    /// ⌘K activation. Selects an open tab, or rebuilds one onto a past conversation.
    ///
    /// The project is added back when it has left the sidebar, and un-collapsed either way:
    /// a tab resumed into a collapsed project would come back invisible, since
    /// `SidebarRow.rows` renders only the header for a collapsed repo. Same reasoning as
    /// `reopenLastClosed`, which un-collapses for the same reason.
    ///
    /// Returns the tab actually opened or selected, `nil` on every path that filed nothing —
    /// `@discardableResult` because ⌘K Return and the search panel's `onSelect` have never
    /// needed the answer, they read `selectedSessionID` same as before. `FleetService` is the
    /// first caller that does: a phone's `search.open` request has no `selectedSessionID` to
    /// fall back on, and reading that property after a call that took the failure branch below
    /// would hand back whatever tab happened to be selected beforehand — a confident answer
    /// naming the wrong conversation. Returning the id directly makes that failure mode
    /// unrepresentable rather than relying on every caller to remember the gap.
    ///
    /// - Parameter selecting: whether a filed, resumed, or already-open tab may become the
    ///   Mac's selection. Defaults to true — ⌘K and the search panel's `onSelect` already
    ///   expect Return to land on what it opened. `FleetService` passes `false` for the phone's
    ///   `search.open`: a command arriving from a client must never move the desk's selection
    ///   off whatever is on screen. The return value is unaffected either way — the phone still
    ///   needs the id it asked about to navigate its own side. Threaded through every place
    ///   this method can resolve a tab to hand back: the `.select` branch and the already-live
    ///   recheck call `select(_:selecting:)` directly; the resume branch below does too; the
    ///   project-row branch has two sides, and both honour it — the existing-repo side calls
    ///   `select(_:selecting:)` directly, and the new-project side passes `selecting` on to
    ///   `addProject(at:selecting:)` rather than taking `addProject`'s own default, so a
    ///   client's search landing on a project new to the sidebar cannot select unconditionally
    ///   through a path this parameter forgot to reach.
    @discardableResult
    func openConversation(
        _ activation: SearchActivation.Activation,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        resolveTranscriptDirectory: (String, UUID) -> String = {
            SessionStore.resolvedTranscriptDirectory(projectPath: $0, conversationID: $1)
        },
        selecting: Bool = true
    ) -> UUID? {
        let projectPath: String
        let conversationID: String
        let title: String

        switch activation {
        case .select(let id):
            // `selectSession` would itself be a no-op when `id` names no live tab — checked
            // here directly (rather than via that method) so this can honour `selecting` too:
            // a stale id (a tab closed between `plan` and this call) still reports `nil`
            // instead of an id that does not resolve to anything.
            guard locate(id) != nil else { return nil }
            select(id, selecting: selecting)
            return id
        case .resume(let conversation, let project, let resultTitle, _):
            projectPath = project; conversationID = conversation; title = resultTitle
        case .addProjectThenResume(let project, let conversation, let resultTitle, _):
            projectPath = project; conversationID = conversation; title = resultTitle
        }

        let url = URL(fileURLWithPath: projectPath, isDirectory: true)
        // A project row, or a result whose conversation id we never learned: there is
        // nothing to resume, so land on the project instead of launching a nameless agent.
        guard let pinned = UUID(uuidString: conversationID) else {
            let opened: UUID?
            if let existing = indexOfRepo(for: url) {
                if repos[existing].isCollapsed {
                    repos[existing].isCollapsed = false
                    emit(.projectCollapsed(id: repos[existing].id, isCollapsed: false))
                }
                opened = repos[existing].sessions.first?.id
                if let opened { select(opened, selecting: selecting) }
            } else {
                let created = addProject(at: url, selecting: selecting)
                // `addProject` delegates to `newSession(in:)`, whose own `launchAccount`
                // failure branch returns a `Session` that was never filed — see that
                // method's doc comment. Checked here rather than trusted, for the same
                // reason `.select` re-checks `locate`: a fabricated id is worse than `nil`.
                opened = repos.flatMap(\.sessions).contains { $0.id == created.id }
                    ? created.id : nil
            }
            persist()
            return opened
        }

        // Enforced here too, not only inside `SearchActivation.plan`: a caller that fills
        // `plan`'s `openSessions` wrong — exactly the case-mismatch bug the `UUID` typing on
        // `ActiveSession.conversationID` exists to prevent — must not be trusted blind, or a
        // second `claude --resume` starts on a conversation that already has a tab, two
        // processes appending one transcript and colliding in claude's pid-keyed registry.
        if let live = repos.flatMap(\.sessions).first(where: { $0.pinnedConversationID == pinned }) {
            select(live.id, selecting: selecting)
            return live.id
        }

        // Resolved before anything is filed, the same as `newSession`: nil would mean "the
        // built-in home" forever, which is correct only until this project's login is set or
        // changes — the silent wrong-login substitution `newSession`'s own comment refuses.
        let account: AgentAccount?
        switch launchAccount(for: .claude, project: projectPath) {
        case .success(let resolved): account = resolved
        case .failure(let error):
            launchFailureReporter.report(error)
            return nil
        }

        let session = Session(
            // Falls back to the id only when the title sanitizes to nothing usable — not
            // when it merely differs from the id — so a tab found *by name* comes back
            // called that name rather than a raw UUID nobody could self-heal: `TailReader`
            // starts at end-of-file, so the transcript's own `custom-title` record already
            // written is never re-read.
            title: ClaudeSession.sanitizedName(title) ?? ClaudeSession.sanitizedName(conversationID)
                ?? "session",
            workingDirectory: projectPath,
            transcriptDirectory: resolveTranscriptDirectory(projectPath, pinned),
            pinnedConversationID: pinned,
            accountID: account?.id
        )
        let deferred = resumeExisting(
            session, inProjectAt: projectPath, at: nil, directoryExists: directoryExists
        )
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
        select(session.id, selecting: selecting)
        persist()

        if deferred {
            codexRestoreTask = Task { [weak self] in
                await self?.resumeRestoredCodex([session.id])
            }
        }
        return session.id
    }
    func closeProject(_ id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        // One history entry for the whole project, and the children below are closed with
        // `recordingHistory: false` so they do not each push one as well. That is what makes
        // a closed project cost a single ⌘⇧T rather than one per tab — the same way a browser
        // reopens a closed window rather than making you undo its tabs one at a time.
        //
        // Recorded before the closes, from the live repo: `closeSession` rewrites `repos`,
        // and by the end of the loop there is nothing left here to read.
        let repo = repos[index]
        closedSessions.record(.project(ClosedSessionHistory.ClosedProject(
            path: repo.url.path,
            isCollapsed: repo.isCollapsed,
            indexInSidebar: index,
            sessions: repo.sessions.enumerated().map { offset, session in
                ClosedSessionHistory.ClosedSession(
                    session: session, projectPath: repo.url.path, indexInProject: offset
                )
            }
        )))
        // Snapshot the ids first: `closeSession` mutates `repos`, so iterating the live
        // array would walk off the end.
        for sessionID in repos[index].sessions.map(\.id) {
            closeSession(sessionID, recordingHistory: false)
        }
        // Re-found rather than reusing `index`: every `closeSession` above rewrote `repos`.
        repos.removeAll { $0.id == id }
        emit(.projectRemoved(id: id))
        persist()
    }

    // MARK: Projects

    /// The sidebar's rendering order, flattened. Computed rather than stored so it cannot
    /// drift from `repos`; it is cheap, and `repos` is already `@Published`.
    var sidebarRows: [SidebarRow] { SidebarRow.rows(for: repos) }

    /// Open a new session in a project named by id rather than by URL.
    ///
    /// The wire has only the id — a phone has no business knowing a path on this machine, and
    /// a path arriving from off-box would be a directory this process opens on a client's say
    /// so. Resolving it here also means the project's own defaults are applied by the one
    /// method that already knows them.
    ///
    /// `nil` when the project is gone, which a phone holding a stale snapshot can ask about.
    ///
    /// Hardcodes `selecting: false` rather than taking a parameter of its own: this is a
    /// phone-only entry point — only `FleetService` calls it, the sidebar's ⌘N and its `+`
    /// button go through `newSessionBelowActive`/`addProject` instead — so there is no caller
    /// that would ever want `true` here. A client's `+` must not move the desk's selection off
    /// whatever is on screen. See `select(_:selecting:)`.
    @discardableResult
    func newSession(inProject id: Repo.ID) -> Session? {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return nil }
        return newSession(in: repos[index].url, selecting: false)
    }

    func setCollapsed(_ isCollapsed: Bool, forProjectAt id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }),
              repos[index].isCollapsed != isCollapsed else { return }
        repos[index].isCollapsed = isCollapsed
        emit(.projectCollapsed(id: id, isCollapsed: isCollapsed))
        persist()
    }

    /// The sidebar's single `.onMove` target. The policy — what may move where — lives in
    /// `SidebarReorder`, which is tested without a store; this only applies the result.
    func moveSidebarRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let updated = SidebarReorder.apply(
            to: repos, rows: sidebarRows, from: source, to: destination
        ) else { return }
        let before = repos
        repos = updated
        emitReorder(from: before, to: updated)
        persist()
    }

    /// A reorder is the one mutation whose input is already a whole rebuilt array — the
    /// policy lives in `SidebarReorder` and hands back `[Repo]`, not a move. Comparing the
    /// two is therefore describing what the caller did, not the store-wide diffing the
    /// design rejected: the comparison is bounded by one gesture.
    private func emitReorder(from before: [Repo], to after: [Repo]) {
        if before.map(\.id) != after.map(\.id) {
            emit(.projectsReordered(order: after.map(\.id)))
        }
        for repo in after {
            guard
                let old = before.first(where: { $0.id == repo.id }),
                old.sessions.map(\.id) != repo.sessions.map(\.id)
            else { continue }
            emit(.sessionsReordered(project: repo.id, order: repo.sessions.map(\.id)))
        }
    }

    /// The one status a collapsed project header shows: the most demanding thing any child
    /// is doing. Idle and unstatused children contribute nothing, so a quiet project shows
    /// no glyph at all — the same "renders nothing" that an unstatused session row gets.
    ///
    /// Background work is deliberately NOT folded in here: it is a decoration on a
    /// *session*, not a value `SessionActivity` can rank, and a project whose only active
    /// tab is idle-with-background-work still has to surface that even though it loses this
    /// filter. `ProjectHeaderRow` reads `projectHasBackgroundWork` alongside this, exactly as
    /// a session row reads `backgroundWorkSessions` alongside `status(for:)`.
    ///
    /// The subagent count is deliberately dropped. `SessionStatusIcon` draws it beside the
    /// spinner, and the collapsed header already carries a number (the session count); two
    /// adjacent numerals read as two counts of the same thing.
    func collapsedStatus(forProjectAt id: Repo.ID) -> SessionStatus? {
        guard let repo = repos.first(where: { $0.id == id }) else { return nil }
        guard var best = repo.sessions
            .compactMap({ statuses[$0.id] })
            .filter({ $0.activity != .idle })
            .max(by: { $0.activity.summaryRank < $1.activity.summaryRank })
        else { return nil }
        best.subagentCount = 0
        return best
    }

    /// Whether any session in this project is running a background task — the collapsed
    /// header's counterpart to a session row's own `backgroundWorkSessions.contains(id)`.
    /// Independent of `collapsedStatus`: a project whose only active tab is idle still
    /// answers `true` here, which is exactly the case `collapsedStatus`'s idle filter drops.
    func projectHasBackgroundWork(forProjectAt id: Repo.ID) -> Bool {
        guard let repo = repos.first(where: { $0.id == id }) else { return false }
        return repo.sessions.contains { backgroundWorkSessions.contains($0.id) }
    }

    /// Test seam. Production statuses arrive through `applyRegistry`, which takes registry
    /// rows keyed by pid; a test that only cares about the sidebar's reading of a status
    /// should not have to fabricate those.
    ///
    /// Routed through `commitStatuses` rather than writing `statuses` directly: this seam
    /// is a stand-in for a registry tick, and a tick that skipped read-state, notifications
    /// and replication would make every test built on it exercise a path production never
    /// takes.
    func applyRegistryForTesting(_ next: [UUID: SessionStatus]) {
        commitStatuses(next, backgroundWork: backgroundWorkSessions)
    }

    /// Test seams. Production drives both from `applyRegistry`; a test that only cares about
    /// the prompt queue should not have to fabricate registry rows.
    func flushPendingResumePromptsForTesting() { flushPendingPrompts() }
    func cancelSupersededPromptsForTesting(_ transitions: [StatusTransition]) {
        cancelSupersededPrompts(transitions)
    }

    /// Marks a tab as mid-injection so a test can assert the shared gate refuses a second
    /// driver. There is no production caller and there must not be one.
    func holdInjectionForTesting(_ id: UUID) { injecting.insert(id) }

    /// Seeds the deferred-prompt queue directly, in the same charter as
    /// `holdInjectionForTesting`: no production caller, and there must not be one.
    ///
    /// It exists because `restore`'s gate now stops the production path from ever queuing for
    /// an agent with no text channel, and `inject`'s own refusal has to be provable *on its
    /// own*. A test that could only reach the injector through that queue would be green
    /// because of the gate above it rather than because of the guard it names — and the two
    /// are the difference between "nothing was queued" and "nothing was typed", which is what
    /// this bug needs asserted separately.
    func queuePendingPromptForTesting(_ text: String, for id: UUID) {
        pendingPrompts[id] = DeferredPrompt(
            text: text, deadline: now().addingTimeInterval(Self.resumePromptWindow)
        )
    }

    /// Test seam, in the style of `flushPendingResumePromptsForTesting`. The registry tick is
    /// the production driver, and a test that wants a second pass without fabricating another
    /// registry scan says so here.
    func flushPromptQueueForTesting() { flushPromptQueue() }

    /// Test seam. Production marks come from `applyReadState` and from restore; a test that
    /// only cares about how a mark is *pruned* should not have to script an edge to create it.
    func markUnreadForTesting(_ ids: Set<UUID>) {
        for id in ids { setUnread(id, true) }
    }

    /// Test seam. Production leaves this nil and injection goes to the live surface.
    var injectorOverride: TextInjecting?

    /// Test seam. The default reads the resumed conversation's transcript off the main
    /// actor and calls back on it; tests substitute a synchronous closure so they need no
    /// expectations. The read is one-shot per resume and can touch a multi-megabyte file,
    /// which is why it does not run inline.
    ///
    /// **It carries the agent, and that is the fix rather than a tidy-up.** The default used
    /// to be `ConversationTitle.resolve` — a claude JSONL parser — reached from `repin`
    /// through an agent-blind `binding(for:).transcriptURL`, so a repointed codex tab would
    /// have had its rollout parsed as a claude transcript. `AgentAdapter.title(fromTranscriptAt:)`
    /// answers `nil` for an agent whose names do not live in its transcript.
    var titleResolver: @MainActor (AgentID, URL, @escaping @MainActor (String?) -> Void) -> Void = {
        agent, url, done in
        Task.detached(priority: .userInitiated) {
            let title = agent.title(fromTranscriptAt: url)
            await done(title)
        }
    }

    func pinnedConversationID(of id: UUID) -> UUID? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].pinnedConversationID
    }

    /// Test seam: which tabs are currently attached to an agent runtime. `attachments`
    /// itself stays private; this exposes just enough to assert a closed tab's late `repin`
    /// completion did not resurrect one.
    var watchedSessionIDs: Set<UUID> { Set(attachments.keys) }

    /// Test seam, the other half of `watchedSessionIDs`: *which* transcript a tab is
    /// tailing. Presence alone cannot catch a watcher left behind on the pre-retarget or
    /// pre-repin path, which is the failure both of those paths exist to prevent.
    func watchedTranscriptURL(of id: UUID) -> URL? { attachments[id]?.binding.transcriptURL }

    /// Which agent a tab runs, and which file its conversation is read from.
    ///
    /// Three answers rather than an optional, because a phone renders them differently: a tab
    /// that is gone is a stale row, a tab whose agent reports no transcript can never have
    /// one, and a transcript that is simply not on disk yet is the ordinary state of a claude
    /// session before its first turn (`TimelineReader` reports that one, not this).
    ///
    /// Keyed on the tab `id`, never `conversationID`: the latter is not stable across a
    /// re-pin, and for codex it differs from the tab id from birth.
    ///
    /// The live attachment first, then the adapter: an attached tab is being tailed right now
    /// and its binding is settled, while a tab with no agent process still has a conversation
    /// worth reading. Everything agent-shaped goes through `AgentAdapter.binding(for:)` and
    /// never through `Session.transcriptDirectory` or `ClaudeSession` — same rule
    /// `toolContext()` follows, so that claude deriving its path from a cwd does not become a
    /// rule every future agent inherits.
    ///
    /// A read, and only a read. It changes no fleet state, so it adds no mutation site for
    /// `FleetReplicator`'s DEBUG drift check to miss and needed no `FleetEvent` case.
    func timelineSource(of id: UUID) -> TimelineSource {
        guard let at = locate(id) else { return .unknownSession }
        let session = repos[at.repo].sessions[at.session]
        let url = attachments[id]?.binding.transcriptURL
            ?? adapter(for: instance(for: session)).binding(for: session).transcriptURL
        guard let url else { return .noTranscript }
        return .file(agent: session.agent, url: url)
    }

    func title(of id: UUID) -> String? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].title
    }

    /// A tab's title together with the project it sits under — what a notification needs, and
    /// what `title(of:)` alone cannot answer without a second `locate` on the same id.
    func titleAndProject(of id: UUID) -> (title: String, project: String)? {
        guard let at = locate(id) else { return nil }
        return (repos[at.repo].sessions[at.session].title, repos[at.repo].displayName)
    }

    /// Which agent a tab runs, for a caller that has to ask a *capability* about it — today
    /// `PromptService`, so its refusal can be `AgentAdapter.dialogDriver` rather than a
    /// second name check of its own. `nil` for a tab that is gone, which every caller already
    /// has to handle.
    ///
    /// Deliberately not derived from `timelineSource(of:)`: that answers `.noTranscript`
    /// without naming an agent, so a caller reading the agent off it would silently lose the
    /// question for exactly the tabs least able to answer it.
    func agent(of id: UUID) -> AgentID? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].agent
    }

    /// The `claude` pid backing a tab, for `PlanGateService`'s `pid` closure — the same field
    /// `applyRegistry` already keys `rows[anchor.pid]` on, so a plan gate and a status read
    /// agree about which process they mean.
    func claudePID(of id: UUID) -> pid_t? {
        anchors[id]?.pid
    }

    /// Every session this Mac knows, for `PlanGateService`'s `sessions` closure. Order is
    /// whatever `repos` is in; `PlanGateService` only ever uses this to scan, never to display.
    func allSessionIDs() -> [UUID] {
        repos.flatMap(\.sessions).map(\.id)
    }

    /// Sidebar → the agent. Updates the title immediately, then tells the agent, by whatever
    /// route that agent renames its own conversation.
    ///
    /// The title lands here and now; only the telling can be deferred or fail. A rename is
    /// therefore never lost from the sidebar, just occasionally late reaching the agent.
    ///
    /// **This used to be claude-only, and every tab took claude's route.** Renaming a codex
    /// tab therefore never sent `thread/name/set`, so the sidebar title and codex's thread
    /// name diverged permanently — and since the thread name is what `session_index.jsonl`
    /// and `thread/read` both report, the next tail or restore flicked the sidebar back to
    /// the old one. Worse, it
    /// queued `/rename <name>` for a pty nothing would ever retire it from: `flushPendingRename`
    /// retried it on every registry tick for the life of the process, and `InputBar.read`
    /// keys on a line starting with `❯` — a common shell prompt glyph — so a match would have
    /// sent Ctrl-U and pasted `/rename foo` into the user's live codex session.
    ///
    /// Claude's leg stays synchronous and inline, deliberately. `AgentAdapter.rename` is
    /// `async`, and dispatching claude through it would push `injectPendingRename` into a
    /// later turn of the run loop — which is exactly the guarantee the injection contract is
    /// built on (`inject` decides *now* whether the bar is busy, and defers only if it is).
    /// Codex has no such constraint: its rename is a request, and nothing waits on it.
    /// `@discardableResult` because every existing caller is a local UI action that has
    /// already validated its own field; the Bool exists for the fleet command, which has to
    /// answer a phone that sent a title this agent cannot use.
    /// Read with:
    /// `log show --predicate 'subsystem == "dev.flightdeck.FlightDeck" AND category == "rename"' --last 30m`
    static let renameLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "rename"
    )

    @discardableResult
    func rename(_ id: UUID, to newTitle: String) -> Bool {
        guard let at = locate(id),
              // Sanitized by THIS agent's rule, not by claude's for everyone. It is what the
              // sidebar shows and what the rename below sends, and those two must agree —
              // but which characters are legal is a property of the channel the name travels
              // down, and codex's is JSON-RPC. See `AgentAdapter.sanitizedTitle`.
              let name = agent(of: id)?.sanitizedTitle(newTitle)
        else { return false }

        // **Already called that, so stop here.** Everything below this line is observable: a
        // `.renamed` event to every paired phone, a `persist()`, and — for claude — a rename
        // TYPED INTO THE LIVE PTY. Re-sending the current name is not merely wasted work, it
        // interrupts a running agent to tell it something it already knows, and the injector
        // may defer it behind a busy turn or a multi-row draft first.
        //
        // Reached by the ordinary gesture rather than by a corner case: both editors seed
        // themselves with the CURRENT title — `SessionSidebar.beginRename` and the phone's
        // rename alert — so opening one and pressing Return without typing lands exactly here.
        //
        // Compared AFTER sanitising, so a title differing only by what this agent's own rule
        // strips is the same title. Comparing the raw string would disagree with the person
        // who typed a trailing space, and then type at the pty to prove the point.
        //
        // `true`, not `false`: false is this method's "that title is unusable" answer, which
        // `FleetService` turns into a `rejected_title` error on the phone. The session has
        // exactly the name the caller asked for, which is acceptance by any reading.
        guard repos[at.repo].sessions[at.session].title != name else { return true }

        repos[at.repo].sessions[at.session].title = name
        emit(.renamed(id: id, title: name, origin: .user))
        persist()

        let session = repos[at.repo].sessions[at.session]
        switch session.agent {
        case .claude:
            // Inline, not through `adapter.rename` — see this method's doc comment above for
            // why claude's leg stays synchronous.
            injectPendingRename(id, name)
        case .codex:
            let adapter = adapter(for: instance(for: session))
            let binding = adapter.binding(for: session)
            // Fire and forget: the sidebar already has the name, and a thread that refuses
            // the rename (or an app-server that is gone) must not block the user's edit or
            // pop an alert over a cosmetic failure.
            //
            // Fire-and-forget is NOT fire-and-say-nothing, and the difference is the whole
            // reason this is logged. When the request never lands, codex keeps the old name;
            // `CodexNameWatcher` then tails that name out of `session_index.jsonl` and pushes
            // it back UP into the sidebar, so the user's rename appears to revert on its own
            // and the working up-path is what disguises the broken down-path. Swallowing the
            // error with a bare `try?` left no evidence anywhere — not a log line, not a
            // failed test — which is why "renames don't reach codex" could only be reported
            // as a symptom and never traced. Cosmetic enough not to alert, never so cosmetic
            // that it should be invisible.
            Task {
                do {
                    try await adapter.rename(binding, to: name)
                } catch {
                    Self.renameLogger.error(
                        "codex rename failed for thread \(binding.conversationID.uuidString.lowercased(), privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        // True means the name was ACCEPTED and the local title changed — not that the agent
        // has been told. The codex arm above is deliberately fire-and-forget and the claude
        // arm queues, so "renamed" here is the same ack-means-dispatched promise every other
        // fleet command makes.
        return true
    }

    /// Queues a rename for `claude` and tries it at once. `SessionStore.rename` above is the
    /// only route into `pendingRenames` — `ClaudeAdapter.rename` never reaches here; see its
    /// doc comment for why claude's leg stays inline instead — so `inject`'s `injecting`
    /// guard stays the single place a second injection into a busy tab can be refused.
    ///
    /// Sanitized *here*, not only in `rename`: what this queues becomes text typed into a
    /// pty, and an adapter's caller arrives with whatever its agent was handed. `rename` runs
    /// the same filter first for a different job — it needs the cleaned value for the sidebar
    /// title, and must reject an unusable one before touching it — and the filter is
    /// idempotent, so an already-clean name passes through unchanged.
    ///
    /// One pending rename per tab, replaced rather than queued: renaming twice before the
    /// injection lands should type the second name once, not both names in turn.
    private func injectPendingRename(_ id: UUID, _ title: String) {
        // Claude's rule by name, not by lookup: what this queues is text typed at claude's
        // pty, so it is claude's channel whatever tab asked for it. `pendingRenames` has no
        // other producer — `AgentAdapter.rename` for an agent that renames over a wire never
        // reaches here.
        guard let name = ClaudeAdapter.sanitizedTitle(title) else { return }
        pendingRenames[id] = name
        flushPendingRename(id)
    }

    // MARK: - A prompt from a paired phone

    /// What a client's prompt did.
    ///
    /// Three cases ack and four refuse. The refusals are distinguished on the wire because
    /// each sends the reader somewhere different: `unsupportedAgent` means never on this tab,
    /// `notRunning` means not until something starts, and a `rejected` means edit the text.
    /// One code for all four would leave someone retyping a message the Mac will never take.
    enum PromptDispatch: Equatable {
        /// Accepted, and the injection has started. `ack`.
        case sent
        /// Accepted and queued — the bar was busy, or claude has not finished booting. `ack`.
        case queued
        /// This token has already been accepted for this tab; nothing was queued a second
        /// time. `ack`, because from the client's side a retry that lands is a send that
        /// landed. See `acceptedPromptTokens`.
        case duplicate
        case rejected(PromptText.Rejection)
        /// No such tab.
        case unknownSession
        /// This tab's agent has no route for a prompt. See `submitPrompt`.
        case unsupportedAgent
        /// Nothing to type into: no surface, no status, or a bare shell.
        case notRunning

        /// The wire spelling — `err`'s `code` — or `nil` for the three that ack. Computed
        /// here rather than in `FleetService` so the mapping lives beside the decision.
        var errorCode: String? {
            switch self {
            case .sent, .queued, .duplicate: return nil
            case .rejected(let reason): return reason.rawValue
            case .unknownSession: return "unknown_session"
            case .unsupportedAgent: return "unsupported_agent"
            case .notRunning: return "not_running"
            }
        }
    }

    /// One phone-sent prompt waiting for a moment when it can be typed.
    ///
    /// **Deliberately NOT `DeferredPrompt`/`pendingPrompts`**, which is one-per-tab with
    /// REPLACE semantics and is cancelled the instant a session goes busy or waiting. Both
    /// are right for what that queue holds — a restore's "Keep going" and a sign-in's
    /// `/login`, where a second request supersedes the first and an agent that started
    /// working on its own has already done the thing — and both are wrong here. Two messages
    /// typed on a phone are two messages, in order. And a prompt arriving mid-turn is the
    /// ORDINARY case rather than the edge one: mid-turn is when a person reaches for their
    /// phone. Reusing that queue would have silently dropped the first of two prompts and
    /// then cancelled the survivor at the next status change.
    struct QueuedPrompt: Equatable {
        let text: String
        /// The client's idempotency key, kept so a flush can identify the entry it retires
        /// without comparing text — two identical messages are two messages.
        let token: UUID
        /// When it stops being worth typing. See `phonePromptWindow`.
        let deadline: Date
    }

    /// FIFO per tab. Internal rather than private so tests can watch a deferral stay
    /// deferred, in the same style as `pendingPrompts`; nothing outside this type writes it.
    private(set) var promptQueue: [UUID: [QueuedPrompt]] = [:]

    /// How long a phone-sent prompt stays worth typing.
    ///
    /// Fifteen minutes against `resumePromptWindow`'s two, and the gap is the whole point.
    /// That one is a restore's "Keep going", which stops making sense within a couple of
    /// minutes of the restore. This one waits out a claude turn, and a turn running a test
    /// suite is routinely longer than two minutes. Bounded at all for the reason that window
    /// is bounded, and the reason is stronger here: this text is the user's own words rather
    /// than two fixed ones, so a prompt surfacing hours later in a conversation that has
    /// moved on is a stranger thing to read.
    static let phonePromptWindow: TimeInterval = 900

    /// Tokens this store has already accepted, oldest first, per tab.
    ///
    /// **This is the whole answer to "what if the phone retries".** The socket can drop
    /// between a prompt being queued and its `ack` being read, and nothing below the phone's
    /// screen model runs a liveness timer — a half-open socket reports nothing until the TCP
    /// retransmit horizon, which is minutes. So the phone genuinely cannot tell "the Mac
    /// never got it" from "the Mac got it and I never heard". Without a key the only safe
    /// client behaviour is never to retry, which makes a lost prompt lost silently; with one,
    /// a retry is free — the same token acks and queues nothing.
    ///
    /// Bounded, and per-tab, because the window in which a retry happens is one screen's
    /// session rather than a day, and an unbounded list keyed on a tab left open for a week
    /// is a leak with a client on the other end of it. Cleared with the tab in
    /// `closeSession`.
    private var acceptedPromptTokens: [UUID: [UUID]] = [:]
    static let maxRememberedPromptTokens = 16

    /// A client asked for text to be typed into a live agent and submitted.
    ///
    /// **Only an agent with a text channel, and that question is asked of the agent rather
    /// than re-decided here.** `AgentAdapter.textChannel` holds the refusal and its evidence,
    /// and a `nil` there IS the refusal; this is one of the three places that consult it —
    /// `inject` and `restore`'s auto-resume gate are the others — so no two of them can come
    /// to different conclusions about one agent. Both shipped agents take the route `rename`
    /// already takes: type into the pty through `inject`, the single funnel where an idle
    /// status, a readable one-row composer and the draft dance are all decided. Each brings
    /// its own reading of that composer — `ClaudeTextChannel` and `CodexTextChannel`, keyed
    /// on different marker glyphs — so this stays a capability question and never becomes a
    /// name check. Guessing at a TUI's input box with the user's own words is a bug this
    /// codebase has already paid for — see `rename` — which is why a channel must be *built*
    /// against that agent's captured screens before it appears here.
    ///
    /// **The order of the checks is load-bearing twice.** The capability test comes before
    /// the status test, so an agent with no channel is told `unsupportedAgent` — never on this
    /// tab — rather than `notRunning`, which would invite a retry that can never succeed. And the token
    /// test comes before the text is validated, so a retry of something already accepted is
    /// idempotent even if the two sends disagreed about the text; they cannot, since a token
    /// is minted per composed message, and if they ever did the first send is the one the
    /// user watched land.
    ///
    /// Changes no fleet state and emits no `FleetEvent`, deliberately: what a phone typed
    /// becomes visible through the transcript the agent writes, not through a mirrored field,
    /// so this feature adds no mutation site for `FleetReplicator`'s drift check to police.
    @discardableResult
    func submitPrompt(_ raw: String, token: UUID, to id: UUID) -> PromptDispatch {
        guard let at = locate(id) else { return .unknownSession }
        guard repos[at.repo].sessions[at.session].agent.textChannel != nil else {
            return .unsupportedAgent
        }
        if acceptedPromptTokens[id, default: []].contains(token) { return .duplicate }
        guard let text = PromptText(raw) else {
            // `rejection(for:)` and `init?` are the same predicate; this call is only to
            // recover the reason. `.empty` is unreachable and is a safe default rather
            // than a force-unwrap.
            return .rejected(PromptText.rejection(for: raw) ?? .empty)
        }
        // A tab with no status and no surface has nothing to type into. That is now the only
        // reason to refuse: `.shell` used to be refused here as "a bare prompt where the text
        // would be RUN rather than read", which was simply wrong — Claude Code writes it for
        // `idle && hasBackgroundTasks`, so it meant the turn had *finished*. Background work
        // is a decoration now and is deliberately not consulted.
        guard status(for: id)?.activity != nil, injector(for: id) != nil
        else { return .notRunning }

        remember(token, for: id)
        // `text.value`, never `raw`: `PromptText` normalises before it measures, so the
        // stripped string is the one the length and control-character guarantees actually
        // cover — and a trailing newline typed into the box would insert a blank line rather
        // than submit anything. It is also what the phone's outbox looks for verbatim in a
        // transcript page before it calls the send confirmed.
        promptQueue[id, default: []].append(
            QueuedPrompt(
                text: text.value, token: token,
                deadline: now().addingTimeInterval(Self.phonePromptWindow)
            )
        )
        // Tried at once rather than left for the next registry tick, so an idle tab feels
        // immediate. `flushPromptQueue(_:)` is exactly what the tick runs; this is only
        // earlier, the same relationship `injectPendingRename` has with `flushPendingRenames`.
        flushPromptQueue(id)
        // Still queued means the injection was deferred. `inject` decides *now* whether the
        // bar is busy, and its `onSent` runs inside the settle — synchronous under a test's
        // substituted `injectionSettle`, one turn later in production — so by the time this
        // line runs the entry is either gone or genuinely waiting.
        return promptQueue[id]?.contains { $0.token == token } == true ? .queued : .sent
    }

    /// Files a token against a tab, oldest evicted first. See `acceptedPromptTokens`.
    private func remember(_ token: UUID, for id: UUID) {
        var tokens = acceptedPromptTokens[id, default: []]
        tokens.append(token)
        if tokens.count > Self.maxRememberedPromptTokens {
            tokens.removeFirst(tokens.count - Self.maxRememberedPromptTokens)
        }
        acceptedPromptTokens[id] = tokens
    }

    /// Types the head of every tab's queue that is finally ready for it.
    ///
    /// Driven by the registry scan for the reason `flushPendingPrompts` is: what a queued
    /// prompt waits on — a turn ending, a draft being cleared, claude finishing its boot — is
    /// often not a status change at all, so gating the retry on one would strand it.
    private func flushPromptQueue() {
        for id in promptQueue.keys { flushPromptQueue(id) }
    }

    /// One tab's turn at the input box.
    ///
    /// **The head only, never the whole queue.** `inject` submits with a Return, so a second
    /// entry in the same pass would be typed into a bar that has just started a turn.
    /// `inject`'s idle gate would refuse it — but only after the settle, by which point the
    /// entry looks flushed to everything upstream. One per pass, and the next pass is a
    /// registry tick away.
    private func flushPromptQueue(_ id: UUID) {
        // Expiry first, and it runs whether or not this tab can be typed into: a queue that
        // is never drained because its tab lost its surface must still empty itself.
        let currentTime = now()
        // Captured before the filter drops them, because a phone is waiting on each one. The
        // window expiring is not an error on anyone's part — the tab was busy longer than the
        // message stayed worth typing — but it IS the end of that message, and the only place
        // that fact exists. Dropping these silently left the phone's outbox row saying
        // "Waiting for your Mac to type this" about a prompt that no longer existed anywhere,
        // with the `.queued` ack as the last thing it had ever been told.
        let expired = promptQueue[id]?.filter { currentTime >= $0.deadline } ?? []
        promptQueue[id] = promptQueue[id]?.filter { currentTime < $0.deadline }
        if promptQueue[id]?.isEmpty == true { promptQueue.removeValue(forKey: id) }
        if !expired.isEmpty {
            emit(expired.map { .promptExpired(id: id, token: $0.token) })
        }
        guard let head = promptQueue[id]?.first else { return }
        // Both other users of this input box go first, and neither costs anything to wait
        // for: a rename is a direct user action that clears within a tick or two, and the
        // resume queue holds text that stops making sense in two minutes. This queue has
        // fifteen.
        guard pendingRenames[id] == nil, pendingPrompts[id] == nil else { return }
        inject(
            head.text,
            into: id,
            allowMidTurn: true,
            // Re-checked after the settle: the tab can be closed, or the entry can expire,
            // while claude repaints. Matched on the TOKEN and not on the text, because two
            // identical messages are two messages and retiring the wrong one loses the other.
            stillWanted: { [weak self] in self?.promptQueue[id]?.first?.token == head.token },
            onSent: { [weak self] in
                guard let self, self.promptQueue[id]?.first?.token == head.token else { return }
                self.promptQueue[id]?.removeFirst()
                if self.promptQueue[id]?.isEmpty == true {
                    self.promptQueue.removeValue(forKey: id)
                }
            }
        )
    }

    // MARK: - Answering a dialog from a paired phone

    /// What a client's answer did.
    ///
    /// **`dispatched` is the ceiling, and that is honest rather than lazy.** The option and
    /// allow paths act across `injectionSettle` — move, wait for claude to repaint, re-read,
    /// then Return — so whether the answer LANDED is not knowable when this returns. §4's rule
    /// is the same one: `ack` means dispatched, and the observable effect arrives separately.
    /// Here it arrives twice over — the session stops being `waiting`, which the phone is
    /// pushed, and the transcript grows a `tool_result`, which the phone's next fetch reads.
    ///
    /// Everything knowable BEFORE the settle is a distinct refusal, because each sends the
    /// reader somewhere different.
    enum AnswerDispatch: Equatable {
        /// Accepted, and the driver has started. `ack`.
        case dispatched
        /// This token has already been answered for this tab. `ack`, because from the client's
        /// side a retry that lands is an answer that landed.
        case duplicate
        case unknownSession
        /// This tab's agent has no dialog Flight Deck can drive. Codex, and anything newer.
        case unsupportedAgent
        /// Nothing is blocked on this tab right now.
        case notWaiting
        /// A shape this build will not drive — see `PromptQuestion.unanswerable`.
        case unanswerable
        /// The terminal could not be read, the dialog was not on it, the answer named a
        /// different kind of dialog than the one derived, the index or the label named
        /// nothing, or another injection is already resolving for this tab.
        ///
        /// **One code for six states deliberately.** Every one means "not right now, and the
        /// phone should look again", and splitting them would invite a client to treat some as
        /// permanent and stop asking. The distinctions are worth a log line, not a wire code.
        case unreadableScreen

        var errorCode: String? {
            switch self {
            case .dispatched, .duplicate: return nil
            case .unknownSession: return "unknown_session"
            case .unsupportedAgent: return "unsupported_agent"
            case .notWaiting: return "not_waiting"
            case .unanswerable: return "unanswerable"
            case .unreadableScreen: return "unreadable_screen"
            }
        }
    }

    /// Tokens this store has already answered with, per tab. Same shape, same bound and same
    /// reasoning as `acceptedPromptTokens` — see it for why a retry has to be free. A separate
    /// list, because a typed prompt's token and an answer's token are minted by different taps
    /// and a shared list would let one silence the other.
    private var answeredPromptTokens: [UUID: [UUID]] = [:]

    /// Where an aborted drive's description goes. See `AnswerAbort`, and `AnswerAbortLog` for
    /// the two places production puts one.
    ///
    /// A seam on the SINK rather than a `#if DEBUG` around the recording: the failure this
    /// exists for reproduces only on the installed Release build, so what gets recorded must be
    /// identical in both configurations and it is only the destination a test replaces.
    var answerAbortSink: (AnswerAbort) -> Void = AnswerAbortLog.record

    /// A client answered the dialog tab `id` is blocked on.
    ///
    /// `open` is the Mac's **own** derivation, from `PromptService`, never the client's claim.
    /// The command from the phone contributes a tab, a call id (already checked against this
    /// derivation by the caller), an intent, and a token. Nothing a phone sends becomes a label
    /// matched on screen. That is the difference between a remote control and a remote keyboard.
    ///
    /// **The order of the checks is load-bearing twice**, as `submitPrompt`'s is. The
    /// capability test — `AgentAdapter.dialogDriver`, and a `nil` there is the refusal —
    /// precedes the status test, so a tab that happens to be `waiting` on an agent whose
    /// dialogs this build has never read is told `unsupportedAgent` — never on this tab —
    /// rather than being let through to that terminal. And the token test precedes anything
    /// being typed, so a retry types nothing even if the screen has moved on.
    ///
    /// **A different question from `submitPrompt`'s, deliberately.** That one asks for a text
    /// channel; this asks for a dialog driver, and an agent can have the second without the
    /// first — driving a dialog needs no input box and no kill ring, only a screen grammar
    /// and arrows. Collapsing the two back into one capability would make an agent's dialogs
    /// undrivable for a reason that is about its composer.
    ///
    /// Changes no fleet state and emits no `FleetEvent`: what the phone answered becomes
    /// visible through the status the agent writes and the transcript it appends.
    @discardableResult
    func answerPrompt(
        _ open: OpenPrompt, with answer: PromptAnswer, in id: UUID, token: UUID
    ) -> AnswerDispatch {
        guard let at = locate(id) else { return .unknownSession }
        guard let driver = repos[at.repo].sessions[at.session].agent.dialogDriver else {
            return .unsupportedAgent
        }
        if answeredPromptTokens[id, default: []].contains(token) { return .duplicate }
        // `inject`'s gate, inverted. A session that is not `waiting` has no dialog up, and a
        // Return there submits whatever is in the input bar — the exact failure `inject`'s own
        // comment describes from the other side. Escape is gated too: a stray Escape into a
        // live TUI is not free either.
        guard statuses[id]?.activity == .waiting else { return .notWaiting }
        guard let injector = injector(for: id) else { return .unreadableScreen }
        // The same set the other two users of this terminal hold, so a rename or a queued
        // phone prompt mid-settle cannot interleave with a dialog being driven.
        guard !injecting.contains(id) else { return .unreadableScreen }

        switch answer {
        case .deny:
            // **One key event, and nothing is read.** No viewport, no marker, no row
            // arithmetic, no settle, no confirmation pass. This is the path a worried person
            // reaches for, and it is deliberately the one that cannot be wrong about which row
            // it is on. It is also therefore the only answer that works on a screen this build
            // cannot parse at all. Escape is a real denial and not a dismissal: the transcript
            // closes the call `is_error=True "The user doesn't want to proceed with this tool
            // use. The tool use was rejected"`, measured against claude 2.1.241 in Task 3.
            //
            // Routing this through the interlock below for symmetry would be a regression, not
            // a tidy-up: it would make the refusal depend on a parse, so a screen that could
            // not be read would leave a person unable to say no from their phone.
            remember(answered: token, for: id)
            driver.deny(injector)
            return .dispatched

        case .allow:
            // **The approval row, and only ever the approval row.** Both shipped agents order
            // a permission dialog plain-yes / DURABLE GRANT / deny, so the target is
            // `driver.allowRow` and there is no `PromptAnswer` case that names another row
            // and no arithmetic here that can reach one. See `PromptAnswer`'s own comment,
            // and `AgentDialogDriver.allowRow` for why that number has no default: an agent
            // that inherited claude's would be one release away from granting "and don't ask
            // again" from a pocket.
            //
            // The ordering claim is checked against each agent's own captures — claude's by
            // `ChoiceDialogTests.testEveryRealDialogOpensWithTheCursorOnItsFirstRow`, codex's
            // by `CodexDialogDriverTests`. If a future build reorders the dialog, those
            // fixtures fail first — and the driver must be rewritten, not the fixtures.
            //
            // **This interlock is STRUCTURALLY WEAKER than `.option`'s for claude, and saying
            // so is the point.** A claude permission dialog's wording is assembled in the TUI
            // at display time from the live permission rule set, so it exists nowhere Flight
            // Deck can read: no transcript record carries it, and there is therefore no label
            // to confirm the row against. All that can be required after the move is that the
            // marker is ON that row. A screen that renumbered its rows would satisfy that.
            // The two paths are not equally verified and must not be read as if they were.
            guard case .permission = open else { return .unreadableScreen }
            guard let viewport = injector.readViewport(),
                  let current = driver.focusedRow(inViewport: viewport)
            else { return .unreadableScreen }
            return drive(
                from: current, to: driver.allowRow,
                confirm: { driver.focusedRow(inViewport: $0) == driver.allowRow },
                driver: driver, injector: injector, id: id, token: token
            )

        case .answers(let selections):
            // The set path. Everything it needs is checked before a key moves: the answers fit
            // the questions the TRANSCRIPT holds, each label matches this Mac's own copy, and
            // the plan exists at all.
            guard case .question(_, let questions) = open else { return .unreadableScreen }
            guard selections.count == questions.count else { return .unreadableScreen }
            for (question, chosen) in zip(questions, selections) {
                for selection in chosen {
                    guard question.options.indices.contains(selection.index),
                          question.options[selection.index].label == selection.label
                    else { return .unreadableScreen }
                }
            }
            guard let plan = AnswerPlan.plan(
                for: questions, answers: selections.map { $0.map(\.index) }
            ) else { return .unanswerable }
            return drive(plan, questions: questions, driver: driver,
                         injector: injector, id: id, token: token)

        case .option(let index, let label):
            // `option` indexes an `AskUserQuestion`'s own options, so a permission dialog —
            // which has no options this build can enumerate — has no list for the index to
            // mean anything in.
            guard case .question(_, let questions) = open else { return .unreadableScreen }
            // **One question, and this refusal is the guard rail.** `.option` names an index
            // into ONE question's options; a set has several lists and a screen showing
            // whichever of them claude has advanced to, so the index would be counted against
            // the wrong question. Nothing drives a set yet, and refusing here is what keeps a
            // client that tries anyway from typing an answer into the wrong dialog.
            guard questions.count == 1, let question = questions.first else {
                return .unanswerable
            }
            guard question.isAnswerable else { return .unanswerable }
            // **`.option` is a commit, and a checkbox row is not.** On a multiSelect question
            // Enter TOGGLES and stays put (`question-checkbox-toggled.captured.txt`), so this
            // path would tick one box, believe it had answered, and leave the dialog open. A
            // checkbox question is answered through the whole-set payload, which knows to
            // press the action row afterwards.
            guard !question.multiSelect else { return .unanswerable }
            // The client's label against the Mac's own copy, before any screen is consulted.
            // A phone naming words this transcript never carried is a reader looking at
            // something else, and its index is not to be trusted either.
            guard question.options.indices.contains(index),
                  question.options[index].label == label
            else { return .unreadableScreen }
            guard let viewport = injector.readViewport(),
                  let current = driver.focusedRow(inViewport: viewport),
                  // The pre-flight half of the interlock: before counting arrows across a
                  // list, confirm the row the cursor is already on says what this question
                  // says it should. Without it a dialog that has been answered and replaced
                  // would be moved through — two keystrokes into someone else's cursor —
                  // and only the re-read would catch it, too late to have sent nothing.
                  //
                  // A cursor outside the transcript's options is refused rather than counted
                  // from: claude appends rows at display time (`Type something.`, `Chat about
                  // this`) that appear in no transcript, so there is no label to confirm.
                  question.options.indices.contains(current),
                  driver.row(current, reads: question.options[current].label,
                             inViewport: viewport)
            else { return .unreadableScreen }
            return drive(
                from: current, to: index,
                confirm: {
                    driver.focusedRow(inViewport: $0) == index
                        && driver.row(index, reads: label, inViewport: $0)
                },
                driver: driver, injector: injector, id: id, token: token
            )
        }
    }

    /// Move the selection, wait for the repaint, re-read, and only then submit.
    ///
    /// **Measured, not assumed, and the re-read is the whole safety property.** Arrows are
    /// relative: a miscounted, dropped or late-repainted keystroke leaves the marker somewhere
    /// this code cannot know about without looking again. `inject` kills first and compares
    /// because the screen cannot be trusted to say whether the buffer was empty; this moves
    /// first and confirms because the screen cannot be trusted to say whether the keystroke
    /// arrived. Same idiom, same reason, and the consequence of skipping it is a Return on a
    /// row nobody chose.
    ///
    /// A failed confirmation sends nothing further and reports nothing: the answer is already
    /// `dispatched` to the client, the cursor has moved, and a moved cursor is recoverable by
    /// the person at the keyboard in a way a wrong Return is not.
    /// Answer a whole set of questions in one drive.
    ///
    /// **The plan is built first and the screen only ever CHECKS it.** `AnswerPlan` knows
    /// every move and press from the transcript and the reader's choices, so this walks a
    /// fixed program: before each press it confirms the cursor is where the plan says it
    /// starts and that the row about to be pressed reads what the plan says it should. A
    /// disagreement aborts — no further key is sent — rather than being counted from.
    ///
    /// **Nothing is committed until the last step.** claude shows a review screen listing every
    /// question with its chosen answer and asks "Ready to submit your answers?", so an abort
    /// part-way leaves a dialog the human can still finish or cancel. That is why this can be
    /// driven at all: the failure mode is "stopped early", never "half an answer sent".
    private func drive(
        _ plan: AnswerPlan,
        questions: [PromptQuestion],
        driver: any AgentDialogDriver,
        injector: TextInjecting,
        id: UUID,
        token: UUID
    ) -> AnswerDispatch {
        remember(answered: token, for: id)
        injecting.insert(id)
        perform(plan.steps, at: 0, questions: questions, driver: driver, injector: injector, id: id)
        return .dispatched
    }

    /// One step, then the next from inside its settle. Recursive rather than a loop because
    /// each press repaints asynchronously and the next step's checks are only meaningful once
    /// the repaint has landed — the same 120ms seam `injectionSettle` is everywhere else.
    private func perform(
        _ steps: [AnswerPlan.Step],
        at index: Int,
        questions: [PromptQuestion],
        driver: any AgentDialogDriver,
        injector: TextInjecting,
        id: UUID
    ) {
        guard index < steps.count else { injecting.remove(id); return }
        let step = steps[index]

        // One guard per check, where a single compound one would do. The conditions, their
        // order and their short-circuiting are unchanged — what the split buys is a NAME for
        // whichever one refused, because an abort sends no further key and is otherwise
        // indistinguishable from a drive that finished.
        guard let screen = injector.readViewport() else {
            note(.unreadableBeforePress, step: index, step, viewport: nil)
            injecting.remove(id)
            return
        }
        let focused = driver.focusedRow(inViewport: screen)
        guard focused == step.from else {
            note(.cursorBeforePress, step: index, step, focused: focused, viewport: screen)
            injecting.remove(id)
            return
        }
        let expected = Self.rowLabel(for: step, questions: questions)
        guard let expected, driver.row(step.to, reads: expected, inViewport: screen) else {
            note(.labelBeforePress, step: index, step, expected: expected,
                 focused: focused, viewport: screen)
            injecting.remove(id)
            return
        }

        let distance = step.to - step.from
        for _ in 0..<abs(distance) {
            if distance > 0 { injector.sendArrowDown() } else { injector.sendArrowUp() }
        }

        injectionSettle { [weak self] in
            guard let self else { return }
            // Re-read after the move: the row under the cursor must STILL be the one the plan
            // named. This is the check that survives a human touching the terminal mid-drive.
            guard let landed = injector.readViewport() else {
                self.note(.unreadableAfterMove, step: index, step, expected: expected,
                          viewport: nil)
                self.injecting.remove(id)
                return
            }
            let arrived = driver.focusedRow(inViewport: landed)
            guard arrived == step.to else {
                self.note(.landingAfterMove, step: index, step, expected: expected,
                          focused: arrived, viewport: landed)
                self.injecting.remove(id)
                return
            }
            injector.sendReturn()
            self.injectionSettle { [weak self] in
                self?.perform(steps, at: index + 1, questions: questions,
                              driver: driver, injector: injector, id: id)
            }
        }
    }

    /// Files one abort against `answerAbortSink`. A method rather than the literal at each
    /// site: the step is the source of every field except the one that failed, so only the
    /// difference is written out where the drive can be read.
    private func note(
        _ check: AnswerAbort.Check,
        step index: Int,
        _ step: AnswerPlan.Step,
        expected: String? = nil,
        focused: Int? = nil,
        viewport: String?
    ) {
        answerAbortSink(AnswerAbort(
            check: check, step: index, purpose: step.purpose, from: step.from, to: step.to,
            expected: expected, focused: focused, viewport: viewport
        ))
    }

    /// What the row a step is about must read, or `nil` when the plan is inconsistent with the
    /// questions — which `AnswerPlan.plan` already refuses to produce, so it is a belt on a
    /// brace.
    static func rowLabel(
        for step: AnswerPlan.Step, questions: [PromptQuestion]
    ) -> String? {
        switch step.purpose {
        case .option(let question, let option):
            guard questions.indices.contains(question),
                  questions[question].options.indices.contains(option) else { return nil }
            return questions[question].options[option].label
        case .action(_, let isLast):
            return AnswerPlan.actionLabel(isLast: isLast)
        case .submit:
            return AnswerPlan.submitAnswersLabel
        }
    }

    private func drive(
        from current: Int,
        to target: Int,
        confirm: @escaping (String) -> Bool,
        driver: any AgentDialogDriver,
        injector: TextInjecting,
        id: UUID,
        token: UUID
    ) -> AnswerDispatch {
        remember(answered: token, for: id)
        injecting.insert(id)

        let steps = target - current
        for _ in 0..<abs(steps) {
            if steps > 0 { injector.sendArrowDown() } else { injector.sendArrowUp() }
        }

        // Claude Code repaints asynchronously — the same seam, and the same 120ms in
        // production, that a kill waits out.
        injectionSettle { [weak self] in
            defer { self?.injecting.remove(id) }
            // Split for the reason `perform`'s is, and one more: `confirm` is a closure the
            // caller composed, so the only thing that can be said about its refusal here is
            // where the marker ended up — which is worth saying, because that is the number
            // the caller disagreed with.
            guard let screen = injector.readViewport() else {
                self?.answerAbortSink(AnswerAbort(
                    check: .unreadableAfterMove, step: nil, purpose: nil,
                    from: current, to: target, expected: nil, focused: nil, viewport: nil
                ))
                return
            }
            guard confirm(screen) else {
                self?.answerAbortSink(AnswerAbort(
                    check: .landingAfterMove, step: nil, purpose: nil,
                    from: current, to: target, expected: nil,
                    focused: driver.focusedRow(inViewport: screen), viewport: screen
                ))
                return
            }
            injector.sendReturn()
        }
        return .dispatched
    }

    /// Files an answered token against a tab, oldest evicted first. See `answeredPromptTokens`.
    private func remember(answered token: UUID, for id: UUID) {
        var tokens = answeredPromptTokens[id, default: []]
        tokens.append(token)
        if tokens.count > Self.maxRememberedPromptTokens {
            tokens.removeFirst(tokens.count - Self.maxRememberedPromptTokens)
        }
        answeredPromptTokens[id] = tokens
    }

    /// Types `text` into a session's input box and submits it, preserving whatever draft was
    /// there. Returns false when this is a bad moment — nothing was sent, and the caller
    /// should leave its request pending and try again on a later tick.
    ///
    /// The gates, and why each one:
    ///
    /// - **An agent with a text channel only.** What gets typed, and how, is *the agent's* —
    ///   claude's is `InputBar`'s one-row box and a kill-and-yank dance that works only
    ///   because Claude Code keeps a deleted-text ring — and this is reached from callers
    ///   that carry no agent at all: `flushPendingPrompts` drains a queue seeded by
    ///   `restore`, and `flushPendingRename` drains one seeded by a keystroke. This is the
    ///   single funnel both pass through, so it is the one place that can refuse a terminal
    ///   this build cannot read, and `AgentID.textChannel` is the question it asks — a `nil`
    ///   there is the whole refusal.
    ///
    ///   **Widening this back out is not the cautious move.** Nothing codex has goes through
    ///   here: `sendToShell` types resume commands and `initialInput` directly at the pty and
    ///   never touches this funnel, and `CodexAdapter.loginInvocation` has `inject: nil`, so
    ///   no codex sign-in text is ever queued either. What passes through today is claude's
    ///   `/login`, claude's `/rename`, a restore's "Keep going" and a phone's message — all
    ///   of them claude's, all of them typed into a box only claude's grammar can find.
    /// - **Idle only.** While `busy` the text queues behind the running turn; while
    ///   `waiting` a Return answers a permission prompt or dialog instead of submitting;
    ///   `shell` was `idle` plus a background task — the turn had already finished, so the
    ///   text was always safe to type — and no longer exists as an activity at all.
    ///
    /// Everything past those two gates — finding the input box, the kill, the settle, the
    /// before/after comparison and the yank — is `AgentTextChannel.submit`'s, and the reasons
    /// each step is shaped the way it is live with it in `ClaudeTextChannel`.
    ///
    /// `stillWanted` is re-checked after the settle delay, because the request can be
    /// replaced or cancelled while the agent repaints. `onSent` runs once the text has been
    /// submitted, and is where the caller retires its pending entry.
    @discardableResult
    private func inject(
        _ text: String,
        into id: UUID,
        allowMidTurn: Bool = false,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool {
        // **`.busy` is allowed, into an empty box only.** This required `.idle`, and that is
        // why a prompt sent from the phone could be accepted and then quietly die: the queue
        // drained only when the tab reached idle, so a tab running back-to-back turns never
        // drained it and the entry expired at `phonePromptWindow` having never been typed —
        // while the same text typed at the Mac worked, because the agent queues mid-turn.
        //
        // The empty-box condition is the whole safety story for typing into a running turn.
        // `submit`'s kill-and-yank can restore a draft when the screen is settled; mid-turn it
        // is reading a screen that is repainting, so a draft is deferred rather than risked.
        //
        // `.waiting` stays refused, and that is why this is a whitelist rather than `!= .idle`.
        // A waiting tab has a select-list dialog up: text typed there goes to the dialog and
        // the Return after it PICKS AN OPTION. Answering a dialog is `answerPrompt`'s job,
        // behind an interlock that reads the screen before committing — a prompt must never
        // become an answer by arriving at the wrong moment.
        guard let channel = session(for: id)?.agent.textChannel,
              let activity = statuses[id]?.activity,
              activity == .idle || activity == .busy,
              let injector = injector(for: id)
        else { return false }
        // Mid-turn is for PROMPTS, not for everything that types. A rename is `/rename x`,
        // a slash command whose effect the user is watching for, and queueing it behind a
        // running turn to land minutes later is worse than waiting for the box. A prompt is
        // the opposite: it is a message to the agent, and landing in its queue is exactly
        // where the sender wanted it.
        if activity == .busy {
            guard allowMidTurn, channel.isComposerEmpty(injector) else { return false }
        }
        // See `injecting`'s doc comment: this is the one place both callers funnel through,
        // so it is the one place that can refuse a second injection for a tab that already
        // has one resolving.
        guard !injecting.contains(id) else { return false }

        // Marked before the channel is asked, and cleared again if it refuses: the channel's
        // contract is that it settles exactly once iff it returns true (see
        // `AgentTextChannel.submit`), so the mark is retired either here or inside that
        // settle and never both.
        injecting.insert(id)
        let started = channel.submit(
            text, into: injector,
            settle: { [weak self] work in
                self?.injectionSettle {
                    defer { self?.injecting.remove(id) }
                    work()
                }
            },
            stillWanted: stillWanted, onSent: onSent
        )
        if !started { injecting.remove(id) }
        return started
    }

    /// Types a pending rename into a session, or leaves it pending if this is a bad moment.
    private func flushPendingRename(_ id: UUID) {
        guard let name = pendingRenames[id] else { return }
        inject(
            "/rename \(name)",
            into: id,
            // A second rename during the settle window replaces the first; typing the
            // superseded name would be wrong, and typing both in turn worse.
            stillWanted: { [weak self] in
                guard let self else { return false }
                return self.pendingRenames[id] == name
            },
            onSent: { [weak self] in self?.pendingRenames[id] = nil }
        )
    }

    /// Retries every deferred rename. Driven by the registry scan, which is what turns a
    /// deferral into a delay rather than a loss.
    private func flushPendingRenames() {
        for id in pendingRenames.keys { flushPendingRename(id) }
    }

    /// Types every queued prompt that is finally ready for it.
    ///
    /// Driven by the registry scan because a queued prompt usually waits on an agent that has
    /// not finished booting — which is not a status change, so gating the retry on one would
    /// strand it.
    ///
    /// No agent test of its own: `inject`'s first gate is the one that refuses a terminal
    /// this build cannot type into, and it is deliberately there rather than here so
    /// `flushPendingRename` is covered by the same guard. An entry that cannot be typed sits
    /// until its deadline and is dropped unsent, which is what this loop already does with
    /// one that never becomes injectable.
    private func flushPendingPrompts() {
        let currentTime = now()
        for (id, prompt) in pendingPrompts {
            guard currentTime < prompt.deadline else {
                // Dropped unsent. See `resumePromptWindow`.
                pendingPrompts.removeValue(forKey: id)
                continue
            }
            // A rename is a direct user action and wants the same input box. It will clear
            // itself within a tick or two, and this is queued anyway.
            guard pendingRenames[id] == nil else { continue }
            inject(
                prompt.text,
                into: id,
                // Cancelled during the settle window — the session started working on its
                // own, or the deadline passed on another path.
                stillWanted: { [weak self] in self?.pendingPrompts[id] != nil },
                onSent: { [weak self] in self?.pendingPrompts.removeValue(forKey: id) }
            )
        }
    }

    /// Drops a queued prompt for any session that has started working on its own.
    ///
    /// Covers both the user getting there first and a resumed `claude` picking its own turn
    /// back up: either way something is already in flight, and "Keep going" would be a second
    /// instruction on top of it. Conservative on purpose — a session that flickers through
    /// `busy` while booting loses its prompt, which is a silent no-op rather than a stray
    /// message typed into someone's work.
    private func cancelSupersededPrompts(_ transitions: [StatusTransition]) {
        guard !pendingPrompts.isEmpty else { return }
        for transition in transitions {
            switch transition.new?.activity {
            case .busy, .waiting:
                pendingPrompts.removeValue(forKey: transition.id)
            case .idle, nil:
                continue
            }
        }
    }

    /// Claude → sidebar. Applied from the transcript watcher; never injects.
    /// The equality check is the loop guard: a `custom-title` line caused by our own
    /// `rename` matches the title we already set and stops here.
    func applyExternalTitle(_ id: UUID, _ title: String) {
        guard let at = locate(id),
              let name = repos[at.repo].sessions[at.session].agent.sanitizedTitle(title),
              repos[at.repo].sessions[at.session].title != name
        else { return }

        repos[at.repo].sessions[at.session].title = name
        emit(.renamed(id: id, title: name, origin: .agent))
        persist()
    }

    /// Tabs sharing a conversation with another tab. Computed rather than stored so it can
    /// never go stale: `repos` is `@Published`, so any change to a pin or to the list
    /// re-evaluates this on the next view update.
    var conflictedSessionIDs: Set<UUID> {
        ConversationPin.conflicted(repos.flatMap(\.sessions))
    }

    /// Tabs running as a login their own project would not have picked today — a work session
    /// left open in a personal repo, or the reverse. Empty whenever there is no
    /// `PreferencesStore` to resolve against, same as `conflictedSessionIDs` degrades to
    /// nothing rather than guessing.
    var accountMismatchedSessionIDs: Set<UUID> {
        guard let preferences else { return [] }
        return Set(repos.flatMap { repo in
            repo.sessions.filter { session in
                let sessionAccount = preferences.resolvedAccountID(for: session.agent, in: session.accountID)
                let projectAccount = preferences.account(for: session.agent, project: repo.url.path)?.id
                return SidebarRow.accountMismatched(session: sessionAccount, project: projectAccount)
            }.map(\.id)
        })
    }

    /// The project new-session UI reasons about when nothing else names one explicitly: the
    /// active session's project, else the last one that was active, else the first repo.
    /// Mirrors `createFromMenu`'s own routing (which folder a new tab lands in) but has no
    /// side effects — no folder picker, no creation — so `SessionSidebar`'s account dropdown
    /// and `SessionCommands`'s File menu can both ask "which project" without duplicating that
    /// walk or triggering it.
    var currentProjectPath: String? {
        if let activeID = selectedSessionID, let at = locate(activeID) {
            return repos[at.repo].sessions[at.session].workingDirectory
        }
        if let url = lastActiveProjectURL, indexOfRepo(for: url) != nil {
            return url.path
        }
        return repos.first?.url.path
    }

    /// The project the window title names — the display name of the repo the ACTIVE session
    /// is filed under, and nil when nothing is selected.
    ///
    /// Deliberately not `currentProjectPath`'s walk. That property answers "where would a new
    /// tab land", so it falls back to the last active project and then to the first repo,
    /// which is right for ⌘N and wrong for a title: with the selection cleared the detail pane
    /// shows the "No Session" empty state, and a title still naming a project would be telling
    /// the user they are somewhere they are not.
    ///
    /// Reads the repo's `displayName` rather than deriving a name from the session's
    /// `workingDirectory`. The two disagree once an agent follows itself into a worktree —
    /// `transcriptDirectory` moves to `<project>/.claude/worktrees/<name>`, and a title built
    /// from a path would start naming the worktree instead of the project the sidebar files
    /// the tab under.
    var currentProjectName: String? {
        guard let activeID = selectedSessionID, let at = locate(activeID) else { return nil }
        return repos[at.repo].displayName
    }

    func status(for id: UUID) -> SessionStatus? { statuses[id] }

    /// The tab's terminal screen, or nil when there is no surface or it cannot be read.
    ///
    /// A read and only a read: it changes no fleet state and adds no mutation site for
    /// `FleetReplicator`'s DEBUG drift check.
    func viewport(of id: UUID) -> String? { injector(for: id)?.readViewport() }

    func sessionExists(_ id: UUID) -> Bool { locate(id) != nil }

    /// The project half of `sessionExists`, for the commands whose only precondition is that
    /// their target still exists. A phone can hold a snapshot older than a project's removal.
    func projectExists(_ id: Repo.ID) -> Bool { repos.contains { $0.id == id } }

    /// Where project `id` lives, or nil if there is no such project. The path is what the
    /// preference lookups are keyed on — agent order and resolved accounts are both per
    /// project directory — so a caller holding only an id needs this to ask them anything.
    func projectPath(_ id: Repo.ID) -> String? {
        repos.first { $0.id == id }?.url.path
    }

    /// Switches registry polling on and covers the tabs that already exist. Called from the
    /// production convenience init only, so tests using `init(provider:persistence:)` never
    /// touch the real registry or spin a timer.
    ///
    /// A sweep rather than a single watcher: restore has already put every tab back by the
    /// time this runs, and each login among them has its own registry to scan. Tabs created
    /// after this point are picked up by `startWatching(tabID:)`.
    func startStatusWatching() {
        isStatusWatchingEnabled = true
        for session in repos.flatMap(\.sessions) where session.agent.hasStatusRegistry {
            startStatusWatching(account: instance(for: session).account)
        }
    }

    /// Builds this account's registry watcher on first ask and memoizes it — the same
    /// once-per-account guard `makeCodexStackIfNeeded` keeps, and for a sharper reason: a
    /// watcher registers itself on the shared `WatchClock`, so a second one for an account
    /// that already has one polls for the rest of the run with nothing holding a reference
    /// able to stop it.
    ///
    /// Silent until `startStatusWatching()` has run. Watchers are created on the tab path now
    /// rather than once at launch, and a test that made a claude tab must not thereby start
    /// scanning the developer's live registry.
    private func startStatusWatching(account: UUID?) {
        guard isStatusWatchingEnabled, statusWatchers[account] == nil else { return }
        let watcher = SessionStatusWatcher(
            root: statusRoot(forAccount: account),
            isAlive: statusIsAlive ?? SessionStatusWatcher.processIsAlive,
            clock: clock
        ) { [weak self] entries in
            self?.applyRegistry(entries, from: account)
        }
        watcher.start()
        statusWatchers[account] = watcher
    }

    /// Stops one account's registry scan once that account's last claude tab is gone — the
    /// claude half of `stopCodexIfUnused`, narrowed the same way. Only the closing tab's own
    /// account can have just lost its last tab.
    ///
    /// Its rows go with it: leaving them in `registryRows` would keep merging a dead login's
    /// last scan into every later tick, and pids get reused.
    private func stopStatusWatchingIfUnused(account: UUID?) {
        guard let watcher = statusWatchers[account] else { return }
        guard !repos.flatMap(\.sessions).contains(where: {
            $0.agent.hasStatusRegistry && instance(for: $0).account == account
        }) else { return }
        watcher.stop()
        statusWatchers[account] = nil
        registryRows[account] = nil
    }

    /// One account's scan, merged with every other account's before it becomes status. See
    /// `registryRows` for why the merge is not optional.
    private func applyRegistry(_ rows: [pid_t: ClaudeStatusFile.Entry], from account: UUID?) {
        registryRows[account] = rows
        guard registryRows.count > 1 else { return applyRegistry(rows) }
        applyRegistry(registryRows.values.reduce(into: [:]) { merged, rows in
            merged.merge(rows) { _, newer in newer }
        })
    }

    /// Rebuilds `statuses` from a registry scan and keeps each tab's anchor current.
    /// Entries for processes Flight Deck does not own are dropped: the registry lists
    /// every `claude` on the machine.
    func applyRegistry(_ rows: [pid_t: ClaudeStatusFile.Entry]) {
        // Quitting: see `isTerminating`'s doc comment. A tick landing here reads an emptied
        // registry, not a real one — returning before even the `defer` below runs is
        // deliberate, so nothing clears a mark or persists over the state auto-resume wants.
        guard !isTerminating else { return }
        // The scan is also the retry tick for deferred renames. `defer` because this method
        // returns early when nothing changed, and a rename usually waits on something that
        // never shows up in `statuses` at all — the user clearing their half-typed draft
        // moves no status, so gating the retry on a status change would strand it.
        defer {
            flushPendingRenames()
            // Same reason as the line above: this is the retry tick, and a prompt usually
            // waits on a `claude` that has not finished booting — which is not a status
            // change, so gating the retry on one would strand it.
            flushPendingPrompts()
            // And the phone's queue, for the same reason and one more: what a phone-sent
            // prompt waits on is usually a turn ENDING, and the tick is where that is seen.
            flushPromptQueue()
        }

        // Resolve against a snapshot of the list before touching anything. Later tasks
        // apply repins and project moves here, and those mutate `repos` — iterating it
        // while it changes would resolve some tabs against a stale view.
        //
        // **Filtered by the same capability as the status rebuild below, and that closes a
        // drift rather than changing an outcome.** These rows are a scan of `claude`
        // processes, so a tab on an agent with no such registry has nothing here that could
        // describe it: the match is `sessionID == pinnedConversationID`, and a claude
        // conversation UUID colliding with a codex thread UUID is not a thing. So codex
        // always resolved `unchanged` and all three branches below found nothing to do —
        // safe by UUID improbability rather than by a guard, while the loop sixty lines down
        // *was* guarded. Two loops over one list, one gated and one not, is how they come
        // apart; and were this one ever to fire, `repin` would hand a codex rollout to
        // `ConversationTitle.resolve`, which is a claude JSONL parser.
        let resolutions: [(tab: UUID, resolution: ConversationPin.Resolution)] =
            repos.flatMap(\.sessions).filter(\.agent.hasStatusRegistry).map { session in
                (session.id, ConversationPin.resolve(
                    conversationID: session.pinnedConversationID,
                    // The transcript directory, not the project: this is the value echoed
                    // back when no row names one, and what comes back feeds
                    // `ClaudeSession.transcriptURL`. Passing the project would move a
                    // worktree session's watcher back onto the project's transcript the
                    // first time a row omitted its cwd.
                    transcriptDirectory: session.transcriptDirectory,
                    anchor: anchors[session.id],
                    rows: rows
                ))
            }
        // Two independent questions per tab, because a reported cwd now answers both: where
        // `claude` is writing (the transcript always follows it) and which project the tab
        // is filed under (it moves only into a project that is already open).
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
            guard let session = session(for: tab) else { continue }
            // Safe on every tick: it is the tab's own transcript directory echoed back when
            // no row named one, so the two branches below simply find nothing to do.
            let cwd = resolution.transcriptDirectory
            if resolution.conversationID != session.pinnedConversationID {
                // `repin` stores this same directory and rebuilds the watcher from it, so
                // the retarget below would stop and restart an identical watcher. `else`
                // rather than a second `if` keeps exactly one owner of "who repoints this
                // tab's watcher" per tick — which is the assumption the deferral in
                // `repin`'s async title-read completion is written against.
                repin(tab, to: resolution.conversationID, transcriptDirectory: cwd)
            } else if !cwd.isEmpty, cwd != session.transcriptDirectory {
                // Compared raw, deliberately, unlike the project comparison below:
                // `ClaudeSession.encodedProjectDirName` is a byte-for-byte encoding of this
                // exact string, so two paths that `comparablePath` calls equal (a symlink
                // and its target) name two different transcript files. Normalizing here
                // would leave a project opened through a symlink watching a path `claude`
                // never writes to.
                retarget(tab, to: cwd)
            }
            // `reportedDirectory`, emphatically not `cwd`: refiling a tab is the one decision
            // here that must fire only on new information. `cwd` is the echo above, so on a
            // tick that reported nothing — no rows at all, or a live row with an empty `cwd`
            // — it comes back naming the tab's *transcript* directory, and a tab whose
            // transcript is inside a worktree the user still has open as a project would be
            // refiled into it on no evidence at all. Before the split the echo was the tab's
            // own project and always compared equal, which is why this branch could read it.
            //
            // A cwd that matches no open project still creates nothing — that is what filed
            // a tab under a phantom project every time `EnterWorktree` ran. Moving into a
            // project that is *already* open remains allowed: the resumed-into-another-
            // project case §7 of the pinning design describes.
            if let reported = resolution.reportedDirectory,
               Self.comparablePath(reported) != Self.comparablePath(session.workingDirectory),
               let destination = indexOfRepo(
                   for: URL(fileURLWithPath: reported, isDirectory: true)
               ) {
                // The repo's own recorded path, not the row's cwd: they differ when the
                // project was opened through a symlink, and filing the tab under the
                // resolved path would leave `Repo.url` and `Session.workingDirectory`
                // disagreeing about the project they both name.
                moveSession(tab, toProjectAt: repos[destination].url)
            }
        }

        var next: [UUID: SessionStatus] = [:]
        var nextBackgroundWork: Set<UUID> = []
        for session in repos.flatMap(\.sessions) {
            // A tab on an agent that has no claude status registry behind it keeps whatever
            // its runtime last reported. This scan can neither confirm nor refute a codex
            // thread — it lists `claude` processes — so rebuilding blindly would erase a
            // codex tab's status on every tick and hand the diff below a fabricated
            // `busy → gone` edge, marking it unread and withdrawing its banner on no
            // evidence at all.
            guard session.agent.hasStatusRegistry else {
                next[session.id] = statuses[session.id]
                continue
            }
            guard let anchor = anchors[session.id], let entry = rows[anchor.pid] else {
                continue
            }
            next[session.id] = SessionStatus(
                activity: entry.activity,
                waitingFor: entry.waitingFor,
                subagentCount: subagentCounts[session.id] ?? 0
            )
            // Latched, not rebuilt: `false` from the registry means "not reported", and only
            // an idle tick is proof the task ended. See `backgroundWorkSessions`.
            if entry.reportsBackgroundWork {
                nextBackgroundWork.insert(session.id)
            } else if entry.activity != .idle, backgroundWorkSessions.contains(session.id) {
                nextBackgroundWork.insert(session.id)
            }
        }

        commitStatuses(next, backgroundWork: nextBackgroundWork)

        // Driven off this same tick, deliberately not a second timer: one poll of two
        // directories (the registry above, `PlannotatorRegistry` inside `refresh()`) is
        // cheaper than two, and two would let a gate and a status be read at different
        // instants — see the brief this method was written against.
        pollPlanGates()
    }

    /// Re-reads `PlannotatorRegistry` through `planGates` and delivers any resulting
    /// notification. Fire-and-forget: this tick's caller (`applyRegistry`) does not await it,
    /// the same way `.newSession`'s command handler does not await its own dispatch — a poll
    /// that is a tick late is a poll, not a failure.
    private func pollPlanGates() {
        guard let planGates else { return }
        Task { @MainActor [weak self] in
            await planGates.refresh()
            self?.deliverPlanGateNotifications()
        }
    }

    /// The plan-gate half of `deliverNotifications`, and why it cannot be folded into that
    /// one method: a gate opening moves neither `statuses` nor `backgroundWorkSessions` —
    /// claude's registry still reports `busy` while a gate is open, which is the defect this
    /// feature exists to fix — so `commitStatuses`'s diff never produces a `StatusTransition`
    /// for it. This runs on its own tick, after `refresh()`, against its own remembered map of
    /// what each session's gate was last time, so a re-poll of an unchanged gate is not a
    /// re-notify and a closed one still gets its banner withdrawn.
    ///
    /// **Emits `.planGateChanged` on every real change, independent of `notifier`.** The wire
    /// event is what lets `FleetSnapshot.apply` fold `planGate` at all — without it, a client
    /// resuming from a replay window never learns a gate opened or closed, and the projection
    /// oracle (which reads `planGates` live) permanently disagrees with the event-fold mirror.
    /// That has to hold even when this Mac has no local notifier — a headless `SessionStore`,
    /// or one under test — so only the OS-banner half below is gated on `notifier`'s presence.
    ///
    /// **Batched into one `emit`, not one per session — the same reason `emitActivity` batches
    /// its whole transition list.** `refresh()` (the caller's caller, `pollPlanGates()`) already
    /// updated `planGates.gates` for every session before this method runs, so the oracle's
    /// live read reflects *all* of this tick's changes from the first line. Emitting per
    /// session inside the loop would `record([event])` — and therefore `checkForDrift()` — one
    /// session at a time: the very first emit, for session A, would already see the oracle
    /// projecting session B's new gate while the mirror still held B's old one (no event for B
    /// has been recorded yet), and trip the DEBUG drift assertion on two gates changing in one
    /// tick. Collecting the events and emitting once after the loop folds the whole tick before
    /// any drift check runs, closing that window the same way `emitActivity` already does for
    /// activity transitions. Not `internal` for the batching to hold, `func` rather than
    /// `private` only so `FleetService` can call this directly after a successful
    /// `annotate`/`resolve` — see the doc comment there for the matching window on that path.
    func deliverPlanGateNotifications() {
        guard let planGates else { return }
        let active = appIsActive()
        var events: [FleetEvent] = []
        for id in repos.flatMap(\.sessions).map(\.id) {
            let gate = planGates.gate(for: id)
            let previous = previousPlanGates[id]
            // Unchanged: `old.status == new.status` always below (both read `statuses[id]` at
            // this same instant), so when the gate itself has not moved, `action` was already
            // guaranteed `.none` — this is a fast path, not a behavior change.
            guard gate != previous else { continue }
            previousPlanGates[id] = gate

            events.append(.planGateChanged(id: id, gate: gate))

            guard let notifier else { continue }
            let old = SessionNotificationPolicy.Input(status: statuses[id], planGate: previous)
            let new = SessionNotificationPolicy.Input(status: statuses[id], planGate: gate)
            switch SessionNotificationPolicy.action(old: old, new: new, appActive: active) {
            case .none:
                continue
            case .notify:
                guard let named = titleAndProject(of: id) else { continue }
                notifier.notify(
                    sessionID: id, title: named.title, subtitle: named.project,
                    body: "A plan is ready for your review."
                )
            case .withdraw:
                notifier.withdraw(sessionID: id)
            }
        }
        emit(events)
    }

    /// The single writer of `statuses`, and the one place a status change turns into its
    /// consequences.
    ///
    /// Every caller hands over a whole rebuilt map rather than a single edit, because every
    /// consequence below is read off the *diff*: an unread mark, a notification, a superseded
    /// resume prompt and the save are all decided per transition. A caller that wrote
    /// `statuses` directly instead would skip all of it — and worse, its value would become
    /// the `previous` snapshot the next tick diffs against, so a later tick could fabricate
    /// or swallow an edge that never happened.
    private func commitStatuses(_ next: [UUID: SessionStatus], backgroundWork: Set<UUID>) {
        let previous = statuses
        let previousBackgroundWork = backgroundWorkSessions
        let previousOpenPromptCalls = openPromptCalls
        // Installed **above** the guard rather than below it, because the third axis is
        // derived FROM them: `openPromptCallReader` asks this store what each tab is doing,
        // and asking it against the statuses this tick is replacing would report no dialog on
        // the very tick a tab first blocks — a card a poll late for no reason. Written through
        // an equality check so an unchanged tick still publishes nothing, which is what the
        // single `guard` used to buy: both of these are `@Published`, and re-assigning an
        // equal value at 2 Hz would invalidate the whole sidebar twice a second.
        if next != statuses { statuses = next }
        if backgroundWork != backgroundWorkSessions { backgroundWorkSessions = backgroundWork }
        openPromptCalls = derivedOpenPromptCalls()
        // THREE axes, not one. A task starting or ending under an otherwise-idle tab moves
        // only `backgroundWork` — guarding on `statuses` alone swallowed that tick entirely,
        // so the badge never lit and no event ever reached the phone. One dialog replaced by
        // the next moves only `openPromptCalls`: same activity, often the same `waitingFor`,
        // and until this axis existed the tick was swallowed the same way, leaving a phone
        // holding a card for a dialog that was gone.
        guard next != previous
            || backgroundWork != previousBackgroundWork
            || openPromptCalls != previousOpenPromptCalls
        else { return }
        // A session that HAD a status and no longer does means its `claude` exited.
        // Drop its sub-agent count too, so a later process reusing the same session
        // UUID does not inherit a count from the dead one. Counts for sessions that
        // never had a status are deliberately left alone — that is the
        // count-arrives-before-registry case.
        for id in previous.keys where next[id] == nil {
            subagentCounts.removeValue(forKey: id)
        }
        // Also `emitActivity`'s second and third axes, below: a tick can move either of these
        // alone, with every `SessionStatus` unchanged, and that tick still has to reach the
        // wire.
        let backgroundWorkChanged = previousBackgroundWork.symmetricDifference(backgroundWork)
        let openPromptChanged = Set(previousOpenPromptCalls.keys).union(openPromptCalls.keys)
            .filter { previousOpenPromptCalls[$0] != openPromptCalls[$0] }
        // `openPromptChanged` is deliberately not unioned in: a tab with a dialog has a status,
        // so it is already in `next.keys`, and adding it would only be a way for this set to
        // disagree with itself.
        let touched = Set(previous.keys)
            .union(next.keys)
            .union(backgroundWorkChanged)
        let transitions = touched.map {
            StatusTransition(id: $0, old: previous[$0], new: next[$0])
        }
        // Emitted first, ahead of `applyReadState`: `statuses` above is already mutated for
        // every session in this tick, so the fleet's activity fields are already "actual"
        // before any event has recorded them. `applyReadState` below records its own event
        // per transition as it goes (through `setUnread`), and the DEBUG drift check runs
        // after every one of those — if it ran before this, it would catch the live
        // activity having changed with no event on the wire for it yet, which is real
        // drift, just not a bug: the fix is recording activity first, not silencing the
        // check.
        emitActivity(transitions, backgroundWorkChanged: backgroundWorkChanged,
                     openPromptChanged: openPromptChanged)
        applyReadState(transitions)
        deliverNotifications(transitions)
        cancelSupersededPrompts(transitions)
        // Below the three-axis guard above, so this writes only on a real transition — a
        // handful of small atomic writes a minute, not one per poll.
        // Recording activity here rather than at quit is what covers a SIGKILL (which is
        // how scripts/swap-release.sh stops the app) and a panic, and an unplanned exit is
        // the case auto-resume is most wanted for.
        persist()
    }

    /// One read/unread decision per session, over every edge this tick produced.
    private func applyReadState(_ transitions: [StatusTransition]) {
        let active = appIsActive()
        for transition in transitions {
            switch SessionReadPolicy.change(
                old: transition.old, new: transition.new,
                isViewed: active && selectedSessionID == transition.id
            ) {
            case .none:
                continue
            case .mark:
                setUnread(transition.id, true)
            case .clear:
                setUnread(transition.id, false)
            }
        }
    }

    /// One notification decision per session, over every edge this tick produced — so a
    /// session that vanished while waiting still gets its banner withdrawn.
    private func deliverNotifications(_ transitions: [StatusTransition]) {
        guard let notifier else { return }
        let active = appIsActive()
        for transition in transitions {
            // **The session's CURRENT gate on both sides, not `nil` on both sides.** This
            // pipeline only ever sees status edges — a gate opening moves neither `statuses`
            // nor `backgroundWorkSessions`, so it produces no `StatusTransition` at all, and
            // `deliverPlanGateNotifications` is where that half of `Input` changes. But
            // `wantsYou` is *"waiting OR a gate"*, so passing `nil` here does not mean "the
            // gate is not this pipeline's business", it means "there is no gate" — and a
            // `waiting`→`busy` edge under an open gate then computed
            // `true`→`false` = `.withdraw`, pulling the banner off a plan still waiting to be
            // read. Nothing could put it back: the gate itself had not changed, so
            // `deliverPlanGateNotifications`'s `guard gate != previous` skips the session
            // forever after. Identical on both sides is what makes this pipeline blind to
            // gates instead of wrong about them — same `wantsYou`, same `subject`, so a
            // status edge under a standing gate neither re-notifies nor withdraws.
            let gate = planGates?.gate(for: transition.id)
            switch SessionNotificationPolicy.action(
                old: .init(status: transition.old, planGate: gate),
                new: .init(status: transition.new, planGate: gate),
                appActive: active
            ) {
            case .none:
                continue
            case .notify:
                guard let status = transition.new, let named = titleAndProject(of: transition.id)
                else { continue }
                notifier.notify(
                    sessionID: transition.id, title: named.title,
                    subtitle: named.project, body: status.tooltip
                )
            case .withdraw:
                notifier.withdraw(sessionID: transition.id)
            }
        }
    }

    /// The fourth consumer of a tick's transitions, and the only one of the four that also
    /// answers to `backgroundWorkChanged`: `SessionStatus` equality is silent about the
    /// background flag, so a tick that moves only that set produces transitions with
    /// `old == new` throughout. Filtering on `old != new` alone would drop it — the sidebar
    /// (Task 5) would still update, because it reads `backgroundWorkSessions` directly, but a
    /// connected phone would hear nothing until some other field on that session happened to
    /// change too. `openPromptChanged` is the same argument again for a different field, and
    /// the one this Mac's stale-card reports were about: which dialog is up is invisible to
    /// `SessionStatus` equality, so a supersede produces `old == new` throughout too.
    /// `changed` is therefore three axes, not one: it does not read off quite the same diff
    /// `applyReadState`, `deliverNotifications` and `cancelSupersededPrompts` do.
    private func emitActivity(
        _ transitions: [StatusTransition], backgroundWorkChanged: Set<UUID>,
        openPromptChanged: Set<UUID>
    ) {
        let changed = transitions.filter {
            $0.old != $0.new
                || backgroundWorkChanged.contains($0.id)
                || openPromptChanged.contains($0.id)
        }
        emit(changed.map { transition in
            .activityChanged(
                id: transition.id,
                // nil rather than "idle": no status means no agent process, and the two
                // render differently.
                activity: transition.new?.activity.rawValue,
                waitingFor: transition.new?.waitingFor,
                subagentCount: transition.new?.subagentCount ?? 0,
                hasBackgroundWork: backgroundWorkSessions.contains(transition.id),
                openPromptCall: openPromptIdentity(of: transition.id)
            )
        })
    }

    /// Which dialog every blocked tab is on, as this Mac reads it right now.
    ///
    /// **Re-derived on every commit and never cached, exactly as `PromptService` re-derives on
    /// every answer** — see that type for why a `served` table fails the case this whole
    /// feature is about: claude answers one dialog and raises the next without the session
    /// leaving `waiting`, and a cache still matches while a re-derivation does not.
    ///
    /// Only `waiting` tabs are asked, so the cost is bounded to the state a human is being
    /// waited on in: an idle or busy fleet reads nothing at all, and the tail a blocked tab
    /// does cost is `PromptService.tailRecords` records once per poll for as long as its
    /// dialog is up. `openPromptCallReader` refuses a codex tab on the agent alone, before any
    /// transcript is resolved, so an agent this build cannot read a dialog for is free too.
    private func derivedOpenPromptCalls() -> [UUID: String] {
        var derived: [UUID: String] = [:]
        for (id, status) in statuses where status.activity == .waiting {
            derived[id] = openPromptCallReader(id)
        }
        return derived
    }

    /// One tab's identity as it goes on the wire. Never `.unreported` — this build always
    /// looks, so nothing found is this Mac asserting there is nothing to answer, which is the
    /// assertion that retires a phone's card. Same rule `FleetProjection` states.
    private func openPromptIdentity(of id: UUID) -> OpenPromptIdentity {
        openPromptCalls[id].map(OpenPromptIdentity.call) ?? .noPrompt
    }

    /// Click-to-activate. The window ordering is the AppDelegate's job; this only moves
    /// the selection.
    private func observeActivationRequests() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: .flightDeckActivateSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?["sessionID"] else { return }
            let id = (raw as? UUID) ?? (raw as? String).flatMap(UUID.init(uuidString:))
            guard let id else { return }
            MainActor.assumeIsolated { self?.selectSession(id) }
        }
    }

    /// Returning to the app marks the tab you return *to* as read.
    ///
    /// Distinct from `observeActivationRequests`, which handles an explicit click on a
    /// notification. This covers the ordinary case: a session finished while you were in
    /// another app, you ⌘-tab back, and the tab you are already looking at should not keep
    /// telling you there is something new in it.
    private func observeAppActivation() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.selectedSessionID else { return }
                self.setUnread(id, false)
            }
        }
    }

    /// The shell exited (or a `close_surface` binding fired), so retire the tab it belonged to.
    ///
    /// libghostty posts this through `GhosttyApp.closeSurface`. Without it the row stayed in
    /// the sidebar pointing at a dead terminal — the surface would render its final frame
    /// forever and never accept input again.
    ///
    /// The notification's object is the `SurfaceView`, so the session is found by identity
    /// rather than by an id libghostty does not know about.
    private func observeSurfaceClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            MainActor.assumeIsolated {
                guard let self,
                      let id = self.surfaces.first(where: { $0.value === view })?.key
                else { return }
                self.closeSession(id)
            }
        }
    }

    /// Applied from a transcript watcher. Stored even when the registry has not yet
    /// reported this session, so the next `applyRegistry` picks it up.
    func applySubagentCount(_ id: UUID, _ count: Int) {
        guard subagentCounts[id] != count else { return }
        subagentCounts[id] = count
        guard var status = statuses[id] else { return }
        status.subagentCount = count
        statuses[id] = status
        emit(.activityChanged(
            id: id, activity: status.activity.rawValue,
            waitingFor: status.waitingFor, subagentCount: status.subagentCount,
            hasBackgroundWork: backgroundWorkSessions.contains(id),
            // Carried, not re-derived: a sub-agent count arriving is not news about a dialog,
            // and reading a transcript to say so would put a tail read on the watcher's path.
            // Omitting it is not an option either — the fold overwrites unconditionally, so an
            // event without it would replace a live call id with `.unreported` and drop this
            // Mac's assertion on the floor.
            openPromptCall: openPromptIdentity(of: id)
        ))
    }

    private func injector(for id: UUID) -> TextInjecting? {
        injectorOverride ?? surfaces[id]
    }

    func surface(for id: UUID) -> Ghostty.SurfaceView? { surfaces[id] }

    func tick() { provider?.tick() }

    /// libghostty's configured default terminal font size, in points. `FontSizeCommands`
    /// resolves against this rather than reaching for `GhosttyApp.shared` directly, so it
    /// stays testable against a stub provider. No provider at all falls back to 12, matching
    /// `GhosttyApp.defaultFontSize`'s own initializer default.
    var defaultFontSize: Float { provider?.defaultFontSize ?? 12 }

    // MARK: - Helpers

    /// The tab's `claude` switched conversations in place (an in-session `/resume`).
    ///
    /// Step order is load-bearing at the end: the title is resolved *before* the new
    /// watcher starts. A resumed conversation's transcript exists by the time we point a
    /// watcher at it, and `TranscriptWatcher` starts tailing an already-existing file from
    /// its current end, so it will not replay history — but if it were started first, an
    /// old rename record could still land before the resolved title and overwrite it.
    private func repin(
        _ tabID: UUID, to conversationID: UUID, transcriptDirectory: String
    ) {
        guard let at = locate(tabID) else { return }

        // Refers to a prompt in a conversation this tab has left.
        notifier?.withdraw(sessionID: tabID)

        repos[at.repo].sessions[at.session].pinnedConversationID = conversationID
        // Stored, not just used below: a resumed conversation carries its own directory, and
        // the next tick compares the row's cwd against this field to decide whether anything
        // moved. Leaving it at the pre-resume value would make that comparison fire a
        // pointless retarget on every subsequent tick.
        repos[at.repo].sessions[at.session].transcriptDirectory = transcriptDirectory

        // The old conversation's outstanding Agent ids can never be answered in the new
        // transcript, so the count would otherwise stick at its last value forever.
        // Only the backing count is reset, not `statuses`: the sole caller is
        // `applyRegistry`, which rebuilds `statuses` from these counts immediately after
        // and diffs the result against the pre-call snapshot to decide notifications.
        // Editing `statuses` here would corrupt that "before" picture.
        subagentCounts[tabID] = 0

        stopWatching(tabID)

        // Derived from the session as just mutated above, so the directory is the registry
        // row's — a resumed conversation carries its own project path, and the row is
        // authoritative about where `claude` is actually writing.
        guard let updated = session(for: tabID) else { return }
        guard let url = adapter(for: instance(for: updated)).binding(for: updated).transcriptURL else {
            // An agent with no transcript to read has no title to resolve from one; it
            // reports titles through its runtime instead.
            startWatching(tabID: tabID)
            persist()
            return
        }
        titleResolver(updated.agent, url) { [weak self] title in
            // Two things can happen during a read that is a whole-file load: the tab can
            // close, and the tab can be repinned again (a second resume, or a fork).
            // `pinnedConversationID(of:)` covers both — it is nil for a closed tab, whose
            // completion would otherwise resurrect a `TranscriptWatcher` nothing will ever
            // stop again, and it differs for a re-repinned one, whose completion would
            // otherwise apply a superseded title and hand the tab a watcher tailing the
            // conversation it has already left. It is also what makes `startWatching`'s
            // unconditional `watchers[tabID] =` safe by construction.
            guard let self, self.pinnedConversationID(of: tabID) == conversationID else {
                return
            }
            if let title { self.applyExternalTitle(tabID, title) }
            // Only when nothing has re-watched this tab in the meantime. `repin` cleared the
            // entry, so a watcher being present means a `retarget` landed during the read
            // and already pointed one at the tab's *newer* directory; `url` was built from
            // the pre-retarget one. A project move cannot be the cause: `moveSession` stopped
            // touching watchers when the transcript path stopped depending on the project.
            if self.attachments[tabID] == nil {
                self.startWatching(tabID: tabID)
            }
        }

        persist()
    }

    /// The tab's `claude` changed directory without changing conversation — a plain `cd`, or
    /// the case this exists for: `EnterWorktree` moving it into
    /// `<project>/.claude/worktrees/<name>`.
    ///
    /// Only the transcript follows. The project the tab is filed under deliberately does not
    /// change, because a worktree is not another project — see `applyRegistry`. The watcher
    /// must follow, though: `claude` names the transcript's directory after its live cwd, so
    /// the old watcher is now tailing a file nothing will ever append to, and the tab would
    /// stop receiving renames and sub-agent counts with nothing to show for it.
    ///
    /// Unlike `repin` there is no title read to defer to: the conversation is the same one,
    /// so its title is already correct and only the path it is written at has moved. The
    /// sub-agent count *is* reset like a repin's, though — see below.
    private func retarget(_ tabID: UUID, to directory: String) {
        guard let at = locate(tabID) else { return }
        repos[at.repo].sessions[at.session].transcriptDirectory = directory

        // Same reasoning as `repin`, and for the same reason it is only the backing count:
        // the new watcher starts with an empty `outstandingAgents`, so an `agentFinished`
        // for an id the old one was tracking is a no-op and `countChanged` never fires. The
        // badge would sit at its pre-retarget value until some later turn boundary with a
        // non-empty set, which for a tab that entered a worktree mid-turn may be never.
        subagentCounts[tabID] = 0

        stopWatching(tabID)
        startWatching(tabID: tabID)
        persist()
    }

    /// Files a session under a different project, creating that project if it is new.
    ///
    /// This does not prune a source project it empties, matching `closeSession`: a
    /// project's lifetime is explicit, and an empty project is a legitimate sidebar state
    /// that now survives a relaunch too, via `SessionSnapshot.projects`.
    ///
    /// The tab id does not change, so `selectedSessionID` needs no fixing up and SwiftUI
    /// animates the same row moving within the sidebar's one flat `ForEach` rather than
    /// recreating it — there are no `Section`s in the sidebar to move between.
    ///
    /// The watcher is deliberately left alone. It used to be restarted here, because
    /// `workingDirectory` was also the input to `ClaudeSession.transcriptURL` — since the
    /// split it is not, `transcriptDirectory` is, and that field is untouched by a move. A
    /// tab moved into another project keeps tailing the transcript `claude` is actually
    /// writing; only `retarget` and `repin` may repoint a watcher now.
    func moveSession(_ id: UUID, toProjectAt url: URL) {
        guard let at = locate(id) else { return }
        let target = url.standardizedFileURL
        guard Self.comparablePath(repos[at.repo].url.path)
                != Self.comparablePath(target.path) else { return }

        // Resolved before the removal below, and its `projectAdded` emitted immediately —
        // not because the index would go stale otherwise (removing a *session* never removes
        // a repo, so `at.repo` stays valid either way), but because the removal and the
        // append are one logical move with no event of their own until `sessionMoved` below.
        // Letting `projectAdded` land between them would emit it against a store that has
        // already lost the session from its source project, one event ahead of where the
        // folded mirror is — exactly the momentary mismatch the drift check exists to catch.
        let destination: Int
        if let existing = indexOfRepo(for: target) {
            destination = existing
        } else {
            repos.append(Repo(url: target))
            destination = repos.count - 1
            emit(.projectAdded(
                FleetProjection.project(
                    repos[destination], statuses: statuses, unread: unreadIdle,
                    backgroundWork: backgroundWorkSessions,
                    openPromptCalls: openPromptCalls, planGates: planGates
                ),
                at: destination
            ))
        }

        var session = repos[at.repo].sessions.remove(at: at.session)
        // Stored as reported, not as compared: normalization is for deciding *whether* to
        // move. `transcriptDirectory` is not touched — where `claude` writes has nothing to
        // do with which project the user files this tab under.
        session.workingDirectory = target.path
        repos[destination].sessions.append(session)
        emit(.sessionMoved(
            id: id, project: repos[destination].id,
            at: repos[destination].sessions.count - 1
        ))
        // Same reasoning as `newSession`: a session landing in a collapsed destination must
        // make that destination visible, or the move is invisible in the sidebar.
        if repos[destination].isCollapsed {
            repos[destination].isCollapsed = false
            emit(.projectCollapsed(id: repos[destination].id, isCollapsed: false))
        }

        if selectedSessionID == id { lastActiveProjectURL = target }
        persist()
    }

    /// Points a tab's agent runtime at whatever conversation the tab currently follows.
    ///
    /// Takes only the tab id, deliberately: the conversation and the directory it is written
    /// in both live on the session, and every caller here mutates the session first and then
    /// re-derives. Passing them separately is how a caller ends up watching a conversation
    /// the tab has already left.
    private func startWatching(tabID: UUID) {
        guard let session = session(for: tabID) else { return }
        let instance = instance(for: session)
        let binding = adapter(for: instance).binding(for: session)
        // Alongside the runtime, because it is the other half of observing this tab: the
        // runtime tails its transcript, and its account's registry is where the status glyph
        // comes from. A no-op for every account that already has one, and for codex, whose
        // tabs have no registry behind them at all.
        // `hasStatusRegistry` rather than `== .claude`: the property is the adapter's own
        // answer and codex's is false, so a third agent with a registry starts being watched
        // by declaring it rather than by someone remembering to widen a comparison here.
        if instance.agent.hasStatusRegistry { startStatusWatching(account: instance.account) }
        // The token is the routing identity: the closure below names its tab directly, so
        // nothing scans `attachments` to decide who an event belongs to. Two tabs following
        // one conversation are two subscribers on one source inside the runtime, which is
        // where that multiplexing now lives.
        let token = runtime(for: instance).attach(binding, for: tabID) { [weak self] event in
            self?.apply(event, to: tabID)
        }
        attachments[tabID] = TabAttachment(instance: instance, binding: binding, token: token)

        // **An agent with no registry has no resting state unless one is seeded here, and
        // without it the tab reads as "no agent running" forever.**
        //
        // A claude tab gets its activity from the status registry, which reports whether the
        // agent is there at all. Codex has none — `hasStatusRegistry` is false — so its only
        // source of activity is `CodexRolloutWatcher`, which speaks exclusively in TURN
        // BOUNDARIES: `task_started` -> busy, `task_complete` -> idle. A codex tab that has
        // never taken a turn therefore never produces a single activity event, and
        // `statuses[tabID]` stays nil for the life of the tab.
        //
        // That nil is not cosmetic. `submitPrompt` refuses a statusless tab with
        // `notRunning`, and the phone renders it as "There's no agent running in this tab
        // right now" — on a tab where `codex resume` is sitting at its composer, ready. It is
        // why typing into codex from the phone stayed broken after the channel existed.
        //
        // `.idle` is the honest claim: attachment happens only once the thread is bound and
        // the tab has been told to run `codex resume`, so there IS an agent and it is not
        // mid-turn. Anything the agent actually does overwrites this within milliseconds —
        // the first `task_started` makes it busy — so this only ever describes the gap
        // before the first turn, which is exactly the gap that was unrepresentable.
        //
        // Seeded only for agents with no registry: a claude tab must keep getting this from
        // the registry, whose absence genuinely means the agent is gone.
        if !instance.agent.hasStatusRegistry, statuses[tabID] == nil {
            applyActivity(.idle, to: tabID)
        }
    }

    /// Drops a tab's subscription. The runtime tears its source down when the last
    /// subscriber leaves, so the store no longer has to ask whether anyone else is following.
    private func stopWatching(_ tabID: UUID) {
        guard let attachment = attachments.removeValue(forKey: tabID) else { return }
        runtime(for: attachment.instance).detach(attachment.token)
    }

    /// One place where an agent's report becomes tab state, whichever agent reported it.
    private func apply(_ event: AgentEvent, to tabID: UUID) {
        switch event {
        case .title(let title): applyExternalTitle(tabID, title)
        case .activity(let activity): applyActivity(activity, to: tabID)
        case .subagentCount(let count): applySubagentCount(tabID, count)
        case .turnEnded: applyTurnEnded(to: tabID)
        }
    }

    /// An agent reported what it is doing.
    ///
    /// Routed through `commitStatuses` rather than written into `statuses`, which is the
    /// whole point of this method existing: that is where the diff lives, and every unread
    /// mark, notification, superseded resume prompt and save is decided from it. Writing the
    /// map directly would skip all of them *and* corrupt the snapshot the next registry tick
    /// diffs against.
    ///
    /// Claude never arrives here in production — its activity comes off the registry tick,
    /// which already carries it — so this is codex's route in practice. It is not gated on
    /// the agent even so: an agent that reports activity is reporting activity, and a gate
    /// would only mean a second rule to keep in step with the one in `applyRegistry`.
    ///
    /// What keeps claude out is that `ClaudeRuntime.ingest` has no production caller, and it
    /// must stay that way: wiring it to the registry tick would route claude's activity in
    /// here on a *different* row-selection rule — an `.activity` event names a conversation,
    /// not an anchored pid — skipping `ConversationPin.resolve`'s pid-recycling validation and
    /// its newest-wins tiebreak, and blanking `waitingFor` on every tick. Claude's status has
    /// one writer, `applyRegistry`, and this is not it.
    private func applyActivity(_ activity: SessionActivity, to tabID: UUID) {
        guard session(for: tabID) != nil else { return }
        var next = statuses
        next[tabID] = SessionStatus(
            activity: activity,
            // Not carried over from the previous status: `waitingFor` describes *this*
            // report's block, and keeping a stale reason on a tab that has moved on would
            // put the wrong sentence in the sidebar and in the notification body.
            waitingFor: nil,
            subagentCount: subagentCounts[tabID] ?? 0
        )
        commitStatuses(next, backgroundWork: backgroundWorkSessions)
    }

    /// An agent finished a turn.
    ///
    /// Nothing for claude to do: its turn boundary reaches the store as a status transition
    /// to `.idle` on the next registry tick, and `applyRegistry` is what turns that into
    /// unread marks and notifications. Codex has no registry to tick and reports the boundary
    /// outright — and the unread mark is exactly what keys off it, so without this a codex
    /// session silently never marks unread.
    ///
    /// Idempotent with the `.activity(.idle)` that `turn/completed` maps to just ahead of it:
    /// landing idle on an already-idle tab produces no change, so `commitStatuses` returns
    /// without touching anything. That is why this is expressed as "the turn left it idle"
    /// rather than as its own kind of edge.
    private func applyTurnEnded(to tabID: UUID) {
        applyActivity(.idle, to: tabID)
    }

    private func indexOfRepo(for url: URL) -> Int? {
        let target = Self.comparablePath(url.path)
        return repos.firstIndex { Self.comparablePath($0.url.path) == target }
    }

    /// The form in which two directory paths are compared for "same project".
    ///
    /// The two sides come from different places: `claude` reports `process.cwd()`, which
    /// `getcwd` has already resolved through symlinks, while Flight Deck stores whatever
    /// the folder picker or a drop handed it — `standardizedFileURL` collapses `.`/`..`
    /// but never follows a symlink. Comparing those raw makes a project reached through a
    /// symlink look like a different project, which files a duplicate repo and leaves an
    /// empty ghost behind on the first registry tick.
    ///
    /// `resolvingSymlinksInPath()` is a no-op for a path that does not exist on disk, so
    /// directories that are only ever named (tests, a project on an unmounted volume)
    /// still compare exactly as written.
    private static func comparablePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// What a tool's command template is expanded against, for the current selection.
    ///
    /// Assembled here rather than in the tools subsystem because this type owns both halves:
    /// `adapter(for:)` resolves the agent, and `repos` knows which project the tab is filed
    /// under. Tools code never holds an adapter.
    ///
    /// Everything agent-shaped goes through `AgentAdapter.location(for:)` — never through
    /// `Session.transcriptDirectory` or `ClaudeSession` — so that claude deriving its
    /// transcript path from the cwd does not become a rule every future agent inherits. See
    /// `ClaudeAdapter`'s doc comment, which keeps `encodedProjectDirName` off the protocol for
    /// the same reason.
    ///
    /// nil when nothing is selected: there is no working directory then, and a tool expanded
    /// against blanks would run somewhere arbitrary. Callers disable themselves instead.
    ///
    /// The account fields come from `account(for:)`, which is nil for both "no accounts
    /// configured" and "this tab's account was deleted" — and both leave `accountName`,
    /// `accountHome` and `accountEnvironment` at their empty defaults rather than refusing to
    /// build a context. A tool is not a session: opening an editor without an account's
    /// variables is better than refusing to open it because a login went away.
    func toolContext() -> ToolContext? {
        guard let id = selectedSessionID, let at = locate(id) else { return nil }
        let repo = repos[at.repo]
        let session = repo.sessions[at.session]
        let adapter = adapter(for: instance(for: session))
        let location = adapter.location(for: session)
        let account = account(for: session)
        return ToolContext(
            workingDirectory: location.workingDirectory,
            projectPath: repo.url.path,
            projectName: repo.displayName,
            sessionTitle: session.title,
            agent: session.agent,
            conversationID: location.binding.conversationID,
            transcriptPath: location.binding.transcriptURL?.path,
            accountName: account?.displayName,
            accountHome: account?.home.path,
            accountEnvironment: account.map(adapter.environment(for:)) ?? [:]
        )
    }

    private func session(for id: UUID) -> Session? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session]
    }

    private func locate(_ id: UUID) -> (repo: Int, session: Int)? {
        for (r, repo) in repos.enumerated() {
            if let s = repo.sessions.firstIndex(where: { $0.id == id }) {
                return (r, s)
            }
        }
        return nil
    }
}

/// Why an answer drive stopped, described well enough to diagnose it without the handset.
///
/// **A drive aborts silently on purpose, and that silence used to reach the log too.** Sending
/// no further key is the right behaviour — a stopped drive leaves a dialog a person can still
/// finish, a Return on the wrong row leaves nothing — but it recorded nothing at all, so a
/// four-option checkbox question that ticked one box and stopped could not be told apart from
/// one that never started. Which check refused, and what it refused against, cost a human a
/// round trip on a phone to find out.
///
/// Every field here answers a question that round trip was spent on. `viewport` is the one
/// that matters: without the actual screen there is no way to say whether the terminal drew
/// something unexpected or the parser misread something ordinary.
struct AnswerAbort: Equatable {
    /// Which check refused, named apart rather than collapsed into "failed". The repairs are
    /// unrelated: a cursor that did not start where the plan said is a screen that moved under
    /// the plan, a label mismatch is this Mac's copy disagreeing with what is drawn, a landing
    /// failure is a keystroke the TUI dropped or has yet to repaint, and an unreadable viewport
    /// is not about the dialog at all.
    enum Check: String, Equatable {
        case unreadableBeforePress = "unreadable-viewport-before-press"
        case cursorBeforePress = "pre-press-cursor"
        case labelBeforePress = "pre-press-label"
        case unreadableAfterMove = "unreadable-viewport-after-move"
        case landingAfterMove = "post-move-landing"
    }

    let check: Check
    /// Which step of the plan, or `nil` for the one-step drive that walks no plan.
    let step: Int?
    let purpose: AnswerPlan.Step.Purpose?
    let from: Int
    let to: Int
    /// The label the check wanted the row to read, verbatim — the string that was compared,
    /// not a description of it, because a trailing space or a stripped glyph is exactly the
    /// kind of difference this is here to expose.
    let expected: String?
    /// What `focusedRow` returned. `nil` covers both "no marker found on the screen" and "no
    /// screen to look at", which the `check` tells apart.
    let focused: Int?
    /// The whole screen the check saw, and the reason any of this goes to a file.
    let viewport: String?

    /// The one-line form. Kept short deliberately: os_log truncates a message, and everything
    /// here has to survive that — which is why the viewport is not part of it.
    var summary: String {
        "answer abort check=\(check.rawValue) step=\(step.map(String.init) ?? "-")"
            + " purpose=\(Self.describe(purpose)) from=\(from) to=\(to)"
            + " focused=\(focused.map(String.init) ?? "nil")"
            + " expected=\(expected.map { "\"\($0)\"" } ?? "-")"
    }

    private static func describe(_ purpose: AnswerPlan.Step.Purpose?) -> String {
        switch purpose {
        case .option(let question, let option): return "option(q\(question),o\(option))"
        case .action(let question, let isLast):
            return "action(q\(question),\(AnswerPlan.actionLabel(isLast: isLast)))"
        case .submit: return "submit"
        case nil: return "-"
        }
    }
}

/// Puts an `AnswerAbort` in the two places it can be read after the fact.
///
/// **Two channels because neither is enough alone.** The unified log is where every other
/// subsystem's summary goes and where a person already looks, but os_log truncates — and the
/// field that decides whether the terminal or the parser was at fault is a whole 40-row screen.
/// So the summary goes to `Logger` and the screen to a file beside it, delimited so consecutive
/// dumps come apart again.
///
/// Unconditional: not `#if DEBUG`, and not behind a preference. The failure this exists for
/// reproduces only on the installed Release build, and an abort is rare enough that always
/// writing one costs nothing worth measuring.
enum AnswerAbortLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "answer"
    )

    /// Beside the system's own logs, where `Console.app` lists it and a `tail -f` finds it
    /// without knowing anything about this app. Not in a container — this build is unsandboxed,
    /// and a path a human can type is the whole point.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/flight-deck-answer.log")

    static func record(_ abort: AnswerAbort) {
        logger.error("\(abort.summary, privacy: .public)")
        write(abort, to: fileURL)
    }

    /// Appends one record: a timestamp, the same fields, then the screen between markers.
    ///
    /// **Every failure is swallowed, and the file is only ever appended to.** This runs inside
    /// a drive a person is waiting on, so a log that cannot be written is not a reason to
    /// behave differently from one that can — and an unopenable file is left alone rather than
    /// replaced, because the history already in it is worth more than this one record.
    static func write(_ abort: AnswerAbort, to url: URL) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Local time, with its offset, because the other half of this record is in the unified
        // log — which Console shows in local time — and correlating the two should not need
        // arithmetic.
        stamp.timeZone = .current
        let record = """
            \(stamp.string(from: Date())) \(abort.summary)
            --- viewport begin ---
            \(abort.viewport ?? "(none — readViewport() returned nil)")
            --- viewport end ---

            """
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(record.utf8))
    }
}
