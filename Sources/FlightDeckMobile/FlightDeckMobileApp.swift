import FleetKit
import SwiftUI

@main
struct FlightDeckMobileApp: App {
    var body: some Scene {
        WindowGroup {
            // Replaced in Task 10. Referencing FleetKit here on purpose: it is what makes
            // this scaffold prove the module actually links for iOS rather than merely that
            // a target was added.
            Text("Not paired — wire \(FleetKitVersion.wire)")
        }
    }
}
