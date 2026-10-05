import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Is a TCP port free on this machine, and if not, who holds it (spec §7). The host answers
/// `port.check` with it (step 5); the Mac's `LocalPortHolder` uses its holder naming for step 4.
///
/// The bind probe decides *whether* the port is held; the naming only decides *who*. Naming
/// alone would call a port free whenever lsof or /proc could not see the holder (another
/// user's process, a sandbox), which is exactly the collision preflight exists to catch.
public struct PortCheck: PortChecking {
    private let run: @Sendable (String, [String]) -> String?
    private let searchPath: [String]
    private let procRoot: URL

    /// - Parameters:
    ///   - run: runs `lsof` and `docker`; injected so tests never depend on what is installed.
    ///   - searchPath: where to look for `docker`. The default is `PATH` plus the usual install
    ///     directories, because a launchd- or systemd-started hostd gets a minimal `PATH` that
    ///     misses Homebrew and Docker Desktop.
    ///   - procRoot: `/proc`, or a fake tree in tests.
    public init(run: @escaping @Sendable (String, [String]) -> String? = HostInfoProbe.runCommand,
                searchPath: [String] = PortCheck.defaultSearchPath(),
                procRoot: URL = URL(fileURLWithPath: "/proc")) {
        self.run = run
        self.searchPath = searchPath
        self.procRoot = procRoot
    }

