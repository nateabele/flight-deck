import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the cloud pane and the session row's icon at phone width so they can be looked at.
///
/// **Not a test, and it asserts nothing**, as `PlanTableRenderHarness`: how a screen sits is a
/// picture. Skipped unless `RENDER_CLOUD` is an absolute output directory (pass it to
/// `xcodebuild` as `TEST_RUNNER_RENDER_CLOUD`).
@MainActor
final class CloudRenderHarness: XCTestCase {
    private final class Idle: InfraCommanding {
        func infra(_ request: InfraRequest, progress: @escaping (String) -> Void) async -> Result<InfraOutcome, InfraRequestError> { .success(.done) }
    }

    private var directory: URL? {
        ProcessInfo.processInfo.environment["RENDER_CLOUD"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
    }

    private func screen(_ cloud: WireSessionCloud?) -> some View {
        NavigationStack {
            SessionCloudScreen(title: "Train the ranker", cloud: cloud, commander: Idle(), now: CloudFixtures.now)
        }
    }

    private func rows() -> some View {
        let plain = WireSession(id: UUID(), title: "docs cleanup", agent: "claude")
        let healthy = WireSession(id: UUID(), title: "Train the ranker", agent: "claude", cloud: CloudFixtures.healthy)
        let failed = WireSession(id: UUID(), title: "Benchmark on GPU", agent: "claude", cloud: CloudFixtures.failed)
        return List {
            ForEach([plain, healthy, failed], id: \.id) { s in
                NavigationLink(value: s.id) { FleetListScreen.row(s, onCloud: {}) }
                    .listRowInsets(FleetListScreen.rowInsets)
            }
        }
    }

    func testDrawCloud() throws {
        try XCTSkipUnless(directory != nil, "set RENDER_CLOUD to draw the cloud pane")
        let directory = self.directory!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawings: [(String, AnyView, CGFloat)] = [
            ("pane-healthy", AnyView(screen(CloudFixtures.healthy)), 1300),
            ("pane-failed", AnyView(screen(CloudFixtures.failed)), 800),
            ("pane-unbudgeted", AnyView(screen(CloudFixtures.unbudgeted)), 700),
            ("pane-empty", AnyView(screen(nil)), 400),
            ("rows", AnyView(NavigationStack { rows().navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline) }), 300),
        ]
        for (name, view, height) in drawings {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let file = "\(name)-\(style == .light ? "light" : "dark").png"
                try XCTUnwrap(image(of: view, style: style, size: CGSize(width: 390, height: height)).pngData())
                    .write(to: directory.appendingPathComponent(file))
                print("RENDERED \(file)")
            }
        }
    }

    private func image(of view: some View, style: UIUserInterfaceStyle, size: CGSize) -> UIImage {
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = style
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}
