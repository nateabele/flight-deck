import SwiftUI

@main
struct FlightDeckMobileApp: App {
    @State private var model = FleetModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Remembers whether the app was actually suspended. See `RedialOnReturn` — reading it off
    /// a single transition is the version that shipped and never fired.
    @State private var redial = RedialOnReturn()

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
        // Fed every transition, because the decision cannot be made from one of them: iOS
        // returns from the background through `.inactive`, so `.active` never arrives with
        // `.background` behind it. `RedialOnReturn` carries the whole argument, including the
        // banner case this still deliberately ignores.
        .onChange(of: scenePhase) { _, phase in
            guard redial.phaseChanged(to: phase), model.mac != nil else { return }
            model.reconnect()
        }
    }
}
