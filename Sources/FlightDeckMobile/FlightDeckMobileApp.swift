import SwiftUI

@main
struct FlightDeckMobileApp: App {
    @State private var model = FleetModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if model.mac == nil {
                PairingScreen(model: model)
            } else {
                FleetListScreen(model: model)
            }
        }
        // **Redial on every return from the background.**
        //
        // iOS tears down an app's sockets when it suspends, and it does not tell the app: the
        // connector comes back believing it is connected to a socket that no longer exists, so
        // nothing retries, no backoff fires, and the fleet list sits there stale until the app
        // is force-quit. Force-quitting "fixing" it is the tell — that is the only path that
        // rebuilt the connector.
        //
        // Unconditional rather than gated on the connector's own state, precisely because that
        // state is what cannot be trusted here: it describes a socket iOS destroyed without
        // telling anyone. `reconnect()` is idempotent from the list's point of view — it
        // rebuilds the connector and re-runs discovery — so the cost of a redundant call is
        // one handshake, against a session that otherwise never comes back.
        //
        // Keyed on `.background` → `.active`, not on `.active` alone: a notification banner or
        // the app switcher passes through `.inactive` without ever suspending, and redialling
        // on those would churn the socket every time a banner appeared.
        .onChange(of: scenePhase) { previous, phase in
            guard phase == .active, previous == .background, model.mac != nil else { return }
            model.reconnect()
        }
    }
}
