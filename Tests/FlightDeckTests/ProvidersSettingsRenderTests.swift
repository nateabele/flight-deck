import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of the Providers section, for layout review, skipped by default. Set
/// `FD_PROVIDERS_RENDER_DIR` to an output directory to run it.
@MainActor
final class ProvidersSettingsRenderTests: XCTestCase {
    private func toml(id: String, name: String, contract: Int = 1, generator: Bool = false) -> String {
        var t = "id = \"\(id)\"\nname = \"\(name)\"\nversion = \"1.2.0\"\ncontract = \(contract)\n\n"
            + "[[kind]]\nid = \"k\"\nsummary = \"s\"\noutput = \"html\"\nentry = \"k.html\"\ninstructions = \"k.md\"\n"
        if generator { t += "\n[generator]\ncommand = [\"python3\", \"gen.py\"]\ntimeout = \"10s\"\n" }
        return t
    }

    private func put(_ root: URL, _ id: String, _ text: String, generator: Bool = false) throws {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("provider.toml"))
        try Data("do it".utf8).write(to: dir.appendingPathComponent("k.md"))
        if generator { try Data("print(1)".utf8).write(to: dir.appendingPathComponent("gen.py")) }
    }

    func testRenderProvidersPane() throws {
        // Always renders, so a blank or failed render fails the suite; FD_PROVIDERS_RENDER_DIR
        // keeps the PNGs where they can be looked at.
        let out = ProcessInfo.processInfo.environment["FD_PROVIDERS_RENDER_DIR"]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("providers-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = out.map { URL(fileURLWithPath: $0) } ?? tmp.appendingPathComponent("png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = tmp.appendingPathComponent("flight-deck")
        let repoRoot = repo.appendingPathComponent(ProviderRegistry.repoSubpath)
        let user = tmp.appendingPathComponent("user"), bundled = tmp.appendingPathComponent("bundled")
        let trust = tmp.appendingPathComponent("trust")
        try put(bundled, "diagrams", toml(id: "diagrams", name: "Diagrams"))
        try put(user, "sketch", toml(id: "sketch", name: "Whiteboard sketches"))
        try put(repoRoot, "arch", toml(id: "arch", name: "Architecture map"))
        try put(repoRoot, "charts", toml(id: "charts", name: "Chart renderer", generator: true), generator: true)
        try put(repoRoot, "future", toml(id: "future", name: "Timeline", contract: 2))
        try put(repoRoot, "bad", "id = \"bad\"\nname = \"Bad\"\n")
        let registry = ProviderRegistry(userRoot: user, bundledRoot: bundled, trustStore: ProviderTrustStore(directory: trust))
        let defaults = UserDefaults(suiteName: "providers-render-\(UUID().uuidString)")!
        let size = NSSize(width: 720, height: 460)

        let model = ProvidersSettingsModel(registry: registry, repo: repo, defaults: defaults)
        model.setEnabled(model.key("sketch"), false)
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try PlanningRender.write(ProvidersPane(model: model), size: size,
                                     to: dir.appendingPathComponent("providers\(suffix).png"), appearance: appearance)
        }
        model.approve(model.key("charts"))
        try PlanningRender.write(ProvidersPane(model: model), size: size,
                                 to: dir.appendingPathComponent("providers-approved.png"))

        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: trust.appendingPathComponent("provider-trust.json"))
        let corrupt = ProvidersSettingsModel(registry: registry, repo: repo, defaults: defaults)
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try PlanningRender.write(ProvidersPane(model: corrupt), size: NSSize(width: 720, height: 560),
                                     to: dir.appendingPathComponent("providers-corrupt\(suffix).png"), appearance: appearance)
        }
        let sizes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
            .map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        XCTAssertGreaterThanOrEqual(sizes.count, 5)
        XCTAssertTrue(sizes.allSatisfy { $0 > 15_000 }, "a blank render compresses to almost nothing: \(sizes)")
    }
}
