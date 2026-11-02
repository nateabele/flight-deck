import Foundation

/// How an `infra.*` stream ended, as `FleetConnector.requestInfra` hands it back: the terminal
/// frame of the stream (`InfraControlWire.swift`), the progress lines having gone to the
/// request's `progress` sink on the way.
public enum InfraOutcome: Equatable, Sendable {
    /// `infraMachine`: `extend`'s machine as it now is.
    case machine(WireInfraMachine)
    /// `infraList`: every machine this Mac knows.
    case list([WireInfraMachine])
    /// `infraDone`: `down` finished, the machine is gone.
    case done
}

/// Why an `infra.*` request did not end in an `InfraOutcome`.
public enum InfraRequestError: Error, Equatable, Sendable {
    /// The socket went away before the stream ended. The request may still be running on the
    /// Mac: a half-finished `down` is not abandoned when its reader goes.
    case disconnected
    /// The Mac answered `err`: a code (`infra_refused`, `infra_not_found`, … or, from a Mac
    /// built before the phone could ask, `out_of_scope`/`unsupported`) and the sentence the
    /// CLI would print after `flightdeck: `.
    case server(code: String, message: String?)

    /// Whether this Mac predates phone-driven infra control.
    public var isMacTooOld: Bool {
        if case .server(let code, _) = self { return code == "out_of_scope" || code == "unsupported" }
        return false
    }
}
