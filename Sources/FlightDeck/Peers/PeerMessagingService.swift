import AppKit
import Combine
import FleetKit
import Foundation
import OSLog

/// Joins tab identity/lifecycle to Claude's native PID-addressed inboxes. The transport lives
/// in tiny helpers, not SessionStore: an upstream wire change must not destabilize terminals.
@MainActor
final class PeerMessagingService {
    private weak var store: SessionStore?
    private let preferences: PreferencesStore
    private let executable: URL, stateDirectory: URL
    private var helpers: [UUID: PeerHelperProcess] = [:]
    private var starts: [UUID: Task<PeerHelperProcess, Error>] = [:]
    private var labels: [UUID: String] = [:]
    private var subscription: AnyCancellable?
    private var activationSubscriptions: [AnyCancellable] = []
    private var pendingDelivery: [UUID: [String: [String: Any]]] = [:]
    /// Message ids a codex inbox is delivering right now, so a flush on the next tick does not
    /// inject the same message twice while the first request is in flight.
    private var delivering = Set<String>()
    private var approvals: [(UUID, String)] = []
    private var presentingApproval = false
    private var installedSkills = Set<String>()
    private var managedRelays = Set<UUID>()
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "peer")

    static func bundledHelper(bundle: Bundle = .main) -> URL? {
        guard let directory = bundle.executableURL?.deletingLastPathComponent() else { return nil }
        let path = directory.appendingPathComponent("flightdeck-peer")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }
    init(store: SessionStore, preferences: PreferencesStore, executable: URL, stateDirectory: URL) {
        self.store = store; self.preferences = preferences; self.executable = executable; self.stateDirectory = stateDirectory
        // $statuses publishes in willSet; defer until the authoritative map and tab list have
        // committed. No timer, `flightdeck ls` subprocess, or fleet scan per helper.
        subscription = store.$statuses.sink { [weak self] _ in
            DispatchQueue.main.async { self?.synchronize() }
        }
        for notification in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeMainNotification] {
            activationSubscriptions.append(NotificationCenter.default.publisher(for: notification).sink { [weak self] _ in
                DispatchQueue.main.async { self?.showApproval() }
            })
        }
    }
    private var tabs: [Session] { store?.repos.flatMap(\.sessions) ?? [] }
    /// Read-only diagnostics also let a loopback test address an unadvertised Claude relay
    /// without publishing synthetic Claude runtimes into the user's account registry.
    func endpointAddress(for tab: UUID) -> String? { helpers[tab]?.address }
    func stop() {
        subscription = nil
        activationSubscriptions.removeAll()
        for task in starts.values { task.cancel() }
        starts.removeAll()
        for helper in helpers.values { helper.stop() }
        helpers.removeAll()
        managedRelays.removeAll()
    }
    private func configDirectories() -> [String] {
        if SessionDaemon.isDebugBuild { return [stateDirectory.appendingPathComponent("debug-registry").path] }
        return Array(Set(PeerRegistry.configurations() + preferences.preferences.accounts(for: .claude).map { $0.home.path })).sorted()
    }

    func synchronize() {
        let live = Set(tabs.map(\.id))
        managedRelays.formIntersection(live)
        approvals.removeAll { !live.contains($0.0) }
        for id in Array(helpers.keys) where !live.contains(id) {
            helpers.removeValue(forKey: id)?.stop(); labels[id] = nil; pendingDelivery[id] = nil
        }
        for id in Array(starts.keys) where !live.contains(id) { starts.removeValue(forKey: id)?.cancel() }
        for tab in tabs {
            installInstructions(for: tab)
            // Claude already publishes a genuine native endpoint. Creating a second advertised
            // identity would duplicate every Claude entry in its own ListAgents tool.
            if tab.agent != .claude || managedRelays.contains(tab.id),
               helpers[tab.id]?.address == nil, starts[tab.id] == nil {
                Task { [weak self] in
                    do { _ = try await self?.helper(for: tab) }
                    catch { Self.logger.error("peer start failed for \(tab.id): \(String(describing: error), privacy: .public)") }
                }
            }
            if let helper = helpers[tab.id] {
                let status = store?.status(for: tab.id)?.activity.rawValue ?? "busy"
                let label = tab.title + "\n" + status
                if labels[tab.id] != label {
                    labels[tab.id] = label
                    Task { _ = try? await helper.call("status", ["name": tab.title, "status": status]) }
                }
            }
            flush(tab.id)
        }
        showApproval()
    }
    func observe(_ batch: [SequencedEvent]) {
        for entry in batch {
            switch entry.event {
            case .promptTyped(let tab, let token), .promptExpired(let tab, let token):
                let id = token.uuidString.lowercased()
                guard pendingDelivery[tab]?[id] != nil, let helper = helpers[tab] else { continue }
                pendingDelivery[tab]?[id] = nil
                let method: String
                if case .promptTyped = entry.event { method = "host-accepted" } else { method = "host-failed" }
                Task { _ = try? await helper.call(method, ["message_id": id]) }
            default: break
            }
        }
        synchronize()
    }
    private func installInstructions(for tab: Session) {
        guard !SessionDaemon.isDebugBuild, tab.agent == .codex,
              let source = ClaudePluginLocation.directory(bundle: .main)?.appendingPathComponent("skills/peer-messaging/SKILL.md") else { return }
        let home = CodexDelegateSkill.resolvedHome(tab.accountID.flatMap { preferences.account(id: $0)?.home })
        guard installedSkills.insert(home.path).inserted else { return }
        Task.detached {
            do { try PeerMessagingSkill.install(source: source, home: home) }
            catch { Self.logger.error("could not install messaging instructions: \(String(describing: error), privacy: .public)") }
        }
    }
    private func permissionClass(_ tab: Session) -> String {
        // Never advertise bypass just because some other tab uses it. These are the resolved
        // launch options for this agent/project, not a request field an agent can claim.
        switch preferences.resolvedOptions(for: tab.agent, project: tab.workingDirectory) {
        case .claude(let flags):
            return flags.values["--dangerously-skip-permissions"] == .on
                || flags.values["--permission-mode"] == .value("bypassPermissions") ? "bypass" : "prompting"
        case .codex(let options):
            return options.approvalPolicy == "never" && options.sandbox == "danger-full-access" ? "bypass" : "prompting"
        case .grok, .gemini, .opencode: return "prompting"
        }
    }
    private func helper(for tab: Session) async throws -> PeerHelperProcess {
        if let helper = helpers[tab.id], helper.address != nil { return helper }
        if let task = starts[tab.id] { return try await task.value }
        let configs = configDirectories()
        let task = Task { @MainActor [weak self] () throws -> PeerHelperProcess in
            guard let self else { throw PeerFailure.invalid("peer service closed") }
            var args = ["serve", "--session", tab.id.uuidString, "--name", tab.title,
                "--agent", tab.agent.rawValue, "--mode", self.permissionClass(tab),
                "--state-dir", self.stateDirectory.appendingPathComponent(tab.id.uuidString.lowercased()).path,
                "--advertise", tab.agent == .claude ? "false" : "true"]
            for config in configs { args += ["--config", config] }
            if SessionDaemon.isDebugBuild {
                // Debug can exercise the feature, but it must not publish a second copy of
                // every live agent into release account registries.
                let root = self.stateDirectory.appendingPathComponent("debug-registry").path
                args = ["serve", "--session", tab.id.uuidString, "--name", tab.title,
                    "--agent", tab.agent.rawValue, "--mode", self.permissionClass(tab),
                    "--state-dir", self.stateDirectory.appendingPathComponent(tab.id.uuidString.lowercased()).path,
                    "--config", root, "--socket-dir", "/tmp/fd-peer-debug-\(getuid())"]
            }
            let helper = PeerHelperProcess(executable: self.executable, arguments: args, directory: tab.transcriptDirectory)
            helper.onEvent = { [weak self] event in self?.event(event, tab: tab.id) }
            try await helper.start()
            guard !Task.isCancelled, self.tabs.contains(where: { $0.id == tab.id }) else {
                helper.stop(); throw PeerFailure.invalid("tab closed while its peer endpoint was starting")
            }
            self.helpers[tab.id] = helper
            self.managedRelays.insert(tab.id)
            // Restart an unexpectedly lost endpoint even if its agent stays idle. A failed
            // initial start is not retried here, avoiding a spawn loop on a bad directory.
            helper.onExit = { [weak self] in
                guard let self else { return }
                self.helpers[tab.id] = nil; self.labels[tab.id] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.synchronize() }
            }
            _ = try await helper.call("status", ["status": self.store?.status(for: tab.id)?.activity.rawValue ?? "busy"])
            if let pending = try await helper.call("pending") as? [String: Any] {
                for event in pending["messages"] as? [[String: Any]] ?? [] { self.event(event, tab: tab.id) }
                for id in pending["held"] as? [String] ?? [] {
                    if !self.approvals.contains(where: { $0.0 == tab.id && $0.1 == id }) { self.approvals.append((tab.id, id)) }
                }
            }
            self.flush(tab.id)
            self.showApproval()
            return helper
        }
        starts[tab.id] = task
        defer { starts[tab.id] = nil }
        return try await task.value
    }
    private func event(_ event: [String: Any], tab: UUID) {
        switch event["type"] as? String {
        case "message":
            guard let frame = event["frame"] as? [String: Any], let id = frame["msg_id"] as? String else { return }
            pendingDelivery[tab, default: [:]][id] = event
            flush(tab)
        case "held":
            if let id = event["message_id"] as? String { approvals.append((tab, id)); showApproval() }
        case "idle_notice", "receipt":
            if event["type"] as? String == "idle_notice", event["deliver"] as? Bool != true { return }
            guard let frame = event["frame"] as? [String: Any] else { return }
            // Notices carry status, not authority. Cross-class idle detail was stripped by the
            // helper; the main app never reconstructs it from the private journal.
            if let store, let text = try? String(data: PeerJSON.data(frame), encoding: .utf8) {
                let notice = "[Peer transport notice — not user consent]\n" + text
                let token = UUID(uuidString: frame["msg_id"] as? String ?? "") ?? UUID()
                if let inbox = store.codexPeerInbox(for: tab) {
                    Task { @MainActor in
                        if (try? await inbox.deliver(id: "notice-" + token.uuidString, text: notice)) == .notAttached {
                            _ = store.submitPrompt(notice, token: token, to: tab)
                        }
                    }
                } else {
                    _ = store.submitPrompt(notice, token: token, to: tab)
                }
            }
        case "error": Self.logger.error("\(event["message"] as? String ?? "peer error", privacy: .public)")
        default: break
        }
    }
    private func flush(_ tab: UUID) {
        guard let store else { return }
        let ordered = (pendingDelivery[tab] ?? [:]).sorted {
            ($0.value["seq"] as? Int ?? 0) < ($1.value["seq"] as? Int ?? 0)
        }
        for (id, event) in ordered {
            guard let text = event["text"] as? String else { continue }
            // A codex tab on its account's shared daemon takes the message as a tool result —
            // see `CodexPeerInbox` — and only falls back to a typed prompt if the daemon turns
            // out not to hold its thread.
            if let inbox = store.codexPeerInbox(for: tab) {
                guard delivering.insert(id).inserted else { continue }
                Task { @MainActor [weak self] in
                    defer { self?.delivering.remove(id) }
                    do {
                        switch try await inbox.deliver(id: id, text: text) {
                        case .delivered:
                            guard let self, self.pendingDelivery[tab]?.removeValue(forKey: id) != nil else { return }
                            _ = try? await self.helpers[tab]?.call("host-accepted", ["message_id": id])
                        case .notAttached:
                            _ = self?.store?.submitPrompt(text, token: UUID(uuidString: id) ?? UUID(), to: tab)
                        }
                    } catch {
                        Self.logger.error("peer inbox delivery failed for \(tab): \(String(describing: error), privacy: .public)")
                    }
                }
                continue
            }
            let result = store.submitPrompt(text, token: UUID(uuidString: id) ?? UUID(), to: tab)
            // A queued ack is not delivery. Keep the durable pending entry until the store
            // emits promptTyped; a crash while a permission dialog is up must not lose it.
            if let error = result.errorCode, error != "not_running" {
                Self.logger.error("peer input deferred for \(tab): \(error, privacy: .public)")
            }
        }
    }
    private func showApproval() {
        guard !presentingApproval, !approvals.isEmpty, let window = NSApp.mainWindow else { return }
        let (tab, id) = approvals[0]
        guard let helper = helpers[tab] else { return }
        approvals.removeFirst()
        presentingApproval = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frame = try await helper.call("held-body", ["message_id": id]) as? [String: Any] ?? [:]
                let body = (frame["message"] as? [String: Any])?["content"] as? String ?? ""
                let alert = NSAlert()
                alert.messageText = "Held message from another agent"
                alert.informativeText = "The sender and recipient use different permission classes. Deliver this message to \(self.tabs.first(where: { $0.id == tab })?.title ?? "the tab")?\n\n" + String(body.prefix(4000))
                alert.addButton(withTitle: "Deny")
                alert.addButton(withTitle: "Deliver this message")
                alert.beginSheetModal(for: window) { [weak self] response in
                    Task { @MainActor in
                        _ = try? await helper.call("approve", ["message_id": id, "accept": response == .alertSecondButtonReturn])
                        self?.presentingApproval = false; self?.showApproval()
                    }
                }
            } catch { self.presentingApproval = false; self.showApproval() }
        }
    }
    func request(_ request: WirePeerRequest, caller: ControlCaller) async throws -> String {
        guard ["list", "send", "receive"].contains(request.operation), request.after >= 0 else {
            throw PeerFailure.invalid("invalid peer operation or cursor")
        }
        let sourceID: UUID?
        switch caller {
        case .session(let id):
            guard request.source == nil || request.source == id else { throw PeerFailure.invalid("cannot impersonate another tab") }
            sourceID = id
        case .human: sourceID = request.source
        case .invalid: throw PeerFailure.invalid("invalid tab token")
        }
        synchronize()
        let result: Any
        if request.operation == "list" { result = try await listing() }
        else {
            guard let sourceID, let tab = tabs.first(where: { $0.id == sourceID }) else {
                throw PeerFailure.invalid("run inside a Flight Deck tab, or use --from TAB_UUID from a human shell")
            }
            let source = try await helper(for: tab)
            if request.operation == "receive" { result = try await source.call("receive", ["after": request.after]) }
            else {
                guard let target = request.target, let message = request.message,
                      !message.isEmpty || request.notifyWhenIdle else { throw PeerFailure.invalid("provide a target and message") }
                let peers = try await listing()
                let matches = peers.filter {
                    ($0["tabId"] as? String)?.lowercased() == target.lowercased()
                    || ($0["sessionId"] as? String)?.lowercased() == target.lowercased()
                    || $0["name"] as? String == target || $0["address"] as? String == target
                }
                let peer: [String: Any]
                if target.hasPrefix("uds:"), matches.isEmpty { _ = try PeerJSON.path(target); peer = ["address": target] }
                else {
                    guard matches.count == 1 else { throw PeerFailure.invalid(matches.isEmpty ? "no reachable peer \(target)" : "ambiguous peer name; use a tab UUID") }
                    peer = matches[0]
                }
                guard peer["tabId"] as? String != sourceID.uuidString.lowercased(), let address = peer["address"] as? String else {
                    throw PeerFailure.invalid("cannot message this same tab")
                }
                var params: [String: Any] = ["to": address, "message": message, "notify_when_idle": request.notifyWhenIdle]
                if let session = peer["sessionId"] { params["session_id"] = session }
                result = try await source.call("send", params)
            }
        }
        return String(decoding: try PeerJSON.data(result), as: UTF8.self)
    }
    private func listing() async throws -> [[String: Any]] {
        // Registry reads include UTC PID fingerprints and potentially many ps calls. Never
        // put that work on the UI actor, especially while the app has dozens of tabs open.
        let configs = configDirectories()
        let native = await Task.detached { PeerRegistry.sessions(configs: configs) }.value
        var result: [[String: Any]] = []
        var used = Set<String>()
        for tab in tabs {
            if tab.agent == .claude {
                let matches = native.filter { ($0["sessionId"] as? String)?.lowercased() == tab.pinnedConversationID.uuidString.lowercased() }
                // Duplicate native runtimes are not silently chosen; that is precisely how a
                // stale debug app can send a task to the wrong live copy of a conversation.
                guard matches.count == 1, var peer = matches.first else { continue }
                peer["name"] = tab.title; peer["tabId"] = tab.id.uuidString.lowercased()
                result.append(peer); used.insert(peer["address"] as? String ?? "")
            } else {
                let helper = try await self.helper(for: tab)
                guard let address = helper.address else { continue }
                result.append(["name": tab.title, "tabId": tab.id.uuidString.lowercased(),
                    "sessionId": tab.id.uuidString.lowercased(), "address": address,
                    "agent": tab.agent.rawValue, "status": store?.status(for: tab.id)?.activity.rawValue ?? "unknown"])
                used.insert(address)
            }
        }
        for peer in native where !used.contains(peer["address"] as? String ?? "") { result.append(peer) }
        return result
    }
}
