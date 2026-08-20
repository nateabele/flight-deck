import Foundation

/// Every address this Mac can currently be reached on, as `host:port` candidates for the
/// pairing code.
///
/// These are candidates, not an address. The key identifies the Mac (§3); by the time the
/// phone has left the room every one of these may be wrong, which is why the phone races
/// them rather than trusting one. Loopback is included deliberately — it is what the
/// loopback tests use, and it costs one failed race attempt in production.
enum LocalEndpoints {
    static func current(port: UInt16) -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let raw = interface.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            // IPv4 only. A link-local IPv6 address needs a zone index to be dialable and
            // would produce candidates that can never connect — noise in a race that is
            // already parallel.
            guard family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append("\(String(cString: host)):\(port)")
        }
        // Loopback last: a phone will never reach it, but the tests will, and putting it
        // first would make every real pairing wait out one dead candidate.
        addresses.append("127.0.0.1:\(port)")
        return addresses
    }
}
