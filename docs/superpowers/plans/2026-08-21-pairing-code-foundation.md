# Pairing Code Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test the crypto foundation for the short pairing code — the code itself, a SPAKE2 wrapper over BoringSSL, and the confirmation and key-sealing steps — entirely headlessly, before any socket or screen depends on it.

**Architecture:** BoringSSL is vendored as an xcframework the way Ghostty already is, and wrapped in a small Swift type in `FleetKit` so nothing outside it touches C. The pairing code is a pure value type with its own alphabet and checksum. BoringSSL's SPAKE2 produces raw keying material and *no* confirmation, so confirmation and key sealing are built here on CryptoKit's HKDF and AES-GCM.

**Tech Stack:** Swift 6 (`FleetKit`), CryptoKit, BoringSSL (C), XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-21-short-pairing-code-design.md`](../specs/2026-08-21-short-pairing-code-design.md)

**Follows:** Plan B (the pairing listener, PAKE frames, packed QR and both UIs) is written against the interfaces this plan produces, once they exist rather than as guesses.

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security and CryptoKit only.** No AppKit, no UIKit, no SwiftUI. The `FleetKitiOS` target compiles the same sources for iOS and is what enforces this — a macOS-only import compiles fine for the Mac and fails there.
- **`FleetKit` builds in Swift 6 language mode.** The rest of the project is Swift 5.
- **The vendored library must build for three slices:** macOS arm64, iOS arm64 (device), iOS simulator.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`. Nothing in this plan is async, so it should not arise.
- **Never run `./scripts/smoke.sh`** — it seizes the foreground for ~70 seconds and captures the user's keystrokes as phantom test failures.
- **Do not run `./scripts/test-unit.sh` while a debug Flight Deck instance is running.** Check with `pgrep -f "harness/Flight Deck.app"` first.
- **Baseline is 1115 tests, 0 failures.** Report the count after every task.
- **The bootstrap PSK and the pairing code are independent.** Nothing in this plan may derive one from the other — see the spec's §6. That constraint is stated here because the type that would tempt someone (`PairingCode`) is built in Task 2.

---

### Task 1: Vendor BoringSSL as an xcframework

The one task with no test-first cycle, because its deliverable is a binary artifact plus proof that Swift can call into it on both platforms. That proof is the test.

**Files:**
- Create: `scripts/build-boringssl.sh`
- Create: `vendor/boringssl-artifacts/BoringSSL.xcframework` (build output, committed)
- Modify: `project.yml` (link the framework into `FleetKit` and `FleetKitiOS`)
- Create: `Sources/FleetKit/SPAKE2/BoringSSLShim.h` (umbrella header exposing only the SPAKE2 surface)
- Test: `Tests/FlightDeckTests/BoringSSLLinkTests.swift`

**Interfaces:**
- Produces: the C symbols `SPAKE2_CTX_new`, `SPAKE2_CTX_free`, `SPAKE2_generate_msg`, `SPAKE2_process_msg`, the `spake2_role_t` enum, and the constants `SPAKE2_MAX_MSG_SIZE` (32) and `SPAKE2_MAX_KEY_SIZE` (64), callable from Swift in `FleetKit`.

- [ ] **Step 1: Write the build script**

BoringSSL builds with CMake and needs Go on the build machine. Build each slice separately, then combine. Create `scripts/build-boringssl.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned rather than tracking master: this is a vendored security dependency, and
# "whatever HEAD was the day someone re-ran this" is not a version anyone can audit.
# Update deliberately, in its own commit, with the tag in the message.
BORINGSSL_TAG="${BORINGSSL_TAG:-0.20250114.0}"
WORK="$(mktemp -d)"
OUT="vendor/boringssl-artifacts"

git clone --depth 1 --branch "$BORINGSSL_TAG" \
  https://boringssl.googlesource.com/boringssl "$WORK/src"

build_slice() {
  local name="$1" sysroot="$2" arch="$3" minflag="$4"
  cmake -S "$WORK/src" -B "$WORK/build-$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_C_FLAGS="$minflag" \
    -DBUILD_SHARED_LIBS=OFF
  cmake --build "$WORK/build-$name" --target crypto
}

build_slice macos     macosx          arm64        "-mmacosx-version-min=14.0"
build_slice ios       iphoneos        arm64        "-miphoneos-version-min=17.0"
build_slice iossim    iphonesimulator "arm64;x86_64" "-mios-simulator-version-min=17.0"

# Headers are identical across slices; take one copy.
HDR="$WORK/headers"
mkdir -p "$HDR"
cp -R "$WORK/src/include/openssl" "$HDR/"

rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/build-macos/libcrypto.a"  -headers "$HDR" \
  -library "$WORK/build-ios/libcrypto.a"    -headers "$HDR" \
  -library "$WORK/build-iossim/libcrypto.a" -headers "$HDR" \
  -output "$OUT/BoringSSL.xcframework"

echo "Built $OUT/BoringSSL.xcframework from BoringSSL $BORINGSSL_TAG"
```

