import AppKit
import IntakeKit
import SwiftUI
@testable import FlightDeck

// The menu-bar regression gate (scripts/test-menu-bar.sh). A bare SwiftUI app, linked against
// this checkout's Debug dylib, that installs the app's real command set and its real AppKit menu
// controllers, hosts the real RootView over two Flight Control projects (each with a shaping
// plan) and a terminal tab, then drives the transitions the maintainer saw blink and counts every item
// SwiftUI removes from the main menu.
//
// A unit test can't do this: only a SwiftUI `App` scene builds a menu bar from `Commands`.
// It never activates, so it takes no focus from whoever is typing. The cost: with the app
// inactive no window is key, so focused values never flow and key-window changes can't be
// driven — the `MenuBarStabilityTests` guard is what keeps focused values out of `Commands`.
//
// Compiled with -D BEFORE it installs the command set and menus as they were on 956ee992
// instead (the AppKit top-level Tools menu, the observing SessionCommands, the focused-value
// Run menu), to show the gate fails there.

final class NullPersistence: SessionPersisting {
    func load() -> SessionSnapshot? { nil }
    func save(_ snapshot: SessionSnapshot) {}
}

@MainActor
enum Fixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-menubar-\(UUID())")
    static let prefs: PreferencesStore = {
        let prefs = PreferencesStore(persistence: nil)
        // No real accounts: the rows must not depend on this Mac's logins.
        prefs.preferences.accounts = []
        return prefs
    }()
    static let store = SessionStore(provider: nil, persistence: NullPersistence(), preferences: prefs, intakesRoot: root)
    static var a: Repo!
    static var b: Repo!
    static var sessionA: UUID!
    static var sessionB: UUID!
    static var intakeA: UUID!

    static func seed() throws {
        let tag = UUID().uuidString.prefix(8)
        store.newSession(in: URL(fileURLWithPath: "/w/menubar-a-\(tag)", isDirectory: true))
        sessionA = store.selectedSessionID
        store.newSession(in: URL(fileURLWithPath: "/w/menubar-b-\(tag)", isDirectory: true))
        sessionB = store.selectedSessionID
        a = store.repos.first { $0.url.path.hasSuffix("menubar-a-\(tag)") }
        b = store.repos.first { $0.url.path.hasSuffix("menubar-b-\(tag)") }
        for (repo, agent) in [(a!, AgentID.codex), (b!, AgentID.claude)] {
            var settings = prefs.projectSettings(repo.url.path)
            settings.flywheelEnabled = true
            settings.defaultAgent = agent   // different orders, so the New Session rows differ
            prefs.setProjectSettings(repo.url.path, settings)
            try seedShaping(project: repo.url.standardizedFileURL.path)
        }
        let service = store.intakeService
        service.pollTapes()
        for repo in [a!, b!] {
            let path = repo.url.standardizedFileURL.path
            service.select(service.intakes(forProject: path).first?.id, inProject: path)
            service.setInspectorShown(true, inProject: path)
        }
        intakeA = service.intakes(forProject: a.url.standardizedFileURL.path).first?.id
    }

    static func seedShaping(project: String) throws {
        var intake = Intake(projectPath: project, intent: "Plan the thing")
        intake.state = .shaping
        intake.recommended = .featurePlan
        intake.chosenPreset = .featurePlan
        intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        try IntakeStore(root: root).save(intake)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: intake.id))
        var tape = tapes.loadTape()
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data("# Plan\n\nSome words.\n".utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
    }
}

