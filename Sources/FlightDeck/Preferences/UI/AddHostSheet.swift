import AppKit
import FleetKit
import SwiftUI

/// The one-line Linux hostd install, from the build's own Info.plist.
///
/// The URL and digest are build settings (`FD_HOSTD_RELEASE_BASE_URL`,
/// `FD_HOSTD_INSTALLER_SHA256`), so a build names exactly the installer it was released with.
/// A build with no digest has no published installer, and showing a command with an empty
/// `--sha256` would hand the user something that fails on their host, or worse, a command
/// they edit to skip the check.
enum LinuxHostInstaller {
    static let baseURLKey = "FDHostdReleaseBaseURL"
    static let digestKey = "FDHostdInstallerSHA256"

    static func command(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        let base = (info?[baseURLKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let digest = (info?[digestKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !digest.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "curl -fsSL \(trimmed)/hostd-install.sh | sh -s -- --sha256 \(digest)"
    }
}

/// What a failed host pairing tells the user.
///
/// The same advice, case for case, as the phone's `FleetModel.message(for:)` — that function
/// is in the iOS app and cannot be called from here — reworded for a host, which may be a
/// Linux box on a tailnet rather than a Mac on this Wi-Fi. `.wrongCode` and
/// `.attemptsExhausted` in particular send the user in opposite directions, and one message
/// for both would spend a guess teaching them nothing.
enum HostPairingMessages {
    static func message(for error: HostPairingError) -> String {
        switch error {
        case .noHostsFound:
            return "No host on this network is showing a pairing code. Show one on the host and try again."
        case .badAddress:
            return "That isn't an address Flight Deck can reach. Enter a host name or an IP address."
        case .cancelled:
            return "Pairing was cancelled."
        case .failed(let failure):
            switch failure {
            case .wrongCode:
                return "The host did not accept that code. Check it against the host's screen."
            case .attemptsExhausted:
                return "Too many tries. Show a new code on the host and start again."
            case .unreachable:
                return "Couldn't reach that host. Check the address and that this Mac can reach it."
            case .droppedByMac:
                return "The host closed the connection before finishing. Try the code again."
            case .noAnswer:
                // Not "check the network": the connection came up, so the network works.
                return "The host answered the connection but not the pairing. "
                    + "It may be busy, or something on it is blocking Flight Deck."
            case .malformedResponse:
                return "The host answered with something Flight Deck didn't understand. Update Flight Deck on both machines."
            }
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? HostPairingError { return message(for: error) }
        return "Couldn't save this host: \(error.localizedDescription)"
    }
}

/// The slice of `PairingBrowser` the sheet uses, so a test drives results by hand rather than
/// browsing the real network.
protocol HostPairingBrowsing: AnyObject {
    var onResults: (([PairingBrowser.DiscoveredMac]) -> Void)? { get set }
    func start()
    func stop()
}

extension PairingBrowser: HostPairingBrowsing {}

/// The Add Host sheet's state, outside SwiftUI: the Mac hosts Bonjour finds, which one is
/// chosen, the typed address and code, and whether to admit that nothing has turned up.
@MainActor
final class AddHostModel: ObservableObject {
    /// What the Mac tab pairs with. A typed address wins over a found Mac: the field is only
    /// ever filled by someone who means it.
    enum MacTarget: Equatable {
        case address(String)
        case host(PairingBrowser.DiscoveredMac)
    }

    /// How long the Mac tab searches before saying Bonjour may not reach the host. A Mac on
    /// the same network with a code up answers in well under a second.
    nonisolated static let notFoundDelay: TimeInterval = 5

    @Published private(set) var hosts: [PairingBrowser.DiscoveredMac] = []
    @Published var selectedHost: String?
    /// Shared by both tabs. A paste of the host's "Copy Pairing Details" string —
    /// `address:port CODE` — is split here into this field and `code`.
    @Published var address = "" {
        didSet {
            // Only a paste that carries a code is rewritten, so the assignment below (which
            // carries none) cannot loop, and plain typing is never touched.
            guard let parsed = PairingDetails.parse(address), let pasted = parsed.code else { return }
            address = parsed.address
            code = PairingCode.grouped(partial: pasted)
        }
    }
    @Published var code = ""
    @Published private(set) var searchedLong = false

    private let browser: HostPairingBrowsing
    private let notFoundDelay: TimeInterval
    private var hintTimer: Task<Void, Never>?

    init(browser: HostPairingBrowsing = PairingBrowser(profile: .host),
         notFoundDelay: TimeInterval = AddHostModel.notFoundDelay) {
        self.browser = browser
        self.notFoundDelay = notFoundDelay
        browser.onResults = { [weak self] results in
            // `PairingBrowser` defaults to `.main`, so this is the main queue already.
            MainActor.assumeIsolated { self?.receive(results) }
        }
    }

    /// The spinner stays: a Mac that is merely slow to advertise still turns up. But Bonjour
    /// stops at the edge of this network, so a host over Tailscale never will, however long
    /// the user waits, and they are told there is another way in.
    var showsNotFoundHint: Bool { searchedLong && hosts.isEmpty }

    var macTarget: MacTarget? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return .address(typed) }
        return hosts.first { $0.serviceName == selectedHost }.map(MacTarget.host)
    }

    /// A full-length code always submits, valid checksum or not: a button that stayed dead on
    /// a mistyped code would leave the user with no way to be told it was mistyped.
    func canPair(kind: AddHostSheet.Kind, pairing: Bool) -> Bool {
        guard !pairing, code.count >= 14 else { return false }
        switch kind {
        case .mac: return macTarget != nil
        case .linux: return !address.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Returns the hint's timer so a test can await it. A hint already earned stays: the
    /// sheet's `onAppear` calls this again, and a re-appearing sheet is no likelier to find
    /// the host than it was a moment ago.
    @discardableResult
    func start() -> Task<Void, Never> {
        browser.start()
        hintTimer?.cancel()
        let delay = notFoundDelay
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.searchedLong = true
        }
        hintTimer = timer
        return timer
    }

    func stop() {
        browser.stop()
        hintTimer?.cancel()
        hintTimer = nil
    }

    private func receive(_ results: [PairingBrowser.DiscoveredMac]) {
        hosts = results
        // The one armed Mac on the network is the one the user means; any more and they
        // choose. A chosen Mac that stopped advertising is no longer choosable.
        if let selectedHost, !results.contains(where: { $0.serviceName == selectedHost }) {
            self.selectedHost = nil
        }
        if selectedHost == nil, results.count == 1 { selectedHost = results[0].serviceName }
    }
}

/// "Add Host…": pair this Mac, as a controller, with another Mac or a Linux box.
///
/// Two halves because the two hosts are set up and found differently: a Mac host is usually
/// found by Bonjour, a Linux host by the address the user types. Both listen for pairing on
/// 47411, so the Mac half takes a typed address too, for a Mac Bonjour cannot reach (across a
/// tailnet). Either half accepts the host's pasted "address:port CODE" in its address field.
struct AddHostSheet: View {
    enum Kind: Hashable { case mac, linux }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hostService: HostService
    @StateObject private var model: AddHostModel

    @State var kind: Kind
    @State private var pairing = false
    @State private var error: String?

    private let installCommand = LinuxHostInstaller.command()

    /// `model` is injectable for the offscreen renders, which show states (the not-found hint,
    /// a found Mac) that a live browse would only reach by chance.
    @MainActor
    init(hostService: HostService, kind: Kind = .mac, model: AddHostModel? = nil) {
        self.hostService = hostService
        _kind = State(initialValue: kind)
        // `wrappedValue` is an autoclosure, so the live model is built once per sheet, not
        // on every re-render of the view that presents it.
        _model = StateObject(wrappedValue: model ?? AddHostModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a host")
                .font(.title2.bold())

            Picker("Host", selection: $kind) {
                Text("Mac").tag(Kind.mac)
                Text("Linux").tag(Kind.linux)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("add-host-kind")

            switch kind {
            case .mac: macSection
            case .linux: linuxSection
            }

            codeField

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("add-host-error")
            }

            HStack {
                if pairing {
                    ProgressView().controlSize(.small)
                    Text("Pairing…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    // A pairing left running would go on to store a host the user backed
                    // out of.
                    if pairing { hostService.cancelPairing() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Pair") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPair(kind: kind, pairing: pairing))
                    .accessibilityIdentifier("add-host-pair")
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Mac

    @ViewBuilder
    private var macSection: some View {
        Text("On the other Mac, open Settings → Hosting, turn on “Let other Macs use this Mac”, and click + under Controllers.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        List(selection: $model.selectedHost) {
            if model.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs showing a pairing code…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("add-host-searching")
                if model.showsNotFoundHint {
                    Text("Not on this network (e.g. over Tailscale)? Enter the Mac's address instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("add-host-not-found-hint")
                }
            } else {
                ForEach(model.hosts, id: \.serviceName) { host in
                    Label(host.displayName, systemImage: "desktopcomputer")
                        .tag(host.serviceName)
                }
            }
        }
        .frame(height: 96)
        .accessibilityIdentifier("add-host-browser")

        // Always usable, not only once the hint shows: someone who already knows the host is
        // on their tailnet should not have to wait out the search.
        TextField("Address", text: $model.address, prompt: Text("Host name or IP address"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("add-host-mac-address")
    }

    // MARK: - Linux

    @ViewBuilder
    private var linuxSection: some View {
        Text("Install the host service on the Linux machine:")
            .font(.callout)
            .foregroundStyle(.secondary)

        if let installCommand {
            HStack(alignment: .top, spacing: 8) {
                Text(installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityIdentifier("add-host-copy-install")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
        } else {
            Text("Linux installer not yet published for this build")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
                .accessibilityIdentifier("add-host-install-unpublished")
        }

        // The installer ends by exec'ing `pair` itself, so telling the user to run it again
        // would arm a second code that replaces the one already on their screen.
        Text("The installer finishes by printing a pairing code. Enter the machine's address and that code below. If the code expires, run `flightdeck-hostd pair` there for a new one.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextField("Address", text: $model.address, prompt: Text("Host name or IP address"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("add-host-address")
    }

    // MARK: - Code

    private var codeField: some View {
        TextField("Code", text: $model.code, prompt: Text("XXXX-XXXX-XXXX"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.title3, design: .monospaced))
            .accessibilityIdentifier("add-host-code")
            .onChange(of: model.code) { _, text in
                // Rewritten into the host's own `XXXX-XXXX-XXXX` shape on every keystroke, so
                // the user compares like with like. The `!=` stops the assignment re-firing
                // this handler in a loop.
                let formatted = PairingCode.grouped(partial: text)
                if formatted != text { model.code = formatted }
            }
    }

    private func pair() {
        // Checked here, before anything dials: a mistyped code must cost none of the host's
        // three guesses.
        guard let parsed = PairingCode(normalizing: model.code) else {
            error = "That code doesn't look right. Check it against the host's screen."
            return
        }
        error = nil
        pairing = true
        let kind = kind, address = model.address, macTarget = model.macTarget
        Task {
            do {
                switch (kind, macTarget) {
                case (.mac, .address(let typed)?): _ = try await hostService.pair(code: parsed, address: typed)
                case (.mac, .host(let candidate)?): _ = try await hostService.pair(code: parsed, candidate: candidate)
                // Unreachable while Pair is disabled without a target; nil browses, as before.
                case (.mac, nil): _ = try await hostService.pair(code: parsed, candidate: nil)
                case (.linux, _): _ = try await hostService.pair(code: parsed, address: address)
                }
                pairing = false
                dismiss()
            } catch HostPairingError.cancelled {
                pairing = false
            } catch {
                pairing = false
                self.error = HostPairingMessages.message(for: error)
            }
        }
    }
}
