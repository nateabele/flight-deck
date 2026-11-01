import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the composer with a failed message at phone width, so Retry and Dismiss can be
/// looked at: one failure that offers Retry (not connected) and one that does not (refused).
///
/// **Not a test, and it asserts nothing**, as `PlanTableRenderHarness`: how far apart two
/// buttons sit is a picture. Skipped unless `RENDER_OUTBOX` is an absolute output directory, or
/// an empty `.render` file exists in `DerivedData/outbox-renders-ios` (an app-hosted suite sees
/// it, as the simulator shares this Mac's file system).
@MainActor
final class OutboxRetryRenderHarness: XCTestCase {
    private final class Fleet: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
        var answer: Result<Void, FleetRequestError> = .failure(.disconnected)
        func timelinePage(_ request: FleetRequest,
                          then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void) {}
        func markRead(_ id: UUID) {}
        func sendPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {
            completion(answer)
        }
        func answerPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
        func viewing(_ session: UUID?) {}
    }

    private var directory: URL? {
        if let value = ProcessInfo.processInfo.environment["RENDER_OUTBOX"], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let marked = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DerivedData/outbox-renders-ios", isDirectory: true)
        return FileManager.default.fileExists(atPath: marked.appendingPathComponent(".render").path) ? marked : nil
    }

    func testDrawFailedMessages() throws {
        try XCTSkipUnless(directory != nil, "set RENDER_OUTBOX to draw the outbox rows")
        let directory = self.directory!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = WireSession(id: UUID(), title: "Bathroom Floorplan", agent: "claude",
                                  activity: "idle", waitingFor: nil, subagentCount: 0,
                                  hasBackgroundWork: false, apiError: nil)
        let cases: [(String, Result<Void, FleetRequestError>)] = [
            ("disconnected", .failure(.disconnected)),
            ("refused", .failure(.server(code: "not_running"))),
        ]
        for (name, answer) in cases {
            let fleet = Fleet()
            fleet.answer = answer
            let model = SessionTimelineModel(sessionID: session.id, fleet: fleet)
            model.send("Add the tub. Fixtures along the bottom wall. What are my options for narrow sink/vanity setups?")
            for style in [UIUserInterfaceStyle.light, .dark] {
                for width in [CGFloat(393), 320] {
                    let image = image(of: PromptComposer(session: session, model: model), style: style, width: width)
                    let file = "\(name)-\(style == .light ? "light" : "dark")-\(Int(width)).png"
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(file))
                    print("RENDERED \(file) \(Int(image.size.width))x\(Int(image.size.height))")
                }
            }
        }
    }

    private func image(of view: some View, style: UIUserInterfaceStyle, width: CGFloat) -> UIImage {
        let controller = UIHostingController(rootView: view.frame(width: width))
        controller.safeAreaRegions = []
        controller.overrideUserInterfaceStyle = style
        let fitted = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: ceil(fitted.height))
        controller.view.backgroundColor = .systemBackground
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}