Make it executable: `chmod +x scripts/build-boringssl.sh`

- [ ] **Step 2: Run it and commit the artifact**

Run: `./scripts/build-boringssl.sh`

If CMake, Ninja or Go are missing the script fails with their own message — install them (`brew install cmake ninja go`) rather than working around it.

The `.xcframework` is committed, exactly as `vendor/ghostty-artifacts/GhosttyKit.xcframework` is. It is large; that is the accepted cost of the option chosen in the spec, which was "upstream stays upstream and nothing is forked."

- [ ] **Step 3: Write the shim header**

BoringSSL's headers pull in a great deal we do not want in `FleetKit`'s module. Expose only SPAKE2. Create `Sources/FleetKit/SPAKE2/BoringSSLShim.h`:

```c
// The only BoringSSL surface FleetKit is allowed to see.
//
// Importing <openssl/curve25519.h> directly would put every other BoringSSL
// declaration into FleetKit's module namespace, where any of it could be reached
// by accident and none of it is reviewed for use here. SPAKE2 is the entire
// reason this dependency exists.
#ifndef FLEETKIT_BORINGSSL_SHIM_H
#define FLEETKIT_BORINGSSL_SHIM_H

#include <openssl/curve25519.h>

#endif
```

- [ ] **Step 4: Wire it into project.yml**

Add to **both** the `FleetKit` and `FleetKitiOS` targets' `dependencies:` list:

```yaml
      - framework: vendor/boringssl-artifacts/BoringSSL.xcframework
        embed: false
```

And in each target's `settings.base`, point the module at the shim:

```yaml
        SWIFT_INCLUDE_PATHS: $(SRCROOT)/Sources/FleetKit/SPAKE2
```

`embed: false` matches how Ghostty is linked: it is a static library, so there is nothing to embed.

- [ ] **Step 5: Write the link test**

Create `Tests/FlightDeckTests/BoringSSLLinkTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// Proves the vendored library is actually linked and callable, on whichever platform this
/// bundle is running. It asserts almost nothing about SPAKE2 — Task 3 does that — because
/// its job is to fail loudly when the xcframework is missing a slice, which otherwise shows
/// up as an inscrutable link error in an unrelated task.
final class BoringSSLLinkTests: XCTestCase {
    func testSPAKE2ContextCanBeCreatedAndFreed() {
        let name = Array("flightdeck".utf8)
        let ctx = name.withUnsafeBufferPointer { buf in
            SPAKE2_CTX_new(spake2_role_alice, buf.baseAddress, buf.count, buf.baseAddress, buf.count)
        }
        XCTAssertNotNil(ctx, "BoringSSL is not linked, or its SPAKE2 slice is missing")
        SPAKE2_CTX_free(ctx)
    }

    func testTheDocumentedBufferConstantsAreWhatWeSizeAgainst() {
        // Task 3's wrapper sizes its buffers from these. If a BoringSSL update changes them,
        // fail here with an obvious message rather than truncating a key somewhere subtle —
        // `SPAKE2_process_msg` silently truncates into a short buffer.
        XCTAssertEqual(SPAKE2_MAX_MSG_SIZE, 32)
        XCTAssertEqual(SPAKE2_MAX_KEY_SIZE, 64)
    }
}
```

- [ ] **Step 6: Verify both platforms**

Run: `./scripts/test-unit.sh`
Expected: 1117 tests, 0 failures (1115 baseline + 2).

Run: `./scripts/build-ios.sh`
Expected: `FleetKitiOS ** BUILD SUCCEEDED **` and `FlightDeckMobile ** BUILD SUCCEEDED **`. A link failure here and not in the macOS run means the iOS or simulator slice is missing from the xcframework.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-boringssl.sh vendor/boringssl-artifacts project.yml \
        Sources/FleetKit/SPAKE2/BoringSSLShim.h \
        Tests/FlightDeckTests/BoringSSLLinkTests.swift
git commit -m "build: vendor BoringSSL's SPAKE2 as an xcframework"
```

---

### Task 2: `PairingCode`

The 12-character code, as a value type. No networking, no crypto beyond the CSPRNG and a hash — this is the piece a person actually types, so its parsing rules matter more than its cleverness.

**Files:**
- Create: `Sources/FleetKit/PairingCode.swift`
- Test: `Tests/FlightDeckTests/PairingCodeTests.swift`

**Interfaces:**
- Produces:
  - `public struct PairingCode: Equatable, Sendable`
  - `public static func mint() -> PairingCode`
  - `public init?(normalizing input: String)` — nil when the input is not 12 valid symbols or the checksum fails
  - `public var formatted: String` — `"XXXX-XXXX-XXXX"`, for display
  - `public var secret: Data` — the 7 bytes the PAKE uses as its password. **Not** the display string.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingCodeTests.swift`:

