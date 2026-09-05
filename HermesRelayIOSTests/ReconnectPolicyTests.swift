import XCTest
@testable import HermesRelayIOS

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultPolicyBacksOffExponentiallyForFiveAttempts() {
        let policy = ReconnectPolicy.default

        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(
            (1...5).map { policy.delayNanoseconds(forAttempt: $0) },
            [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
        )
    }

    func testPolicyExhaustsAfterTheFinalAttempt() {
        let policy = ReconnectPolicy.default

        XCTAssertNil(policy.delayNanoseconds(forAttempt: 6))
        XCTAssertNil(policy.delayNanoseconds(forAttempt: 99))
    }

    func testPolicyRejectsNonPositiveAttemptNumbers() {
        let policy = ReconnectPolicy.default

        XCTAssertNil(policy.delayNanoseconds(forAttempt: 0))
        XCTAssertNil(policy.delayNanoseconds(forAttempt: -1))
    }
}
