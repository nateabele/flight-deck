import SwiftUI

/// Temporary container (plan spec deviation 14): integration moves `CapabilityIndexPane` into
/// L3-R's `FlightControlSettingsTab` as a section and deletes this tab and its
/// `PreferencesTab.capabilityIndex` case. It exists so the two parallel branches never edit the
/// same tab file.
///
/// Takes the service, not the store: observing `SessionStore` would redraw the whole pane on
/// every session tick.
struct CapabilityIndexSettingsTab: View {
    let index: CapabilityIndexService?

    var body: some View {
        if let index {
            CapabilityIndexPane(service: index)
        } else {
            Text("The capability index is not running in this window.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
