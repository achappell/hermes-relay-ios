import Foundation

enum WebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

protocol WebSocketConnection: Sendable {
    func send(text: String) async throws
    func receive() async throws -> WebSocketFrame
    func close() async
}

protocol WebSocketConnectionFactory: Sendable {
    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection
}

struct URLSessionWebSocketConnectionFactory: WebSocketConnectionFactory {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: urlRequest)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

private final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSocketFrame, Error>) in
            task.receive { result in
                switch result {
                case .success(.string(let text)):
                    continuation.resume(returning: .text(text))
                case .success(.data(let data)):
                    continuation.resume(returning: .binary(data))
                case .failure(let error):
                    continuation.resume(throwing: error)
                @unknown default:
                    continuation.resume(throwing: RelaySessionError.unsupportedFrame)
                }
            }
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