```swift
import XCTest
import FleetKit

final class PairingCodeTests: XCTestCase {
    func testAMintedCodeFormatsAsTwelveSymbolsInThreeGroups() {
        let code = PairingCode.mint()
        XCTAssertEqual(code.formatted.count, 14, "12 symbols plus two hyphens")
        let groups = code.formatted.split(separator: "-")
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
    }

    /// The alphabet is the whole reason this is typable. `I`, `L`, `O` and `U` are absent:
    /// the first three because they are unreadable next to `1` and `0`, and `U` because
    /// excluding it is what keeps an accidental obscenity out of a code the user reads aloud.
    func testTheAlphabetExcludesTheAmbiguousLetters() {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for _ in 0..<200 {
            let symbols = PairingCode.mint().formatted.filter { $0 != "-" }
            XCTAssertTrue(symbols.allSatisfy { alphabet.contains($0) }, "\(symbols)")
        }
    }

    func testAMintedCodeRoundTripsThroughItsOwnFormatting() {
        let code = PairingCode.mint()
        XCTAssertEqual(PairingCode(normalizing: code.formatted), code)
    }

    /// Someone reading a code off a screen across the room types what they hear, in whatever
    /// case their keyboard is in, with or without the hyphens we added for legibility.
    func testInputIsNormalizedBeforeItIsJudged() {
        let code = PairingCode.mint()
        let bare = code.formatted.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(PairingCode(normalizing: bare.lowercased()), code)
        XCTAssertEqual(PairingCode(normalizing: "  \(code.formatted)  "), code)
        let spaced = bare.map { String($0) }.joined(separator: " ")
        XCTAssertEqual(PairingCode(normalizing: spaced), code,
                       "spaces anywhere are noise, not signal")
    }

    /// The checksum is what makes a 3-attempt budget workable: a typo must be caught here,
    /// on the device, rather than spending a third of the budget to learn it on the Mac.
    func testASingleCharacterTypoIsRejectedLocally() {
        let code = PairingCode.mint()
        var symbols = Array(code.formatted.filter { $0 != "-" })
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var rejected = 0
        for position in symbols.indices {
            let original = symbols[position]
            for replacement in alphabet where replacement != original {
                symbols[position] = replacement
                if PairingCode(normalizing: String(symbols)) == nil { rejected += 1 }
            }
            symbols[position] = original
        }
        // A 5-bit checksum catches 31/32 of single-symbol errors. Assert the rate rather than
        // "all", because claiming a 5-bit check is perfect would be a lie a future reader
        // might rely on.
        let total = symbols.count * (alphabet.count - 1)
        XCTAssertGreaterThan(Double(rejected) / Double(total), 0.9)
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        XCTAssertNil(PairingCode(normalizing: ""))
        XCTAssertNil(PairingCode(normalizing: "TOO-SHORT"))
        XCTAssertNil(PairingCode(normalizing: "IIII-LLLL-OOOO"), "excluded letters are not symbols")
        XCTAssertNil(PairingCode(normalizing: "!!!!-!!!!-!!!!"))
    }

    /// Two codes minted in a row must differ. A stuck CSPRNG or a mis-masked value that
    /// collapsed the space would otherwise pass every other test in this file.
    func testMintedCodesAreNotRepeating() {
        let codes = Set((0..<500).map { _ in PairingCode.mint().formatted })
        XCTAssertEqual(codes.count, 500)
    }

    /// The password handed to SPAKE2 is the 55 bits, not the display string — so hyphenation
    /// and case cannot change what the two sides prove knowledge of.
    func testTheSecretIsIndependentOfPresentation() {
        let code = PairingCode.mint()
        let bare = code.formatted.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(PairingCode(normalizing: bare)?.secret, code.secret)
        XCTAssertEqual(code.secret.count, 7)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PairingCode' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/PairingCode.swift`:

```swift
import CryptoKit
import Foundation
import Security

/// The short code a user types when they cannot scan the QR.
///
/// Twelve symbols: eleven of entropy (55 bits) and one checksum. The alphabet is Crockford
/// base32 — `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — which omits `I`, `L`, `O` and `U`. The first
/// three are omitted because a code is read off one screen and typed into another device, often
/// from across a room, and `1`/`I`/`l` and `0`/`O` are the errors that produces.
///
/// **55 bits is not the security boundary; the attempt limit is.** Three online guesses against
/// 55 bits is roughly 1 in 10¹⁶ per window, and SPAKE2 is what denies an attacker any offline
/// path. Shortening the code would still be safe on those numbers — it is this long because
/// there is no reason for it to be shorter, not because 55 bits is a computed minimum.
///
/// **The code and the pairing channel's bootstrap PSK must stay independent.** Deriving that
/// PSK from this code looks like free confidentiality and would hand a passive observer an
/// offline attack on these 55 bits, which is the exact thing SPAKE2 is here to prevent.
public struct PairingCode: Equatable, Sendable {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let symbolCount = 12
    private static let entropySymbols = 11

