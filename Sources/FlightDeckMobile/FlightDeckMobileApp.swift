import SwiftUI

@main
struct FlightDeckMobileApp: App {
    @State private var model = FleetModel()

    var body: some Scene {
        WindowGroup {
            if model.mac == nil {
                PairingScreen(model: model)
            } else {
                FleetListScreen(model: model)
            }
        }
    }
}
