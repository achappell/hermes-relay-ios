import Foundation

/// Errors crossing the direct transport boundary never contain a URL, server
/// message, prompt, token, close reason, or underlying Foundation error.
enum StandardSessionError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint, missingToken, connectionFailed, disconnected
    case requestTimedOut, invalidResponse, requestRejected, resumeFailed
    case turnAlreadyActive, deliveryUncertain, unsupportedInteraction
    case operationInProgress, turnFailed, conversationReplaced
    case unsupportedBaseline

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Standard requires a secure wss endpoint ending in /api/ws, without embedded credentials or a fragment."
        case .missingToken:
            return "Add a Standard token before connecting."
        case .connectionFailed:
            return "Could not connect or authenticate to Standard. Check this connection's endpoint and token."
        case .disconnected:
            return "The Standard connection closed. The last prompt was not resent."
        case .requestTimedOut:
            return "Standard did not respond in time. The last prompt was not resent."
        case .invalidResponse:
            return "Standard sent an invalid response. The last prompt was not resent."
        case .unsupportedBaseline:
            return "This Standard server does not provide the supported native session interface."
        case .requestRejected:
            return "Standard rejected the request. The prompt was not resent."
        case .resumeFailed:
            return "The earlier Standard conversation could not be resumed. The last prompt was not resent. Start a new conversation deliberately or leave this conversation."
        case .turnAlreadyActive:
            return "Hermes is finishing the previous response. Wait, start a new conversation, or leave this conversation."
        case .deliveryUncertain:
            return "The previous Standard turn is unconfirmed. Start a new conversation or leave this conversation; it will not be resent."
        case .unsupportedInteraction:
            return "This response requires a choice or protected input, which text-only Standard does not support. Nothing was approved. Start a new conversation or leave this conversation."
        case .operationInProgress:
            return "A Standard connection operation is already in progress."
        case .turnFailed:
            return "Standard could not complete the response. The prompt was not resent."
        case .conversationReplaced:
            return "A new Standard conversation was started."
        }
    }
}

