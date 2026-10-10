import XCTest
@testable import HostKit
#if os(macOS)
import HostKitDarwin
import IOKit.pwr_mgt
#endif

/// "Keep this Mac awake while plugged in": the holder's take/release across every on/off ×
/// AC/battery transition and its own exit, against a fake IOKit (assertions and the power
/// source), so no test here keeps the developer's Mac awake.
final class KeepAwakeTests: XCTestCase {
    /// Every assertion taken and not yet released, by kind, with the name it was taken under.
    final class FakePower: PowerAsserting, @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var live: [Int: (PowerAssertionKind, String)] = [:]
        private(set) var taken = 0

        func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion {
            let id: Int = lock.withLock {
                next += 1
                taken += 1
                live[next] = (kind, reason)
                return next
            }
            return PowerAssertion { [self] in _ = lock.withLock { live.removeValue(forKey: id) } }
        }

        var held: [PowerAssertionKind] {
            lock.withLock { live.values.map(\.0).sorted { "\($0)" < "\($1)" } }
        }
        var names: Set<String> { lock.withLock { Set(live.values.map(\.1)) } }
    }

    final class FakeSource: PowerSourceMonitoring, @unchecked Sendable {
        var current: PowerSource
        private(set) var onChange: (@Sendable (PowerSource) -> Void)?
        private(set) var started = 0, stopped = 0
        init(_ source: PowerSource) { current = source }
        func start(onChange: @escaping @Sendable (PowerSource) -> Void) {
            started += 1
            self.onChange = onChange
        }
        func stop() { stopped += 1; onChange = nil }
        /// What IOKit's notification does: the source changes, then the callback fires.
        func change(to source: PowerSource) {
            current = source
            onChange?(source)
        }
    }

    private let both: [PowerAssertionKind] = [.displaySleep, .idleSleep]

    func testOffHoldsNothingEvenOnAC() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: false)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: false, holding: false, power: .ac))
    }

    /// Both kinds: idle system sleep alone still lets the display sleep, and display sleep
    /// (or the screen saver) is what locks the screen under "require password".
    func testOnAndOnACHoldsSystemAndDisplayUnderItsName() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: true)
        XCTAssertEqual(power.held, both)
        XCTAssertEqual(power.names, [KeepAwakeHolder.assertionName])
        XCTAssertEqual(KeepAwakeHolder.assertionName, "Flight Deck hosting: keep awake while plugged in")
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: true, holding: true, power: .ac))
    }

    func testOnButOnBatteryHoldsNothing() {
        let power = FakePower()
        let holder = KeepAwakeHolder(power: power, source: FakeSource(.battery), enabled: true)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: true, holding: false, power: .battery))
    }

    /// An unreadable source is not "plugged in": keeping a laptop awake on battery is the
    /// failure this option must never cause.
    func testUnknownSourceHoldsNothing() {
        let power = FakePower()
        let holder = KeepAwakeHolder(power: power, source: FakeSource(.unknown), enabled: true)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status.holding, false)
    }

    func testUnpluggingReleasesAndPluggingInRetakes() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: true)
        source.change(to: .battery)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status.holding, false)
        source.change(to: .ac)
        XCTAssertEqual(power.held, both)
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: true, holding: true, power: .ac))
    }

    /// IOKit notifies on every power-source change, battery percentage included; a repeat AC
    /// must not stack a second pair of assertions (each needs its own release).
    func testRepeatedACNotificationsDoNotStack() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: true)
        source.change(to: .ac)
        source.change(to: .ac)
        XCTAssertEqual(power.held, both)
        XCTAssertEqual(power.taken, 2)
        withExtendedLifetime(holder) {}
    }

    func testTurningOffReleasesAndOnRetakes() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: true)
        holder.setEnabled(false)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: false, holding: false, power: .ac))
        holder.setEnabled(true)
        XCTAssertEqual(power.held, both)
        holder.setEnabled(true)
        XCTAssertEqual(power.taken, 4, "setting the same value again takes nothing new")
    }

    func testTurningOnWhileOnBatteryWaitsForTheAdapter() {
        let power = FakePower(), source = FakeSource(.battery)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: false)
        holder.setEnabled(true)
        XCTAssertEqual(power.held, [])
        source.change(to: .ac)
        XCTAssertEqual(power.held, both)
    }

    /// Off: a plug-in must not take anything just because the monitor still runs.
    func testPluggingInWhileOffTakesNothing() {
        let power = FakePower(), source = FakeSource(.battery)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: false)
        source.change(to: .ac)
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(holder.status, KeepAwakeStatus(enabled: false, holding: false, power: .ac))
    }

    func testShutdownReleasesStopsWatchingAndIgnoresLaterChanges() {
        let power = FakePower(), source = FakeSource(.ac)
        let holder = KeepAwakeHolder(power: power, source: source, enabled: true)
        let notify = source.onChange
        holder.shutdown()
        XCTAssertEqual(power.held, [])
        XCTAssertEqual(source.stopped, 1)
        // A notification already in flight when the holder exits.
        notify?(.ac)
        holder.setEnabled(true)
        XCTAssertEqual(power.held, [])
    }

    /// The holder going away without a shutdown (hostd's teardown path skipped) still lets
    /// the Mac sleep: an assertion orphaned by a dropped reference would otherwise outlive it
    /// for the life of the process.
    func testHolderDeinitReleases() {
        let power = FakePower(), source = FakeSource(.ac)
        var holder: KeepAwakeHolder? = KeepAwakeHolder(power: power, source: source, enabled: true)
        XCTAssertEqual(power.held, both)
        holder = nil
        XCTAssertNil(holder)
        XCTAssertEqual(power.held, [])
    }

    // MARK: - Settings

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSettingsDefaultToOffAndRoundTrip() throws {
        let root = try tempRoot()
        XCTAssertEqual(HostingSettings.load(root: root), HostingSettings(keepAwakeWhilePluggedIn: false))
        try HostingSettings(keepAwakeWhilePluggedIn: true).save(root: root)
        XCTAssertEqual(HostingSettings.load(root: root), HostingSettings(keepAwakeWhilePluggedIn: true))
        let mode = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(HostingSettings.fileName).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    /// A file a later build wrote with keys this one does not know, or one cut short, must
    /// not take hosting down: it reads as the defaults.
    func testUnreadableSettingsReadAsDefaults() throws {
        let root = try tempRoot()
        try Data("{not json".utf8).write(to: root.appendingPathComponent(HostingSettings.fileName))
        XCTAssertEqual(HostingSettings.load(root: root), HostingSettings())
        try Data(#"{"keepAwakeWhilePluggedIn":true,"future":1}"#.utf8)
            .write(to: root.appendingPathComponent(HostingSettings.fileName))
        XCTAssertEqual(HostingSettings.load(root: root), HostingSettings(keepAwakeWhilePluggedIn: true))
    }

    // MARK: - Wire

    func testAdminShapesArePinned() throws {
        XCTAssertEqual(try HostWire.encode(AdminRequest.keepAwake), #"{"t":"keepAwake"}"#)
        XCTAssertEqual(try HostWire.encode(AdminRequest.setKeepAwake(true)), #"{"on":true,"t":"setKeepAwake"}"#)
        XCTAssertEqual(
            try HostWire.encode(AdminReply.keepAwake(KeepAwakeStatus(enabled: true, holding: false, power: .battery))),
            #"{"enabled":true,"holding":false,"power":"battery","t":"keepAwake"}"#)
        for r: AdminRequest in [.keepAwake, .setKeepAwake(false), .setKeepAwake(true)] {
            XCTAssertEqual(try HostWire.decode(AdminRequest.self, from: HostWire.encode(r)), r)
        }
        let reply = AdminReply.keepAwake(KeepAwakeStatus(enabled: true, holding: true, power: .ac))
        XCTAssertEqual(try HostWire.decode(AdminReply.self, from: HostWire.encode(reply)), reply)
    }

    /// A power source this build has no name for (a later hostd's) reads as unknown rather
    /// than failing the whole reply.
    func testUnknownPowerSpellingDecodesAsUnknown() throws {
        XCTAssertEqual(
            try HostWire.decode(AdminReply.self, from: #"{"enabled":true,"holding":false,"power":"solar","t":"keepAwake"}"#),
            .keepAwake(KeepAwakeStatus(enabled: true, holding: false, power: .unknown)))
    }

    // MARK: - IOKit

    #if os(macOS)
    func testProvidingPowerTypeMapsToSource() {
        XCTAssertEqual(IOKitPowerSource.source(providingType: kIOPMACPowerKey), .ac)
        XCTAssertEqual(IOKitPowerSource.source(providingType: kIOPMBatteryPowerKey), .battery)
        // A UPS providing power means the mains are out: not "plugged in".
        XCTAssertEqual(IOKitPowerSource.source(providingType: kIOPMUPSPowerKey), .battery)
        XCTAssertEqual(IOKitPowerSource.source(providingType: nil), .unknown)
    }

    /// Every Mac this runs on reports a source (a desktop says AC), so `unknown` here would
    /// mean the read itself is broken and the option would silently never hold.
    func testThisMacReportsAPowerSource() {
        XCTAssertNotEqual(IOKitPowerSource().current, .unknown)
    }

    /// The real assertions under the real name, visible to `pmset -g assertions` while held
    /// and gone after shutdown. AC is faked so this runs the same on a laptop on battery.
    func testRealAssertionsAreNamedAndReleased() {
        let holder = KeepAwakeHolder(power: IOKitPowerAssertions(), source: FakeSource(.ac), enabled: true)
        let held = assertions(named: KeepAwakeHolder.assertionName)
        XCTAssertTrue(held.contains(kIOPMAssertionTypePreventUserIdleSystemSleep), "\(held)")
        XCTAssertTrue(held.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep), "\(held)")
        holder.shutdown()
        XCTAssertEqual(assertions(named: KeepAwakeHolder.assertionName), [])
    }

    /// Types of this process's assertions with `name`.
    private func assertions(named name: String) -> [String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return [] }
        let mine = byPid.first { ($0.key as? NSNumber)?.int32Value == getpid() }?.value ?? []
        return mine.filter { $0[kIOPMAssertionNameKey] as? String == name }
            .compactMap { $0[kIOPMAssertionTypeKey] as? String }
    }
    #endif
}
