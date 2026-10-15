import FleetKit
import Foundation
import MachO
import OSLog

/// What this phone writes down about itself, and how the Mac reads it back.
///
/// **It exists because the phone was the only unobserved half of this system.** The Mac keeps
/// `~/Library/Logs/flight-deck-answer.log` (every aborted answer drive, with the viewport that
/// caused it) and `~/Library/Logs/flight-deck-prompt.log` (every dialog it believed was open,
/// and every frame it pushed about one). The phone kept nothing at all — `Logger` appeared
/// nowhere in this target — so when a handset showed a card for a dialog the Mac had already
/// left, "the Mac never pushed the closure" and "the phone never applied one it was sent" were
/// indistinguishable, and the only evidence available was a person reading their screen aloud.
/// Two bugs were chased that way for a day each.
///
/// **Structural only, and this is a hard boundary rather than a habit.** These lines are
/// fetched over the fleet socket and written to a file on somebody's Mac, so nothing here may
/// carry prompt option text, transcript content, a session title, or anything a person typed.
/// Ids, counts, states and timings. Every call site below is one line of that shape; a call
/// that interpolated a label would put a user's own words on a wire the user never chose to
/// put them on.
///
/// **A diagnostic aid, not a trace.** One line per connection transition, one per change in
/// what dialog this phone believes is open, one per answer and its outcome. Nothing is logged
/// per render, per event or per fetched page — `blocked(agent:activity:call:)` is called from a
/// view body, so the model logs the *transition* and not the call.
///
/// **Nothing reads a record back and no branch is taken on one.** A change here that altered
/// when a frame is sent, or what is in it, would destroy the thing being measured — the same
/// rule `PromptLifecycleRecord` states on the Mac.
enum PhoneLog {
    /// The app's own bundle id: the unified-log subsystem every `Channel` writes under, so
    /// Console.app and a sysdiagnose can select exactly these lines.
    ///
    /// Read from the bundle with the literal as a fallback, matching `PromptLifecycleLog` on
    /// the Mac: a test bundle has its own identifier, and a subsystem that silently became
    /// the test host's would make `entries(seconds:limit:)` return nothing with no hint why.
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.radify.flightdeck.FlightDeckMobile"

    /// Dialling, connecting, snapshots and resume points — the phone's counterpart to the
    /// Mac's `resume lastSeq=… mode=…` line.
    static let connection = Channel(category: "connection")
    /// What dialog this phone believes is open, and what the Mac told it was open.
    static let prompt = Channel(category: "prompt")
    /// Answers sent, and what came back.
    static let answer = Channel(category: "answer")
    /// Main-thread stalls, and the main-thread work slow enough to cause one: durations, byte
    /// counts and return addresses only. A stall is logged by `MainStallWatch`; the work around
    /// it logs itself only past a threshold, so a healthy phone writes little here.
    static let perf = Channel(category: "perf")

    /// Every category a fetch can return: the channels above, and nothing else, since only a
    /// `Channel` writes the journal. Named so a channel added later for something noisy is a
    /// deliberate line here rather than an accident that ships itself to a Mac.
    static let categories = ["connection", "prompt", "answer", "perf"]

    /// One category of line: written to the unified log, for Console.app and a sysdiagnose,
    /// and to `PhoneJournal`, which is what a fetch reads back.
    struct Channel: Sendable {
        let category: String
        private let logger: Logger

        init(category: String) {
            assert(PhoneLog.categories.contains(category), "add \(category) to PhoneLog.categories")
            self.category = category
            logger = Logger(subsystem: PhoneLog.subsystem, category: category)
        }

        /// `flush` writes the journal before returning: for a caller that may be killed a
        /// moment later — the stall watch, mid-freeze — and never from the main thread.
        func notice(_ message: String, flush: Bool = false) {
            logger.notice("\(message, privacy: .public)")
            PhoneJournal.append(level: "notice", category: category, message: message, flush: flush)
        }

