import Foundation

/// Anything that can type text into a live terminal. Mirrors the `SurfaceProvider`
/// seam so the Store stays testable without a real surface.
@MainActor
protocol TextInjecting: AnyObject {
    func sendText(_ text: String)
}

extension Ghostty.SurfaceView: TextInjecting {
    func sendText(_ text: String) {
        surfaceModel?.sendText(text)
    }
}
