import Foundation
import IntakeKit

/// The shell and environment new sessions are spawned into.
struct ShellPreferences: Codable, Equatable {
    /// nil means "use `$SHELL`", which is `ShellResolver`'s existing behaviour.
    var shellOverride: String?
    /// Extra variables merged into every new session's environment.
    var environment: [String: String]
    /// Blanks an inherited `CLAUDE_CODE_CHILD_SESSION`. Claude Code sets that marker for
    /// nested sessions, and it turns transcript saving off — which silently kills the
    /// sidebar's inbound rename sync, since the watcher tails a file that is never
    /// written. See docs/FOLLOWUPS.md. Defaults on.
    var clearChildSessionMarker: Bool
    /// Bytes of terminal output `fd-abduco` keeps in its replay ring, so a reattach can
    /// redraw the scrollback a session had before it detached. Applies to every session's
    /// shell, regardless of agent — this is terminal infrastructure, not a Claude setting.
    /// Optional for the same reason every field added to this struct after
    /// `clearChildSessionMarker` must be: a `"shell": {...}` blob already on disk predates
    /// this field, and a non-optional property with no default would fail to decode every
    /// one of them. `nil` means "never configured", which reads as 4 MiB.
    var scrollbackBudgetBytes: Int?
    /// Whether an idle session's agent is put to sleep (SIGSTOP'd, its terminal detached)
    /// after `sleepIdleThresholdSeconds` of inactivity. Applies to every session's shell,
    /// regardless of agent — sleep freezes a process group and tears down a terminal surface,
    /// neither of which is Claude-specific. Optional for the same reason `scrollbackBudgetBytes`
    /// is: a `"shell": {...}` blob already on disk predates this field, and a non-optional
    /// property with no default would fail to decode every one of them. `nil` means "never
    /// configured", which reads as on — idle sleep is on by default.
    var idleSleepEnabled: Bool?
    /// How long a session must sit idle before it is put to sleep. Optional for the same
    /// reason as `idleSleepEnabled`. `nil` reads as 600 (10 minutes).
    var sleepIdleThresholdSeconds: Int?
    /// Whether a session whose turn died on a transient API error is automatically nudged
    /// back to life on a backoff ladder. Applies to every agent that declares an
    /// `AgentTurnRecovery`, which is why it lives here rather than under `claude`. Optional
    /// for the same reason `idleSleepEnabled` is — a `"shell": {...}` blob already on disk
    /// predates this field. `nil` reads as OFF: this feature types into a terminal, so it is
    /// opt-in.
    var autoRetryAPIErrors: Bool?

    init(
        shellOverride: String? = nil,
        environment: [String: String] = [:],
        clearChildSessionMarker: Bool = true,
        scrollbackBudgetBytes: Int? = nil,
        idleSleepEnabled: Bool? = nil,
        sleepIdleThresholdSeconds: Int? = nil,
        autoRetryAPIErrors: Bool? = nil
    ) {
        self.shellOverride = shellOverride
        self.environment = environment
        self.clearChildSessionMarker = clearChildSessionMarker
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.idleSleepEnabled = idleSleepEnabled
        self.sleepIdleThresholdSeconds = sleepIdleThresholdSeconds
        self.autoRetryAPIErrors = autoRetryAPIErrors
    }
}

/// Alerts the user has chosen to stop seeing.
struct ConfirmationPreferences: Codable, Equatable {
    /// Set by the "Don't ask me again" box on the project-close alert.
    var suppressProjectClose: Bool

    init(suppressProjectClose: Bool = false) {
        self.suppressProjectClose = suppressProjectClose
    }
}

/// Session-lifecycle behaviour, edited on the Claude tab.
///
/// Every field added here must be Optional or carry a custom decoder, for the reason given
/// on `Preferences.claude`: users already have `"claude": {...}` blobs on disk, and a
/// non-optional field with no default would fail to decode every one of them.
struct ClaudePreferences: Codable, Equatable {
    /// Sessions that were mid-turn when Flight Deck last went away are prompted to continue
    /// once they have resumed and settled. Off by default: picking work back up unattended
    /// is a decision the user has to make deliberately, not one to inherit from an upgrade.
    var autoResumeRunningSessions: Bool
    /// Whether a paired phone may send Escape at a dialog this Mac cannot name. See
    /// `PreferencesStore.allowsBlockedPromptAbort` for why it defaults off. Optional for the
    /// same reason every field on this struct must be, per the type's doc comment: an
    /// existing `"claude": {...}` blob on disk has no such key, and it must go on decoding.
    var allowsBlockedPromptAbort: Bool?

