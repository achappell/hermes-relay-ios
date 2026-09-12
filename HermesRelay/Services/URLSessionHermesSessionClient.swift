import Foundation
import Network

enum RelaySessionError: LocalizedError, Equatable, Sendable {
    case helloAckMissing
    case notConnected
    case turnAlreadyActive
    case unexpectedBinaryFrame
    case unsupportedFrame
    case connectionTimedOut
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
        case .connectionTimedOut:
            return "The Hermes relay connection timed out."
        case .disconnected:
            return "The Hermes relay connection was closed."
        }
    }
}

actor URLSessionHermesSessionClient: HermesSessionClient {
    private let profile: RelayProfile
    private let token: String
    private let socketFactory: any WebSocketConnectionFactory
    private let sendTimeoutNanoseconds: UInt64
    private let interruptionConfirmationTimeoutNanoseconds: UInt64
    private let onTransportDisconnected: (@MainActor @Sendable () -> Void)?

    private var socket: (any WebSocketConnection)?
    private var readerTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var transportGeneration = 0
    private var sessionID: String?
    private var sessionMetadata: SessionMetadata?
    private var activeTurnID: String?
    private var activeContinuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var capabilities: [String] = []
    private var interruptionRequestTurnID: String?
    private var interruptionContinuation: AsyncStream<Bool>.Continuation?
    private var interruptionTimeoutTask: Task<Void, Never>?
    private var audioStarted = false
    private var audioFileStarted = false
    private var turnCompletionPending = false
    private var discardBinaryUntilAudioStart = false
    private var normalizer = HermesEventNormalizer()

    init(
        profile: RelayProfile,
        token: String,
        socketFactory: any WebSocketConnectionFactory,
        sendTimeoutNanoseconds: UInt64 = 10_000_000_000,
        interruptionConfirmationTimeoutNanoseconds: UInt64 = 2_000_000_000,
        onTransportDisconnected: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.profile = profile
        self.token = token
        self.socketFactory = socketFactory
        self.sendTimeoutNanoseconds = sendTimeoutNanoseconds
        self.interruptionConfirmationTimeoutNanoseconds = interruptionConfirmationTimeoutNanoseconds
        self.onTransportDisconnected = onTransportDisconnected
    }

    func connect() async throws -> SessionMetadata {
        if let sessionID, socket != nil {
            return sessionMetadata ?? SessionMetadata(sessionID: sessionID, model: nil)
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
            sessionMetadata = metadata
            capabilities = metadata.capabilities
            transportGeneration += 1
            let generation = transportGeneration
            startPathMonitoring()
            readerTask = Task { [weak self] in
                await self?.receiveLoop(generation: generation)
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
        turnCompletionPending = false
        normalizer = HermesEventNormalizer()
        let generation = transportGeneration
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.cancelLocalTurn(turnID: turnID)
            }
        }

        do {
            let message = try turnJSON(turnID: turnID, sessionID: sessionID, text: text)
            try await send(message: message, on: socket)
        } catch {
            await failTransport(error, generation: generation)
        }
        return stream
    }

    /// Send one explicit interruption and wait for Hermes to confirm it. The
    /// active turn's stream remains owned by `receiveLoop`, so the confirmation
    /// can arrive without opening a second WebSocket reader.
    func interruptActiveTurn() async -> Bool {
        guard let socket,
              let sessionID,
              let turnID = activeTurnID,
              capabilities.contains("interrupt") else {
            return false
        }
        if interruptionRequestTurnID == turnID {
            return true
        }

        let (confirmationStream, continuation) = AsyncStream<Bool>.makeStream()
        interruptionRequestTurnID = turnID
        interruptionContinuation = continuation
        let timeout = interruptionConfirmationTimeoutNanoseconds
        interruptionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            await self?.resolveInterruption(confirmed: false)
        }

        do {
            try await send(
                message: interruptJSON(turnID: turnID, sessionID: sessionID),
                on: socket
            )
        } catch {
            resolveInterruption(confirmed: false)
            return false
        }

        return await confirmationStream.first(where: { _ in true }) ?? false
    }

    func disconnect() async {
        let connection = socket
        markTransportDisconnected()
        stopPathMonitoring()
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

            let payload = object["payload"] as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? object["model"] as? String
            let payloadCapabilities = stringArrayValue(for: "capabilities", in: payload)
            let rootCapabilities = stringArrayValue(for: "capabilities", in: object)
                .filter { !payloadCapabilities.contains($0) }
            return SessionMetadata(
                sessionID: sessionID,
                model: model,
                capabilities: payloadCapabilities + rootCapabilities
            )
        }
    }

    private func receiveLoop(generation: Int) async {
        while !Task.isCancelled {
            guard generation == transportGeneration, let socket else { return }

            do {
                let frame = try await socket.receive()
                guard generation == transportGeneration, !Task.isCancelled else { return }
                switch frame {
                case .text(let text):
                    try handleTextFrame(text)
                case .binary(let data):
                    guard activeContinuation != nil else {
                        // A remote interruption can leave one already-buffered
                        // binary frame behind the terminal event. It belongs to
                        // the stale turn and must not resurrect the transport.
                        continue
                    }
                    guard audioStarted || audioFileStarted else {
                        if discardBinaryUntilAudioStart {
                            // A terminal interruption can leave one binary
                            // frame buffered behind its confirmation. Drop it
                            // until the next turn describes a fresh stream.
                            continue
                        }
                        await failTransport(RelaySessionError.unexpectedBinaryFrame, generation: generation)
                        return
                    }
                    activeContinuation?.yield(
                        normalizer.normalizeBinary(data, audioFileActive: audioFileStarted)
                    )
                }
            } catch is CancellationError {
                // A transport may report cancellation without this reader
                // having been cancelled by our own teardown.
                if !Task.isCancelled {
                    await failTransport(RelaySessionError.disconnected, generation: generation)
                }
                return
            } catch let error as HermesEventNormalizationError {
                await failTransport(error, generation: generation)
                return
            } catch {
                await failTransport(RelaySessionError.disconnected, generation: generation)
                return
            }
        }
    }

    private func handleTextFrame(_ text: String) throws {
        guard let turnID = activeTurnID else { return }
        let data = Data(text.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let frameTurnID = turnIdentifier(in: object),
           frameTurnID != turnID {
            return
        }

        let events = try normalizer.normalizeJSON(data, turnID: turnID)
        for event in events {
            switch event {
            case .audioStart:
                audioFileStarted = false
                audioStarted = true
                discardBinaryUntilAudioStart = false
                activeContinuation?.yield(event)
            case .audioEnd:
                audioStarted = false
                activeContinuation?.yield(event)
            case .audioFileStart:
                audioStarted = false
                audioFileStarted = true
                discardBinaryUntilAudioStart = false
                activeContinuation?.yield(event)
            case .audioFileEnd:
                audioFileStarted = false
                activeContinuation?.yield(event)
                if turnCompletionPending {
                    turnCompletionPending = false
                    finishActiveTurn()
                    return
                }
            case .audioAbort:
                audioStarted = false
                audioFileStarted = false
                discardBinaryUntilAudioStart = true
                activeContinuation?.yield(event)
            case .turnInterrupted:
                activeContinuation?.yield(event)
                resolveInterruption(confirmed: true)
                finishActiveTurn()
                discardBinaryUntilAudioStart = true
                return
            case .error:
                activeContinuation?.yield(event)
                finishActiveTurn()
                return
            case .turnComplete:
                activeContinuation?.yield(event)
                if audioFileStarted {
                    // File-backed audio may be delivered after the terminal
                    // turn event. Keep the stream open until its bytes have
                    // reached the coordinator.
                    turnCompletionPending = true
                } else {
                    finishActiveTurn()
                }
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

    private func send(message: String, on socket: any WebSocketConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.send(text: message)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.sendTimeoutNanoseconds)
                throw RelaySessionError.connectionTimedOut
            }

            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func failTransport(_ error: Error, generation: Int? = nil) async {
        if let generation, generation != transportGeneration {
            return
        }
        let connection = socket
        markTransportDisconnected()
        stopPathMonitoring()
        readerTask?.cancel()
        readerTask = nil
        finishActiveTurn(throwing: error)
        if connection != nil {
            await onTransportDisconnected?()
        }
        await connection?.close()
    }

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .unsatisfied else { return }
            Task { [weak self] in
                await self?.networkBecameUnavailable()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "HermesRelayIOS.network-path"))
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func networkBecameUnavailable() async {
        guard socket != nil else { return }
        await failTransport(RelaySessionError.disconnected)
    }

    private func markTransportDisconnected() {
        transportGeneration += 1
        socket = nil
        sessionID = nil
        sessionMetadata = nil
        capabilities = []
        resolveInterruption(confirmed: false)
        audioStarted = false
        audioFileStarted = false
        turnCompletionPending = false
        discardBinaryUntilAudioStart = false
    }

    private func finishActiveTurn(throwing error: Error? = nil) {
        guard let continuation = activeContinuation else { return }
        resolveInterruption(confirmed: false)
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        activeContinuation = nil
        activeTurnID = nil
        audioStarted = false
        audioFileStarted = false
        turnCompletionPending = false
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

    private func interruptJSON(turnID: String, sessionID: String) throws -> String {
        try jsonString([
            "type": "interrupt",
            "protocol_version": 1,
            "turn_id": turnID,
            "session_id": sessionID,
        ])
    }

    private func turnIdentifier(in object: [String: Any]) -> String? {
        let payload = object["payload"] as? [String: Any]
        return payload?["turn_id"] as? String ?? object["turn_id"] as? String
    }

    private func stringArrayValue(for key: String, in object: [String: Any]) -> [String] {
        let rawValues = object[key] as? [Any] ?? []
        var values: [String] = []
        for rawValue in rawValues {
            guard let value = rawValue as? String else { continue }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !values.contains(normalized) else { continue }
            values.append(normalized)
        }
        return values
    }

    private func resolveInterruption(confirmed: Bool) {
        guard interruptionRequestTurnID != nil else { return }
        interruptionTimeoutTask?.cancel()
        interruptionTimeoutTask = nil
        interruptionRequestTurnID = nil
        let continuation = interruptionContinuation
        interruptionContinuation = nil
        continuation?.yield(confirmed)
        continuation?.finish()
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
