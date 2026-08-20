import XCTest
@testable import FlightDeck

@MainActor
final class AccountsSectionTests: XCTestCase {
    /// Everything this suite names on disk lives under here, so nothing is ever created,
    /// listed or trashed outside the temporary directory.
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A path under this test's own temporary root. Not created — most of these tests only
    /// need a home that no other account claims.
    private func temporary(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    private func makeDirectory(_ name: String, containing entries: [String: String] = [:]) throws -> URL {
        let url = temporary(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, contents) in entries {
            try contents.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return url
    }

    func testDefaultHomeIsDerivedFromTheNameAndAgent() {
        let home = AccountDraft.defaultHome(for: .claude, name: "Field Wealth")
        XCTAssertEqual(home.lastPathComponent, ".claude-field-wealth")
        XCTAssertEqual(AccountDraft.defaultHome(for: .codex, name: "Work").lastPathComponent, ".codex-work")
    }

    func testTheBuiltInAccountCannotBeRemoved() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        XCTAssertFalse(AccountsSection.canRemove(builtIn, boundAccountIDs: []))
    }

    func testAnAccountWithLiveSessionsCannotBeRemovedOrRelocated() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertFalse(AccountsSection.canRemove(work, boundAccountIDs: [work.id]))
        XCTAssertTrue(AccountsSection.canRemove(work, boundAccountIDs: []))
    }

    /// Two accounts on one home would put two `CodexStack`s on one `session_index.jsonl`, so the
    /// sheet refuses before anything is created rather than failing later at launch.
    func testTheAddSheetRefusesAHomeAnotherAccountAlreadyUses() {
        let store = PreferencesStore(persistence: nil)
        let taken = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [taken]
        XCTAssertEqual(
            AccountDraft.validate(home: taken.home.path, agent: .claude, editing: nil, in: store),
            .homeAlreadyUsed
        )
        XCTAssertEqual(
            AccountDraft.validate(home: temporary("other").path, agent: .claude, editing: nil, in: store),
            .ok
        )
    }

