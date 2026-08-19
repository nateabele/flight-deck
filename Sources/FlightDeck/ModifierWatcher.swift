import AppKit
import Combine

/// Publishes the currently-held modifier keys so the sidebar button can relabel itself
/// mid-chord. A local monitor (not global) because this only matters while Flight Deck is
/// frontmost, and a global monitor would need accessibility permission for no benefit.
@MainActor
final class ModifierWatcher: ObservableObject {
    @Published private(set) var flags: NSEvent.ModifierFlags = []
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flags = event.modifierFlags
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
