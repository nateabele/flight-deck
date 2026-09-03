import Foundation

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

    init(
        shellOverride: String? = nil,
        environment: [String: String] = [:],
        clearChildSessionMarker: Bool = true
    ) {
        self.shellOverride = shellOverride
        self.environment = environment
        self.clearChildSessionMarker = clearChildSessionMarker
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

    init(autoResumeRunningSessions: Bool = false) {
        self.autoResumeRunningSessions = autoResumeRunningSessions
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
    /// Ordered. Relative order *within one agent's* entries is that agent's default ordering:
    /// the topmost is what a project with no explicit choice resolves to.
    ///
    /// Optional in storage for the same reason `storedAgents` is — see that property. `nil`
    /// means "never migrated", which `migrateAccountsIfNeeded` fills in.
    var storedAccounts: [AgentAccount]?
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

    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences(),
        confirmations: ConfirmationPreferences? = nil,
        claude: ClaudePreferences? = nil,
        storedAgents: [AgentSettings]? = nil,
        storedTools: [ToolDefinition]? = nil,
        storedAccounts: [AgentAccount]? = nil,
        storedProjectSettings: [String: ProjectSettings]? = nil,
        pairedDevices: [PairedDevice]? = nil,
        installID: UUID? = nil,
        fleetPort: UInt16? = nil,
        terminalFontSize: Float? = nil
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
        self.confirmations = confirmations
        self.claude = claude
        self.storedAgents = storedAgents
        self.storedTools = storedTools
        self.storedAccounts = storedAccounts
        self.storedProjectSettings = storedProjectSettings
        self.pairedDevices = pairedDevices
        self.installID = installID
        self.fleetPort = fleetPort
        self.terminalFontSize = terminalFontSize
    }

    /// Falls back to claude-then-codex so a `Preferences` that has never been migrated
    /// behaves exactly as it always has, with claude on ⌘N.
    var agents: [AgentSettings] {
        get { storedAgents ?? Self.defaultAgents }
        set { storedAgents = newValue }
    }

    static let defaultAgents: [AgentSettings] = [
        AgentSettings(id: .claude, options: .claude(FlagSet())),
        AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
    ]

    /// Folds today's single-agent settings (`globalFlags`) into the list. Idempotent — safe
    /// to call on every load — so it never overwrites a list the user has already reordered.
    mutating func migrateAgentsIfNeeded() {
        guard storedAgents == nil else { return }
        storedAgents = [
            AgentSettings(id: .claude, options: .claude(globalFlags)),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
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

    var accounts: [AgentAccount] {
        get { storedAccounts ?? [] }
        set { storedAccounts = newValue }
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
    /// Cannot resurrect what the user removed: this never sets `storedAccounts` back to nil,
    /// so `migrateAccountsIfNeeded` never reseeds on a later launch. That is deliberate for an
    /// account the user removed, but it is not scoped per agent — if this purge empties one
    /// agent's accounts entirely, that agent stays empty; nothing here (or afterward) restores it.
    mutating func purgeRemovedAccounts() {
        // `accounts` is a computed view over `storedAccounts` whose setter writes back, so on
        // preferences that have never been migrated this get-modify-set would turn a nil
        // `storedAccounts` into `[]` — permanently defeating `migrateAccountsIfNeeded`'s
        // seed-once `guard storedAccounts == nil` and leaving the user with no accounts at
        // all, forever. Today's call site runs after that migration so it cannot happen; this
        // guard means it still cannot if the order ever changes, and it is honest besides:
        // there is nothing to purge.
        guard storedAccounts != nil else { return }
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
    /// Deliberately not a re-scan on later launches: a re-scan resurrects accounts the user
    /// removed. The Accounts pane offers "Scan for Accounts…" for additions made afterwards.
    mutating func migrateAccountsIfNeeded(
        // Overridable so tests can migrate against a temp directory instead of the real
        // `$HOME` — this scans for sibling account directories, which must never touch the
        // developer's actual `~/.claude` / `~/.codex`.
        homeRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard storedAccounts == nil else { return }
        var seeded: [AgentAccount] = []
        for agent in AgentID.allCases {
            let builtIn = homeRoot.appendingPathComponent(agent.builtInHome.lastPathComponent, isDirectory: true)
            seeded.append(AgentAccount(
                agent: agent,
                displayName: AccountDirectory.identity(atHome: builtIn, agent: agent)?.email ?? "Default",
                home: builtIn,
                cachedIdentity: AccountDirectory.identity(atHome: builtIn, agent: agent)
            ))
            for home in AccountDirectory.discover(in: homeRoot, agent: agent) {
                let identity = AccountDirectory.identity(atHome: home, agent: agent)
                seeded.append(AgentAccount(
                    agent: agent,
                    displayName: identity?.email ?? home.lastPathComponent,
                    home: home,
                    cachedIdentity: identity
                ))
            }
        }
        storedAccounts = seeded
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