        func error(_ message: String) {
            logger.error("\(message, privacy: .public)")
            PhoneJournal.append(level: "error", category: category, message: message, flush: false)
        }
    }

    /// One `perf` line. See `Channel.notice(_:flush:)`.
    static func perfNote(_ line: String, flush: Bool = false) {
        perf.notice(line, flush: flush)
    }

    /// Milliseconds since `start`, for the `perf` lines.
    static func elapsed(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    /// This phone's own entries from the last `seconds` seconds, oldest first, at most `limit`.
    ///
    /// **Read from `PhoneJournal`, not from `OSLogStore`, and that is the whole fix for the
    /// fetch.** `OSLogStore(scope: .currentProcessIdentifier)` took 18.7 s on a handset to
    /// return a few dozen lines (measured 2026-10-14), past the Mac's 10 s `askDeadline`, so
    /// every fetch timed out — and it ran on the main thread then, freezing the UI for as
    /// long. The journal is this app's own file of exactly these lines: reading it is a file
    /// read and a scan from the end, milliseconds. It also outlives a launch, which the
    /// current-process log store never did, so a phone that was killed still has the lines
    /// leading up to it.
    ///
    /// Both bounds are clamped here rather than trusted from the Mac, the same contract
    /// `FleetService`'s `.search` handler keeps against a phone: a peer-side bug that asked for
    /// a week of entries must not cost this phone an unbounded read.
    static func entries(seconds: Int, limit: Int) -> Result<WirePhoneLogs, PhoneRequestRefusal> {
        let window = min(max(seconds, 1), PhoneLogLimits.maxSeconds)
        let cap = min(max(limit, 1), PhoneLogLimits.maxEntries)
        let start = DispatchTime.now().uptimeNanoseconds
        guard let lines = PhoneJournal.lines() else {
            return .failure(PhoneRequestRefusal(code: "unreadable"))
        }
        let since = Date().addingTimeInterval(-TimeInterval(window))
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Newest first, stopping at the first line older than the window: the journal is in
        // write order, so nothing before it can be newer.
        var newest: [WirePhoneLogEntry] = []
        var truncated = false
        for line in lines.reversed() {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let at = parse.date(from: String(fields[0])) else { continue }
            if at < since { break }
            if newest.count == cap { truncated = true; break }
            newest.append(WirePhoneLogEntry(
                at: String(fields[0]), level: String(fields[1]),
                category: String(fields[2]), message: String(fields[3])
            ))
        }
        perfNote("logs read ms=\(elapsed(since: start)) lines=\(lines.count) served=\(newest.count)")
        return .success(WirePhoneLogs(entries: newest.reversed(), truncated: truncated))
    }
}

/// A one-time measurement of why `OSLogStore` was too slow to serve a fetch: the read that
/// `PhoneLog.entries` used to make, timed stage by stage, run once per installed build at
/// background priority, off the main thread, with the result written to the journal as one
/// `perf` line (`oslogstore probe …`). It costs one background read of the system store per
/// install and nothing after; delete it once the numbers are in hand.
enum OSLogStoreProbe {
    static func runOncePerBuild() {
        let key = "oslogstore-probe." + StackSymbols.appImageSummary()
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.global(qos: .background).async {
            let ms = { (start: UInt64) in PhoneLog.elapsed(since: start) }
            var t = DispatchTime.now().uptimeNanoseconds
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
                return PhoneLog.perfNote("oslogstore probe open failed")
            }
            let open = ms(t)
            t = DispatchTime.now().uptimeNanoseconds
            let since = store.position(date: Date().addingTimeInterval(-60))
            let position = ms(t)
            // The fetch's own query: this app's subsystem and categories, last 60 s.
            let predicate = NSPredicate(
                format: "subsystem == %@ AND category IN %@", PhoneLog.subsystem, PhoneLog.categories
            )
            t = DispatchTime.now().uptimeNanoseconds
            let filtered = (try? store.getEntries(with: [], at: since, matching: predicate)).map { Array($0).count } ?? -1
            let filteredMs = ms(t)
            // The same window with no predicate: how much the store walks to find those few.
            t = DispatchTime.now().uptimeNanoseconds
            let everything = (try? store.getEntries(with: [], at: since)).map { Array($0).count } ?? -1
            let everythingMs = ms(t)
            PhoneLog.perfNote("""
                oslogstore probe open=\(open)ms position=\(position)ms \
                filtered=\(filtered) entries in \(filteredMs)ms \
                unfiltered=\(everything) entries in \(everythingMs)ms window=60s
                """)
        }
    }
}

