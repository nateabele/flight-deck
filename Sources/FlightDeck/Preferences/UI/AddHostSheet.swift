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

/// Mac hosts with a pairing window open right now, for the Mac half of the sheet.
@MainActor
final class HostPairingBrowserModel: ObservableObject {
    @Published private(set) var hosts: [PairingBrowser.DiscoveredMac] = []
    private let browser = PairingBrowser(profile: .host)

    init() {
        browser.onResults = { [weak self] results in
            // `PairingBrowser` defaults to `.main`, so this is the main queue already.
            MainActor.assumeIsolated { self?.hosts = results }
        }
    }

    func start() { browser.start() }
    func stop() { browser.stop() }
}

/// "Add Host…": pair this Mac, as a controller, with another Mac or a Linux box.
///
/// Two halves because the two hosts are found differently: a Mac host's pairing listener is
/// on an ephemeral port that only Bonjour can name, and a Linux host listens on the fixed
/// 47411 at an address the user types.
struct AddHostSheet: View {
    enum Kind: Hashable { case mac, linux }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hostService: HostService
    @StateObject private var browser = HostPairingBrowserModel()

    @State var kind: Kind = .mac
    @State private var selectedHost: String?
    @State private var code = ""
    @State private var address = ""
    @State private var pairing = false
    @State private var error: String?

    private let installCommand = LinuxHostInstaller.command()

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
                    .disabled(!canPair)
                    .accessibilityIdentifier("add-host-pair")
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.hosts) { _, hosts in
            // The one armed Mac on the network is the one the user means; any more and
            // they choose. A chosen Mac that stopped advertising is no longer choosable.
            if let selectedHost, !hosts.contains(where: { $0.serviceName == selectedHost }) {
                self.selectedHost = nil
            }
            if selectedHost == nil, hosts.count == 1 { selectedHost = hosts[0].serviceName }
        }
    }

    // MARK: - Mac

    @ViewBuilder
    private var macSection: some View {
        Text("On the other Mac, open Settings → Hosting, turn on “Let other Macs use this Mac”, and click + under Controllers.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        List(selection: $selectedHost) {
            if browser.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs showing a pairing code…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("add-host-searching")
            } else {
                ForEach(browser.hosts, id: \.serviceName) { host in
                    Label(host.displayName, systemImage: "desktopcomputer")
                        .tag(host.serviceName)
                }
            }
        }
        .frame(height: 96)
        .accessibilityIdentifier("add-host-browser")
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

        TextField("Address", text: $address, prompt: Text("Host name or IP address"))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("add-host-address")
    }

    // MARK: - Code

    private var codeField: some View {
        TextField("Code", text: $code, prompt: Text("XXXX-XXXX-XXXX"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.title3, design: .monospaced))
            .accessibilityIdentifier("add-host-code")
            .onChange(of: code) { _, text in
                // Rewritten into the host's own `XXXX-XXXX-XXXX` shape on every keystroke, so
                // the user compares like with like. The `!=` stops the assignment re-firing
                // this handler in a loop.
                let formatted = PairingCode.grouped(partial: text)
                if formatted != text { code = formatted }
            }
    }

    /// A full-length code always submits, valid checksum or not: a button that stayed dead on
    /// a mistyped code would leave the user with no way to be told it was mistyped.
    private var canPair: Bool {
        guard !pairing, code.count >= 14 else { return false }
        switch kind {
        case .mac: return selectedHost != nil
        case .linux: return !address.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func pair() {
        // Checked here, before anything dials: a mistyped code must cost none of the host's
        // three guesses.
        guard let parsed = PairingCode(normalizing: code) else {
            error = "That code doesn't look right. Check it against the host's screen."
            return
        }
        error = nil
        pairing = true
        let candidate = browser.hosts.first { $0.serviceName == selectedHost }
        let kind = kind, address = address
        Task {
            do {
                switch kind {
                case .mac: _ = try await hostService.pair(code: parsed, candidate: candidate)
                case .linux: _ = try await hostService.pair(code: parsed, address: address)
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
