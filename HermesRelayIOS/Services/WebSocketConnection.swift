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
        let connection = URLSessionWebSocketConnection(task: task)
        task.resume()
        return connection
    }
}

// Foundation's callback methods are not overridable. This small seam lets
// tests independently drive receive callbacks and native close notifications.
protocol WebSocketTask: AnyObject, Sendable {
    var delegate: (any URLSessionTaskDelegate)? { get set }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketTask {}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: any WebSocketTask
    private let receiveState = WebSocketReceiveState()

    init(task: any WebSocketTask) {
        self.task = task
        task.delegate = WebSocketCloseDelegate(receiveState: receiveState)
    }

    func send(text: String) async throws {
        try receiveState.checkOpen()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.send(.string(text)) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            self.receiveState.finish(throwing: RelaySessionError.disconnected)
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSocketFrame, Error>) in
            let id = UUID()
            guard receiveState.register(continuation, id: id) else { return }
            task.receive { [receiveState] result in
                switch result {
                case .success(.string(let text)):
                    receiveState.complete(id: id, frame: .text(text))
                case .success(.data(let data)):
                    receiveState.complete(id: id, frame: .binary(data))
                case .failure(let error):
                    receiveState.finish(throwing: error)
                @unknown default:
                    receiveState.finish(throwing: RelaySessionError.unsupportedFrame)
                }
            }
        }
    }

    func close() async {
        receiveState.finish(throwing: RelaySessionError.disconnected)
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Task delegates are retained by URLSession. Keep only the receive state
/// here, not the connection/task, to avoid a retain cycle.
private final class WebSocketCloseDelegate: NSObject, URLSessionWebSocketDelegate {
    let receiveState: WebSocketReceiveState

    init(receiveState: WebSocketReceiveState) {
        self.receiveState = receiveState
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Close reasons are server-controlled; never copy them into UI/logs.
        receiveState.finish(throwing: RelaySessionError.disconnected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        receiveState.finish(throwing: RelaySessionError.disconnected)
    }
}

/// A close notification and receive callback can arrive in either order.
/// Remove continuations under the lock and resume outside it, exactly once.
private final class WebSocketReceiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var terminalError: Error?
    private var pending: [UUID: CheckedContinuation<WebSocketFrame, Error>] = [:]

    func checkOpen() throws {
        if let error = lock.withLock({ terminalError }) { throw error }
    }

    func register(_ continuation: CheckedContinuation<WebSocketFrame, Error>, id: UUID) -> Bool {
        let error: Error? = lock.withLock {
            if let terminalError { return terminalError }
            pending[id] = continuation
            return nil
        }
        if let error {
            continuation.resume(throwing: error)
            return false
        }
        return true
    }

    func complete(id: UUID, frame: WebSocketFrame) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(returning: frame)
    }

    func finish(throwing error: Error) {
        let continuations = lock.withLock {
            if terminalError == nil { terminalError = error }
            let continuations = Array(pending.values)
            pending.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}
