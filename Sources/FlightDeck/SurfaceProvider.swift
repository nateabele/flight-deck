import Foundation

/// The one seam through which the Store creates terminal surfaces and drives
/// libghostty's event loop. Real terminals come from `GhosttyApp`; tests inject
/// a stub so Store logic can be exercised without a live terminal.
protocol SurfaceProvider: AnyObject {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView?
    func tick()
}

extension GhosttyApp: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
        makeSurfaceView(baseConfig: config)
    }
}
