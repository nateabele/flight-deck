import Foundation

// STUB, deleted at the C8 integration merge. Track W2 (`c8-svc`) owns the real
// `DelegationHostServices.swift` with exactly these signatures (C8-wave.md, "The hook between W1
// and W2", in its 3-argument form: `DelegationHostContext` has no `acceptChannel`; the
// connection's acceptor rides on each `handle` call instead). It exists only so the router
// (`DelegationHost`) compiles and runs before W2 merges: every service, port and screen op is
// answered `not_implemented` by the router until then.

public struct DelegationHostContext: Sendable {
    public let runner: any RunControlling
    public let workspace: any WorkspaceStore
    public let portCheck: any PortChecking
    public let screen: ScreenLease
    /// True while controller `slot` has at least one live connection.
    public let isConnected: @Sendable (UUID) -> Bool

    public init(runner: any RunControlling, workspace: any WorkspaceStore, portCheck: any PortChecking,
                screen: ScreenLease, isConnected: @escaping @Sendable (UUID) -> Bool) {
        self.runner = runner
        self.workspace = workspace
        self.portCheck = portCheck
        self.screen = screen
        self.isConnected = isConnected
    }
}

public final class DelegationHostServices: @unchecked Sendable {
    public init(context: DelegationHostContext, orphanTimeout: TimeInterval = 1800) {}

    /// Handles service.*, port.*, screen.status. Returns nil for any other op.
    public func handle(_ request: DelegationRequest, controller: UUID,
                       accept: @escaping @Sendable (ChannelID) async throws -> any ByteChannel)
        async throws -> DelegationReply? { nil }

    public func controllerDisconnected(_ slot: UUID) {}
    public func controllerConnected(_ slot: UUID) {}
}
