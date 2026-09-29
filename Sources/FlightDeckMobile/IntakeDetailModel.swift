import FleetKit
import Foundation

@MainActor
protocol IntakeFetching: AnyObject {
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void)
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void)
}

/// One open intake's content, refreshed by the screen's 1.5 s loop (spec §6.2). A `nil` reply
/// means "unchanged since my etag"; a disconnect keeps what is on screen (it goes stale, it does
/// not go blank); `unknown_intake` means the Mac no longer has it (spec §9).
@MainActor
@Observable
final class IntakeDetailModel {
    let id: UUID
    private(set) var detail: WireIntakeDetail?
    private(set) var failure: String?
    private(set) var gone = false
    /// Mac clock − phone clock, from the last detail's `servedAt` (Review Focus #1).
    private(set) var macClockOffset: TimeInterval = 0
    @ObservationIgnored private weak var fetcher: IntakeFetching?
    @ObservationIgnored private let receivedAt: () -> Date
    @ObservationIgnored private var inFlight = false
    /// Told each fresh offset, so the Sessions list's clocks share it (`FlightControlModel`).
    @ObservationIgnored private let onOffset: ((TimeInterval) -> Void)?

    init(id: UUID, fetcher: IntakeFetching, receivedAt: @escaping () -> Date = Date.init,
         onOffset: ((TimeInterval) -> Void)? = nil) {
        self.id = id
        self.fetcher = fetcher
        self.receivedAt = receivedAt
        self.onOffset = onOffset
    }

    func refresh() {
        guard !inFlight, let fetcher else { return }
        inFlight = true
        fetcher.intakeDetail(id, ifNot: detail?.etag) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let fresh?):
                self.detail = fresh
                self.macClockOffset = fresh.servedAt.timeIntervalSince(self.receivedAt())
                self.onOffset?(self.macClockOffset)
                self.failure = nil
                self.gone = false
            case .success(nil):
                self.gone = false
            case .failure(.server(code: "unknown_intake")):
                self.gone = true
            case .failure(.disconnected):
                break
            case .failure(let error):
                self.failure = "\(error)"
            }
        }
    }
}