    /// The 55 bits, right-aligned in 7 bytes. This is what SPAKE2 uses as its password, so it
    /// is deliberately *not* derived from the display string: hyphens and case are presentation
    /// and must not change what the two sides prove knowledge of.
    public let secret: Data

    private init(secret: Data) {
        self.secret = secret
    }

    public static func mint() -> PairingCode {
        var bytes = [UInt8](repeating: 0, count: 7)
        // Same reasoning as `FleetDeviceKey.mint()`: a CSPRNG that will not answer is not a
        // condition to degrade around, so trap rather than fall back to something weaker.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        // 7 bytes is 56 bits; the code carries 55. Clear the top bit so the value and its
        // encoding agree — otherwise the 56th bit would be minted, dropped on the way out,
        // and two distinct secrets would render as the same code.
        bytes[0] &= 0x7F
        return PairingCode(secret: Data(bytes))
    }

    public init?(normalizing input: String) {
        let symbols = input.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard symbols.count == Self.symbolCount else { return nil }

        var values: [UInt8] = []
        values.reserveCapacity(Self.symbolCount)
        for character in symbols {
            guard let value = Self.alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(value))
        }

        let entropy = Array(values[..<Self.entropySymbols])
        let secret = Self.pack(entropy)
        guard values[Self.entropySymbols] == Self.checkSymbol(for: secret) else { return nil }
        self.init(secret: secret)
    }

    public var formatted: String {
        let entropy = Self.unpack(secret)
        let symbols = (entropy + [Self.checkSymbol(for: secret)])
            .map { String(Self.alphabet[Int($0)]) }
            .joined()
        let groups = stride(from: 0, to: symbols.count, by: 4).map {
            String(symbols[symbols.index(symbols.startIndex, offsetBy: $0)...]
                .prefix(4))
        }
        return groups.joined(separator: "-")
    }

    /// 11 five-bit symbols, most significant first, into the low 55 bits of 7 bytes.
    private static func pack(_ symbols: [UInt8]) -> Data {
        var value: UInt64 = 0
        for symbol in symbols { value = (value << 5) | UInt64(symbol) }
        var bytes = [UInt8](repeating: 0, count: 7)
        for index in 0..<7 { bytes[6 - index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        return Data(bytes)
    }

    private static func unpack(_ secret: Data) -> [UInt8] {
        var value: UInt64 = 0
        for byte in secret { value = (value << 8) | UInt64(byte) }
        return (0..<entropySymbols).reversed().map { UInt8((value >> (5 * UInt64($0))) & 0x1F) }
    }

    /// Five bits of SHA-256 over the packed secret.
    ///
    /// Not a cryptographic control — an attacker computes it as easily as we do. It exists so a
    /// mistyped code fails on the phone instead of spending one of three attempts on the Mac to
    /// discover the same thing, and so the phone can say "that code doesn't look right" rather
    /// than "pairing failed", which sends the user somewhere different.
    private static func checkSymbol(for secret: Data) -> UInt8 {
        let digest = SHA256.hash(data: secret)
        return digest.withUnsafeBytes { UInt8($0[0] & 0x1F) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. 1125 tests, 0 failures (1117 + 8).

- [ ] **Step 5: Verify the iOS slice still compiles**

Run: `./scripts/build-ios.sh 2>&1 | tail -3`
Expected: `FleetKitiOS ** BUILD SUCCEEDED **`. `PairingCode` imports CryptoKit, which is available on both platforms — this step is what proves that rather than assuming it.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/PairingCode.swift Tests/FlightDeckTests/PairingCodeTests.swift
git commit -m "feat: a twelve-character pairing code that survives being typed"
```

---

### Task 3: `SPAKE2Session`

The Swift wrapper. Everything C stays behind this type.

**Files:**
- Create: `Sources/FleetKit/SPAKE2/SPAKE2Session.swift`
- Test: `Tests/FlightDeckTests/SPAKE2SessionTests.swift`

**Interfaces:**
- Consumes: the C symbols from Task 1; `PairingCode.secret` from Task 2.
- Produces:
  - `public enum SPAKE2Role { case initiator, responder }`
  - `public final class SPAKE2Session`
  - `public init(role: SPAKE2Role, myName: Data, theirName: Data)`
  - `public func message(for code: PairingCode) throws -> Data` — callable **once**
  - `public func keyMaterial(from peerMessage: Data) throws -> Data` — 64 bytes, callable once, after `message(for:)`
  - `public enum SPAKE2Error: Error { case contextUnavailable, generateFailed, processFailed, wrongOrder }`

- [ ] **Step 1: Write the failing tests**

The vectors come from BoringSSL's own `crypto/curve25519/spake2_test.cc`, which is in the source tree Task 1 clones — copy them from there rather than from a blog post, and cite the file in a comment.

Create `Tests/FlightDeckTests/SPAKE2SessionTests.swift`:

```swift
import XCTest
import FleetKit

final class SPAKE2SessionTests: XCTestCase {
    private let alice = Data("alice".utf8)
    private let bob = Data("bob".utf8)

    /// The property the whole design rests on: same code, both sides land on the same key.
    func testBothSidesDeriveTheSameKeyFromTheSameCode() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        let initiatorKey = try initiator.keyMaterial(from: fromResponder)
        let responderKey = try responder.keyMaterial(from: fromInitiator)

        XCTAssertEqual(initiatorKey, responderKey)
        XCTAssertEqual(initiatorKey.count, 64)
    }

    /// And the property that makes the attempt limit meaningful: a wrong code does not fail
    /// loudly, it silently produces a *different* key. That is why key confirmation (Task 4)
    /// exists at all — without it the Mac cannot tell these two cases apart.
    func testADifferentCodeYieldsADifferentKeyRatherThanAnError() throws {
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        let fromInitiator = try initiator.message(for: .mint())
        let fromResponder = try responder.message(for: .mint())

        let initiatorKey = try initiator.keyMaterial(from: fromResponder)
        let responderKey = try responder.keyMaterial(from: fromInitiator)

        XCTAssertNotEqual(initiatorKey, responderKey)
    }

    /// The names are bound into the exchange precisely so one code cannot be replayed against
    /// a different device — BoringSSL's header calls this context confusion.
    func testMismatchedNamesYieldDifferentKeys() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(
            role: .responder, myName: Data("carol".utf8), theirName: alice
        )

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        XCTAssertNotEqual(
            try initiator.keyMaterial(from: fromResponder),
            try responder.keyMaterial(from: fromInitiator)
        )
    }

    func testAMessageIsThirtyTwoBytes() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertEqual(try session.message(for: .mint()).count, 32)
    }

    /// BoringSSL documents one `generate_msg` per context and a context that is finished after
    /// `process_msg`. Enforce both in Swift rather than letting a misuse reach C, where the
    /// documented behaviour is an error return that is easy to drop.
    func testAContextRefusesToBeReused() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.message(for: .mint()))
    }

    func testKeyMaterialBeforeAMessageIsRefused() {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertThrowsError(try session.keyMaterial(from: Data(repeating: 0, count: 32)))
    }

    func testAMalformedPeerMessageIsAnErrorNotACrash() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.keyMaterial(from: Data([0x00])))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SPAKE2Session' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/SPAKE2/SPAKE2Session.swift`:

