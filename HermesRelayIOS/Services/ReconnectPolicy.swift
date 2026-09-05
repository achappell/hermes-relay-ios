import Foundation

/// Bounded exponential backoff for recovering an unexpectedly lost relay
/// transport. The policy is pure: it decides *when* the next attempt may run
/// and when the budget is spent, and leaves the sleeping to its caller so the
/// schedule stays testable without waiting in real time.
struct ReconnectPolicy: Equatable, Sendable {
    /// Delay before each attempt, in nanoseconds, indexed by attempt order.
    let delaysNanoseconds: [UInt64]

    static let `default` = ReconnectPolicy(
        delaysNanoseconds: [
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
        ]
    )

    var maxAttempts: Int {
        delaysNanoseconds.count
    }

    /// Delay preceding the given 1-based attempt, or `nil` once the budget is
    /// exhausted.
    func delayNanoseconds(forAttempt attempt: Int) -> UInt64? {
        guard attempt >= 1, attempt <= delaysNanoseconds.count else { return nil }
        return delaysNanoseconds[attempt - 1]
    }
}
