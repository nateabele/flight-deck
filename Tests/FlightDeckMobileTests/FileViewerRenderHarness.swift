import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws the file viewer's first screen at phone size — markdown, a source file opened at a
/// line, a log, a downsampled image — so it can be looked at.
///
/// **Not a test, and it asserts nothing** — see `PlanTableRenderHarness`. Skipped unless an
/// empty `.render` file sits in `DerivedData/file-viewer-renders-ios`.
@MainActor
final class FileViewerRenderHarness: XCTestCase {
    private final class Reader: FileReading {
        let data: Data
        let downsampled: Bool
        init(_ data: Data, downsampled: Bool = false) { self.data = data; self.downsampled = downsampled }
        func readFile(session: UUID, path: String, offset: Int64, limit: Int, maxPixel: Int?,
                      then completion: @escaping (Result<WireFileChunk, FleetRequestError>) -> Void) {
            let start = Int(offset), end = min(data.count, start + limit)
            completion(.success(WireFileChunk(
                path: "/Users/me/Projects/flight-deck/" + path, size: Int64(data.count), offset: offset,
                data: data.subdata(in: start..<end), downsampled: downsampled,
                pixelWidth: downsampled ? 6048 : nil, pixelHeight: downsampled ? 4024 : nil)))
        }
    }

    private var directory: URL? {
        let marked = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/file-viewer-renders-ios", isDirectory: true)
        return FileManager.default.fileExists(atPath: marked.appendingPathComponent(".render").path) ? marked : nil
    }

    func testDrawFiles() throws {
        try XCTSkipUnless(directory != nil, "touch DerivedData/file-viewer-renders-ios/.render to draw the file viewer")
        let directory = self.directory!
        let markdown = """
        ---
        name: peer-messaging
        description: Talk to other agent tabs.
        ---
        # Peer messaging

        Flight Deck lets an agent in one tab **message another**, see [the spec](docs/PEER-MESSAGING.md).

        ## Rules

        - A message is delivered once, in order.
        - A reply names the thread it answers.

        | Op | Writes |
        |---|---|
        | list | no |
        | send | yes |

        ```swift
        try await peers.send(to: tab, text: "hi")
        ```
        """
        let swift = (1...80).map { i in i == 42 ? "    let answer = try await connector.requestFile(session: id, path: path)" : "    // line \(i) of the file, with some ordinary code-ish text" }
            .joined(separator: "\n")
        let log = (1...60).map { "2026-10-25 12:47:\(String(format: "%02d", $0 % 60)) build step \($0) finished in \($0 * 37) ms; nothing to report." }
            .joined(separator: "\n")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 300, y: 200, width: 600, height: 400))
        }.jpegData(compressionQuality: 0.8)!

        let cases: [(String, String, Reader)] = [
            ("markdown", "skills/SKILL.md", Reader(Data(markdown.utf8))),
            ("code", "Sources/FleetConnector.swift:42", Reader(Data(swift.utf8))),
            ("text", "build.log", Reader(Data(log.utf8))),
            ("image", "assets/photo.jpg", Reader(image, downsampled: true)),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, link, reader) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let route = FileRoute(session: UUID(), link: LocalFileLink(string: link)!)
                let view = NavigationStack { FileViewerScreen(route: route, reader: reader) }
                let png = render(view, style: style)
                let file = "\(name)-\(style == .light ? "light" : "dark").png"
                try XCTUnwrap(png.pngData()).write(to: directory.appendingPathComponent(file))
                print("RENDERED \(file)")
            }
        }
    }

    private func render(_ view: some View, style: UIUserInterfaceStyle) -> UIImage {
        let size = CGSize(width: 393, height: 852)
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = style
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        // `.task` loads the file and `onChange` scrolls to the line: both need the run loop.
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
}
