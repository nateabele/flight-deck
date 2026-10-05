import Foundation
import IntakeKit

/// OpenCode has no meter (L3-U §3): a 429 `APIError` is the whole signal, and it puts the
/// account over hard until `retry-after`, or for the 15-minute backoff when there is none.
///
/// A real `UsageMeterSource`, so the OpenCode adapter (another workstream's branch) can return
/// it from `usageMeterSource(account:)` and `UsageService.consume(_:)` reads it like any other.
/// Until that branch merges, nothing calls `ingest` outside tests.
final class OpenCodeErrorUsageSource: UsageMeterSource, @unchecked Sendable {
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation

    init() { (readings, continuation) = AsyncStream.makeStream(of: UsageReading.self) }

    @discardableResult
    func ingest(_ event: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading? {
        guard let reading = OpenCodeRateLimit.reading(for: event, account: account) else { return nil }
        continuation.yield(reading)
        return reading
    }

    func finish() { continuation.finish() }
}
