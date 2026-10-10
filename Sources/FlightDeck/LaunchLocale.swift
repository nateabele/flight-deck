import Foundation
import os

/// Makes, before libghostty starts any thread, every environment change libghostty's
/// `ensureLocale` would otherwise make while one of its threads is reading the environment.
///
/// Why this exists: `ghostty_init` spawns a `sentry-init` thread (`crash.init`) and *then*, on
/// the calling thread, runs `ensureLocale`. That thread reads `XDG_CACHE_HOME` with Zig's
/// `std.posix.getenv`, which walks `environ` directly — without libc's environment lock. When
/// LANG is unset, `ensureLocale` calls `setenv("LANG", …)` and `setenv("LANGUAGE", …)`; adding a
/// variable reallocates `environ` and frees the old array under the walk. That is the SIGSEGV in
/// `posix.getenv` on `sentry-init` (UI-test Mac, 2026-10-09), with the main thread inside
/// `ensureLocale`'s `setlocale`. LANG is unset for every launchd-started app — Dock, Finder,
/// `open`, XCUITest — so every real launch ran the race; only the window is narrow.
///
/// Doing ghostty's work first removes the race rather than narrowing it: with LANG non-empty and
/// `setlocale(LC_ALL, "")` resolvable, `ensureLocale` reaches neither `setLangFromCocoa` nor its
/// fallback, so libghostty mutates nothing. (vendor/ghostty is pristine, and its sentry is a
/// build-time option with no runtime switch, so the race cannot be closed from inside it.)
///
/// `changes` mirrors ghostty v1.3.1 `src/os/locale.zig` so the resulting environment — which
/// every tab's shell inherits — is what ghostty would have produced. Re-check it on a ghostty bump.
enum LaunchLocale {
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "locale")

    /// What `setLangFromCocoa` reads from `NSLocale`.
    struct Cocoa: Equatable {
        var languageCode: String?
        var countryCode: String?
        var preferredLanguages: [String]
    }

    /// The fallback `ensureLocale` settles on when nothing else resolves.
    static let fallbackLang = "en_US.UTF-8"

    /// The variables to change (nil = unset) so that `ensureLocale` then finds nothing to do.
    ///
    /// - Parameters:
    ///   - resolve: `setlocale(LC_ALL, "")` evaluated against an environment: the locale name,
    ///     or nil when libc cannot load it.
    ///   - canonicalize: BCP-47 to POSIX, as ghostty's `i18n.canonicalizeLocale`.
    static func changes(
        environment: [String: String],
        cocoa: Cocoa,
        resolve: ([String: String]) -> String?,
        canonicalize: (String) -> String
    ) -> [String: String?] {
        var env = environment

        // setLangFromCocoa: only when LANG is unset or empty, and only with both codes.
        if env["LANG"]?.isEmpty ?? true,
           let language = cocoa.languageCode, let country = cocoa.countryCode {
            env["LANG"] = "\(language)_\(country).UTF-8"
            if !cocoa.preferredLanguages.isEmpty {
                env["LANGUAGE"] = cocoa.preferredLanguages
                    .map { canonicalize($0) + ".UTF-8" }
                    .joined(separator: ":")
            }
        }

        // ensureLocale's fallbacks — unset an unloadable LANG, then settle on en_US.UTF-8 — end
        // with LANG=en_US.UTF-8 whenever LANG was what failed. Setting that directly is the same
        // end state without leaving LANG unset, which would send ensureLocale back to Cocoa.
        if resolve(env) == nil {
            env["LANG"] = fallbackLang
        }

        var diff: [String: String?] = [:]
        for key in Set(environment.keys).union(env.keys) where environment[key] != env[key] {
            diff[key] = .some(env[key])
        }
        return diff
    }

    /// The categories `setlocale(LC_ALL, "")` loads, each from LC_ALL, then its own variable,
    /// then LANG, then "C" — POSIX order, which macOS libc follows.
    private static let categories: [(name: String, mask: Int32)] = [
        ("LC_COLLATE", LC_COLLATE_MASK), ("LC_CTYPE", LC_CTYPE_MASK),
        ("LC_MONETARY", LC_MONETARY_MASK), ("LC_NUMERIC", LC_NUMERIC_MASK),
        ("LC_TIME", LC_TIME_MASK), ("LC_MESSAGES", LC_MESSAGES_MASK),
    ]

    /// `setlocale(LC_ALL, "")` against `env`, without touching the process locale or environment:
    /// each category is loaded with `newlocale`. Nil when any category cannot be loaded.
    static func resolve(_ env: [String: String]) -> String? {
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        var names: [String] = []
        for category in categories {
            let name = value("LC_ALL") ?? value(category.name) ?? value("LANG") ?? "C"
            guard let loaded = newlocale(category.mask, name, nil) else { return nil }
            freelocale(loaded)
            names.append(name)
        }
        return Set(names).count == 1 ? names[0] : names.joined(separator: "/")
    }

    /// ghostty's `i18n.canonicalizeLocale`: its zh fix-up, else the libintl canonicalizer
    /// libghostty links (declared in BridgingHeader.h), so LANGUAGE matches ghostty's byte for byte.
    static func canonicalize(_ bcp47: String) -> String {
        let parts = bcp47.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "zh" {
            switch (parts[1], parts[2]) {
            case ("Hans", "SG"): return "zh_SG"
            case ("Hans", _): return "zh_CN"
            case ("Hant", "MO"): return "zh_MO"
            case ("Hant", "HK"): return "zh_HK"
            case ("Hant", _): return "zh_TW"
            default: break
            }
        }
        // libintl canonicalizes in place and needs room to grow: ghostty gives it >= 16 bytes.
        var buffer = [CChar](repeating: 0, count: max(64, bcp47.utf8.count * 2 + 16))
        _ = bcp47.withCString { strncpy(&buffer, $0, buffer.count - 1) }
        _libintl_locale_name_canonicalize(&buffer)
        return String(cString: buffer)
    }

    /// Applies `changes` to this process. Call before `ghostty_init` — before libghostty has
    /// any thread to race — and from one thread; GhosttyApp's one-time init does.
    static func prepareProcessEnvironment() {
        let current = NSLocale.current as NSLocale
        let cocoa = Cocoa(
            languageCode: current.languageCode,
            countryCode: current.countryCode,
            preferredLanguages: NSLocale.preferredLanguages
        )
        let planned = changes(
            environment: ProcessInfo.processInfo.environment,
            cocoa: cocoa, resolve: resolve, canonicalize: canonicalize
        )
        for (key, value) in planned.sorted(by: { $0.key < $1.key }) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
            logger.info("set \(key, privacy: .public)=\(value ?? "<unset>", privacy: .public) before ghostty_init")
        }
    }
}
