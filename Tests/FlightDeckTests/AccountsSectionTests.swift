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

    /// The built-in account is removable like any other now. It is not special — it is simply
    /// what a nil `Session.accountID` resolves to, and a tombstone keeps resolving.
    func testTheBuiltInAccountCanBeRemovedWhenAnotherAccountRemains() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertTrue(AccountsSection.canRemove(builtIn, among: [builtIn, work]))
    }

    /// The one refusal left: there must always be at least one account per agent.
    func testAnAgentsLastAccountCannotBeRemoved() {
        let only = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        XCTAssertFalse(AccountsSection.canRemove(only, among: [only]))
    }

    /// Live sessions no longer refuse removal — they only change the warning. A tombstone
    /// keeps the account resolvable, so those tabs keep their identity.
    func testAnAccountWithLiveSessionsCanStillBeRemoved() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let other = AgentAccount(agent: .claude, displayName: "O", home: temporary("o"))
        XCTAssertTrue(AccountsSection.canRemove(work, among: [work, other]))
    }

    /// Relocating is NOT removing, and keeps the old guard. Moving a home out from under a
    /// running agent leaves its already-forked shell pointed at the old path, and relocating
    /// the built-in account makes `isBuiltIn` false — which changes what a nil
    /// `Session.accountID` resolves to.
    func testRelocateStillRefusesTheBuiltInAccountAndLiveSessions() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertFalse(AccountsSection.canRelocate(builtIn, boundAccountIDs: []))
        XCTAssertFalse(AccountsSection.canRelocate(work, boundAccountIDs: [work.id]))
        XCTAssertTrue(AccountsSection.canRelocate(work, boundAccountIDs: []))
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
        let other = AgentAccount(agent: .claude, displayName: "O", home: temporary("o"))
        store.preferences.storedAccounts = [work, other]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, in: store) {
            trashed.append($0)
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(trashed, [work.home])
    }

    /// An agent's last account must never reach the trash closure, no matter what disables the
    /// menu item — `deleteFiles` re-checks this itself immediately before the call.
    func testDeleteFilesRefusesAnAgentsLastAccount() {
        let store = PreferencesStore(persistence: nil)
        let only = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [only]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: only.id, in: store) {
            trashed.append($0)
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: only.home.path), "the refusal never touches disk")
    }

    /// Live sessions warn, they do not refuse — see the accepted risk in the spec.
    func testDeleteFilesIsPermittedWithLiveSessions() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let other = AgentAccount(agent: .claude, displayName: "O", home: temporary("o"))
        store.preferences.storedAccounts = [work, other]

        var trashed: [URL] = []
        let ok = AccountsSection.deleteFiles(accountID: work.id, in: store) {
            trashed.append($0)
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(trashed, [work.home])
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

    /// Removal is a soft delete now — the record stays, tombstoned, so a legacy or running tab
    /// keeps resolving it. Only the LIST this section renders from must go empty.
    func testRemoveTakesAnOrdinaryAccountOutOfTheList() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let other = AgentAccount(agent: .claude, displayName: "O", home: temporary("o"))
        store.preferences.storedAccounts = [work, other]

        XCTAssertTrue(AccountsSection.remove(accountID: work.id, in: store))
        XCTAssertTrue(store.account(id: work.id)?.isRemoved == true)
        XCTAssertTrue(store.preferences.accounts(for: .claude).allSatisfy { $0.id != work.id })
    }

    /// The confirmation dialog can sit open while the account list changes underneath it — an
    /// agent's last account can be removed out from under the dialog just as easily as it can
    /// arrive after the button was already disabled — so the press re-checks the same rule.
    func testRemoveRefusesAnAgentsLastAccountEvenIfTheDialogWasAlreadyOpen() {
        let store = PreferencesStore(persistence: nil)
        let only = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [only]

        XCTAssertFalse(AccountsSection.remove(accountID: only.id, in: store))
        XCTAssertEqual(store.preferences.accounts.map(\.id), [only.id], "the registry entry survives")
    }

    func testRemoveRefusesAnAccountThatIsAlreadyGone() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertFalse(AccountsSection.remove(accountID: UUID(), in: store))
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
