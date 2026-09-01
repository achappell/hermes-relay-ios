import Foundation

protocol HermesSessionClient: Sendable {
    func connect() async throws -> SessionMetadata
    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error>
    func disconnect() async
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
}
