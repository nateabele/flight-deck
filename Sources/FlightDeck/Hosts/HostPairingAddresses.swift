import Foundation
import HostKit
import SystemConfiguration

/// Where a controller can reach this Mac to pair, for the Hosting tab's pairing sheet.
///
/// Bonjour finds a pairing Mac only on the same network. Across a tailnet the user on the other
/// Mac has to type an address, and the host is the one machine that knows its own — so the
/// sheet lists them, port included, best first, and the first one goes into the copied string.
///
/// Best first means most likely to work from wherever the other Mac is: Tailscale (its IPv4,
/// then its MagicDNS name) reaches this Mac from anywhere on the tailnet, a LAN address only
/// from this network, and the `.local` name only where multicast DNS does — the same network
/// again, and less reliably.
enum HostPairingAddresses {
    /// What `tailscale status --json` says about this machine, when Tailscale is up.
    struct Tailscale: Equatable, Sendable {
        var ipv4: [String]
        /// MagicDNS, fully qualified with its trailing dot as the CLI prints it.
        var dnsName: String?
    }

    enum Kind: Equatable, Sendable {
        case tailscale, tailscaleName, lan, bonjour

        var label: String {
            switch self {
            case .tailscale: "Tailscale"
            case .tailscaleName: "Tailscale name"
            case .lan: "This network"
            case .bonjour: "Local name"
            }
        }
    }

    struct Entry: Equatable, Sendable, Identifiable {
        let kind: Kind
        /// `host:port`, exactly what the other Mac types (and what `PairingDetails` copies).
        let endpoint: String
        var id: String { endpoint }
    }

    /// The pure half. `interfaces` is `HostEndpoints.enumerate()` (IPv4 only); `primary` is the
    /// interface macOS routes by default, which ranks the real LAN ahead of a VM bridge.
    static func list(tailscale: Tailscale?, interfaces: [HostEndpoints.Interface], primary: String?,
                     localHostName: String?, port: Int) -> [Entry] {
        var entries: [Entry] = []
        func add(_ kind: Kind, _ host: String) {
            let endpoint = "\(host):\(port)"
            if !entries.contains(where: { $0.endpoint == endpoint }) { entries.append(Entry(kind: kind, endpoint: endpoint)) }
        }
        for address in tailscale?.ipv4 ?? [] { add(.tailscale, address) }
        if let name = tailscale?.dnsName.map(trimmingRootDot), !name.isEmpty { add(.tailscaleName, name) }
        // HostKit's ranking, minus loopback and link-local — the same list a host advertises
        // in `helloAck`, uncapped, and a tailnet tunnel still leads when the CLI was missing.
        let ranked = HostEndpoints.advertised(interfaces, primary: primary, port: UInt16(clamping: port),
                                              limit: .max)
        for endpoint in ranked {
            let host = String(endpoint[..<(endpoint.lastIndex(of: ":") ?? endpoint.endIndex)])
            add(HostEndpoints.isCGNAT(host) ? .tailscale : .lan, host)
        }
        if let localHostName, !localHostName.isEmpty { add(.bonjour, "\(localHostName).local") }
        return entries
    }