/// Native hermes_cli serve /api/ws JSON-RPC, not the REST API or fork relay.
/// One reader owns every response and event, including those preceding an RPC
/// acknowledgement. A reconnect only resumes a known durable conversation.
actor StandardSessionClient: StandardConversationSessionClient {
    private typealias Continuation = AsyncThrowingStream<HermesEvent, Error>.Continuation

    private struct PendingRequest {
        let continuation: CheckedContinuation<StandardJSON, Error>
        let timer: Task<Void, Never>
        let sender: Task<Void, Never>
        let expectsReply: Bool
    }

    private struct PendingOpen {
        let id: UUID
        let continuation: CheckedContinuation<any WebSocketConnection, Error>
        let timer: Task<Void, Never>
        let opener: Task<Void, Never>
    }

    private struct Turn {
        let id: String
        let requestID: String
        let sessionID: String
        var continuation: Continuation?
        var remoteID: String?
        var admissionID: String?
        var executionGeneration: Int?
        var bufferedEvents: [StandardJSON] = []
        var lastSequence: Int?
        var normalizer = HermesEventNormalizer()
    }

    private let profile: RelayProfile
    private let token: String
    private let connectionFactory: any WebSocketConnectionFactory
    private let requestTimeoutNanoseconds: UInt64
    private let onTransportDisconnected: (@MainActor @Sendable () -> Void)?
    private var socket: (any WebSocketConnection)?
    private var opening: PendingOpen?
    private var reader: Task<Void, Never>?
    private var requests: [String: PendingRequest] = [:]
    private var generation: UInt64 = 0
    private var operationInProgress = false
    private var metadata: SessionMetadata?
    private var runtimeSessionID: String?
    private var storedSessionID: String?
    private var turn: Turn?
    private var segmentOffsets: [Int: Int] = [:]
    private var uncertain = false
    private var authorityReady = false
    private var authorityEpoch: Int?
    private var replayEpoch: String?
    private var lastSequence: Int?
    private var interruptTurnID: String?
    private var interruptRequestID: String?
    private var interruptWaiters: [UUID: CheckedContinuation<HermesInterruptOutcome, Never>] = [:]
    private var interruptTimer: Task<Void, Never>?

    init(
        profile: RelayProfile,
        token: String,
        connectionFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory(),
        storedSessionID: String? = nil,
        requestTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onTransportDisconnected: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.profile = profile
        self.token = token
        self.connectionFactory = connectionFactory
        self.storedSessionID = storedSessionID?.isEmpty == false ? storedSessionID : nil
        self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
        self.onTransportDisconnected = onTransportDisconnected
    }

    /// Authenticated, noncreating setup probe. The upstream liveness method is
    /// `gateway.ping`; gateway.ready is an unsolicited notification.
    func checkConnection() async throws {
        guard !operationInProgress, metadata == nil, turn == nil else {
            throw StandardSessionError.operationInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            try await ensureTransport()
            guard authorityReady else { throw StandardSessionError.unsupportedBaseline }
            await closeTransport(error: .disconnected, notify: false)
        } catch {
            await closeTransport(error: safeError(error), notify: false)
            throw safeError(error)
        }
    }

    func connect() async throws -> SessionMetadata {
        if socket != nil, let metadata { return metadata }
        return try await openConversation(create: false)
    }

    func createNewConversation() async throws -> SessionMetadata {
        try await openConversation(create: true)
    }

    private func openConversation(create: Bool) async throws -> SessionMetadata {
        guard !operationInProgress else { throw StandardSessionError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }
        let durable = create ? nil : storedSessionID
        do {
            try await ensureTransport()
            let attempt = generation
            var params: [String: StandardJSON] = [
                "profile": .string(profile.standardProfile?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"),
            ]
            if let durable {
                params["session_id"] = .string(durable)
                params["omit_messages"] = .bool(true)
            }
            let result = try await request(method: durable == nil ? "session.create" : "session.resume", params: params)
            try Task.checkCancellation()
            guard attempt == generation, socket != nil,
                  let runtime = result["session_id"].string?.nonEmpty,
                  let stored = result["stored_session_id"].string?.nonEmpty,
                  let epoch = result["authority_epoch"].integer,
                  let replay = result["replay_epoch"].string?.nonEmpty,
                  let sequence = result["last_sequence"].integer, sequence >= 0 else {
                throw StandardSessionError.invalidResponse
            }
            if create {
                finishTurn(throwing: StandardSessionError.conversationReplaced)
                uncertain = false
            }
            runtimeSessionID = runtime
            storedSessionID = stored
            authorityEpoch = epoch
            replayEpoch = replay
            lastSequence = sequence
            let resultMetadata = SessionMetadata(
                standardSessionID: runtime,
                storedSessionID: stored,
                model: result["info"]["model"].string,
                capabilities: ["text_stream", "interrupt"]
            )
            metadata = resultMetadata
            // The canonical resume is a read-only attach. Never import its
            // messages, queued admissions, or prompt text as a request to send.
            if result["running"].bool == true || !(result["pending"].array ?? []).isEmpty {
                uncertain = true
            }
            if !(result["prompts"].array ?? []).isEmpty || result["pending_connection"].object != nil
                || !(result["open_requests"].array ?? []).isEmpty {
                uncertain = true
                throw StandardSessionError.unsupportedInteraction
            }
            return resultMetadata
        } catch {
            await closeTransport(error: safeError(error), notify: false)
            if error is CancellationError { throw CancellationError() }
            if durable != nil, safeError(error) != .unsupportedInteraction {
                throw StandardSessionError.resumeFailed
            }
            throw safeError(error)
        }
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        guard !operationInProgress else {
            continuation.finish(throwing: StandardSessionError.operationInProgress)
            return stream
        }
        guard !uncertain else {
            continuation.finish(throwing: StandardSessionError.deliveryUncertain)
            return stream
        }
        guard turn == nil else {
            continuation.finish(throwing: StandardSessionError.turnAlreadyActive)
            return stream
        }
        guard socket != nil, let session = runtimeSessionID, metadata != nil else {
            continuation.finish(throwing: StandardSessionError.disconnected)
            return stream
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish(throwing: StandardSessionError.requestRejected)
            return stream
        }
        let id = UUID().uuidString
        let requestID = UUID().uuidString
        turn = Turn(id: id, requestID: requestID, sessionID: session, continuation: continuation, lastSequence: lastSequence)
        segmentOffsets.removeAll(keepingCapacity: true)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancelObservation(turnID: id) }
            }
        }
        Task { [weak self] in
            await self?.submit(text: text, session: session, turnID: id, requestID: requestID)
        }
        return stream
    }

    private func submit(text: String, session: String, turnID: String, requestID: String) async {
        guard turn?.id == turnID, runtimeSessionID == session else { return }
        do {
            let result = try await request(id: requestID, method: "prompt.submit", params: [
                "session_id": .string(session), "profile": .string(profile.standardProfile ?? "default"),
                "text": .string(text), "submission_id": .string(requestID),
            ])
            guard turn?.id == turnID else { return }
            guard result["ref"]["session_id"].string == session,
                  result["authority_epoch"].integer == authorityEpoch,
                  let admission = result["admission_id"].string?.nonEmpty,
                  ["queued", "started", "terminal"].contains(result["status"].string ?? "") else {
                uncertain = true
                failObservation(turnID: turnID, error: .deliveryUncertain)
                return
            }
            turn?.admissionID = admission
            turn?.executionGeneration = result["execution_generation"].integer
            let buffered = turn?.bufferedEvents ?? []
            turn?.bufferedEvents.removeAll()
            for event in buffered { try handleEvent(event) }
        } catch {
            guard turn?.id == turnID else { return }
            let failure = safeError(error)
            if failure == .requestRejected, turn?.bufferedEvents.isEmpty == true {
                finishTurn(throwing: failure)
            } else {
                uncertain = true
                failObservation(turnID: turnID, error: failure)
            }
        }
    }

    func interruptActiveTurn() async -> Bool {
        await interruptActiveTurnOutcome() == .confirmed
    }

    func interruptActiveTurnOutcome() async -> HermesInterruptOutcome {
        guard let active = turn, socket != nil, runtimeSessionID == active.sessionID else { return .unavailable }
        guard let execution = active.executionGeneration else { return .uncertain }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return .uncertain }
            return await withCheckedContinuation { continuation in
                interruptWaiters[waiterID] = continuation
                guard interruptTurnID == nil else { return }
                interruptTurnID = active.id
                let timeout = requestTimeoutNanoseconds
                interruptTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.resolveInterruption(.uncertain, ifTurnID: active.id)
                }
                Task { [weak self] in
                    await self?.requestInterruption(session: active.sessionID, turnID: active.id, execution: execution)
                }
            }
        } onCancel: {
            Task { await self.cancelInterruptWaiter(waiterID) }
        }
    }

    private func requestInterruption(session: String, turnID: String, execution: Int) async {
        guard turn?.id == turnID, interruptTurnID == turnID else { return }
        let requestID = UUID().uuidString
        interruptRequestID = requestID
        do {
            let result = try await request(id: requestID, method: "session.interrupt", params: [
                "session_id": .string(session), "profile": .string(profile.standardProfile ?? "default"),
                "execution_generation": .number(Double(execution)),
            ])
            guard interruptTurnID == turnID else { return }
            guard result["ref"]["session_id"].string == session,
                  result["execution_generation"].integer == execution,
                  result["authority_epoch"].integer == authorityEpoch else {
                resolveInterruption(.rejected)
                return
            }
            // Native acknowledgement reports the handle, often still running:
            // only the correlated interrupted terminal event confirms a stop.
        } catch {
            resolveInterruption(safeError(error) == .requestRejected ? .rejected : .uncertain, ifTurnID: turnID)
        }
    }

    private func cancelInterruptWaiter(_ id: UUID) {
        interruptWaiters.removeValue(forKey: id)?.resume(returning: .uncertain)
    }

    private func resolveInterruption(_ outcome: HermesInterruptOutcome, ifTurnID: String? = nil) {
        if let ifTurnID, interruptTurnID != ifTurnID { return }
        interruptTurnID = nil
        interruptTimer?.cancel()
        interruptTimer = nil
        if let requestID = interruptRequestID {
            interruptRequestID = nil
            resolveRequest(id: requestID, result: .failure(StandardSessionError.disconnected))
        }
        let waiters = interruptWaiters
        interruptWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: outcome) }
    }

    func disconnect() async {
        await closeTransport(error: .disconnected, notify: false)
    }

    /// Explicitly leaving is local only. No interrupt, close-session, resume,
    /// create, or prompt is sent. The owner keeps the historic transcript.
    func leaveConversation() async {
        await closeTransport(error: .disconnected, notify: false)
        storedSessionID = nil
        uncertain = false
        finishTurn(throwing: StandardSessionError.disconnected)
    }

    private func privateRequest() throws -> URLRequest {
        guard profile.standardProfile != nil,
              var components = URLComponents(url: profile.endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.percentEncodedPath == "/api/ws",
              components.percentEncodedQuery == nil else { throw StandardSessionError.invalidEndpoint }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StandardSessionError.missingToken }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw StandardSessionError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Double(requestTimeoutNanoseconds) / 1_000_000_000
        return request
    }

    private func ensureTransport() async throws {
        if socket != nil { return }
        let request = try privateRequest()
        let attempt = generation
        let id = UUID()
        let connection: any WebSocketConnection = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let factory = connectionFactory
                let timeout = requestTimeoutNanoseconds
                let opener = Task { [weak self] in
                    do {
                        let opened = try await factory.open(urlRequest: request)
                        guard let self else { await opened.close(); return }
                        await self.completeOpen(id: id, connection: opened)
                    } catch {
                        await self?.failOpen(id: id, error: .connectionFailed)
                    }
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.failOpen(id: id, error: .requestTimedOut)
                }
                opening = PendingOpen(id: id, continuation: continuation, timer: timer, opener: opener)
            }
        } onCancel: {
            Task { await self.failOpen(id: id, error: .disconnected) }
        }
        guard attempt == generation, !Task.isCancelled else {
            await connection.close()
            throw CancellationError()
        }
        socket = connection
        reader = Task { [weak self] in await self?.receiveLoop(connection: connection, generation: attempt) }
        let pong = try await self.request(method: "gateway.ping", params: [:])
        guard pong["ok"].bool == true else { throw StandardSessionError.invalidResponse }
        guard authorityReady else { throw StandardSessionError.unsupportedBaseline }
    }

    private func completeOpen(id: UUID, connection: any WebSocketConnection) async {
        guard let pending = opening, pending.id == id else { await connection.close(); return }
        opening = nil
        pending.timer.cancel()
        pending.continuation.resume(returning: connection)
    }

    private func failOpen(id: UUID, error: StandardSessionError) {
        guard let pending = opening, pending.id == id else { return }
        opening = nil
        pending.timer.cancel()
        pending.opener.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func request(
        id: String = UUID().uuidString,
        method: String,
        params: [String: StandardJSON]
    ) async throws -> StandardJSON {
        try await transmit(id: id, frame: .object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "method": .string(method), "params": .object(params),
        ]), expectsReply: true)
    }

    private func transmit(id: String, frame: StandardJSON, expectsReply: Bool) async throws -> StandardJSON {
        guard let connection = socket else { throw StandardSessionError.disconnected }
        guard requests.count < 32 else { throw StandardSessionError.operationInProgress }
        let data: Data
        do { data = try JSONEncoder().encode(frame) } catch { throw StandardSessionError.invalidResponse }
        let text = String(decoding: data, as: UTF8.self)
        let attempt = generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = requestTimeoutNanoseconds
                let sender = Task { [weak self] in
                    do {
                        try await connection.send(text: text)
                        await self?.didSend(id: id, generation: attempt)
                    } catch {
                        await self?.closeTransport(error: .disconnected, notify: true, ifGeneration: attempt)
                    }
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.expireRequest(id: id, generation: attempt)
                }
                requests[id] = PendingRequest(continuation: continuation, timer: timer, sender: sender, expectsReply: expectsReply)
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id, generation: attempt) }
        }
    }

    private func didSend(id: String, generation: UInt64) {
        guard generation == self.generation, requests[id]?.expectsReply == false else { return }
        resolveRequest(id: id, result: .success(.null))
    }

    private func resolveRequest(id: String, result: Result<StandardJSON, Error>) {
        guard let pending = requests.removeValue(forKey: id) else { return }
        pending.timer.cancel()
        // A response can precede send's completion callback. Cancelling that
        // sender here would cancel a healthy URLSession WebSocket task.
        pending.continuation.resume(with: result)
    }

    private func expireRequest(id: String, generation: UInt64) async {
        guard generation == self.generation, requests[id] != nil else { return }
        await closeTransport(error: .requestTimedOut, notify: true)
    }

    private func cancelRequest(id: String, generation: UInt64) async {
        guard generation == self.generation, requests[id] != nil else { return }
        await closeTransport(error: .disconnected, notify: false)
    }

    private func receiveLoop(connection: any WebSocketConnection, generation: UInt64) async {
        while !Task.isCancelled {
            do {
                let frame = try await connection.receive()
                guard generation == self.generation, !Task.isCancelled else { return }
                guard case .text(let text) = frame, text.utf8.count <= 4_194_304 else {
                    throw StandardSessionError.invalidResponse
                }
                let value: StandardJSON
                do { value = try JSONDecoder().decode(StandardJSON.self, from: Data(text.utf8)) }
                catch { throw StandardSessionError.invalidResponse }
                try handleFrame(value)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                await closeTransport(error: safeError(error), notify: true)
                return
            }
        }
    }

    private func handleFrame(_ value: StandardJSON) throws {
        guard value.object != nil, value["jsonrpc"].string == "2.0" else { throw StandardSessionError.invalidResponse }
        if let id = value["id"].string, requests[id]?.expectsReply == true {
            guard value["method"].isNull,
                  value["result"].isNull != value["error"].isNull else { throw StandardSessionError.invalidResponse }
            if !value["error"].isNull {
                resolveRequest(id: id, result: .failure(StandardSessionError.requestRejected))
            } else {
                guard value["result"].object != nil else { throw StandardSessionError.invalidResponse }
                resolveRequest(id: id, result: .success(value["result"]))
            }
            return
        }
        guard let method = value["method"].string else {
            // Replies arriving after cancellation/completion cannot revive work.
            guard !value["id"].isNull else { throw StandardSessionError.invalidResponse }
            return
        }
        if !value["id"].isNull {
            // A server-initiated JSON-RPC request must never be answered with a
            // choice, secret, or approval. A standard -32601 response is safe.
            if turn != nil, value["params"]["session_id"].isNull || belongsToCurrentSession(value["params"]) {
                blockUnsupportedInteraction()
            }
            let responseID = UUID().uuidString
            let response: StandardJSON = .object([
                "jsonrpc": .string("2.0"), "id": value["id"],
                "error": .object(["code": .number(-32601), "message": .string("This client does not support interactive requests.")]),
            ])
            Task { [weak self] in _ = try? await self?.transmit(id: responseID, frame: response, expectsReply: false) }
            return
        }
        guard method == "event" else { return }
        try handleEvent(value["params"])
    }

    private func handleEvent(_ params: StandardJSON) throws {
        guard params.object != nil, let type = params["type"].string, !type.isEmpty,
              params["payload"].isNull || params["payload"].object != nil else { throw StandardSessionError.invalidResponse }
        if type == "gateway.ready" {
            guard params["payload"]["session_authority"].bool == true else { throw StandardSessionError.unsupportedBaseline }
            authorityReady = true
            return
        }
        guard belongsToCurrentSession(params), turn?.sessionID == runtimeSessionID else { return }
        let payload = params["payload"]
        if type == "session.replay_gap" {
            throw StandardSessionError.invalidResponse
        }
        guard params["authority_epoch"].integer == authorityEpoch,
              params["replay_epoch"].string == replayEpoch else { return }
        guard let admission = turn?.admissionID else {
            guard (turn?.bufferedEvents.count ?? 0) < 1_024 else { throw StandardSessionError.invalidResponse }
            turn?.bufferedEvents.append(params)
            return
        }
        guard let active = turn else { return }
        guard params["admission_id"].string == admission,
              let execution = params["execution_generation"].integer else { return }
        if let known = active.executionGeneration, execution != known { return }
        turn?.executionGeneration = execution
        if let inner = payload["session_id"].string, !inner.isEmpty, inner != active.sessionID {
            // session.title intentionally contains the durable identity. It is
            // not a text event, and is never passed to the turn normalizer.
            if type == "session.title" { return }
            throw StandardSessionError.invalidResponse
        }
        let remoteID = params["turn_id"].string ?? payload["turn_id"].string
        if let remoteID, let known = active.remoteID, remoteID != known { return }
        if let remoteID { turn?.remoteID = remoteID }
        guard let sequence = params["seq"].integer, sequence > 0 else { throw StandardSessionError.invalidResponse }
        if let last = active.lastSequence, sequence <= last { return }
        turn?.lastSequence = sequence
        lastSequence = sequence
        // New upstreams stamp delta offsets in UTF-16 units. Drop duplicates;
        // a gap must fail rather than silently truncate the response.
        if type == "message.delta", let segment = payload["segment"].integer,
           let offset = payload["offset"].integer, let text = payload["text"].string {
            guard segment >= 0, offset >= 0 else { throw StandardSessionError.invalidResponse }
            let expected = segmentOffsets[segment, default: 0]
            if offset < expected {
                guard text.utf16.count <= expected - offset else { throw StandardSessionError.invalidResponse }
                return
            }
            guard offset == expected else { throw StandardSessionError.invalidResponse }
            segmentOffsets[segment] = offset + text.utf16.count
        }
        if ["approval.request", "clarify.request", "secret.request", "sudo.request", "connection.request"].contains(type) {
            blockUnsupportedInteraction()
            return
        }
        switch type {
        case "tool.start", "tool.generating":
            emit(.status(text: "Hermes is using a tool…", kind: "tool"))
        case "tool.complete":
            emit(.status(text: "Hermes finished a tool operation.", kind: "tool"))
        case "error":
            emit(.error(StandardSessionError.turnFailed.localizedDescription))
            finishTurn(throwing: StandardSessionError.turnFailed)
        case "message.complete":
            var safePayload = payload.object ?? [:]
            guard let status = payload["status"].string, ["complete", "interrupted", "error"].contains(status) else {
                throw StandardSessionError.invalidResponse
            }
            let failed = status == "error"
            safePayload["failure_reason"] = .string(failed ? StandardSessionError.turnFailed.localizedDescription : "")
            if failed {
                // Failure payloads can contain URLs/provider exceptions. Retain
                // already-streamed text, never turn an exception into chat.
                safePayload["text"] = .string("")
                safePayload["rendered"] = .string("")
                safePayload["reasoning"] = .string("")
            }
            try normalize(type: type, payload: .object(safePayload))
            if failed {
                emit(.error(StandardSessionError.turnFailed.localizedDescription))
                finishTurn(throwing: StandardSessionError.turnFailed)
            } else if status == "interrupted" {
                emit(.turnInterrupted(turnID: active.id, reason: "Standard ended the interrupted response."))
                resolveInterruption(.confirmed)
                finishTurn()
            } else if status == "complete" {
                emit(.turnComplete(turnID: active.id))
                finishTurn()
            } else {
                throw StandardSessionError.invalidResponse
            }
        case "message.interim":
            if payload["already_streamed"].bool != true { try normalize(type: "message.delta", payload: payload) }
        case "message.start", "message.delta",
             "thinking.delta", "reasoning.delta", "reasoning.available", "status.update":
            try normalize(type: type, payload: payload)
        default:
            // Audio and unknown metadata are not direct text capabilities.
            break
        }
    }

    private func belongsToCurrentSession(_ params: StandardJSON) -> Bool {
        guard let runtimeSessionID else { return false }
        return params["session_id"].string == runtimeSessionID
    }

    private func normalize(type: String, payload: StandardJSON) throws {
        guard let id = turn?.id else { return }
        let data = try JSONEncoder().encode(StandardJSON.object(["type": .string(type), "payload": payload]))
        let events = try turn?.normalizer.normalizeJSON(data, turnID: id) ?? []
        for event in events { emit(event) }
    }

    private func emit(_ event: HermesEvent) {
        guard let continuation = turn?.continuation else { return }
        if case .dropped = continuation.yield(event) {
            uncertain = true
            failObservation(turnID: turn?.id ?? "", error: .invalidResponse)
        }
    }

    private func blockUnsupportedInteraction() {
        uncertain = true
        if let id = turn?.id { failObservation(turnID: id, error: .unsupportedInteraction) }
    }

    private func failObservation(turnID: String, error: StandardSessionError) {
        guard turn?.id == turnID else { return }
        let continuation = turn?.continuation
        turn?.continuation = nil
        continuation?.finish(throwing: error)
    }

    private func cancelObservation(turnID: String) {
        guard turn?.id == turnID else { return }
        // Cancelling observation is not proof that Hermes stopped. Keep its
        // turn slot until an actual terminal event, New conversation, or Leave.
        turn?.continuation = nil
    }

    private func finishTurn(throwing error: Error? = nil) {
        let active = turn
        turn = nil
        resolveInterruption(.rejected)
        if let active {
            resolveRequest(id: active.requestID, result: .failure(error ?? StandardSessionError.conversationReplaced))
        }
        if let error { active?.continuation?.finish(throwing: error) }
        else { active?.continuation?.finish() }
    }

    private func closeTransport(
        error: StandardSessionError,
        notify: Bool,
        ifGeneration: UInt64? = nil
    ) async {
        if let ifGeneration, ifGeneration != generation { return }
        let hadTransport = socket != nil
        let connection = socket
        socket = nil
        metadata = nil
        runtimeSessionID = nil
        authorityReady = false
        authorityEpoch = nil
        replayEpoch = nil
        lastSequence = nil
        resolveInterruption(.uncertain)
        generation &+= 1
        reader?.cancel()
        reader = nil
        if let opening { failOpen(id: opening.id, error: error) }
        let pending = requests
        requests.removeAll()
        for request in pending.values {
            request.timer.cancel()
            request.sender.cancel()
            request.continuation.resume(throwing: error)
        }
        if turn != nil { uncertain = true }
        finishTurn(throwing: error)
        if notify, hadTransport { await onTransportDisconnected?() }
        await connection?.close()
    }

    private func safeError(_ error: Error) -> StandardSessionError {
        error as? StandardSessionError ?? .disconnected
    }
}

/// Small typed JSON boundary keeps untrusted Foundation objects out of tasks
/// and continuations under Swift's strict concurrency checking.
private indirect enum StandardJSON: Codable, Sendable {
    case object([String: StandardJSON]), array([StandardJSON]), string(String)
    case number(Double), bool(Bool), null

    subscript(_ key: String) -> StandardJSON { object?[key] ?? .null }
    var object: [String: StandardJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [StandardJSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var integer: Int? {
        guard case .number(let value) = self, value.isFinite,
              value >= Double(Int.min), value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
    var isNull: Bool { if case .null = self { true } else { false } }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: StandardJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([StandardJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
