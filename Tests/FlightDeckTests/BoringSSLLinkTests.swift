import XCTest
import BoringSSLShim
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