    /// `deleteFiles` never touches a real directory in this suite — a spy stands in for the
    /// Trash so the run leaves no junk behind, and it hermetically proves the call site is the
    /// account's own `home` and nothing else.
    func testDeleteFilesTrashesTheAccountsOwnHomeForAnOrdinaryAccount() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [work]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, boundAccountIDs: [], in: store) {
            trashed.append($0)
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(trashed, [work.home])
    }

    /// The built-in home must never reach the trash closure, no matter what disables the menu
    /// item — `deleteFiles` re-checks this itself immediately before the call.
    func testDeleteFilesRefusesTheBuiltInAccount() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [builtIn]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: builtIn.id, boundAccountIDs: [], in: store) {
            trashed.append($0)
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(trashed.isEmpty)
    }

    /// Same guard, the other reason: an account with a tab open on it right now must not have
    /// its home pulled out from under that tab.
    func testDeleteFilesRefusesAnAccountWithLiveSessions() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [work]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, boundAccountIDs: [work.id], in: store) {
            trashed.append($0)
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(trashed.isEmpty)
    }

    // MARK: Home plausibility

    /// A cleared Location field is refused *as empty*, not as a bad folder. `URL(fileURLWithPath: "")`
    /// resolves to the process working directory, so without the text-level check the sheet
    /// would happily file an account whose home is the cwd — and offer to trash it later.
    func testAnEmptyLocationIsRefused() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertEqual(AccountDraft.validate(home: "", agent: .claude, editing: nil, in: store), .locationEmpty)
        XCTAssertEqual(AccountDraft.validate(home: "   ", agent: .claude, editing: nil, in: store), .locationEmpty)
    }

    /// The sanity rule's accepting half: a directory the agent already lives in, and a path
    /// Flight Deck is about to create.
    func testAnExistingAgentHomeAndAFreshPathAreBothAccepted() throws {
        let store = PreferencesStore(persistence: nil)
        let existing = try makeDirectory("signed-in", containing: [".claude.json": "{}"])
        XCTAssertEqual(
            AccountDraft.validate(home: existing.path, agent: .claude, editing: nil, in: store), .ok
        )
        XCTAssertEqual(
            AccountDraft.validate(home: temporary("brand-new").path, agent: .claude, editing: nil, in: store),
            .ok, "nothing there yet, so Add creates it"
        )
        XCTAssertEqual(
            AccountDraft.validate(home: try makeDirectory("empty").path, agent: .claude, editing: nil, in: store),
            .ok, "an empty folder holds nothing to lose"
        )
    }

    /// The rule that stops "Also Delete Files…" from ever being pointed at somebody's source
    /// tree: a directory with files in it that are not this agent's login is refused outright.
    func testADirectoryThatIsNotAnAgentHomeAndNotEmptyIsRefused() throws {
        let store = PreferencesStore(persistence: nil)
        let project = try makeDirectory("project", containing: ["README.md": "hi"])
        XCTAssertEqual(
            AccountDraft.validate(home: project.path, agent: .claude, editing: nil, in: store),
            .notAnAgentHome
        )
        XCTAssertEqual(
            AccountDraft.validate(home: project.path, agent: .codex, editing: nil, in: store),
            .notAnAgentHome, "the marker is per agent — a claude home is not a codex home"
        )
    }

    /// A path that exists as a file is not a directory an agent could ever write a home into.
    func testAFileIsNotAPlausibleHome() throws {
        let store = PreferencesStore(persistence: nil)
        let file = root.appendingPathComponent("not-a-directory")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(AccountDirectory.isVacant(file))
        XCTAssertEqual(
            AccountDraft.validate(home: file.path, agent: .claude, editing: nil, in: store),
            .notAnAgentHome
        )
    }

    /// Relocating a home back onto itself is not a collision, and an agent home stays valid
    /// for its own account.
    func testRelocatingAnAccountOntoItsOwnHomeIsAccepted() throws {
        let store = PreferencesStore(persistence: nil)
        let home = try makeDirectory("mine", containing: [".claude.json": "{}"])
        let account = AgentAccount(agent: .claude, displayName: "M", home: home)
        store.preferences.storedAccounts = [account]
        XCTAssertEqual(
            AccountDraft.validate(home: home.path, agent: .claude, editing: account.id, in: store), .ok
        )
    }

    /// Every refusal says something the user can act on; a good draft says nothing at all.
    func testEveryRefusalCarriesAMessageAndOkCarriesNone() {
        XCTAssertNil(AccountDraft.Validation.ok.message(for: .claude))
        for reason in [AccountDraft.Validation.locationEmpty, .homeAlreadyUsed, .notAnAgentHome] {
            XCTAssertFalse(reason.message(for: .claude)?.isEmpty ?? true, "\(reason) needs a message")
        }
        XCTAssertTrue(
            AccountDraft.Validation.notAnAgentHome.message(for: .codex)?.contains("Codex") ?? false,
            "the folder message names the agent whose home was expected"
        )
    }

    // MARK: Remove, re-guarded at press time

    func testRemoveDropsAnOrdinaryAccount() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [work]

        XCTAssertTrue(AccountsSection.remove(accountID: work.id, boundAccountIDs: [], in: store))
        XCTAssertTrue(store.preferences.accounts.isEmpty)
    }

    /// The confirmation dialog can sit open while a tab binds to the account. Removing it then
    /// would flip that tab's `AgentInstance` key from `id` to nil mid-run — stranding its
    /// watchers and building a second codex stack on `builtInHome` — so the press re-checks.
    func testRemoveRefusesAnAccountABoundSessionAcquiredWhileTheDialogWasOpen() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [work]

        XCTAssertFalse(AccountsSection.remove(accountID: work.id, boundAccountIDs: [work.id], in: store))
        XCTAssertEqual(store.preferences.accounts.map(\.id), [work.id], "the registry entry survives")
    }

    func testRemoveRefusesTheBuiltInAccount() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [builtIn]

        XCTAssertFalse(AccountsSection.remove(accountID: builtIn.id, boundAccountIDs: [], in: store))
        XCTAssertEqual(store.preferences.accounts.map(\.id), [builtIn.id])
    }

    func testRemoveRefusesAnAccountThatIsAlreadyGone() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertFalse(AccountsSection.remove(accountID: UUID(), boundAccountIDs: [], in: store))
    }

    // MARK: Bound sessions, by resolved id

    /// Spec §9: a tab that stores no account is bound to the agent's **built-in** account, not
    /// to nothing. Reading `Session.accountID` raw would show the built-in account as unbound
    /// while a legacy tab is running inside it.
    func testASessionStoringNoAccountCountsAsBoundToTheBuiltInAccount() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [builtIn]
        let legacy = Session(title: "t", workingDirectory: "/p", agent: .claude, accountID: nil)

        let bound = AccountsSection.boundAccountIDs(in: [legacy], resolvedBy: store)
        XCTAssertEqual(bound, [builtIn.id])
        XCTAssertFalse(AccountsSection.canRemove(builtIn, boundAccountIDs: bound))
        XCTAssertFalse(AccountsSection.remove(accountID: builtIn.id, boundAccountIDs: bound, in: store))
    }

    /// The other two shapes, so the resolution is not just "always the built-in": a stored id
    /// binds itself, and an id that no longer resolves binds nothing — it must not be read as
    /// the built-in account and hold *that* account hostage.
    func testAStoredIdBindsItselfAndADanglingIdBindsNothing() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        store.preferences.storedAccounts = [builtIn, work]

        let onWork = Session(title: "t", workingDirectory: "/p", agent: .claude, accountID: work.id)
        let dangling = Session(title: "t", workingDirectory: "/p", agent: .claude, accountID: UUID())

        XCTAssertEqual(AccountsSection.boundAccountIDs(in: [onWork], resolvedBy: store), [work.id])
        XCTAssertTrue(AccountsSection.boundAccountIDs(in: [dangling], resolvedBy: store).isEmpty)
    }

    /// A codex tab must not pin a claude account, and vice versa: resolution is per agent.
    func testASessionForTheOtherAgentDoesNotBindThisAgentsBuiltInAccount() {
        let store = PreferencesStore(persistence: nil)
        let claude = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let codex = AgentAccount(agent: .codex, displayName: "D", home: AgentID.codex.builtInHome)
        store.preferences.storedAccounts = [claude, codex]
        let tab = Session(title: "t", workingDirectory: "/p", agent: .codex, accountID: nil)

        XCTAssertEqual(AccountsSection.boundAccountIDs(in: [tab], resolvedBy: store), [codex.id])
    }
}
