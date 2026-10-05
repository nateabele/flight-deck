import Foundation

/// Advertises the hostd over mDNS by running `avahi-publish`, one child per service, for as long
/// as the service should be visible: avahi-publish withdraws the record when it exits, so the
/// child's lifetime *is* the advertisement's.
///
/// A host without avahi is normal (containers, minimal servers, hosts reached over Tailscale by
/// address), so a missing binary publishes nothing and says nothing: discovery is a convenience
/// and the controller can always dial by address.
struct AvahiPublisher: Sendable {
    let executable: String

    init(executable: String = "/usr/bin/avahi-publish") {
        self.executable = executable
    }

    /// `avahi-publish -s NAME TYPE PORT`: the hostd itself, for the life of `serve`.
    static func serviceArguments(hostName: String, port: Int) -> [String] {
        ["-s", hostName, "_fd-host._tcp", String(port)]
    }

    /// The pairing window, only while a code is armed. The `name` TXT is what a controller's
    /// pairing browser can show before it connects.
    static func pairingArguments(hostName: String, port: Int) -> [String] {
        ["-s", hostName, "_fd-host-pair._tcp", String(port), "name=\(hostName)"]
    }

    /// The running child, or nil when avahi-publish is absent or would not start.
    func publish(_ arguments: [String]) -> Process? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("avahi-publish did not start: \(error)\n".utf8))
            return nil
        }
        return process
    }

    func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