```swift
import Foundation

public enum SPAKE2Role: Sendable {
    /// The phone. Arbitrary but fixed: SPAKE2 is asymmetric and the two ends must disagree
    /// about which they are, so this mapping is part of the protocol and cannot be flipped
    /// on one side alone.
    case initiator
    /// The Mac.
    case responder
}

public enum SPAKE2Error: Error, Equatable {
    case contextUnavailable
    case generateFailed
    case processFailed
    case wrongOrder
}

/// One run of SPAKE2, wrapping BoringSSL.
///
/// A session is single-use in the C library — one `generate_msg`, then one `process_msg`, then
/// the context may only be freed — and this type enforces that in Swift rather than relying on
/// callers to read the header. A retry needs a new session.
///
/// **This produces keying material and nothing else.** BoringSSL performs no key confirmation,
/// and a wrong password does not fail here: it silently yields a different key. Distinguishing
/// "right code" from "wrong code" is `PairingSecrets`' job (Task 4), and until that confirmation
/// runs, nothing derived from this material may be trusted or acted on.
public final class SPAKE2Session {
    private var context: OpaquePointer?
    private var hasGenerated = false
    private var hasProcessed = false

    public init(role: SPAKE2Role, myName: Data, theirName: Data) {
        let cRole = role == .initiator ? spake2_role_alice : spake2_role_bob
        context = myName.withUnsafeBytes { mine in
            theirName.withUnsafeBytes { theirs in
                SPAKE2_CTX_new(
                    cRole,
                    mine.baseAddress?.assumingMemoryBound(to: UInt8.self), mine.count,
                    theirs.baseAddress?.assumingMemoryBound(to: UInt8.self), theirs.count
                )
            }
        }
    }

    deinit {
        if let context { SPAKE2_CTX_free(context) }
    }

    public func message(for code: PairingCode) throws -> Data {
        guard let context else { throw SPAKE2Error.contextUnavailable }
        guard !hasGenerated else { throw SPAKE2Error.wrongOrder }

        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_MSG_SIZE))
        var outLength = 0
        let ok = code.secret.withUnsafeBytes { password in
            SPAKE2_generate_msg(
                context, &out, &outLength, out.count,
                password.baseAddress?.assumingMemoryBound(to: UInt8.self), password.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.generateFailed }
        hasGenerated = true
        return Data(out[..<outLength])
    }

    public func keyMaterial(from peerMessage: Data) throws -> Data {
        guard let context else { throw SPAKE2Error.contextUnavailable }
        guard hasGenerated, !hasProcessed else { throw SPAKE2Error.wrongOrder }

        // Sized from SPAKE2_MAX_KEY_SIZE, not from what we intend to use. `process_msg`
        // truncates silently into a short buffer, so a smaller number here would not fail —
        // it would quietly produce less key material than both sides expect.
        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_KEY_SIZE))
        var outLength = 0
        let ok = peerMessage.withUnsafeBytes { message in
            SPAKE2_process_msg(
                context, &out, &outLength, out.count,
                message.baseAddress?.assumingMemoryBound(to: UInt8.self), message.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.processFailed }
        hasProcessed = true
        return Data(out[..<outLength])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. 1132 tests, 0 failures (1125 + 7).

- [ ] **Step 5: Add the BoringSSL vectors**

Open `crypto/curve25519/spake2_test.cc` in the BoringSSL source Task 1 cloned. Add one test to `SPAKE2SessionTests.swift` that drives a known vector through `SPAKE2Session` and asserts the documented key material, citing the file and line. A round-trip test proves the two ends agree with each other; only a vector proves they agree with the specification, and an implementation wrong in the same way on both sides passes the former.

If the vectors are not in a form this wrapper can drive (they may fix the ephemeral scalars, which the public API does not expose), say so in the report and add a test asserting interoperation against a second independent `SPAKE2Session` pair with fixed names instead — and record the gap in `docs/FOLLOWUPS.md` rather than leaving it implied.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/SPAKE2/SPAKE2Session.swift Tests/FlightDeckTests/SPAKE2SessionTests.swift
git commit -m "feat: wrap BoringSSL's SPAKE2 in a single-use Swift session"
```

