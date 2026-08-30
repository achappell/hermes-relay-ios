import Foundation

protocol HermesSessionClient: Sendable {
    func connect() async throws -> SessionMetadata
    func sendTurn(text: String) -> AsyncThrowingStream<HermesEvent, Error>
    func disconnect() async
}

struct RelayUnavailableError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "The Hermes relay client is not wired yet."
    }
}

/// Safe foundation behavior until the WebSocket transport is implemented.
struct UnavailableHermesSessionClient: HermesSessionClient {
    func connect() async throws -> SessionMetadata {
        throw RelayUnavailableError()
    }

    func sendTurn(text: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RelayUnavailableError())
        }
    }

    func disconnect() async {}
}
