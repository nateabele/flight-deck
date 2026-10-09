import XCTest
@testable import FlightDeck

/// Pins the fix for the `sentry-init` SIGSEGV: libghostty's `ensureLocale` must find nothing to
/// set, because it runs on the main thread while libghostty's own `sentry-init` thread walks
/// `environ` with no lock (`std.posix.getenv`). A `setenv` that grows `environ` frees the array
/// under that walk. `LaunchLocale` makes every change `ensureLocale` would make, first.
final class LaunchLocaleTests: XCTestCase {
    /// A resolver standing in for `setlocale(LC_ALL, "")`: LANG decides, and only the names in
    /// `valid` exist on this pretend system. An unset LANG resolves to "C", as libc's does.
    private func resolver(valid: Set<String>) -> ([String: String]) -> String? {
        return { env in
            guard let lang = env["LANG"], !lang.isEmpty else { return "C" }
            return valid.contains(lang) ? lang : nil
        }
    }

    private let identity: (String) -> String = { $0.replacingOccurrences(of: "-", with: "_") }

    /// The common case, and the crash's: a launchd-started app (Dock, Finder, XCUITest) has no
    /// LANG, so `ensureLocale` would `setenv` LANG and LANGUAGE from Cocoa.
    func testAnUnsetLangIsSetFromCocoaWithLanguageAlongside() {
        let changes = LaunchLocale.changes(
            environment: ["HOME": "/Users/x"],
            cocoa: .init(languageCode: "en", countryCode: "US", preferredLanguages: ["en-US", "fr-FR"]),
            resolve: resolver(valid: ["en_US.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertEqual(changes["LANG"], .some("en_US.UTF-8"))
        XCTAssertEqual(changes["LANGUAGE"], .some("en_US.UTF-8:fr_FR.UTF-8"))
    }

    func testAnEmptyLangCountsAsUnset() {
        let changes = LaunchLocale.changes(
            environment: ["LANG": ""],
            cocoa: .init(languageCode: "de", countryCode: "DE", preferredLanguages: []),
            resolve: resolver(valid: ["de_DE.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertEqual(changes["LANG"], .some("de_DE.UTF-8"))
        XCTAssertNil(changes["LANGUAGE"], "no preferred languages, so ghostty sets no LANGUAGE")
    }

    /// Launched from a shell, LANG is inherited and valid: `ensureLocale` changes nothing, so
    /// neither may we — LANGUAGE included, which ghostty only sets on the Cocoa path.
    func testAValidInheritedLangChangesNothing() {
        let changes = LaunchLocale.changes(
            environment: ["LANG": "en_GB.UTF-8"],
            cocoa: .init(languageCode: "en", countryCode: "US", preferredLanguages: ["en-US"]),
            resolve: resolver(valid: ["en_GB.UTF-8", "en_US.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertTrue(changes.isEmpty, "got \(changes)")
    }

    /// An invalid LANG makes `ensureLocale` unset it and then set the en_US.UTF-8 fallback.
    func testAnInvalidLangGetsGhosttysFallback() {
        let changes = LaunchLocale.changes(
            environment: ["LANG": "xx_YY.BOGUS"],
            cocoa: .init(languageCode: "en", countryCode: "US", preferredLanguages: []),
            resolve: resolver(valid: ["en_US.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertEqual(changes["LANG"], .some("en_US.UTF-8"))
    }

    /// Cocoa can produce a name libc lacks (a region with no locale file). ghostty would set
    /// it, fail, unset it and fall back — keeping the LANGUAGE it already set.
    func testACocoaLangLibcCannotLoadFallsBackButKeepsLanguage() {
        let changes = LaunchLocale.changes(
            environment: [:],
            cocoa: .init(languageCode: "en", countryCode: "001", preferredLanguages: ["en"]),
            resolve: resolver(valid: ["en_US.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertEqual(changes["LANG"], .some("en_US.UTF-8"))
        XCTAssertEqual(changes["LANGUAGE"], .some("en.UTF-8"))
    }

    /// No country code: ghostty sets nothing, and setlocale("") resolves to "C" and returns.
    func testNoCountryCodeChangesNothing() {
        let changes = LaunchLocale.changes(
            environment: [:],
            cocoa: .init(languageCode: "en", countryCode: nil, preferredLanguages: ["en"]),
            resolve: resolver(valid: ["en_US.UTF-8"]),
            canonicalize: identity
        )
        XCTAssertTrue(changes.isEmpty, "got \(changes)")
    }

    /// The real resolver and canonicalizer, against this Mac's libc and ghostty's libintl.
    func testTheRealCanonicalizerMatchesGhosttys() {
        XCTAssertEqual(LaunchLocale.canonicalize("en-US"), "en_US")
        XCTAssertEqual(LaunchLocale.canonicalize("zh-Hans-CN"), "zh_CN")
        XCTAssertEqual(LaunchLocale.canonicalize("zh-Hant-HK"), "zh_HK")
    }

    func testTheRealResolverAcceptsUTF8AndRejectsGarbage() {
        XCTAssertNotNil(LaunchLocale.resolve(["LANG": "en_US.UTF-8"]))
        XCTAssertNil(LaunchLocale.resolve(["LANG": "xx_YY.BOGUS"]))
        XCTAssertEqual(LaunchLocale.resolve([:]), "C")
        XCTAssertNil(LaunchLocale.resolve(["LANG": "en_US.UTF-8", "LC_CTYPE": "xx_YY.BOGUS"]))
    }

    /// The point of the type: whatever it plans, `ensureLocale`'s first `setlocale(LC_ALL, "")`
    /// then succeeds with LANG set, so it reaches neither `setLangFromCocoa` nor its fallback.
    func testThePlannedEnvironmentLeavesEnsureLocaleNothingToSet() {
        for env in [[:], ["LANG": ""], ["LANG": "xx_YY.BOGUS"], ["LANG": "en_US.UTF-8"]] {
            var after = env
            for (key, value) in LaunchLocale.changes(
                environment: env,
                cocoa: .init(languageCode: "en", countryCode: "US", preferredLanguages: ["en-US"]),
                resolve: LaunchLocale.resolve,
                canonicalize: LaunchLocale.canonicalize
            ) { after[key] = value }
            XCTAssertFalse(after["LANG"]?.isEmpty ?? true, "LANG unset after \(env)")
            XCTAssertNotNil(LaunchLocale.resolve(after), "unresolvable after \(env)")
        }
    }

    /// The ordering is the fix. Preparing after `ghostty_init` is exactly the crash.
    func testGhosttyInitRunsOnlyAfterTheEnvironmentIsPrepared() {
        var calls: [String] = []
        let ok = GhosttyApp.initializeLibrary(
            prepareEnvironment: { calls.append("prepare") },
            initialize: { calls.append("ghostty_init"); return true }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, ["prepare", "ghostty_init"])
    }
}