/// The phone's own log file: every `PhoneLog` line, one per line, in write order.
///
/// `Library/Caches/phone.log`, rotated to `phone.1.log` past 1 MB, so the two never hold more
/// than 2 MB. Each line is `<ISO-8601 local time> <level> <category> <message>`. Read back by
/// `PhoneLog.entries` for a fetch over the fleet socket, and by `scripts/phone-stalls.sh`
/// through `devicectl` when the socket cannot be reached — a phone with a stuck main thread.
///
/// All file work, the timestamp's formatting included, happens on one serial queue: these
/// lines are written from the main thread, and a diagnostic that costs the thread it is
/// diagnosing is measuring itself.
enum PhoneJournal {
    private static let queue = DispatchQueue(label: "flightdeck.phone-journal")
    static let maxBytes = 1_000_000

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    static func append(level: String, category: String, message: String, flush: Bool) {
        let now = Date()
        // One line per entry whatever the message holds.
        let flat = message.replacingOccurrences(of: "\n", with: " ")
        let write: @Sendable () -> Void = {
            guard let dir = directory else { return }
            let url = dir.appendingPathComponent("phone.log")
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            stamp.timeZone = .current
            let line = "\(stamp.string(from: now)) \(level) \(category) \(flat)\n"
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > maxBytes {
                let old = dir.appendingPathComponent("phone.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        if flush { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// Every line of `phone.1.log` then `phone.log`, oldest first; nil when neither can be
    /// read. On the journal's queue, so a write in flight is either wholly in or wholly out.
    static func lines() -> [Substring]? {
        queue.sync {
            guard let dir = directory else { return nil }
            var text = ""
            var found = false
            for name in ["phone.1.log", "phone.log"] {
                if let part = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                    text += part
                    found = true
                }
            }
            return found ? text.split(separator: "\n") : nil
        }
    }
}

/// Notices when the main thread stops answering, for how long, and what it was doing.
///
/// A utility thread posts an empty block to the main queue every 100 ms and waits for it. A
/// block that takes more than 250 ms to run means the main thread was busy that long — the
/// freeze a person sees as taps going nowhere. While it stays busy, the watch samples the
/// main thread's stack (at 250 ms, then every 500 ms, at most `maxSamples` times), and once it
/// answers, logs the stall's length and each sample to `perf`.
///
/// **How a sample is taken, and why it is safe.** The main thread is suspended with
/// `thread_suspend`, its registers read with `thread_get_state`, and its frame-pointer chain
/// walked — every read checked against the main thread's own stack bounds — into a buffer
/// allocated before the watch starts. Nothing between suspend and resume allocates, locks or
/// touches the Swift runtime: the suspended thread may hold the malloc lock, and anything
/// that waited on it would deadlock both threads. Return addresses are symbolicated after
/// `thread_resume`, as `image+offset` (and the nearest exported symbol where `dladdr` has
/// one); `scripts/phone-stalls.sh` resolves the app's own frames against the build's dSYM.
///
/// **Structural only, like everything in `PhoneLog`:** addresses and durations, never data.
enum MainStallWatch {
    private static let started = OSAllocatedUnfairLock(initialState: false)
    static let maxSamples = 4
    static let maxFrames = 48

    /// Must be called on the main thread: it records that thread's port and stack bounds.
    static func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let first = started.withLock { started in
            defer { started = true }
            return !started
        }
        guard first else { return }
        let target = MainThreadTarget.current()
        PhoneLog.perfNote("stall watch armed \(StackSymbols.appImageSummary())")
        let thread = Thread {
            let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
            while true {
                let sent = DispatchTime.now().uptimeNanoseconds
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                    // Each sample is written the moment it is taken, before the stall ends:
                    // a freeze long enough for iOS's watchdog to kill the app never ends, and
                    // a watch that logged only on recovery recorded nothing about the freezes
                    // that mattered most (the launch kills of 2026-10-14 left no line at all).
                    var taken = 0
                    repeat {
                        let count = target.sample(into: frames, capacity: maxFrames)
                        let sample = Array(UnsafeBufferPointer(start: frames, count: count))
                        PhoneLog.perfNote("""
                            main stalled ms>=\(PhoneLog.elapsed(since: sent)) \
                            stack[\(taken)] \(StackSymbols.describe(sample))
                            """, flush: true)
                        taken += 1
                    } while taken < maxSamples
                        && answered.wait(timeout: .now() + .milliseconds(500)) == .timedOut
                    if taken == maxSamples { answered.wait() }
                    PhoneLog.perfNote("main stall ms=\(PhoneLog.elapsed(since: sent)) samples=\(taken)")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.qualityOfService = .utility
        thread.name = "MainStallWatch"
        thread.start()
    }
}

/// The main thread, as another thread needs to know it to sample it.
struct MainThreadTarget: Sendable {
    let port: thread_act_t
    let stackLow: UInt
    let stackHigh: UInt

    static func current() -> MainThreadTarget {
        let me = pthread_self()
        let high = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let size = UInt(pthread_get_stacksize_np(me))
        return MainThreadTarget(port: mach_thread_self(), stackLow: high - size, stackHigh: high)
    }

    /// Return addresses, innermost first, written into `buffer`; the count written.
    /// See `MainStallWatch` for why this function must not allocate.
    func sample(into buffer: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        guard thread_suspend(port) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(port) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(port, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var written = 0
        buffer[written] = Self.strip(UInt(state.__pc)); written += 1
        buffer[written] = Self.strip(UInt(state.__lr)); written += 1
        var fp = UInt(state.__fp)
        while written < capacity, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
            let record = UnsafePointer<UInt>(bitPattern: fp)!
            let next = record[0]
            let ret = Self.strip(record[1])
            if ret == 0 { break }
            buffer[written] = ret; written += 1
            guard next > fp else { break }
            fp = next
        }
        return written
    }

    /// Drops pointer-authentication bits: system frameworks are arm64e and sign the return
    /// addresses they save. User addresses on iOS fit well inside 36 bits.
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_000F_FFFF_FFFF }
}

/// Turns sampled addresses into something a reader — or `atos` — can resolve.
enum StackSymbols {
    /// `image+0xoffset` per frame, with `dladdr`'s nearest exported symbol when it has one.
    /// The app's own frames are left as offsets: its symbols are not exported, and the
    /// nearest exported one would name the wrong function.
    static func describe(_ addresses: [UInt]) -> String {
        addresses.map { address -> String in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                  let base = info.dli_fbase, let file = info.dli_fname
            else { return String(format: "?0x%lx", address) }
            let image = (String(cString: file) as NSString).lastPathComponent
            let offset = address - UInt(bitPattern: base)
            var text = "\(image)+0x\(String(offset, radix: 16))"
            if image != "FlightDeckMobile", let name = info.dli_sname {
                text += "(\(String(cString: name)))"
            }
            return text
        }.joined(separator: " | ")
    }

    /// The running app binary's LC_UUID, so a sample is only ever symbolicated against the
    /// dSYM of the build that took it.
    static func appImageSummary() -> String {
        guard let header = _dyld_get_image_header(0) else { return "uuid=?" }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return "uuid=\(UUID(uuid: uuid).uuidString)"
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return "uuid=?"
    }
}