---

### Task 4: `PairingSecrets` — confirmation and sealing

The step BoringSSL leaves to us, and the one that makes a wrong code detectable.

**Files:**
- Create: `Sources/FleetKit/SPAKE2/PairingSecrets.swift`
- Test: `Tests/FlightDeckTests/PairingSecretsTests.swift`

**Interfaces:**
- Consumes: `SPAKE2Session.keyMaterial(from:)` (Task 3), `FleetDeviceKey` (existing, `Sources/FleetKit/FleetTLS.swift`).
- Produces:
  - `public struct PairingSecrets`
  - `public init(keyMaterial: Data, transcript: Data)`
  - `public var initiatorConfirmation: Data` / `public var responderConfirmation: Data` — 32 bytes each
  - `public func seal(_ key: FleetDeviceKey, slot: UUID, macName: String) throws -> Data`
  - `public func open(_ sealed: Data) throws -> (key: FleetDeviceKey, macName: String)`
  - `public enum PairingSealError: Error { case sealFailed, openFailed }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingSecretsTests.swift`:

```swift
import XCTest
import FleetKit

final class PairingSecretsTests: XCTestCase {
    private func agreeing() throws -> (PairingSecrets, PairingSecrets) {
        let code = PairingCode.mint()
        let phone = SPAKE2Session(role: .initiator, myName: Data("phone".utf8),
                                  theirName: Data("mac".utf8))
        let mac = SPAKE2Session(role: .responder, myName: Data("mac".utf8),
                                theirName: Data("phone".utf8))
        let fromPhone = try phone.message(for: code)
        let fromMac = try mac.message(for: code)
        let transcript = fromPhone + fromMac
        return (
            PairingSecrets(keyMaterial: try phone.keyMaterial(from: fromMac), transcript: transcript),
            PairingSecrets(keyMaterial: try mac.keyMaterial(from: fromPhone), transcript: transcript)
        )
    }

    /// The point of the whole task: with the same code, each side can prove to the other that
    /// it holds the same key material, and the proofs differ by direction so one cannot be
    /// replayed back at its sender.
    func testConfirmationsMatchAcrossSidesAndDifferByDirection() throws {
        let (phone, mac) = try agreeing()
        XCTAssertEqual(phone.initiatorConfirmation, mac.initiatorConfirmation)
        XCTAssertEqual(phone.responderConfirmation, mac.responderConfirmation)
        XCTAssertNotEqual(phone.initiatorConfirmation, phone.responderConfirmation)
        XCTAssertEqual(phone.initiatorConfirmation.count, 32)
    }

    /// This is what the Mac's three-attempt budget actually counts. A wrong code produces
    /// different key material (proved in Task 3) and therefore a confirmation that does not
    /// match — which is the only signal distinguishing a typo from an attack.
    func testAWrongCodeProducesANonMatchingConfirmation() throws {
        let phone = SPAKE2Session(role: .initiator, myName: Data("phone".utf8),
                                  theirName: Data("mac".utf8))
        let mac = SPAKE2Session(role: .responder, myName: Data("mac".utf8),
                                theirName: Data("phone".utf8))
        let fromPhone = try phone.message(for: .mint())
        let fromMac = try mac.message(for: .mint())
        let transcript = fromPhone + fromMac

        let phoneSecrets = PairingSecrets(
            keyMaterial: try phone.keyMaterial(from: fromMac), transcript: transcript)
        let macSecrets = PairingSecrets(
            keyMaterial: try mac.keyMaterial(from: fromPhone), transcript: transcript)

        XCTAssertNotEqual(phoneSecrets.initiatorConfirmation, macSecrets.initiatorConfirmation)
    }

    /// Two runs with the same code must not produce the same confirmations, or a captured
    /// proof could be replayed into a later window.
    func testConfirmationsAreBoundToTheTranscript() throws {
        let material = Data(repeating: 0xAB, count: 64)
        let first = PairingSecrets(keyMaterial: material, transcript: Data([0x01]))
        let second = PairingSecrets(keyMaterial: material, transcript: Data([0x02]))
        XCTAssertNotEqual(first.initiatorConfirmation, second.initiatorConfirmation)
    }

    func testTheDeviceKeyRoundTripsThroughSealing() throws {
        let (phone, mac) = try agreeing()
        let key = FleetDeviceKey.mint()
        let slot = UUID()
        let sealed = try mac.seal(key, slot: slot, macName: "Nate's MacBook Pro")
        let opened = try phone.open(sealed)
        XCTAssertEqual(opened.key, key)
        XCTAssertEqual(opened.macName, "Nate's MacBook Pro")
    }

    /// The sealed key is the one genuinely secret thing crossing the pairing channel, and that
    /// channel offers no confidentiality of its own — its PSK is public. So this must fail for
    /// anyone who did not complete the exchange.
    func testSealedMaterialIsUselessWithoutTheSharedKey() throws {
        let (_, mac) = try agreeing()
        let (stranger, _) = try agreeing()
        let sealed = try mac.seal(FleetDeviceKey.mint(), slot: UUID(), macName: "m")
        XCTAssertThrowsError(try stranger.open(sealed))
    }

    func testATamperedSealIsRejected() throws {
        let (phone, mac) = try agreeing()
        var sealed = try mac.seal(FleetDeviceKey.mint(), slot: UUID(), macName: "m")
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try phone.open(sealed))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PairingSecrets' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/SPAKE2/PairingSecrets.swift`:

```swift
import CryptoKit
import Foundation

public enum PairingSealError: Error, Equatable {
    case sealFailed
    case openFailed
}

/// Everything derived from a completed SPAKE2 exchange: the two confirmation values, and the
/// key that seals the real device key on its way to the phone.
///
/// This exists because BoringSSL's SPAKE2 does not confirm keys. Its header is explicit that a
/// wrong password yields a *different* key rather than an error, so without an explicit
/// confirmation step the Mac has no way to distinguish a typo from a correct pairing — and the
/// three-attempt budget would have nothing to count.
///
/// Every value is bound to the transcript (both SPAKE2 messages, in a fixed order) so a proof
/// captured from one window cannot be replayed into another.
public struct PairingSecrets {
    private let confirmationKey: SymmetricKey
    private let sealingKey: SymmetricKey
    private let transcript: Data

    public init(keyMaterial: Data, transcript: Data) {
        let base = SymmetricKey(data: keyMaterial)
        self.transcript = transcript
        // Separate subkeys for separate jobs. Reusing one key for both confirmation and
        // encryption would mean a confirmation value — which is sent in the clear, by design —
        // is derived from the same secret that protects the device key.
        self.confirmationKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base, salt: transcript,
            info: Data("flightdeck-pairing-confirm".utf8), outputByteCount: 32
        )
        self.sealingKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base, salt: transcript,
            info: Data("flightdeck-pairing-seal".utf8), outputByteCount: 32
        )
    }

    /// The phone proves itself with this; the Mac checks it before spending an attempt.
    public var initiatorConfirmation: Data { confirmation(for: "initiator") }
    /// The Mac proves itself with this, so a phone cannot be walked through a pairing by
    /// something that never knew the code.
    public var responderConfirmation: Data { confirmation(for: "responder") }

    private func confirmation(for role: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(role.utf8) + transcript, using: confirmationKey
        ))
    }

    public func seal(_ key: FleetDeviceKey, slot: UUID, macName: String) throws -> Data {
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: slot.uuid) { Data($0) })
        payload.append(key.secret)
        payload.append(Data(macName.utf8))
        guard let sealed = try? AES.GCM.seal(payload, using: sealingKey).combined else {
            throw PairingSealError.sealFailed
        }
        return sealed
    }

    public func open(_ sealed: Data) throws -> (key: FleetDeviceKey, macName: String) {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let payload = try? AES.GCM.open(box, using: sealingKey),
              payload.count >= 48,
              let macName = String(data: payload[48...], encoding: .utf8)
        else { throw PairingSealError.openFailed }

        let slotBytes = [UInt8](payload[..<16])
        let slot = UUID(uuid: (
            slotBytes[0], slotBytes[1], slotBytes[2], slotBytes[3],
            slotBytes[4], slotBytes[5], slotBytes[6], slotBytes[7],
            slotBytes[8], slotBytes[9], slotBytes[10], slotBytes[11],
            slotBytes[12], slotBytes[13], slotBytes[14], slotBytes[15]
        ))
        return (FleetDeviceKey(slot: slot, secret: payload[16..<48]), macName)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. 1138 tests, 0 failures (1132 + 6).

- [ ] **Step 5: Verify the iOS slice**

Run: `./scripts/build-ios.sh 2>&1 | tail -3`
Expected: `FleetKitiOS ** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/SPAKE2/PairingSecrets.swift Tests/FlightDeckTests/PairingSecretsTests.swift
git commit -m "feat: confirm the pairing key and seal the device key under it"
```

---

### Task 5: Document the foundation

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/FOLLOWUPS.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Extend `docs/ARCHITECTURE.md`**

Add to the fleet section, in the house voice — explain *why*, name the failure avoided:

- That `FleetKit` now links a vendored BoringSSL, what it is for, and the one-function reason a dependency this size is carried.
- That SPAKE2 produces keying material and no confirmation, so `PairingSecrets` exists, and that until confirmation runs nothing derived from the exchange may be trusted.
- That the pairing code's 55 bits are not the security boundary — the attempt limit is, and SPAKE2 is what removes the offline path.

- [ ] **Step 2: Add to `docs/FOLLOWUPS.md`**

A dated section recording:

- **BoringSSL is pinned to a tag and updated by hand.** `scripts/build-boringssl.sh` takes `BORINGSSL_TAG`; nothing watches upstream for security fixes. Say plainly that this is a standing obligation, not an automated one.
- **The xcframework is a large committed binary**, and why that was chosen over extracting the few source files: no fork to maintain, at the cost of size.
- Whatever the Task 3 test-vector step found — in particular, if BoringSSL's own vectors could not be driven through the public API, that gap is recorded here rather than left implied.

- [ ] **Step 3: Update `AGENTS.md`**

Add `scripts/build-boringssl.sh` to the Commands table with its one-line reason, and note that `vendor/boringssl-artifacts/` is a committed build product that is not rebuilt by the normal build scripts.

- [ ] **Step 4: Final verification**

Run: `./scripts/test-unit.sh` → 1138 tests, 0 failures.
Run: `./scripts/build.sh` → `** BUILD SUCCEEDED **`.
Run: `./scripts/build-ios.sh` → both iOS targets build.

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md docs/FOLLOWUPS.md AGENTS.md
git commit -m "docs: describe the pairing crypto foundation and what it obliges us to"
```

---

## Done when

- `PairingCode.mint()` produces a 12-symbol code that round-trips through its own formatting, survives being lowercased and de-hyphenated, and rejects better than 90% of single-character typos locally.
- Two `SPAKE2Session`s with the same code derive identical key material; with different codes they derive different material and no error.
- `PairingSecrets` produces matching confirmations across the two sides, different ones by direction, transcript-bound, and seals a `FleetDeviceKey` that only the peer can open.
- `./scripts/test-unit.sh` passes at 1138, `./scripts/build.sh` succeeds, and both iOS targets build.
- Nothing in this plan opens a socket or draws a screen.

## Not in this plan

- **The pairing listener, the PAKE frames, the packed QR, and both UIs.** That is Plan B, written against these interfaces once they exist.
- **Rate limiting.** The three-attempt budget belongs with the listener that counts attempts, not with the types that make an attempt distinguishable.
- **Retiring the long code.** The current `PairingPayload` is untouched here and keeps working.