    /// `Self`'s IPv4 addresses and MagicDNS name, or nil unless `BackendState` is `Running`:
    /// a stopped or logged-out Tailscale still reports a `Self`, whose addresses reach nothing.
    static func tailscale(statusJSON: Data) -> Tailscale? {
        struct Status: Decodable {
            struct Node: Decodable {
                var TailscaleIPs: [String]?
                var DNSName: String?
            }
            var BackendState: String?
            var `Self`: Node?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              status.BackendState == "Running", let node = status.Self
        else { return nil }
        let ipv4 = (node.TailscaleIPs ?? []).filter { !$0.contains(":") }
        let name = node.DNSName.flatMap { $0.isEmpty ? nil : $0 }
        guard !ipv4.isEmpty || name != nil else { return nil }
        return Tailscale(ipv4: ipv4, dnsName: name)
    }

    /// Everything, live. Blocking for as long as the Tailscale CLI takes (bounded), so call it
    /// off the main actor.
    static func current(port: Int) -> [Entry] {
        list(tailscale: TailscaleCLI.status().flatMap(tailscale(statusJSON:)),
             interfaces: HostEndpoints.enumerate(), primary: primaryInterfaceName(),
             localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?, port: port)
    }

    private static func trimmingRootDot(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Same source as `LocalEndpoints`' own: the interface carrying the default route.
    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "dev.flightdeck.HostPairingAddresses" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
}

/// `tailscale status --json`, from whichever CLI this Mac has. Every failure is nil: a Mac
/// without Tailscale simply lists no tailnet address.
enum TailscaleCLI {
    /// The Mac App Store and standalone app's binary. Shared with `ToolResolver`'s search path.
    static let appBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// The Mac App Store and standalone app's own binary, which answers CLI arguments, then a
    /// Homebrew or manual install. Searched explicitly as well as on `PATH`, because an app
    /// launched from the Dock gets launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`.
    static func candidates(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/tailscale" }
        var seen = Set<String>()
        return ([appBinary] + onPath
                + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"])
            .filter { seen.insert($0).inserted }
    }

    /// Bounded, because a wedged daemon must not hold the pairing sheet's address list
    /// hostage: past `timeout` the process is killed and this CLI counts as absent.
    static func status(timeout: TimeInterval = 2) -> Data? {
        let fm = FileManager.default
        for path in candidates() where fm.isExecutableFile(atPath: path) {
            if let data = run(path, ["status", "--json"], timeout: timeout) { return data }
        }
        return nil
    }

    /// One bounded run of the CLI at `path`: its stdout on a zero exit, else nil. Internal so
    /// `TailnetIntegration` drives `lock status` and `lock sign` through the same guard
    /// against a wedged daemon.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Read concurrently with the wait: the status of a large tailnet outgrows the pipe's
        // buffer, and a child blocked writing to a full pipe never exits.
        nonisolated(unsafe) var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        drained.wait()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// The one string the host's "Copy pairing details" button produces, and its parse on the
/// controller, so a cross-network pairing is a single paste rather than an address and a code
/// read off one screen and typed into another.
enum PairingDetails {
    struct Parsed: Equatable {
        /// As pasted: `host`, `host:port`, `[v6]` or `[v6]:port`.
        var address: String
        /// `XXXX-XXXX-XXXX`, upper-cased; not checksum-checked, so a mistyped code still lands
        /// in the field and `pair()` says what is wrong with it.
        var code: String?
    }

    /// `<address>:<port> <CODE>`.
    static func format(endpoint: String, code: String) -> String { "\(endpoint) \(code)" }

    /// One address, optionally one code, in either order and separated by any whitespace.
    /// Nil for anything else — an empty field, a lone code, two addresses, prose — so a
    /// caller can leave the field as typed.
    static func parse(_ text: String) -> Parsed? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...2).contains(tokens.count) else { return nil }
        let codes = tokens.filter(isCode)
        let addresses = tokens.filter { !isCode($0) }
        guard codes.count <= 1, addresses.count == 1, isAddress(addresses[0]) else { return nil }
        return Parsed(address: addresses[0], code: codes.first?.uppercased())
    }

    private static let addressCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_[]%"))

    /// The host's `XXXX-XXXX-XXXX` shape, which no host name or address has.
    private static func isCode(_ token: String) -> Bool {
        let groups = token.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 3 && groups.allSatisfy { group in
            group.count == 4 && group.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// Plausibly a host, then dialable: `HostService.pairingEndpoint` is what `pair` will use.
    private static func isAddress(_ token: String) -> Bool {
        guard token.unicodeScalars.allSatisfy(addressCharacters.contains),
              token.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        else { return false }
        return HostService.pairingEndpoint(token) != nil
    }
}
