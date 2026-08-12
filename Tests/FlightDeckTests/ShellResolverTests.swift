import XCTest
@testable import FlightDeck

final class ShellResolverTests: XCTestCase {
    func testUsesShellEnvWhenSet() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/fish"])
        XCTAssertEqual(shell, "/bin/fish")
    }
    func testFallsBackToZshWhenUnset() {
        let shell = ShellResolver.resolve(environment: [:])
        XCTAssertEqual(shell, "/bin/zsh")
    }
    func testFallsBackToZshWhenEmpty() {
        let shell = ShellResolver.resolve(environment: ["SHELL": ""])
        XCTAssertEqual(shell, "/bin/zsh")
    }

    func testOverrideWinsOverShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: "/bin/fish")
        XCTAssertEqual(shell, "/bin/fish")
    }

    func testEmptyOverrideFallsBackToShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: "  ")
        XCTAssertEqual(shell, "/bin/bash")
    }

    func testNilOverrideFallsBackToShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: nil)
        XCTAssertEqual(shell, "/bin/bash")
    }
}
