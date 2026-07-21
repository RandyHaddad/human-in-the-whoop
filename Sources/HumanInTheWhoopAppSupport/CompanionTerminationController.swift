import HumanInTheWhoopCore

public enum CompanionTerminationError: Error, Equatable, Sendable {
    case softOffNotConfirmed
}

/// Makes every supported companion quit a fail-safe Soft Off boundary.
///
/// This path is deliberately local and synchronous: it never contacts WHOOP,
/// preserves the paused Recovery and Charge ledger, and refuses to report
/// success until the durable feature flag has been reread as Off.
public struct CompanionTerminationController: Sendable {
    private let engine: ChargeEngine

    public init(engine: ChargeEngine) {
        self.engine = engine
    }

    public func prepareForTermination() throws {
        try engine.setEnabled(false)
        guard try !engine.currentState().enabled else {
            throw CompanionTerminationError.softOffNotConfirmed
        }
    }
}
