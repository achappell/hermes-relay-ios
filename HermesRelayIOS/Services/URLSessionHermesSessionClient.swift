import Foundation

enum RelaySessionError: LocalizedError, Equatable, Sendable {
    case helloAckMissing
    case notConnected
    case turnAlreadyActive
    case unexpectedBinaryFrame
    case unsupportedFrame
    case disconnected

    var errorDescription: String? {
        switch self {
        case .helloAckMissing:
            return "The Hermes relay did not acknowledge the session."
        case .notConnected:
            return "Connect to the Hermes relay before sending a turn."
        case .turnAlreadyActive:
            return "A Hermes turn is already active."
        case .unexpectedBinaryFrame:
            return "The Hermes relay sent audio before describing its format."
        case .unsupportedFrame:
            return "The Hermes relay sent an unsupported WebSocket frame."
        case .disconnected:
            return "The Hermes relay connection was closed."
        }
    }
}

actor URLSessionHermesSessionClient: HermesSessionClient {
    private let profile: RelayProfile
    private let token: String
    private let socketFactory: any WebSocketConnectionFactory

    private var socket: (any WebSocketConnection)?
    private var readerTask: Task<Void, Never>?
    private var sessionID: String?
    private var activeTurnID: String?
    private var activeContinuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var audioStarted = false
    private var audioFileStarted = false
    private var normalizer = HermesEventNormalizer()

    init(profile: RelayProfile, token: String, socketFactory: any WebSocketConnectionFactory) {
        self.profile = profile
        self.token = token
        self.socketFactory = socketFactory
    }

    func connect() async throws -> SessionMetadata {
        if let sessionID, socket != nil {
            return SessionMetadata(sessionID: sessionID, model: nil)
        }

        var request = URLRequest(url: profile.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let connection = try await socketFactory.open(urlRequest: request)
        let newSessionID = UUID().uuidString

        do {
            try await connection.send(text: helloJSON(sessionID: newSessionID))
            let metadata = try await receiveHelloAck(from: connection, sessionID: newSessionID)

            socket = connection
            sessionID = newSessionID
            readerTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            return metadata
        } catch {
            await connection.close()
            throw error
        }
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream()

        guard let socket, let sessionID else {
            continuation.finish(throwing: RelaySessionError.notConnected)
            return stream
        }
        guard activeContinuation == nil else {
            continuation.finish(throwing: RelaySessionError.turnAlreadyActive)
            return stream
        }

        let turnID = UUID().uuidString
        activeTurnID = turnID
        activeContinuation = continuation
        audioStarted = false
        audioFileStarted = false
        normalizer = HermesEventNormalizer()
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.cancelLocalTurn(turnID: turnID)
            }
        }

        do {
            try await socket.send(text: turnJSON(turnID: turnID, sessionID: sessionID, text: text))
        } catch {
            finishActiveTurn(throwing: error)
        }
        return stream
    }

    func disconnect() async {
        let connection = socket
        socket = nil
        sessionID = nil
        readerTask?.cancel()
        readerTask = nil
        finishActiveTurn(throwing: RelaySessionError.disconnected)
        await connection?.close()
    }

    private func receiveHelloAck(
        from connection: any WebSocketConnection,
        sessionID: String
    ) async throws -> SessionMetadata {
        while true {
            let frame = try await connection.receive()
            guard case .text(let text) = frame else {
                throw RelaySessionError.helloAckMissing
            }
            guard let jsonObject = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let object = jsonObject as? [String: Any],
                  object["type"] as? String == "hello_ack"
            else {
                throw RelaySessionError.helloAckMissing
            }

            let payload = object["payload"] as? [String: Any] ?? object
            return SessionMetadata(
                sessionID: sessionID,
                model: payload["model"] as? String ?? object["model"] as? String
            )
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let socket else { return }

            do {
                let frame = try await socket.receive()
                switch frame {
                case .text(let text):
                    try handleTextFrame(text)
                case .binary(let data):
                    guard activeContinuation != nil, audioStarted || audioFileStarted else {
                        finishActiveTurn(throwing: RelaySessionError.unexpectedBinaryFrame)
                        return
                    }
                    activeContinuation?.yield(
                        normalizer.normalizeBinary(data, audioFileActive: audioFileStarted)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                finishActiveTurn(throwing: RelaySessionError.disconnected)
                return
            }
        }
    }

    private func handleTextFrame(_ text: String) throws {
        guard let turnID = activeTurnID else { return }
        let events = try normalizer.normalizeJSON(Data(text.utf8), turnID: turnID)
        for event in events {
            switch event {
            case .audioStart:
                audioFileStarted = false
                audioStarted = true
                activeContinuation?.yield(event)
            case .audioEnd:
                audioStarted = false
                activeContinuation?.yield(event)
            case .audioFileStart:
                audioStarted = false
                audioFileStarted = true
                activeContinuation?.yield(event)
            case .audioFileEnd:
                audioFileStarted = false
                activeContinuation?.yield(event)
            case .error:
                activeContinuation?.yield(event)
                finishActiveTurn()
                return
            case .turnComplete:
                activeContinuation?.yield(event)
                finishActiveTurn()
                return
            default:
                activeContinuation?.yield(event)
            }
        }
    }

    private func cancelLocalTurn(turnID: String) {
        guard activeTurnID == turnID else { return }
        finishActiveTurn(throwing: RelaySessionError.disconnected)
    }

    private func finishActiveTurn(throwing error: Error? = nil) {
        guard let continuation = activeContinuation else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        activeContinuation = nil
        activeTurnID = nil
        audioStarted = false
        audioFileStarted = false
    }

    private func helloJSON(sessionID: String) throws -> String {
        try jsonString([
            "type": "hello",
            "protocol_version": 1,
            "client_id": profile.clientID,
            "device_id": profile.deviceID,
            "session_id": sessionID,
            "display_name": profile.displayName,
        ])
    }

    private func turnJSON(turnID: String, sessionID: String, text: String) throws -> String {
        try jsonString([
            "type": "turn",
            "protocol_version": 1,
            "turn_id": turnID,
            "session_id": sessionID,
            "text": text,
            "stt_source": "local",
        ])
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
