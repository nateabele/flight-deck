import FleetKit
import Foundation
import Observation

/// What `SessionCloudModel` sends `infra.*` requests through. `FleetModel` is the real one; a
/// test hands a fake. `progress` hears each streamed line; the result is the stream's terminal
/// frame (or its failure), exactly once.
@MainActor
protocol InfraCommanding: AnyObject {
    func infra(_ request: InfraRequest, progress: @escaping (String) -> Void) async -> Result<InfraOutcome, InfraRequestError>
}

/// The cloud pane's action state: which machine has a request running, the progress lines a
/// destroy streams, and the last error. The machines themselves are not held here — the screen
/// reads them live off `WireSession.cloud`, so a `session.cloud` event from the Mac is what
/// changes the page, and a finished destroy shows up as the machine leaving.
@MainActor
@Observable
final class SessionCloudModel {
    enum Action: Equatable { case extend, destroy }

    /// One machine's request in flight, or its last failure.
    struct Activity: Equatable {
        var action: Action
        var lines: [String] = []
        var failure: String?
        var running: Bool { failure == nil }
    }

    /// By machine name. An entry is removed on success and kept (with `failure`) on error, until
    /// the next attempt replaces it.
    private(set) var activity: [String: Activity] = [:]

    @ObservationIgnored private let commander: any InfraCommanding

    init(commander: any InfraCommanding) {
        self.commander = commander
    }

    func isBusy(_ name: String) -> Bool { activity[name]?.running ?? false }

    func extend(_ name: String) async {
        await run(.extend, name: name, request: .extend(name: name, seconds: CloudStyle.extendSeconds))
    }

    func destroy(_ name: String) async {
        await run(.destroy, name: name, request: .down(name: name, orphanID: nil))
    }

    private func run(_ action: Action, name: String, request: InfraRequest) async {
        // One request per machine at a time: a second tap on Extend must not stack an hour.
        guard !isBusy(name) else { return }
        activity[name] = Activity(action: action)
        let result = await commander.infra(request) { [weak self] line in
            self?.activity[name]?.lines.append(line)
        }
        switch result {
        case .success:
            activity[name] = nil
        case .failure(let error):
            activity[name]?.failure = CloudStyle.failureText(error)
        }
    }

    func dismissFailure(_ name: String) {
        if activity[name]?.failure != nil { activity[name] = nil }
    }
}