    init(autoResumeRunningSessions: Bool = false, allowsBlockedPromptAbort: Bool? = nil) {
        self.autoResumeRunningSessions = autoResumeRunningSessions
        self.allowsBlockedPromptAbort = allowsBlockedPromptAbort
    }
}

/// Everything the Preferences window edits.
struct Preferences: Codable, Equatable {
    var globalFlags: FlagSet
    /// Keyed by standardized project path. Kept here rather than on `Repo` because an
    /// override outlives the project it belongs to — closing a project removes it from
    /// `SessionStore` entirely.
    var projectFlags: [String: FlagSet]
    var shell: ShellPreferences
    /// Optional, and it has to stay that way. `UserDefaultsPreferencesPersistence.load()`
    /// decodes with `try?`, and synthesized `Codable` throws on a missing key rather than
    /// falling back to a property default — so a non-optional field here would fail to
    /// decode every existing `preferences.v1` blob and silently reset every flag, override
    /// and shell setting the user has. `nil` means "never answered", which is not suppressed.
    var confirmations: ConfirmationPreferences?
    /// Optional for exactly the reason `confirmations` is — see that property's comment.
    /// `nil` means "never configured", which reads as every field's default.
    var claude: ClaudePreferences?
    /// Ordered; position binds the New Session shortcuts (see `NewSessionAffordance`).
    /// Optional in storage, for the same reason `confirmations` is: a snapshot written before
    /// agent adapters decodes cleanly, and `migrateAgentsIfNeeded()` fills it in from today's
    /// single-agent settings rather than failing the whole decode.
    var storedAgents: [AgentSettings]?
    /// Ordered; position is the overlay's left-to-right order.
    ///
    /// Optional in storage for exactly the reason `confirmations` is — see that property's
    /// comment. `nil` means "never materialised", which `migrateToolsIfNeeded` fills in.
    /// An *empty* array is a different thing entirely: it means the user deleted every tool,
    /// and it must stay empty.
    var storedTools: [ToolDefinition]?
    /// The pre-list account store, now a MIRROR of `storedAccountList` (its claude and codex
    /// accounts, flat) written for an older Flight Deck build — see `AccountList.legacyAccounts`.
    /// Read only when `storedAccountList` is nil, i.e. to migrate a blob from before the list.
    /// Never write it directly: write `accounts` or `accountList`.
    var storedAccounts: [AgentAccount]?
    /// Settings → Accounts (unify brief R6): every account and pool, in order. The source of
    /// truth for accounts AND for pools; `accounts` and `PreferencesStore.effectivePools` read
    /// it. Optional for the reason `confirmations` is; nil means "never migrated", which
    /// `migrateAccountsIfNeeded` fills in from `storedAccounts` and `capacity.pools`.
    var storedAccountList: AccountList?
    /// Keyed by standardized project path, replacing `projectFlags`. Optional for the same
    /// reason; `migrateProjectSettingsIfNeeded` folds the old field in.
    var storedProjectSettings: [String: ProjectSettings]?
    /// Phones paired to this Mac, each holding the secret its TLS handshake is authenticated
    /// with. Optional for exactly the reason `confirmations` is — see that property's
    /// comment; a non-optional field here would fail to decode every existing
    /// `preferences.v1` blob.
    ///
    /// These are secrets in `UserDefaults`, which is a plist readable by anything running as
    /// this user. That is the same exposure as `sessions.json` and as the agents' own
    /// credentials, and it matches the trust model in the mobile companion spec §3 — but it
    /// is deliberately not Keychain-grade, and it is recorded in docs/FOLLOWUPS.md rather
    /// than left to be discovered.
    var pairedDevices: [PairedDevice]?
    /// Minted once per install, and used only to make this Mac's Bonjour instance name
    /// unique. Optional for the same reason as everything else here — see `confirmations`.
    var installID: UUID?
    /// The port the fleet listener last successfully bound to, so the next launch can ask for
    /// it again. Optional for the same reason as everything else here — see `confirmations` —
    /// and `nil` means "never bound", which asks the OS for any free port.
    ///
    /// Persisted for the reason `installID` is: a phone remembers this Mac as `host:port`
    /// strings (`PairedMac.endpoints`, seeded from the pairing payload), so a port re-drawn
    /// from the ephemeral range on every launch invalidates every endpoint every paired device
    /// holds the moment the Mac restarts — leaving Bonjour as the only way back, and anything
    /// that breaks Bonjour as a permanent stranding. A hint, never a guarantee: nothing
    /// reserves this port while Flight Deck is not running, so `FleetService.start` treats a
    /// port it cannot rebind as a preference to abandon, not a reason to have no listener.
    var fleetPort: UInt16?
    /// Points. Optional for exactly the reason `confirmations` is — see that property's comment.
    /// `nil` means "never changed", which resolves to libghostty's configured `font-size`.
    var terminalFontSize: Float?
    /// Flight Control routing (L3-R): the global rule list, the rule compiler, which planning
    /// kinds you have seen and which rule hints you dismissed. Optional for exactly the reason
    /// `confirmations` is — see that property's comment.
    var flightControlRouting: RoutingPreferences?

