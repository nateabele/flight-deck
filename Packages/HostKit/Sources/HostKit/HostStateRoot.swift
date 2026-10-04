import Foundation

public enum HostStateRoot {
    /// Where the host keeps its paired-controller secrets. The Mac name matches the app-support
    /// convention but is deliberately not "Flight Deck": the app and its Debug build already
    /// own those directories, and hostd must never share state with them.
    public static func `default`() -> URL {
        #if os(Linux)
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("flightdeck-hostd")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/flightdeck-hostd")
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flight Deck Host")
        #endif
    }
}
