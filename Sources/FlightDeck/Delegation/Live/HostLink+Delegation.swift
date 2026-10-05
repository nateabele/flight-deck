import Foundation
import HostKit

/// `HostLink` as delegation's transport: its requests carry `DelegationRequest`s, and its
/// channels are the winner's mux (HostLinkChannels.swift).
extension HostLink: DelegationTransport {
    var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    func send(_ request: DelegationRequest, timeout: TimeInterval) async throws -> DelegationReply {
        switch try await self.request(.delegation(request), timeout: timeout) {
        case .delegation(let reply):
            return reply
        case .hostInfo:
            // A host bug, refused as `HostService.info` refuses the mirror case: under the
            // code a malformed answer gets, which `hostLine` words with the host's name.
            throw HostLinkError.remote(code: "unexpected_reply", message: "answered a delegation request with host info")
        }
    }
}