    /// Flight Control's pools and hand-off settings (L3-U). Optional for exactly the reason
    /// `confirmations` is — see that property's comment. `nil` means "never configured": the
    /// default pools and hand-off settings.
    var capacity: CapacityPreferences?

    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences(),
        confirmations: ConfirmationPreferences? = nil,
        claude: ClaudePreferences? = nil,
        storedAgents: [AgentSettings]? = nil,
        storedTools: [ToolDefinition]? = nil,
        storedAccounts: [AgentAccount]? = nil,
        storedAccountList: AccountList? = nil,
        storedProjectSettings: [String: ProjectSettings]? = nil,
        pairedDevices: [PairedDevice]? = nil,
        installID: UUID? = nil,
        fleetPort: UInt16? = nil,
        terminalFontSize: Float? = nil,
        flightControlRouting: RoutingPreferences? = nil,
        capacity: CapacityPreferences? = nil
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
        self.confirmations = confirmations
        self.claude = claude
        self.storedAgents = storedAgents
        self.storedTools = storedTools
        self.storedAccounts = storedAccounts
        self.storedAccountList = storedAccountList
        self.storedProjectSettings = storedProjectSettings
        self.pairedDevices = pairedDevices
        self.installID = installID
        self.fleetPort = fleetPort
        self.terminalFontSize = terminalFontSize
        self.flightControlRouting = flightControlRouting
        self.capacity = capacity
    }

    /// Falls back to claude-then-codex so a `Preferences` that has never been migrated
    /// behaves exactly as it always has, with claude on ⌘N.
    ///
    /// Tab-ready agents only (unify brief R4). This list IS the new-tab surface — the New
    /// Session menus, ⌘N's binding and the project agent order all read it — so an agent that
    /// cannot run a tab yet (grok, gemini) must never appear in it, whatever a stored list says.
    var agents: [AgentSettings] {
        get { (storedAgents ?? Self.defaultAgents).filter { $0.id.tabReady } }
        set { storedAgents = newValue }
    }

    static let defaultAgents: [AgentSettings] = [
        AgentSettings(id: .claude, options: .claude(FlagSet())),
        AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
    ]

    /// Folds today's single-agent settings (`globalFlags`) into the list. Idempotent — safe
    /// to call on every load — so it never overwrites a list the user has already reordered.
    ///
    /// Also appends any tab-ready agent the stored list lacks, at the end so no existing
    /// shortcut moves. That is how an agent becomes reachable the launch after its track flips
    /// `AgentID.tabReady`: without it, a list stored before grok existed would never offer it.
    mutating func migrateAgentsIfNeeded() {
        if storedAgents == nil {
            storedAgents = [
                AgentSettings(id: .claude, options: .claude(globalFlags)),
                AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
            ]
        }
        for agent in AgentID.tabReadyCases where !(storedAgents ?? []).contains(where: { $0.id == agent }) {
            storedAgents?.append(AgentSettings(id: agent, options: .empty(for: agent)))
        }
    }

    /// Reorders the agent list, which rebinds the New Session shortcuts
    /// (`NewSessionAffordance`) — dragging a row in the Agents tab is the only way a user
    /// changes what ⌘N launches.
    mutating func moveAgents(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = agents
        list.move(fromOffsets: source, toOffset: destination)
        agents = list
    }

    /// Reads through the optional so a `Preferences` that predates materialisation still has
    /// tools. Writes go straight to `storedTools`, which is what lets an emptied list persist
    /// as empty rather than falling back to the defaults on the next read.
    var tools: [ToolDefinition] {
        get { storedTools ?? Self.defaultTools(terminalCommand: Self.fallbackTerminalCommand) }
        set { storedTools = newValue }
    }

    /// Used only by the getter above, for a blob that somehow reaches a reader before
    /// `migrateToolsIfNeeded` has run. Deliberately does not probe: a getter is not a place to
    /// touch `NSWorkspace`.
    static let fallbackTerminalCommand = "open -b com.apple.Terminal ${cwd}"

    static func defaultTools(terminalCommand: String) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "Editor",
                symbol: "chevron.left.forwardslash.chevron.right",
                // `$EDITOR` is left for the login shell to resolve — see `ToolTemplate.expand`
                // and `ShellToolLauncher`. Flight Deck's own process has no `$EDITOR` at all
                // when it is launched from Finder.
                command: "$EDITOR ${cwd}",
                shortcut: ToolShortcut(key: "o", modifiers: [.command])
            ),
            ToolDefinition(
                name: "Terminal",
                symbol: "terminal",
                command: terminalCommand,
                shortcut: ToolShortcut(key: "t", modifiers: [.command])
            ),
        ]
    }

    /// Fills in the starting tools once. Idempotent — safe on every load — so it never
    /// overwrites a list the user has edited, reordered, or emptied.
    mutating func migrateToolsIfNeeded(terminalCommand: String) {
        guard storedTools == nil else { return }
        storedTools = Self.defaultTools(terminalCommand: terminalCommand)
    }

    /// Every account, flat, in list order — tombstones included. A view over `accountList`;
    /// writing it reconciles the list (see `AccountList.accounts`), so every caller that edited
    /// the old flat array keeps working and keeps each account in its pool.
    var accounts: [AgentAccount] {
        get { accountList.accounts }
        set { accountList.accounts = newValue }
    }

    /// The Accounts list, migrated on the fly from the pre-list fields when it was never stored.
    ///
    /// Every write also refreshes the legacy mirror (`storedAccounts`, `capacity.pools`): an
    /// older build installed over this one (several sessions on this machine build and swap
    /// their own) then still finds the same account ids and pools instead of re-seeding new ids
    /// that orphan every tab and project assignment. The mirror never feeds back — this build
    /// reads it only while `storedAccountList` is nil.
    var accountList: AccountList {
        get { storedAccountList ?? .migrating(accounts: storedAccounts ?? [], pools: capacity?.pools ?? []) }
        set {
            storedAccountList = newValue
            storedAccounts = newValue.legacyAccounts
            let legacyPools = newValue.legacyPools
            if capacity != nil || !legacyPools.isEmpty {
                var next = capacity ?? CapacityPreferences()
                next.pools = legacyPools.isEmpty ? nil : legacyPools
                capacity = next
            }
        }
    }

    /// One agent's LIVE accounts. Tombstones are filtered here rather than at each caller
    /// because every consumer of this — the Accounts list, the Projects tab's picker,
    /// reordering — is a list the user picks from, and a removed account must appear in none
    /// of them. Lookups BY ID go through `PreferencesStore.account(id:)` instead and must
    /// keep seeing tombstones; see `AgentAccount.removedAt`.
    func accounts(for agent: AgentID) -> [AgentAccount] {
        accounts.filter { $0.agent == agent && !$0.isRemoved }
    }

    /// Every live account, flat. What the "New … Session" menus render — the raw `accounts`
    /// array would offer a login the user has removed.
    var liveAccounts: [AgentAccount] { accounts.filter { !$0.isRemoved } }

    /// Drops every tombstone. Called once at launch, from `PreferencesStore.init`'s migration
    /// chain: tombstones exist only to keep a *running* tab's identity stable, and at launch
    /// there are none left to protect. Nothing else prunes them — one mechanism, not two.
    ///
    /// Cannot resurrect what the user removed: this never sets `storedAccountList` back to nil,
    /// so `migrateAccountsIfNeeded` never reseeds on a later launch. That is deliberate for an
    /// account the user removed, but it is not scoped per agent — if this purge empties one
    /// agent's accounts entirely, that agent stays empty; nothing here (or afterward) restores it.
    mutating func purgeRemovedAccounts() {
        // `accounts` is a computed view over `storedAccountList` whose setter writes back, so
        // on preferences that have never been migrated this get-modify-set would store an empty
        // list — permanently defeating `migrateAccountsIfNeeded`'s seed-once
        // `guard storedAccountList == nil` and leaving the user with no accounts at
        // all, forever. Today's call site runs after that migration so it cannot happen; this
        // guard means it still cannot if the order ever changes, and it is honest besides:
        // there is nothing to purge.
        guard storedAccountList != nil || storedAccounts != nil else { return }
        accounts.removeAll { $0.isRemoved }
    }

    var projectSettings: [String: ProjectSettings] {
        get { storedProjectSettings ?? [:] }
        set { storedProjectSettings = newValue }
    }

    /// Reorders one agent's accounts without disturbing any other agent's.
    ///
    /// `accounts` is one flat array, so offsets from a per-agent list cannot be applied to it
    /// directly. This maps them back: pull out this agent's entries, reorder them, then write
    /// them into the positions the flat array already reserved for that agent.
    ///
    /// The write-back filter must match `accounts(for:)`'s exactly, tombstones included. Read
    /// live entries but write into every slot for the agent and the iterator runs dry early:
    /// a tombstone mid-list swallows one entry and shifts every account after it.
    mutating func moveAccounts(forAgent agent: AgentID, fromOffsets source: IndexSet, toOffset destination: Int) {
        var mine = accounts(for: agent)
        mine.move(fromOffsets: source, toOffset: destination)
        var reordered = mine.makeIterator()
        accounts = accounts.map {
            $0.agent == agent && !$0.isRemoved ? (reordered.next() ?? $0) : $0
        }
    }

    /// Seeds the built-in account per agent, then discovers siblings ONCE.
    ///
    /// Every `AgentID` is seeded on a fresh install, grok and gemini included: planning bills an
    /// agent's first account (unify brief R9), and a built-in account is what that resolves to.
    /// An install that migrated before grok and gemini existed is not re-seeded — that would
    /// also resurrect a claude or codex login the user removed.
    ///
    /// Deliberately not a re-scan on later launches: a re-scan resurrects accounts the user
    /// removed. The Accounts pane offers "Scan for Accounts…" for additions made afterwards.
    mutating func migrateAccountsIfNeeded(
        // Overridable so tests can migrate against a temp directory instead of the real
        // `$HOME` — this scans for sibling account directories, which must never touch the
        // developer's actual `~/.claude` / `~/.codex`.
        homeRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard storedAccountList == nil else { return }
        // A blob from before the list already has its accounts (and maybe pools): those are
        // folded in as they are, never re-seeded.
        if storedAccounts != nil {
            accountList = .migrating(accounts: storedAccounts ?? [], pools: capacity?.pools ?? [])
            return
        }
        var seeded: [AgentAccount] = []
        for agent in AgentID.allCases {
            let builtIn = homeRoot.appendingPathComponent(agent.builtInHome.lastPathComponent, isDirectory: true)
            seeded.append(AgentAccount(
                agent: agent,
                displayName: AccountDirectory.identity(atHome: builtIn, agent: agent)?.email ?? "Default",
                home: builtIn,
                cachedIdentity: AccountDirectory.identity(atHome: builtIn, agent: agent)
            ))
            // Gemini has its built-in account only (unify brief R5): a `~/.gemini-work` would
            // be a directory agy never reads, since its login is in the keychain.
            for home in AccountDirectory.discover(in: homeRoot, agent: agent) where agent.homeEnvironmentKey != nil {
                let identity = AccountDirectory.identity(atHome: home, agent: agent)
                seeded.append(AgentAccount(
                    agent: agent,
                    displayName: identity?.email ?? home.lastPathComponent,
                    home: home,
                    cachedIdentity: identity
                ))
            }
        }
        accountList = AccountList(entries: seeded.map(AccountEntry.account))
    }

    /// Folds today's per-project claude flags into the per-agent record. Every existing project
    /// lands in the unspecified state — no default agent, no account — with its flags intact.
    mutating func migrateProjectSettingsIfNeeded() {
        guard storedProjectSettings == nil else { return }
        storedProjectSettings = projectFlags.mapValues {
            ProjectSettings(options: [.claude: .claude($0)])
        }
    }

    /// Makes `agents[claude].options` the single source for global claude flags.
    ///
    /// `globalFlags` and the claude agent row have held the same value in parallel since the
    /// Agents tab shipped, with only the former being read. Two homes for one setting is
    /// tolerable while nothing else writes either; it is not once per-(project, agent) options
    /// exist. `globalFlags` stays as a decode-only legacy field.
    mutating func migrateGlobalFlagsIfNeeded() {
        guard let index = agents.firstIndex(where: { $0.id == .claude }),
              case .claude(let existing) = agents[index].options, existing.isEmpty,
              !globalFlags.isEmpty
        else { return }
        var list = agents
        list[index].options = .claude(globalFlags)
        agents = list
    }
}
