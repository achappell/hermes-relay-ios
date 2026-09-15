import Foundation

protocol HermesSessionClient: Sendable {
    func connect() async throws -> SessionMetadata
    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error>
    /// Request the active turn be interrupted. A true result means Hermes
    /// confirmed the interruption; false means the endpoint has no usable
    /// interrupt contract and the caller should use its legacy fallback.
    func interruptActiveTurn() async -> Bool
    /// Typed interruption projection used by the Home seam. The Boolean
    /// requirement remains source-compatible with the original legacy client
    /// and injected fakes.
    func interruptActiveTurnOutcome() async -> HermesInterruptOutcome
    func disconnect() async
}

extension HermesSessionClient {
    func interruptActiveTurn() async -> Bool { false }

    func interruptActiveTurnOutcome() async -> HermesInterruptOutcome {
        await interruptActiveTurn() ? .confirmed : .unavailable
    }
}

enum HermesInterruptOutcome: Equatable, Sendable {
    case confirmed
    case rejected
    case unavailable
    case uncertain
}

struct RelayUnavailableError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "Configure a Hermes relay before connecting."
    }
}

/// Explicit fallback for previews and stores without a configured relay.
struct UnavailableHermesSessionClient: HermesSessionClient {
    func connect() async throws -> SessionMetadata {
        throw RelayUnavailableError()
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RelayUnavailableError())
        }
    }

    func disconnect() async {}

    func interruptActiveTurnOutcome() async -> HermesInterruptOutcome { .unavailable }
}
