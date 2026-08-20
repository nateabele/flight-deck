import Network
import XCTest
import FleetKit

final class FleetAdvertisementTests: XCTestCase {
    private var server: FleetSocketServer?
    private var browser: NWBrowser?

    override func tearDown() {
        browser?.cancel()
        server?.stop()
        browser = nil
        server = nil
        super.tearDown()
    }

    func testTheServiceTypeIsTheOneTheClientBrowsesFor() {
        XCTAssertEqual(FleetSocketServer.bonjourType, "_flightdeck._tcp")
    }

    /// Finds our own advertisement on this machine. If this hangs on a first run, macOS is
    /// asking for local-network permission — that is the prompt Task 6 exists to make sure
    /// the app can even receive, and answering it once fixes the run.
    func testAStartedServerIsDiscoverable() async throws {
        let name = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let server = FleetSocketServer()
        server.onHello = { _, _ in [] }
        self.server = server
        _ = try await server.start(keys: [.mint()], port: nil, serviceName: name)

        let found = expectation(description: "browsed")
        let browser = NWBrowser(
            for: .bonjour(type: FleetSocketServer.bonjourType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let service, _, _, _) = result.endpoint { return service }
                return nil
            }
            if names.contains(name) { found.fulfill() }
        }
        browser.start(queue: .main)
        await fulfillment(of: [found], timeout: 20)
    }
}
