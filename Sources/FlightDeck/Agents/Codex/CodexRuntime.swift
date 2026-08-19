import Foundation

/// Codex's observation half: one app-server for the whole app, notifications routed by
/// `threadId`.
///
/// One connection rather than one per tab is not an optimisation — a thread lives in the
/// app-server process that created it, so a per-call process would lose every thread it
/// made the moment it exited.
@MainActor
final class CodexRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        var state = CodexThreadState()
        /// A reconcile is scheduled or in flight. Guards against a burst scheduling one per
        /// notification; cleared again when a read is dropped, so the next notification
        /// retries. See `finishReconcile`.
        var reconcileScheduled = false
        /// How many more reads this attachment may spend. Bounded because the retry above is
        /// otherwise one read per notification on a busy thread — which is the thread that
        /// needs reconciling least, since its notifications are keeping it current already.
        var reconcilesRemaining = CodexRuntime.reconcileAttempts
        /// Counts notifications that CHANGED something for this thread. Strictly increasing
        /// is the only property it needs: it is compared for equality, never read as a
        /// quantity. A notification the mapper turns into no events is deliberately not
        /// counted — it moved nothing, so it cannot have made a read stale.
        var version = 0
        /// The `version` an in-flight read was ISSUED against; nil when none is.
        var reconcilingAt: Int?
        /// Which reconcile that is. Drawn from a runtime-wide monotonic sequence and never
        /// reused, so a read belonging to a *replaced* attachment can never match the
        /// replacement's — a per-attachment counter restarts at attach and would.
        var reconcileToken: Int?
    }

    /// Reads one attachment may spend before it stops retrying. Three rather than one because
    /// a retry only happens when a read was overtaken, and rather than unbounded because
    /// sustained traffic would otherwise mean a read per notification forever.
    private static let reconcileAttempts = 3

    /// The reconcile a delivery belongs to, carried task-locally.
    ///
    /// `reconcile` is an injected `(UUID) async -> Void`: there is no parameter to thread a
    /// token through a closure whose body this class does not own, and changing that
    /// signature would mean rewriting a test that predates this work. A task-local propagates
    /// across every `await` inside the closure for free, and reading it in `applyReconciled`
    /// is what makes a delivery identifiable rather than merely plausible.
    @TaskLocal private static var deliveringReconcile: Int?

    private var attachments: [UUID: Attachment] = [:]
    private var nextReconcileToken = 0
    private let rpc: CodexRPC

    /// Re-reads authoritative title and status for a thread. Injected so tests need no
    /// server; production wires it to `thread/read` — see `reconcileByReading`.
    var reconcile: (UUID) async -> Void = { _ in }

    init(rpc: CodexRPC) {
        self.rpc = rpc
        rpc.onNotification = { [weak self] method, params in
            self?.handle(method: method, params: params)
        }
    }

    /// Points `reconcile` at codex's own `thread/read`.
    ///
    /// A method rather than a closure written where the stack is built, so the production
    /// wire is reachable from a test: `SessionStore`'s `CodexStack` holds a
    /// `CodexProcessTransport` no committed test may start, and a closure written inside its
    /// initializer could only ever be exercised against that.
    ///
    /// The closure reads and nothing else — the write goes back through `applyReconciled`,
    /// which is where the ordering guard lives. Nothing wired here may touch tab state
    /// directly. The adapter is captured by value (a struct over the same `rpc`); `self`
    /// weakly, because `self` is what owns this closure.
    func reconcileByReading(with adapter: CodexAdapter) {
        reconcile = { [weak self] id in
            guard let state = try? await adapter.read(
                AgentBinding(conversationID: id, transcriptURL: nil)
            ) else { return }
            self?.applyReconciled(title: state.title, activity: state.activity, for: id)
        }
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        attachments[binding.conversationID] = Attachment(onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        attachments[binding.conversationID] = nil
    }

    func handle(method: String, params: [String: Any]) {
        guard let raw = params["threadId"] as? String,
              let id = UUID(uuidString: raw),
              var attachment = attachments[id]
        else { return }

        // Reconcile-on-first-contact. A tab whose codex sat behind the directory-trust or
        // hooks-review prompt produced nothing until the user cleared it, so its title and
        // status are stale by exactly one read. Doing this on first contact rather than on a
        // timer means no polling and no arbitrary delay.
        //
        // Only scheduled here. The version it is measured against is taken when the read is
        // actually ISSUED, inside the task — see `beginReconcile`.
        if !attachment.reconcileScheduled, attachment.reconcilesRemaining > 0 {
            attachment.reconcileScheduled = true
            Task { await self.runReconcile(for: id) }
        }

        let events = CodexEventMapper.events(method: method, params: params, state: &attachment.state)
        // Counted only when the notification actually said something. An `item/started` for
        // an item this app does not model, or a `thread/status/changed` carrying a status the
        // mapper does not recognise, moves nothing — and a read invalidated by a notification
        // that changed nothing is a read thrown away for no reason.
        if !events.isEmpty { attachment.version += 1 }
        attachments[id] = attachment
        for event in events { attachment.onEvent(event) }
    }

    /// One reconcile, from issue to delivery, under a token of its own.
    ///
    /// The three steps are separated so the middle one — the injected closure, which may do
    /// anything and takes as long as an RPC takes — is bracketed by state this class controls.
    private func runReconcile(for id: UUID) async {
        guard let token = beginReconcile(for: id) else { return }
        await Self.$deliveringReconcile.withValue(token) { await reconcile(id) }
        finishReconcile(for: id, token: token)
    }

    /// Stamps the read about to be issued, and returns the token it is issued under.
    ///
    /// Called from inside the task rather than from `handle`, which is the whole point.
    /// `CodexProcessTransport` delivers every line of one pipe chunk in a single synchronous
    /// loop, so first contact is routinely a burst of notifications — and all of it lands
    /// before this task gets a slice. None of it can have made the read stale: the read has
    /// not been sent yet, and codex answers it with everything those notifications reported.
    /// Sampling `version` here rather than at schedule time is therefore not a workaround but
    /// the correct measurement — only a notification that arrives after the read is issued
    /// can describe something the answer does not already contain.
    private func beginReconcile(for id: UUID) -> Int? {
        guard var attachment = attachments[id], attachment.reconcilesRemaining > 0 else { return nil }
        nextReconcileToken += 1
        attachment.reconcilesRemaining -= 1
        attachment.reconcilingAt = attachment.version
        attachment.reconcileToken = nextReconcileToken
        attachments[id] = attachment
        return nextReconcileToken
    }

    /// Re-arms when a read came home to nothing.
    ///
    /// `applyReconciled` clears `reconcilingAt` on delivery, so a token still holding one
    /// means the read was dropped — overtaken by a notification, or never answered at all.
    /// Abandoning it there would leave the tab stale for the life of the attachment on the
    /// strength of one unlucky interleaving; re-arming lets the next notification try again,
    /// within `reconcilesRemaining`.
    private func finishReconcile(for id: UUID, token: Int) {
        guard var attachment = attachments[id],
              attachment.reconcileToken == token,
              attachment.reconcilingAt != nil
        else { return }
        attachment.reconcilingAt = nil
        attachment.reconcileToken = nil
        attachment.reconcileScheduled = false
        attachments[id] = attachment
    }

    /// Delivers what `reconcile` read — but only if nothing has moved under it.
    ///
    /// This is the ordering guard the injected `reconcile` cannot provide for itself.
    /// `reconcile` is `async` and `handle` is not, so `Task { await reconcile(id) }` only
    /// *schedules*, and a notification arriving while the read is in flight lands first. The
    /// answer can therefore describe a thread that has already moved on, and writing it
    /// straight through would flick a tab's title or status back to an older value seconds
    /// after the user watched it change.
    ///
    /// Two independent checks, because they fail for different reasons:
    ///
    /// - **Token.** Identifies *which* reconcile this is. Tokens come from a runtime-wide
    ///   monotonic sequence and are never reused, so a read belonging to an attachment that
    ///   has since been detached and replaced cannot match the replacement's — which a
    ///   per-attachment counter, restarting at zero on `attach`, would let it do. The token
    ///   travels task-locally; a delivery from outside a reconcile has none and is refused.
    /// - **Version.** Says whether anything the read cannot know about happened since it was
    ///   ISSUED (not scheduled — see `beginReconcile`). A mismatch means a notification
    ///   overtook it, and dropping is right rather than merely safe: that notification is
    ///   strictly newer than a read already in flight when it arrived. It costs little
    ///   either, because `finishReconcile` re-arms and the next notification tries again.
    ///
    /// Handed back as ordinary events rather than written anywhere: a reconcile carries the
    /// same news a notification does, so routing it through the attachment keeps one path
    /// into the store for both. It is also why this is the runtime's method and not the
    /// store's — everything the guard reads lives here.
    func applyReconciled(title: String?, activity: SessionActivity?, for conversationID: UUID) {
        guard let token = Self.deliveringReconcile,
              var attachment = attachments[conversationID],
              attachment.reconcileToken == token,
              attachment.reconcilingAt == attachment.version
        else { return }
        // Cleared so a second delivery under the same token cannot apply, and so
        // `finishReconcile` can tell a delivered read from a dropped one.
        attachment.reconcilingAt = nil
        attachment.reconcileToken = nil
        attachments[conversationID] = attachment
        if let title { attachment.onEvent(.title(title)) }
        if let activity { attachment.onEvent(.activity(activity)) }
    }
}