    public static func defaultSearchPath() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return path + ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
    }

    /// Runs on a global queue: `lsof` and `docker ps` block for up to seconds, and a blocked
    /// cooperative thread stalls every other task on the host, including the run streams.
    public func holder(of port: UInt16) async -> PortHolder {
        await check([port])[0].holder
    }

    /// One `docker ps` for the whole batch, and only if some port is held: it costs ~100 ms
    /// against a live daemon, and a recipe with five ports would otherwise pay it five times.
    public func check(_ ports: [UInt16]) async -> [PortStatus] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let docker = DockerListing(check: self)
                cont.resume(returning: ports.map { PortStatus(port: $0, holder: holderNow(of: $0, docker: docker)) })
            }
        }
    }

    private func holderNow(of port: UInt16, docker: DockerListing) -> PortHolder {
        switch Self.probe(port) {
        case true?: return .free
        case false?: return name(holderOf: port, docker: docker) ?? .unknown
        // Could not bind for another reason (a privileged port, no permission): trust a
        // holder if one can be named, else the port is not known to be taken.
        case nil: return name(holderOf: port, docker: docker) ?? .free
        }
    }

    /// Who holds `port`, without probing: the caller already knows it is taken (the Mac's
    /// own bind just failed). Docker first, because Docker Desktop, OrbStack and Linux's
    /// docker-proxy hold a published port in their own process, and "OrbStack (pid 12191)"
    /// tells the user nothing they can stop.
    ///
    /// Blocks on `lsof`/`docker` for up to seconds, so never on the main queue.
    public func name(holderOf port: UInt16) -> PortHolder? {
        name(holderOf: port, docker: DockerListing(check: self))
    }

    private func name(holderOf port: UInt16, docker: DockerListing) -> PortHolder? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        if let container = docker.output.flatMap({ Self.parseDockerPS($0, port: port) }) {
            return .container(name: container)
        }
        #if os(Linux)
        return procHolder(of: port)
        #else
        // `+c0`: the full command name; lsof's default cuts it at 9 characters.
        return run("/usr/sbin/lsof", ["+c0", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).flatMap(Self.parseLsof)
        #endif
    }

    // MARK: Docker

    /// `docker ps` run at most once, on first use.
    private final class DockerListing: @unchecked Sendable {
        private let check: PortCheck
        private var cached: String??

        init(check: PortCheck) { self.check = check }

        var output: String? {
            if let cached { return cached }
            let fm = FileManager.default
            let out = check.searchPath.map { "\($0)/docker" }.first(where: fm.isExecutableFile(atPath:))
                .flatMap { check.run($0, ["ps", "--format", "{{.Names}}\t{{.Ports}}"]) }
            cached = .some(out)
            return out
        }
    }

    /// `docker ps --format '{{.Names}}\t{{.Ports}}'` → the container publishing `port` on the
    /// host side (`0.0.0.0:5434->5432/tcp` publishes 5434). TCP only; an unpublished
    /// `6379/tcp` holds nothing on the host.
    static func parseDockerPS(_ text: String, port: UInt16) -> String? {
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2 else { continue }
            for entry in cols[1].split(separator: ",") {
                let sides = entry.trimmingCharacters(in: .whitespaces).components(separatedBy: "->")
                guard sides.count == 2, sides[1].hasSuffix("/tcp"),
                      let hostPorts = sides[0].split(separator: ":").last
                else { continue }
                let bounds = hostPorts.split(separator: "-").compactMap { UInt16($0) }
                guard let lo = bounds.first, let hi = bounds.last, lo <= hi else { continue }
                if (lo...hi).contains(port) { return String(cols[0]) }
            }
        }
        return nil
    }

    // MARK: lsof (macOS)

    /// The first listener row of `lsof -nP -iTCP:<p> -sTCP:LISTEN`. lsof writes a space in a
    /// command name as `\x20`, which is what makes splitting the row on whitespace safe.
    static func parseLsof(_ text: String) -> PortHolder? {
        for line in text.split(separator: "\n") where !line.hasPrefix("COMMAND") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2, let pid = Int32(cols[1]) else { continue }
            return .process(name: cols[0].replacingOccurrences(of: "\\x20", with: " "), pid: pid)
        }
        return nil
    }

    // MARK: /proc (Linux)

    /// The process holding a listening socket on `port`: the socket's inode from
    /// `net/tcp{,6}`, then the `fd/` link that points at it. Processes this user cannot read
    /// are skipped, so a root-owned holder reads as nil (and the probe still says "held").
    func procHolder(of port: UInt16) -> PortHolder? {
        let fm = FileManager.default
        let inodes = ["net/tcp", "net/tcp6"].reduce(into: Set<UInt64>()) { found, file in
            let text = (try? String(contentsOf: procRoot.appendingPathComponent(file), encoding: .utf8)) ?? ""
            found.formUnion(Self.listeningInodes(text, port: port))
        }
        guard !inodes.isEmpty else { return nil }
        let pids = ((try? fm.contentsOfDirectory(atPath: procRoot.path)) ?? [])
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .sorted { Int($0) ?? 0 < Int($1) ?? 0 }
        for pid in pids {
            let fdDir = procRoot.appendingPathComponent("\(pid)/fd")
            for fd in (try? fm.contentsOfDirectory(atPath: fdDir.path)) ?? [] {
                guard let link = try? fm.destinationOfSymbolicLink(atPath: fdDir.appendingPathComponent(fd).path),
                      let inode = Self.socketInode(link: link), inodes.contains(inode),
                      let pidValue = Int32(pid)
                else { continue }
                let comm = (try? String(contentsOf: procRoot.appendingPathComponent("\(pid)/comm"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .process(name: comm.isEmpty ? pid : comm, pid: pidValue)
            }
        }
        return nil
    }

    /// Inodes of LISTEN rows (state `0A`) on `port` in a `/proc/net/tcp` or `tcp6` table. A
    /// connected row shares its local port on the client side, so counting it would name a
    /// client as the holder.
    static func listeningInodes(_ table: String, port: UInt16) -> Set<UInt64> {
        var out = Set<UInt64>()
        for line in table.split(separator: "\n") {
            let cols = line.split(separator: " ")
            guard cols.count > 9, cols[3] == "0A",
                  let hex = cols[1].split(separator: ":").last, UInt16(hex, radix: 16) == port,
                  let inode = UInt64(cols[9])
            else { continue }
            out.insert(inode)
        }
        return out
    }

    /// `socket:[4242]` → 4242; any other fd link → nil.
    static func socketInode(link: String) -> UInt64? {
        guard link.hasPrefix("socket:["), link.hasSuffix("]") else { return nil }
        return UInt64(link.dropFirst("socket:[".count).dropLast())
    }

    // MARK: Bind probe

    /// True when nothing listens on `port` on any local address.
    public static func isFree(_ port: UInt16) -> Bool { probe(port) == true }

    /// Binds (never listens) `SO_REUSEADDR` sockets on 0.0.0.0, dual-stack ::, 127.0.0.1 and
    /// ::1. True: free; false: `EADDRINUSE`; nil: a bind failed for another reason and says
    /// nothing.
    ///
    /// `SO_REUSEADDR` makes a TIME_WAIT left by a service that just stopped read as free, as
    /// it is to the next service, which binds with it too. Reading it as held failed every
    /// quick `down`/`up` for 30 s. The four addresses are needed because the option is
    /// lenient on macOS: there a wildcard bind succeeds beside a 127.0.0.1 listener, and only
    /// the exact-address probe collides with it. All four together catch a listener on any of
    /// them, measured on both kernels. On Linux a TIME_WAIT left by a server *without*
    /// `SO_REUSEADDR` still reads as held, and correctly: the next server cannot bind over it
    /// either.
    static func probe(_ port: UInt16) -> Bool? {
        var unsure = false
        for address in ProbeAddress.allCases {
            switch bindOnce(port, address) {
            case 0: continue
            case EADDRINUSE: return false
            case EAFNOSUPPORT, EADDRNOTAVAIL: continue   // no IPv6 on this host
            default: unsure = true
            }
        }
        return unsure ? nil : true
    }

    private enum ProbeAddress: CaseIterable { case v4Any, v6AnyDual, v4Loopback, v6Loopback }

    /// 0 on success, else the errno of the failing call.
    private static func bindOnce(_ port: UInt16, _ address: ProbeAddress) -> Int32 {
        let v6 = address == .v6AnyDual || address == .v6Loopback
        #if os(Linux)
        let fd = socket(v6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var one: Int32 = 1, zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32
        if v6 {
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = address == .v6Loopback ? in6addr_loopback : in6addr_any
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = address == .v4Loopback ? inet_addr("127.0.0.1") : 0
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return result == 0 ? 0 : errno
    }

    // MARK: Suggestion

    /// A free local port to offer in place of a held `port`: `port + 10000` and up (5432 →
    /// 15432, the spec's own example), or just above `port` when that would pass 65535.
    /// `excluding` is the ports this same request already claimed, so two conflicts never
    /// get the same suggestion. Bounded, so a crowded machine answers nil quickly rather than
    /// scanning 50,000 binds.
    public static func suggestFree(near port: UInt16, excluding: Set<UInt16>,
                                   isFree: (UInt16) -> Bool = PortCheck.isFree) -> UInt16? {
        let start = Int(port) + 10000 <= 65535 ? Int(port) + 10000 : Int(port) + 1
        for candidate in start..<min(start + 100, 65536) {
            let p = UInt16(candidate)
            if !excluding.contains(p), isFree(p) { return p }
        }
        return nil
    }
}