var removalsByMenu: [String: Int] = [:]
var missingAtChecks: [String: Int] = [:]
/// Evidence the transitions did something: our own rewrites, and the most windows seen.
var ownedRewrites = 0
var maxWindows = 0
var newSessionTitles = Set<String>()

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var observers: [NSObjectProtocol] = []
    #if BEFORE
    lazy var tools = ToolsMenuController()
    lazy var inspector = InspectorMenuController()
    #else
    lazy var tools = ToolsMenuController()
    lazy var inspector = InspectorMenuController()
    lazy var run = RunMenuController()
    lazy var newSession = NewSessionMenuController(store: Fixture.store, preferences: Fixture.prefs)
    #endif
    var extra: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            for window in NSApp.windows { window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { MainActor.assumeIsolated { self.go() } }
    }

    @MainActor func install(_ main: NSMenu) {
        tools.tools = [ToolDefinition(name: "Editor", symbol: "gear", command: "true",
                                      shortcut: ToolShortcut(key: "o", modifiers: [.command]))]
        tools.install(in: main)
        #if BEFORE
        inspector.install(in: main)
        #else
        inspector.install(in: main)
        run.install(in: main)
        newSession.install(in: main)
        #endif
    }

    /// Every item our controllers own right now.
    @MainActor func ownedItems() -> [NSMenuItem] {
        #if BEFORE
        return tools.menu.items
        #else
        func flatten(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + flatten($0.submenu?.items ?? []) } }
        return flatten(tools.items + inspector.items + run.items + newSession.items)
        #endif
    }

    /// The AppKit items that must be in the bar at every check, by the menu that holds them.
    @MainActor func ours(_ main: NSMenu) -> [(String, Bool)] {
        var result: [(String, Bool)] = [("Tools", main.items.contains { $0.submenu?.items.contains(where: { $0.title == "Editor" }) ?? false })]
        #if !BEFORE
        let view = main.items.first { $0.submenu?.title == "View" }?.submenu
        let inspectorMenu = view?.items.first { $0.submenu?.title == InspectorMenuShell.title }?.submenu
        result.append(("View ▸ Inspector", inspectorMenu?.items.contains { $0.title == "Notes" } ?? false))
        result.append(("Run", main.items.first { $0.submenu?.title == RunMenuShell.title }?.submenu?.items.contains { $0.title == "Step" } ?? false))
        let file = main.items.first { $0.submenu?.title == "File" }?.submenu
        result.append(("File ▸ New Session", file?.items.contains { $0.title.hasPrefix("New ") && $0.title.hasSuffix(" Session") } ?? false))
        #endif
        return result
    }

    @MainActor func go() {
        do { try Fixture.seed() } catch { print("seed failed: \(error)"); exit(2) }
        guard let main = NSApp.mainMenu else { print("no main menu"); exit(2) }
        install(main)
        let store = Fixture.store
        let service = store.intakeService
        let prefs = Fixture.prefs
        var steps: [(String, () -> Void)] = []
        func add(_ name: String, _ times: Int, _ action: @escaping (Int) -> Void) {
            for i in 0..<times { steps.append((name, { action(i) })) }
        }
        add("tab switch between two projects' terminals", 10) { i in store.selectSession(i % 2 == 0 ? Fixture.sessionA : Fixture.sessionB) }
        add("plan <-> terminal (Flight Control project view)", 10) { i in
            if i % 2 == 0 { store.selectProject(Fixture.a.id) } else { store.selectSession(Fixture.sessionB) }
        }
        add("plan <-> plan (two projects)", 10) { i in store.selectProject((i % 2 == 0 ? Fixture.a : Fixture.b).id) }
        add("inspector mode switch", 10) { i in
            store.selectProject(Fixture.a.id)
            service.setInspectorMode(i % 2 == 0 ? .notes : .rounds, for: Fixture.intakeA)
        }
        add("intake state change (selection, inspector shown, tape poll)", 10) { i in
            let path = Fixture.a.url.standardizedFileURL.path
            switch i % 3 {
            case 0: service.setInspectorShown(i % 2 == 0, inProject: path)
            case 1: service.select(i % 2 == 0 ? nil : Fixture.intakeA, inProject: path)
            default: service.pollTapes()
            }
        }
        add("preference edit (a project's default agent)", 6) { i in
            var settings = prefs.projectSettings(Fixture.b.url.path)
            settings.defaultAgent = i % 2 == 0 ? .grok : .claude
            prefs.setProjectSettings(Fixture.b.url.path, settings)
        }
        add("Settings window open/close", 6) { i in
            if i % 2 == 0 {
                // The app menu's own Settings… item, as a click would fire it.
                let appMenu = main.items.first?.submenu
                if let index = appMenu?.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
                    appMenu?.performActionForItem(at: index)
                }
            }
            else { NSApp.windows.filter { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") }.forEach { $0.close() } }
        }
        add("second window open/close", 6) { [weak self] i in
            if i % 2 == 0 {
                let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: Text("other"))
                w.orderFrontRegardless()
                self?.extra = w
            } else { self?.extra?.close() }
        }

        // Every item removed from the bar or from a menu that holds our items, by menu — except
        // our own controllers moving their own items (New Session rewriting itself for the
        // current project), which is AppKit editing what it owns, not the bar being rebuilt.
        // Each notification is matched against the menu's items as last seen to find what went.
        var lastSeen: [ObjectIdentifier: [NSMenuItem]] = [:]
        var owned = Set<ObjectIdentifier>()
        func watched(_ menu: NSMenu) -> Bool {
            menu === main || ["File", "View", "Tools", "Run", "Inspector"].contains(menu.title)
        }
        func record(_ menu: NSMenu) { lastSeen[ObjectIdentifier(menu)] = menu.items }
        func recordAll() {
            for item in main.items { if let sub = item.submenu { record(sub); for inner in sub.items { if let deeper = inner.submenu { record(deeper) } } } }
            record(main)
            for item in ownedItems() { owned.insert(ObjectIdentifier(item)) }
        }
        recordAll()
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, watched(menu) else { return }
            MainActor.assumeIsolated {
                for item in self.ownedItems() { owned.insert(ObjectIdentifier(item)) }
                record(menu)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didRemoveItemNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, watched(menu) else { return }
            let now = Set(menu.items.map(ObjectIdentifier.init))
            let gone = (lastSeen[ObjectIdentifier(menu)] ?? []).filter { !now.contains(ObjectIdentifier($0)) }
            record(menu)
            if !gone.isEmpty && gone.allSatisfy({ owned.contains(ObjectIdentifier($0)) }) { ownedRewrites += 1; return }
            let name = menu === main ? "main menu (top-level)" : menu.title
            removalsByMenu[name, default: 0] += 1
        })
        var index = 0
        var lines: [String] = []
        var current = ""
        var baseRemovals: [String: Int] = [:]
        var baseMissing: [String: Int] = [:]
        var failed = false
        func flush() {
            guard !current.isEmpty else { return }
            let removed = removalsByMenu.compactMap { key, value in value - (baseRemovals[key] ?? 0) > 0 ? "\(key) \(value - (baseRemovals[key] ?? 0))" : nil }
            let missing = missingAtChecks.compactMap { key, value in value - (baseMissing[key] ?? 0) > 0 ? "\(key) \(value - (baseMissing[key] ?? 0))" : nil }
            if !removed.isEmpty || !missing.isEmpty { failed = true }
            lines.append("\(current): removals=[\(removed.sorted().joined(separator: ", "))] missingAtChecks=[\(missing.sorted().joined(separator: ", "))]"
                         + " (own rewrites \(ownedRewrites - baseRewrites), windows up to \(maxWindows), File leads with \(newSessionTitles.sorted()),"
                         + " redraws \(RenderProbe.counts.filter { ["project", "detail", "inspector"].contains($0.key) }.sorted { $0.key < $1.key })")
            maxWindows = 0
            newSessionTitles = []
        }
        var baseRewrites = 0
        func check() {
            for (name, present) in ours(main) where !present { missingAtChecks[name, default: 0] += 1 }
            maxWindows = max(maxWindows, NSApp.windows.filter(\.isVisible).count)
            if let first = main.items.first(where: { $0.submenu?.title == "File" })?.submenu?.items.first { newSessionTitles.insert(first.title) }
        }
        func tick() {
            check()
            if index == steps.count {
                flush()
                print("MENUBAR active=\(NSApp.isActive)")
                print(lines.joined(separator: "\n"))
                print(failed ? "MENUBAR FAIL" : "MENUBAR PASS")
                exit(failed ? 1 : 0)
            }
            let (name, action) = steps[index]
            if name != current {
                flush()
                current = name
                baseRemovals = removalsByMenu
                baseMissing = missingAtChecks
                baseRewrites = ownedRewrites
                RenderProbe.reset()
            }
            action()
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { recordAll(); tick() } }
        }
        tick()
    }
}

@main
struct MenuBarHarnessApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            RootView(store: Fixture.store, preferences: Fixture.prefs)
                .frame(width: 1000, height: 700)
        }
        .commands {
            #if BEFORE
            SessionCommands(store: Fixture.store, preferences: Fixture.prefs)
            EditCommands()
            FontSizeCommands(store: Fixture.store, preferences: Fixture.prefs)
            TabNavigationCommands(store: Fixture.store)
            SearchCommands()
            PlanningCommands()
            ShortcutOverlayCommands()
            #else
            FlightDeckCommands(store: Fixture.store, preferences: Fixture.prefs)
            #endif
        }
        Settings { Text("Settings").frame(width: 300, height: 200) }
    }
}
