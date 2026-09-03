import Foundation

/// The one seam through which the Store creates terminal surfaces and drives
/// libghostty's event loop. Real terminals come from `GhosttyApp`; tests inject
/// a stub so Store logic can be exercised without a live terminal.
protocol SurfaceProvider: AnyObject {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView?
    func tick()
    /// libghostty's configured `font-size`, in points — what an unset `Preferences
    /// .terminalFontSize` resolves to. See `GhosttyApp.defaultFontSize`.
    var defaultFontSize: Float { get }
}

extension GhosttyApp: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
        makeSurfaceView(baseConfig: config)
    }
}
