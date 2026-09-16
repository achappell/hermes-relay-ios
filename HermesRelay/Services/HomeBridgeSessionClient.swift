import Foundation

enum HomeBridgeClientFactoryError: Error, Equatable, Sendable {
    case unsupportedMode
}

struct UnavailableHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory {
    let failure: HomeBridgeFailure

    init(failure: HomeBridgeFailure = .publicAdapterUnavailable) {
        self.failure = failure
    }

    func make(
        profileID: UUID,
        mode: AppleTransportMode
    ) -> any HomeBridgeSessionClient {
        UnavailableHomeBridgeSessionClient(failure: failure)
    }
}

struct UnavailableHomeBridgeSessionClient: HomeBridgeSessionClient {
    let failure: HomeBridgeFailure

    init(failure: HomeBridgeFailure = .publicAdapterUnavailable) {
        self.failure = failure
    }

    func open(claim: HomeConversationClaim) async -> HomeOpenOutcome {
        .unavailable(failure)
    }

    func reconnect(binding: HomeConversationBinding) async -> HomeReconnectOutcome {
        .unavailable(failure)
    }

    func submitPrompt(
        _ text: String,
        binding: HomeConversationBinding
    ) async -> HomePromptSubmissionOutcome {
        .rejected(failure)
    }

    func interrupt(
        binding: HomeConversationBinding,
        turnID: String
    ) async -> HomeInterruptOutcome {
        .unavailable(failure)
    }

    func respond(
        to prompt: HomeStructuredPrompt,
        with response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome {
        .rejected(failure)
    }

    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome {
        .rejected(failure)
    }

    func ping(binding: HomeConversationBinding) async -> HomePingOutcome {
        .unavailable(failure)
    }

    func cancelPending(requestID: HomePendingRequestID) async {}

    func events() async -> AsyncThrowingStream<HomeBridgeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func close() async {}
}

struct DefaultHomeBridgeSessionClientFactory: HomeBridgeSessionClientFactory {
    let dependencies: HomeBridgeClientDependencies

    init(dependencies: HomeBridgeClientDependencies) {
        self.dependencies = dependencies
    }

    func make(
        profileID: UUID,
        mode: AppleTransportMode
    ) -> any HomeBridgeSessionClient {
        guard mode == .home else {
            return UnavailableHomeBridgeSessionClient(
                failure: .home(code: .capabilityUnavailable, phase: .lifecycle)
            )
        }
        guard dependencies.publicAdapterEnabled else {
            return UnavailableHomeBridgeSessionClient()
        }
        return URLSessionHomeBridgeSessionClient(dependencies: dependencies)
    }
}

typealias HomeBridgeClientFactory = DefaultHomeBridgeSessionClientFactory

private enum HomeBridgeTransportError: Error, Equatable, Sendable {
    case disconnected
    case cancelled
    case invalidResponse
}

private final class HomeConnectionHolder: @unchecked Sendable {
    var connection: (any WebSocketConnection)?
}

private struct HomeEventEnvelope {
    let scope: HomeEventScope
    let type: String
    let payload: [String: Any]
}

actor URLSessionHomeBridgeSessionClient: HomeBridgeSessionClient {
    private static let allowedMethods: Set<String> = [
        "conversation.open",
        "conversation.reconnect",
        "prompt.submit",
        "session.interrupt",
        "prompt.respond",
        "command.dispatch",
        "bridge.ping",
    ]

    private let dependencies: HomeBridgeClientDependencies
    private let deadlines: HomeOperationDeadlines
    private var socket: (any WebSocketConnection)?
    private var readerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var currentClaim: HomeConversationClaim?
    private var currentBinding: HomeConversationBinding?
    private var bridgeReady = false
    private var capabilities = HomeBridgeCapabilities()
    private var pending: [String: CheckedContinuation<HomeWireResponse, Error>] = [:]
    private var pendingPrompts: [String: HomePendingStructuredPrompt] = [:]
    private var eventContinuation: AsyncThrowingStream<HomeBridgeEvent, Error>.Continuation?
    private var eventStream: AsyncThrowingStream<HomeBridgeEvent, Error>?
    private var activeAudioScope: HomeEventScope?
    private var pendingAudioScope: HomeEventScope?
    private var audioAccumulator: HomePCMAccumulator?
    private var audioGeneration: UInt64?
    private var audioTerminalReceived = false
    private var closed = false

    init(
        dependencies: HomeBridgeClientDependencies,
        deadlines: HomeOperationDeadlines = .default
    ) {
        self.dependencies = dependencies
        self.deadlines = deadlines
    }

    func open(claim: HomeConversationClaim) async -> HomeOpenOutcome {
        guard !closed else { return .disconnected(.home(code: .transportUnavailable, phase: .lifecycle)) }
        guard dependencies.publicAdapterEnabled else { return .unavailable(.publicAdapterUnavailable) }
        do {
            try claim.approvedRoute.validate()
            guard let approved = try await dependencies.routeProvider.approvedRoute(for: claim.profileID) else {
                return .unavailable(.route(.unavailable))
            }
            guard approved == claim.approvedRoute else {
                return .unavailable(.route(.identityMismatch))
            }
            if let currentBinding {
                guard currentBinding.profileID == claim.profileID,
                      currentBinding.conversationHandle == claim.conversationHandle,
                      currentBinding.endpoint == claim.approvedRoute.endpoint,
                      currentBinding.route == claim.approvedRoute.identity,
                      currentBinding.householdBinding == claim.approvedRoute.householdBinding else {
                    return .unavailable(.home(code: .conversationMismatch, phase: .open))
                }
                if bridgeReady, socket != nil {
                    return .ready(binding: currentBinding, capabilities: capabilities)
                }
            }
            bridgeReady = false
            try await installSocket(route: claim.approvedRoute, profileID: claim.profileID)
            currentClaim = claim

            let requestID = HomePendingRequestID()
            let response = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.open,
                clock: dependencies.clock,
                cancelPending: { [weak self] requestID in
                    await self?.cancelPending(requestID: requestID)
                },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "conversation.open",
                        params: ["conversation_handle": .string(claim.conversationHandle)]
                    )
                }
            )
            let ready = try decodeReady(response)
            guard ready.schema == 1,
                  !ready.conversationHandle.isEmpty,
                  ready.conversationHandle == claim.conversationHandle else {
                throw HomeWireDecodingError.invalidShape
            }
            guard ready.status == .ready,
                  let wireRoute = ready.route,
                  let wireCapabilities = ready.capabilities else {
                if ready.reason == .reconnectRequired {
                    return .unavailable(.reconnectRequired)
                }
                return .unavailable(mapOpenReason(ready.reason ?? .protocolError))
            }
            guard wireRoute.routeClass == claim.approvedRoute.identity.routeClass,
                  wireRoute.id == claim.approvedRoute.identity.id else {
                return .unavailable(.route(.identityMismatch))
            }
            guard ready.reason == nil else {
                return .unavailable(mapOpenReason(ready.reason!))
            }
            capabilities = HomeBridgeCapabilities(wireCapabilities)
            let binding = HomeConversationBinding(
                profileID: claim.profileID,
                conversationHandle: claim.conversationHandle,
                endpoint: claim.approvedRoute.endpoint,
                route: claim.approvedRoute.identity,
                householdBinding: claim.approvedRoute.householdBinding,
                capabilities: capabilities
            )
            currentBinding = binding
            bridgeReady = true
            return .ready(binding: binding, capabilities: capabilities)
        } catch is HomeWireDecodingError {
            return .unavailable(.home(code: .protocolError, phase: .open))
        } catch is HomeDeadlineError {
            return .disconnected(.home(code: .transportTimeout, phase: .open))
        } catch is CancellationError {
            return .disconnected(.home(code: .transportTimeout, phase: .open))
        } catch {
            let failure = failure(for: error, phase: .open)
            return failure.classification == .uncertain
                ? .disconnected(failure)
                : .unavailable(failure)
        }
    }

    func reconnect(binding: HomeConversationBinding) async -> HomeReconnectOutcome {
        guard !closed else { return .disconnected(.home(code: .transportUnavailable, phase: .lifecycle)) }
        do {
            guard validateBindingIdentity(binding) == nil else {
                return .unavailable(.home(code: .conversationMismatch, phase: .reconnect))
            }
            bridgeReady = false
            if socket == nil {
                let route = HomeApprovedRoute(
                    endpoint: binding.endpoint,
                    identity: binding.route,
                    householdBinding: binding.householdBinding
                )
                try route.validate()
                guard let approved = try await dependencies.routeProvider.approvedRoute(for: binding.profileID),
                      approved == route else {
                    return .unavailable(.route(.identityMismatch))
                }
                try await installSocket(route: route, profileID: binding.profileID)
            }
            currentBinding = binding
            capabilities = binding.capabilities
            let requestID = HomePendingRequestID()
            let response = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.reconnectAttempt,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "conversation.reconnect",
                        params: ["conversation_handle": .string(binding.conversationHandle)]
                    )
                }
            )
            let result = try decodeReconnect(response, binding: binding)
            switch result.status {
            case .ready:
                let unresolved = result.unresolvedTurnID.map {
                    HomeUnresolvedTurn(turnID: $0, resumeCursor: result.resumeCursor)
                }
                bridgeReady = true
                return .ready(binding: binding, unresolvedTurn: unresolved)
            case .unavailable:
                if result.reason == .reconnectRequired {
                    return .unavailable(.reconnectRequired)
                }
                return .unavailable(mapOpenReason(result.reason ?? .protocolError))
            }
        } catch is HomeWireDecodingError {
            return .unavailable(.home(code: .protocolError, phase: .reconnect))
        } catch is HomeDeadlineError {
            return .disconnected(.home(code: .transportTimeout, phase: .reconnect))
        } catch is CancellationError {
            return .disconnected(.home(code: .transportTimeout, phase: .reconnect))
        } catch {
            let failure = failure(for: error, phase: .reconnect)
            return failure.classification == .uncertain
                ? .disconnected(failure)
                : .unavailable(failure)
        }
    }

    func submitPrompt(
        _ text: String,
        binding: HomeConversationBinding
    ) async -> HomePromptSubmissionOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.home(code: .invalidRequest, phase: .submission))
        }
        guard validateCurrentBinding(binding) == nil else {
            return .rejected(.home(code: .conversationMismatch, phase: .submission))
        }
        let requestID = HomePendingRequestID()
        do {
            let response = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.promptAcceptance,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "prompt.submit",
                        params: [
                            "conversation_handle": .string(binding.conversationHandle),
                            "text": .string(text),
                        ]
                    )
                }
            )
            let result = try decodeSubmission(response, binding: binding)
            guard result.status == "accepted" else {
                return .rejected(.home(code: .requestRejected, phase: .submission))
            }
            let turn = HomeTurnBinding(
                conversationHandle: binding.conversationHandle,
                turnID: result.turnID,
                correlationID: result.correlationID
            )
            clearAudioStreamState()
            pendingAudioScope = HomeEventScope(
                conversationHandle: turn.conversationHandle,
                turnID: turn.turnID,
                correlationID: turn.correlationID
            )
            return .accepted(turn)
        } catch is HomeDeadlineError {
            return .uncertain(.home(code: .transportTimeout, phase: .submission))
        } catch is CancellationError {
            return .uncertain(.home(code: .transportTimeout, phase: .submission))
        } catch is HomeWireDecodingError {
            return .rejected(.home(code: .protocolError, phase: .submission))
        } catch {
            let failure = failure(for: error, phase: .submission)
            if failure.classification == .uncertain {
                return .uncertain(failure)
            }
            return .rejected(failure)
        }
    }

    func interrupt(
        binding: HomeConversationBinding,
        turnID: String
    ) async -> HomeInterruptOutcome {
        guard validateCurrentBinding(binding) == nil else {
            return .rejected(.home(code: .conversationMismatch, phase: .interrupt))
        }
        guard binding.capabilities.interrupt else {
            return .unavailable(.home(code: .capabilityUnavailable, phase: .interrupt))
        }
        let requestID = HomePendingRequestID()
        do {
            let response = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.interruptAcknowledgement,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "session.interrupt",
                        params: [
                            "conversation_handle": .string(binding.conversationHandle),
                            "turn_id": .string(turnID),
                        ]
                    )
                }
            )
            let status = responseString(response, key: "status") ?? "acknowledged"
            guard status == "accepted" || status == "acknowledged" else {
                return .rejected(.home(code: .requestRejected, phase: .interrupt))
            }
            return .acknowledged
        } catch is HomeDeadlineError {
            return .uncertain(.home(code: .transportTimeout, phase: .interrupt))
        } catch is CancellationError {
            return .uncertain(.home(code: .transportTimeout, phase: .interrupt))
        } catch is HomeWireDecodingError {
            return .rejected(.home(code: .protocolError, phase: .interrupt))
        } catch {
            let failure = failure(for: error, phase: .interrupt)
            return failure.classification == .uncertain ? .uncertain(failure) : .unavailable(failure)
        }
    }

    func respond(
        to prompt: HomeStructuredPrompt,
        with response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome {
        guard let binding = currentBinding,
              binding.conversationHandle == prompt.conversationHandle else {
            return .rejected(.home(code: .conversationMismatch, phase: .structuredResponse))
        }
        guard let pendingPrompt = pendingPrompts[prompt.correlationID],
              pendingPrompt.prompt == prompt else {
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        guard responseMatchesPrompt(prompt, response: response) else {
            return .rejected(.home(code: .invalidRequest, phase: .structuredResponse))
        }
        guard !pendingPrompt.isExpired(at: Date()) else {
            pendingPrompts.removeValue(forKey: prompt.correlationID)
            return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        }
        let requestID = HomePendingRequestID()
        do {
            let responseFrame = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.structuredResponse,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "prompt.respond",
                        params: self.responseParameters(for: prompt, response: response)
                    )
                }
            )
            let result = try decodeCorrelatedResult(responseFrame)
            guard result.handle == prompt.conversationHandle,
                  result.turnID == prompt.turnID,
                  result.correlationID == prompt.correlationID else {
                return .rejected(.home(code: .conversationMismatch, phase: .structuredResponse))
            }
            switch result.status.lowercased() {
            case "ok", "accepted", "resolved", "complete", "completed":
                pendingPrompts.removeValue(forKey: prompt.correlationID)
                return .accepted
            case "rejected", "denied", "expired", "failed", "error", "unavailable":
                return .rejected(.home(code: .requestRejected, phase: .structuredResponse))
            default:
                return .rejected(.home(code: .protocolError, phase: .structuredResponse))
            }
        } catch is HomeDeadlineError {
            return .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        } catch is CancellationError {
            return .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        } catch is HomeWireDecodingError {
            return .rejected(.home(code: .protocolError, phase: .structuredResponse))
        } catch {
            let failure = failure(for: error, phase: .structuredResponse)
            return failure.classification == .uncertain ? .uncertain(failure) : .rejected(failure)
        }
    }

    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome {
        guard validateCurrentBinding(command.binding) == nil else {
            return .rejected(.home(code: .conversationMismatch, phase: .command))
        }
        guard command.binding.capabilities.commands.contains(command.name.lowercased()) else {
            return .rejected(.home(code: .capabilityUnavailable, phase: .command))
        }
        let requestID = HomePendingRequestID()
        do {
            var params: [String: HomeJSONValue] = [
                "conversation_handle": .string(command.binding.conversationHandle),
                "name": .string(command.name),
            ]
            if let argument = command.argument { params["argument"] = .string(argument) }
            let requestParams = params
            let response = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.command,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(id: requestID, method: "command.dispatch", params: requestParams)
                }
            )
            let result = try decodeCommandResult(response, binding: command.binding)
            switch result.status {
            case .accepted, .completed:
                return .completed(result)
            case .rejected, .unavailable:
                return .rejected(.home(
                    code: result.safeCode ?? .requestRejected,
                    phase: .command
                ))
            }
        } catch is HomeDeadlineError {
            return .uncertain(.home(code: .transportTimeout, phase: .command))
        } catch is CancellationError {
            return .uncertain(.home(code: .transportTimeout, phase: .command))
        } catch is HomeWireDecodingError {
            return .rejected(.home(code: .protocolError, phase: .command))
        } catch {
            let failure = failure(for: error, phase: .command)
            return failure.classification == .uncertain ? .uncertain(failure) : .rejected(failure)
        }
    }

    func ping(binding: HomeConversationBinding) async -> HomePingOutcome {
        guard validateCurrentBinding(binding) == nil else {
            return .unavailable(.home(code: .conversationMismatch, phase: .ping))
        }
        let requestID = HomePendingRequestID()
        do {
            _ = try await withHomeDeadline(
                requestID: requestID,
                timeout: deadlines.ping,
                clock: dependencies.clock,
                cancelPending: { [weak self] id in await self?.cancelPending(requestID: id) },
                operation: { [weak self] in
                    guard let self else { throw HomeBridgeTransportError.disconnected }
                    return try await self.request(
                        id: requestID,
                        method: "bridge.ping",
                        params: ["conversation_handle": .string(binding.conversationHandle)]
                    )
                }
            )
            return .alive
        } catch is HomeDeadlineError {
            return .unavailable(.home(code: .transportTimeout, phase: .ping))
        } catch is CancellationError {
            return .unavailable(.home(code: .transportTimeout, phase: .ping))
        } catch {
            return .unavailable(failure(for: error, phase: .ping))
        }
    }

    func cancelPending(requestID: HomePendingRequestID) async {
        guard let continuation = pending.removeValue(forKey: requestID.rawValue) else { return }
        continuation.resume(throwing: HomeBridgeTransportError.cancelled)
    }

    func events() async -> AsyncThrowingStream<HomeBridgeEvent, Error> {
        if let eventStream { return eventStream }
        let (stream, continuation) = AsyncThrowingStream<HomeBridgeEvent, Error>.makeStream()
        eventStream = stream
        eventContinuation = continuation
        return stream
    }

    func close() async {
        guard !closed else { return }
        closed = true
        generation &+= 1
        readerTask?.cancel()
        readerTask = nil
        let connection = socket
        socket = nil
        currentClaim = nil
        currentBinding = nil
        bridgeReady = false
        audioAccumulator = nil
        activeAudioScope = nil
        pendingAudioScope = nil
        audioGeneration = nil
        audioTerminalReceived = false
        pendingPrompts.removeAll()
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: HomeBridgeTransportError.disconnected) }
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        await connection?.close()
    }

    private func installSocket(route: HomeApprovedRoute, profileID: UUID) async throws {
        guard socket == nil else { return }
        let holder = HomeConnectionHolder()
        try await dependencies.credentialStore.withPrivateDeviceCredential(for: profileID) { [socketFactory = dependencies.socketFactory] credential in
            var request = URLRequest(url: route.endpoint)
            request.httpMethod = "GET"
            request.setValue("Device \(String(decoding: credential, as: UTF8.self))", forHTTPHeaderField: "Authorization")
            holder.connection = try await socketFactory.open(urlRequest: request)
        }
        guard let connection = holder.connection else { throw HomeBridgeTransportError.disconnected }
        socket = connection
        generation &+= 1
        let readerGeneration = generation
        readerTask = Task { [weak self] in
            await self?.receiveLoop(connection: connection, generation: readerGeneration)
        }
    }

    private func request(
        id: HomePendingRequestID,
        method: String,
        params: [String: HomeJSONValue]
    ) async throws -> HomeWireResponse {
        guard Self.allowedMethods.contains(method), let socket else {
            throw HomeBridgeTransportError.disconnected
        }
        let request = HomeJSONRPCRequest(id: id.rawValue, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HomeWireResponse, Error>) in
                pending[id.rawValue] = continuation
                Task { [weak self] in
                    do {
                        try await socket.send(text: text)
                    } catch {
                        await self?.resolvePending(id: id, throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPending(requestID: id) }
        }
    }

    private func receiveLoop(
        connection: any WebSocketConnection,
        generation readerGeneration: UInt64
    ) async {
        while !Task.isCancelled {
            do {
                let frame = try await connection.receive()
                guard readerGeneration == generation, !closed else { return }
                switch frame {
                case .text(let text):
                    try await handleTextFrame(text)
                case .binary(let data):
                    try await handleBinaryFrame(data)
                }
            } catch is CancellationError {
                return
            } catch let error as HomeWireDecodingError {
                await transportLost(
                    generation: readerGeneration,
                    decodingError: error
                )
                return
            } catch {
                await transportLost(generation: readerGeneration)
                return
            }
        }
    }

    private func handleTextFrame(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomeWireDecodingError.invalidShape
        }
        guard object["jsonrpc"] as? String == "2.0",
              intValue(object["schema"]) == 1 else {
            throw HomeWireDecodingError.unsupportedSchema
        }
        if let id = object["id"] as? String {
            try requireKeys(object, allowed: ["jsonrpc", "schema", "id", "result", "error"])
            let response = try decodeResponse(object)
            resolvePending(id: HomePendingRequestID(rawValue: id), response: response)
            return
        }
        try requireKeys(object, allowed: ["jsonrpc", "schema", "method", "params"])
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else {
            throw HomeWireDecodingError.invalidShape
        }
        switch method {
        case "event":
            let envelope = try decodeEventEnvelope(params)
            if let prompt = try decodeStructuredPrompt(envelope) {
                pendingPrompts[prompt.correlationID] = HomePendingStructuredPrompt(
                    prompt: prompt,
                    receivedAt: Date(),
                    expiresAt: prompt.expiresAt
                )
                eventContinuation?.yield(.structuredPrompt(prompt))
            } else if let event = try decodeStandardEvent(envelope) {
                eventContinuation?.yield(.standard(event))
            }
        case "audio.frame":
            do {
                if let event = try decodeAudioFrame(params) {
                    eventContinuation?.yield(event)
                }
            } catch let error as HomeWireDecodingError {
                guard error == .invalidAudioFrame,
                      let scope = audioFailureScope(from: params) else {
                    throw error
                }
                finishInvalidAudio(scope: scope)
            }
        default:
            throw HomeWireDecodingError.unsupportedMethod
        }
    }

    private func handleBinaryFrame(_ data: Data) async throws {
        if let pendingAudioScope, activeAudioScope == nil, !audioTerminalReceived {
            finishInvalidAudio(scope: pendingAudioScope)
            return
        }
        guard let scope = activeAudioScope,
              let audioGeneration,
              audioGeneration == generation,
              !audioTerminalReceived,
              var accumulator = audioAccumulator else {
            // A late binary frame is stale transport data, never a playback
            // candidate. Keep the control socket alive so the known text
            // terminal can still be delivered.
            return
        }
        let joined = try accumulator.append(transportChunk: data)
        audioAccumulator = accumulator
        if !joined.isEmpty { eventContinuation?.yield(.binaryPCM(scope, joined)) }
    }

    private func decodeEventEnvelope(_ params: [String: Any]) throws -> HomeEventEnvelope {
        try requireKeys(params, allowed: [
            "schema", "conversation_handle", "turn_id", "correlation_id", "event",
        ])
        guard intValue(params["schema"]) == 1,
              let handle = params["conversation_handle"] as? String,
              !handle.isEmpty,
              let event = params["event"] as? [String: Any],
              let type = event["type"] as? String,
              !type.isEmpty,
              let payload = event["payload"] as? [String: Any] else {
            throw HomeWireDecodingError.invalidShape
        }
        guard let binding = currentBinding else {
            throw HomeWireDecodingError.invalidShape
        }
        guard handle == binding.conversationHandle else {
            throw HomeWireDecodingError.conversationMismatch
        }
        try requireKeys(event, allowed: ["type", "payload"])

        let turnID: String?
        if let value = params["turn_id"] {
            guard let value = value as? String, !value.isEmpty else {
                throw HomeWireDecodingError.invalidShape
            }
            turnID = value
        } else {
            turnID = nil
        }

        let correlationID: String?
        if let value = params["correlation_id"] {
            guard let value = value as? String, !value.isEmpty else {
                throw HomeWireDecodingError.invalidShape
            }
            correlationID = value
        } else {
            correlationID = nil
        }

        return HomeEventEnvelope(
            scope: HomeEventScope(
                conversationHandle: handle,
                turnID: turnID,
                correlationID: correlationID
            ),
            type: type,
            payload: payload
        )
    }

    private func decodeStandardEvent(_ envelope: HomeEventEnvelope) throws -> HomeStandardEvent? {
        guard let type = HomeStandardEventType(rawValue: envelope.type) else {
            throw HomeWireDecodingError.invalidShape
        }
        guard let binding = currentBinding else {
            throw HomeWireDecodingError.invalidShape
        }
        guard envelope.scope.conversationHandle == binding.conversationHandle else {
            throw HomeWireDecodingError.conversationMismatch
        }
        let scope = envelope.scope
        let payload = envelope.payload
        let localPayload: HomeStandardEventPayload
        switch type {
        case .messageStart:
            try requireKeys(payload, allowed: ["kind"])
            localPayload = .start(kind: try optionalEventKind(payload, key: "kind"))
        case .messageDelta, .textDelta:
            try requireKeys(payload, allowed: ["rendered", "text", "replace", "kind"])
            localPayload = .delta(
                rendered: try optionalString(payload, key: "rendered"),
                text: try optionalString(payload, key: "text"),
                replace: try optionalBool(payload, key: "replace") ?? false,
                kind: try optionalEventKind(payload, key: "kind")
            )
        case .text, .textFinal, .messageComplete:
            try requireKeys(payload, allowed: ["rendered", "text", "status", "reasoning", "failure_reason"])
            let failureReason = try optionalFailureCode(payload, key: "failure_reason")
            localPayload = .final(
                rendered: try optionalString(payload, key: "rendered"),
                text: try optionalString(payload, key: "text"),
                status: try optionalString(payload, key: "status"),
                reasoning: try optionalString(payload, key: "reasoning"),
                failureReason: failureReason
            )
        case .thinking, .reasoning, .status:
            try requireKeys(payload, allowed: ["text", "status", "reasoning", "kind"])
            localPayload = .activity(
                text: try optionalString(payload, key: "text"),
                status: try optionalString(payload, key: "status"),
                reasoning: try optionalString(payload, key: "reasoning"),
                kind: try optionalEventKind(payload, key: "kind")
            )
        case .turnComplete, .turnInterrupted, .audioAbort:
            try requireKeys(payload, allowed: ["kind"])
            guard scope.turnID != nil else { return nil }
            localPayload = .terminal(kind: try optionalEventKind(payload, key: "kind"))
        case .error:
            try requireKeys(payload, allowed: ["code", "phase"])
            guard let codeString = payload["code"] as? String,
                  let code = HomeFailureCode(rawValue: codeString),
                  let phaseString = payload["phase"] as? String,
                  let phase = HomeFailurePhase(rawValue: phaseString) else {
                throw HomeWireDecodingError.invalidShape
            }
            localPayload = .error(HomeSafeError(code: code, phase: phase))
        }
        return HomeStandardEvent(type: type, scope: scope, payload: localPayload)
    }

    private func decodeStructuredPrompt(_ envelope: HomeEventEnvelope) throws -> HomeStructuredPrompt? {
        let typeName = envelope.type
        let kind: HomeStructuredPromptKind?
        switch typeName {
        case "approval.request": kind = .approval
        case "clarify.request": kind = .clarification
        case "secret.request": kind = .secret
        case "sudo.request": kind = .sudo
        default: kind = nil
        }
        guard let kind else { return nil }
        guard let turnID = envelope.scope.turnID,
              let correlationID = envelope.scope.correlationID,
              let binding = currentBinding,
              binding.conversationHandle == envelope.scope.conversationHandle else {
            throw HomeWireDecodingError.conversationMismatch
        }
        let payload = envelope.payload
        try requireKeys(payload, allowed: ["options", "expires_at", "sensitive"])
        let options = try optionalStringArray(payload, key: "options") ?? []
        let expiresAt = try optionalISO8601Date(payload, key: "expires_at")
        let sensitive = try optionalBool(payload, key: "sensitive")
            ?? (kind == .secret || kind == .sudo)
        return HomeStructuredPrompt(
            kind: kind,
            conversationHandle: envelope.scope.conversationHandle,
            turnID: turnID,
            correlationID: correlationID,
            options: options,
            expiresAt: expiresAt,
            sensitive: sensitive
        )
    }

    private func decodeAudioFrame(_ params: [String: Any]) throws -> HomeBridgeEvent? {
        try requireKeys(params, allowed: [
            "schema", "conversation_handle", "turn_id", "correlation_id", "frame",
        ])
        guard intValue(params["schema"]) == 1,
              let handle = params["conversation_handle"] as? String,
              !handle.isEmpty,
              let binding = currentBinding,
              handle == binding.conversationHandle,
              let turnID = params["turn_id"] as? String,
              !turnID.isEmpty,
              let frame = params["frame"] as? [String: Any],
              let kind = frame["kind"] as? String else {
            throw HomeWireDecodingError.invalidAudioFrame
        }
        let scope = HomeEventScope(
            conversationHandle: handle,
            turnID: turnID,
            correlationID: try optionalNonEmptyString(params, key: "correlation_id")
        )
        switch kind {
        case "start":
            try requireKeys(frame, allowed: [
                "kind", "sample_rate", "channels", "sample_width", "byte_order",
            ])
            guard activeAudioScope == nil,
                  let sampleRate = intValue(frame["sample_rate"]),
                  let channels = intValue(frame["channels"]),
                  let sampleWidth = intValue(frame["sample_width"]),
                  let byteOrder = frame["byte_order"] as? String,
                  let order = HomeByteOrder(rawValue: byteOrder) else {
                throw HomeWireDecodingError.invalidAudioFrame
            }
            let format = HomeAudioFormat(
                sampleRate: sampleRate,
                channels: channels,
                sampleWidth: sampleWidth,
                byteOrder: order
            )
            guard format.isValidSignedPCM else { throw HomeWireDecodingError.invalidAudioFrame }
            activeAudioScope = scope
            pendingAudioScope = nil
            audioAccumulator = HomePCMAccumulator()
            audioGeneration = generation
            audioTerminalReceived = false
            return .audioStart(scope, format)
        case "end":
            try requireKeys(frame, allowed: ["kind"])
            guard audioScopeMatches(scope),
                  var accumulator = audioAccumulator else {
                throw HomeWireDecodingError.invalidAudioFrame
            }
            do {
                try accumulator.finish()
                let finishedScope = activeAudioScope ?? scope
                audioAccumulator = nil
                activeAudioScope = nil
                pendingAudioScope = nil
                audioGeneration = nil
                audioTerminalReceived = true
                return .audioTerminal(finishedScope, .end)
            } catch {
                let failedScope = activeAudioScope ?? scope
                audioAccumulator = nil
                activeAudioScope = nil
                pendingAudioScope = nil
                audioGeneration = nil
                audioTerminalReceived = true
                return .audioTerminal(failedScope, .invalid)
            }
        case "fallback", "unavailable":
            try requireKeys(frame, allowed: kind == "unavailable" ? ["kind", "reason"] : ["kind"])
            if kind == "unavailable" {
                guard let reason = frame["reason"] as? String, !reason.isEmpty else {
                    throw HomeWireDecodingError.invalidAudioFrame
                }
            }
            guard audioScopeMatches(scope) else { return nil }
            audioAccumulator = nil
            activeAudioScope = nil
            pendingAudioScope = nil
            audioGeneration = nil
            audioTerminalReceived = true
            return .audioTerminal(scope, kind == "fallback" ? .fallback : .unavailable)
        default:
            throw HomeWireDecodingError.invalidAudioFrame
        }
    }

    private func responseParameters(
        for prompt: HomeStructuredPrompt,
        response: HomePromptResponse
    ) -> [String: HomeJSONValue] {
        var params: [String: HomeJSONValue] = [
            "conversation_handle": .string(prompt.conversationHandle),
            "turn_id": .string(prompt.turnID),
            "correlation_id": .string(prompt.correlationID),
            "event_type": .string(prompt.eventType),
        ]
        switch response {
        case .approval(let choice, let all):
            params["choice"] = .string(choice)
            if let all { params["all"] = .bool(all) }
        case .clarification(let answer):
            params["answer"] = .string(answer)
        case .secret(let value):
            params["value"] = .string(value)
        case .sudo(let password):
            params["password"] = .string(password)
        }
        return params
    }

    private func validateCurrentBinding(_ binding: HomeConversationBinding) -> HomeBridgeFailure? {
        guard bridgeReady, socket != nil else {
            return .home(code: .transportUnavailable, phase: .lifecycle)
        }
        return validateBindingIdentity(binding)
    }

    private func validateBindingIdentity(_ binding: HomeConversationBinding) -> HomeBridgeFailure? {
        guard let currentBinding else { return .home(code: .conversationMismatch, phase: .lifecycle) }
        guard currentBinding == binding else { return .home(code: .conversationMismatch, phase: .lifecycle) }
        return nil
    }

    private func audioScopeMatches(_ scope: HomeEventScope) -> Bool {
        guard let activeAudioScope,
              activeAudioScope.conversationHandle == scope.conversationHandle,
              activeAudioScope.turnID == scope.turnID else { return false }
        return scope.correlationID == nil || activeAudioScope.correlationID == scope.correlationID
    }

    private func pendingAudioScopeMatches(_ scope: HomeEventScope) -> Bool {
        guard let pendingAudioScope,
              pendingAudioScope.conversationHandle == scope.conversationHandle,
              pendingAudioScope.turnID == scope.turnID else { return false }
        return scope.correlationID == nil || pendingAudioScope.correlationID == scope.correlationID
    }

    private func audioFailureScope(from params: [String: Any]) -> HomeEventScope? {
        guard intValue(params["schema"]) == 1,
              let handle = params["conversation_handle"] as? String,
              !handle.isEmpty,
              let turnID = params["turn_id"] as? String,
              !turnID.isEmpty,
              let binding = currentBinding,
              binding.conversationHandle == handle else { return nil }
        let correlationID: String?
        if let value = params["correlation_id"] {
            guard let value = value as? String, !value.isEmpty else { return nil }
            correlationID = value
        } else {
            correlationID = nil
        }
        let scope = HomeEventScope(
            conversationHandle: handle,
            turnID: turnID,
            correlationID: correlationID
        )
        guard audioScopeMatches(scope) || pendingAudioScopeMatches(scope) else { return nil }
        return scope
    }

    private func clearAudioStreamState() {
        activeAudioScope = nil
        audioAccumulator = nil
        audioGeneration = nil
        audioTerminalReceived = false
    }

    private func finishInvalidAudio(scope: HomeEventScope) {
        clearAudioStreamState()
        pendingAudioScope = nil
        audioTerminalReceived = true
        eventContinuation?.yield(.audioTerminal(scope, .invalid))
    }

    fileprivate static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private func resolvePending(id: HomePendingRequestID, response: HomeWireResponse) {
        guard let continuation = pending.removeValue(forKey: id.rawValue) else { return }
        continuation.resume(returning: response)
    }

    private func resolvePending(id: HomePendingRequestID, throwing error: Error) {
        guard let continuation = pending.removeValue(forKey: id.rawValue) else { return }
        continuation.resume(throwing: error)
    }

    private func transportLost(
        generation lostGeneration: UInt64,
        decodingError: HomeWireDecodingError? = nil
    ) async {
        guard lostGeneration == generation, !closed else { return }
        socket = nil
        bridgeReady = false
        if let activeAudioScope {
            pendingAudioScope = activeAudioScope
        }
        clearAudioStreamState()
        let failure: Error = decodingError ?? HomeBridgeTransportError.disconnected
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: failure)
        }
        pendingPrompts.removeAll()
        eventContinuation?.finish(throwing: failure)
        eventContinuation = nil
        eventStream = nil
    }
}

private struct HomeWireResponse: @unchecked Sendable {
    let id: String
    let result: [String: Any]
    let errorCode: String?
}

private func decodeResponse(_ object: [String: Any]) throws -> HomeWireResponse {
    guard let id = object["id"] as? String,
          !id.isEmpty else { throw HomeWireDecodingError.invalidShape }
    let hasResult = object["result"] != nil
    let hasError = object["error"] != nil
    guard hasResult != hasError else { throw HomeWireDecodingError.invalidShape }
    let result = object["result"] as? [String: Any] ?? [:]
    let errorObject = object["error"] as? [String: Any]
    if hasResult, object["result"] is NSNull {
        throw HomeWireDecodingError.invalidShape
    }
    if hasError {
        guard let errorObject,
              jsonRPCErrorCode(errorObject["code"]) != nil else {
            throw HomeWireDecodingError.invalidShape
        }
    }
    let stableCode = (errorObject?["data"] as? [String: Any])?["code"] as? String
    return HomeWireResponse(
        id: id,
        result: result,
        // The numeric JSON-RPC code is transport metadata. Home's stable
        // failure vocabulary is carried by error.data.code; an error without
        // that safe code is still an error, but maps to protocol_error.
        errorCode: hasError ? (stableCode ?? HomeFailureCode.protocolError.rawValue) : nil
    )
}

private func jsonRPCErrorCode(_ value: Any?) -> Int? {
    intValue(value)
}

private func decodeReady(_ response: HomeWireResponse) throws -> HomeReadyWireResult {
    if let errorCode = response.errorCode {
        throw HomeBridgeWireFailure(code: errorCode)
    }
    let data = try JSONSerialization.data(withJSONObject: response.result)
    return try JSONDecoder().decode(HomeReadyWireResult.self, from: data)
}

private struct HomeReconnectWireResult {
    let status: HomeBridgeReadyStatus
    let reason: HomeWireReason?
    let unresolvedTurnID: String?
    let resumeCursor: String?
}

private func decodeReconnect(
    _ response: HomeWireResponse,
    binding: HomeConversationBinding
) throws -> HomeReconnectWireResult {
    if let errorCode = response.errorCode { throw HomeBridgeWireFailure(code: errorCode) }
    try requireKeys(response.result, allowed: [
        "schema", "status", "conversation_handle", "unresolved_turn", "turn_id", "resume_cursor", "reason",
    ])
    guard (intValue(response.result["schema"]) ?? 0) == 1,
          response.result["conversation_handle"] as? String == binding.conversationHandle,
          let statusString = response.result["status"] as? String,
          let status = HomeBridgeReadyStatus(rawValue: statusString) else {
        throw HomeWireDecodingError.invalidShape
    }
    return HomeReconnectWireResult(
        status: status,
        reason: (response.result["reason"] as? String).flatMap(HomeWireReason.init(rawValue:)),
        unresolvedTurnID: response.result["turn_id"] as? String
            ?? (response.result["unresolved_turn"] as? [String: Any])?["turn_id"] as? String,
        resumeCursor: response.result["resume_cursor"] as? String
            ?? (response.result["unresolved_turn"] as? [String: Any])?["resume_cursor"] as? String
    )
}

private struct HomeSubmissionWireResult {
    let status: String
    let turnID: String
    let correlationID: String
}

private func decodeSubmission(
    _ response: HomeWireResponse,
    binding: HomeConversationBinding
) throws -> HomeSubmissionWireResult {
    if let errorCode = response.errorCode { throw HomeBridgeWireFailure(code: errorCode) }
    try requireKeys(response.result, allowed: ["schema", "status", "conversation_handle", "turn_id", "correlation_id"])
    guard (intValue(response.result["schema"]) ?? 0) == 1,
          response.result["conversation_handle"] as? String == binding.conversationHandle,
          let status = response.result["status"] as? String,
          let turnID = response.result["turn_id"] as? String,
          let correlationID = response.result["correlation_id"] as? String,
          !turnID.isEmpty,
          !correlationID.isEmpty else {
        throw HomeWireDecodingError.invalidShape
    }
    return HomeSubmissionWireResult(status: status, turnID: turnID, correlationID: correlationID)
}

private struct HomeCorrelatedResult {
    let handle: String
    let turnID: String
    let correlationID: String
    let status: String
}

private func decodeCorrelatedResult(_ response: HomeWireResponse) throws -> HomeCorrelatedResult {
    if let errorCode = response.errorCode { throw HomeBridgeWireFailure(code: errorCode) }
    try requireKeys(response.result, allowed: ["schema", "status", "conversation_handle", "turn_id", "correlation_id"])
    guard (intValue(response.result["schema"]) ?? 0) == 1,
          let handle = response.result["conversation_handle"] as? String,
          let turnID = response.result["turn_id"] as? String,
          let correlationID = response.result["correlation_id"] as? String,
          let status = response.result["status"] as? String,
          !handle.isEmpty,
          !turnID.isEmpty,
          !correlationID.isEmpty,
          !status.isEmpty else {
        throw HomeWireDecodingError.invalidShape
    }
    return HomeCorrelatedResult(
        handle: handle,
        turnID: turnID,
        correlationID: correlationID,
        status: status
    )
}

private func decodeCommandResult(
    _ response: HomeWireResponse,
    binding: HomeConversationBinding
) throws -> HomeCommandResult {
    if let errorCode = response.errorCode { throw HomeBridgeWireFailure(code: errorCode) }
    try requireKeys(response.result, allowed: [
        "schema", "conversation_handle", "turn_id", "correlation_id", "name", "status", "code",
    ])
    guard (intValue(response.result["schema"]) ?? 0) == 1,
          let handle = response.result["conversation_handle"] as? String,
          handle == binding.conversationHandle,
          let correlationID = response.result["correlation_id"] as? String,
          let name = response.result["name"] as? String,
          let statusString = response.result["status"] as? String,
          let status = HomeCommandStatus(rawValue: statusString) else {
        throw HomeWireDecodingError.invalidShape
    }
    return HomeCommandResult(
        conversationHandle: handle,
        turnID: response.result["turn_id"] as? String,
        correlationID: correlationID,
        name: name,
        status: status,
        safeCode: (response.result["code"] as? String).flatMap(HomeFailureCode.init(rawValue:))
    )
}

private func responseString(_ response: HomeWireResponse, key: String) -> String? {
    response.result[key] as? String
}

private func mapOpenReason(_ reason: HomeWireReason) -> HomeBridgeFailure {
    switch reason {
    case .reconnectRequired: return .reconnectRequired
    case .routeUnavailable: return .route(.unavailable)
    case .routeUnauthorized: return .route(.unauthorized)
    case .routeIdentityMismatch: return .route(.identityMismatch)
    case .routeTimeout: return .route(.timeout)
    default: return .home(code: HomeFailureCode(rawValue: reason.rawValue) ?? .protocolError, phase: .open)
    }
}

private func failure(for error: Error, phase: HomeFailurePhase) -> HomeBridgeFailure {
    if let wire = error as? HomeBridgeWireFailure {
        if let code = HomeFailureCode(rawValue: wire.code) {
            return .home(code: code, phase: phase)
        }
        if let reason = HomeWireReason(rawValue: wire.code) { return mapOpenReason(reason) }
        return .home(code: .protocolError, phase: phase)
    }
    if error is HomeBridgeTransportError {
        return .home(code: .transportUnavailable, phase: phase)
    }
    return .home(code: .protocolError, phase: phase)
}

private struct HomeBridgeWireFailure: Error, Sendable {
    let code: String
}

private func requireKeys(_ object: [String: Any], allowed: Set<String>) throws {
    guard object.keys.allSatisfy(allowed.contains) else { throw HomeWireDecodingError.unknownField }
}

private func requireKeys(_ object: [String: Any], allowed: [String]) throws {
    try requireKeys(object, allowed: Set(allowed))
}

private func optionalString(_ object: [String: Any], key: String) throws -> String? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard let value = value as? String else { throw HomeWireDecodingError.invalidShape }
    return value
}

private func optionalNonEmptyString(_ object: [String: Any], key: String) throws -> String? {
    guard let value = try optionalString(object, key: key) else { return nil }
    guard !value.isEmpty else { throw HomeWireDecodingError.invalidShape }
    return value
}

private func optionalStringArray(_ object: [String: Any], key: String) throws -> [String]? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard let values = value as? [Any] else { throw HomeWireDecodingError.invalidShape }
    guard values.allSatisfy({ $0 is String }) else {
        throw HomeWireDecodingError.invalidShape
    }
    return values.compactMap { $0 as? String }
}

private func optionalBool(_ object: [String: Any], key: String) throws -> Bool? {
    guard let value = object[key] else { return nil }
    if value is NSNull { return nil }
    guard isJSONBoolean(value), let value = value as? Bool else {
        throw HomeWireDecodingError.invalidShape
    }
    return value
}

private func optionalEventKind(
    _ object: [String: Any],
    key: String
) throws -> HomeStandardEventKind? {
    guard let value = try optionalString(object, key: key) else { return nil }
    return HomeStandardEventKind(rawValue: value)
}

private func optionalFailureCode(
    _ object: [String: Any],
    key: String
) throws -> HomeFailureCode? {
    guard let value = try optionalString(object, key: key) else { return nil }
    guard let code = HomeFailureCode(rawValue: value) else {
        throw HomeWireDecodingError.invalidShape
    }
    return code
}

private func optionalISO8601Date(
    _ object: [String: Any],
    key: String
) throws -> Date? {
    guard let value = try optionalString(object, key: key) else { return nil }
    guard let date = URLSessionHomeBridgeSessionClient.parseISO8601Date(value) else {
        throw HomeWireDecodingError.invalidShape
    }
    return date
}

private func intValue(_ value: Any?) -> Int? {
    guard let value, !isJSONBoolean(value) else { return nil }
    if let value = value as? Int { return value }
    guard let value = value as? NSNumber else { return nil }
    let doubleValue = value.doubleValue
    guard doubleValue.isFinite,
          doubleValue.rounded() == doubleValue,
          let integer = Int(exactly: doubleValue) else {
        return nil
    }
    return integer
}

private func isJSONBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return value is Bool }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func responseMatchesPrompt(
    _ prompt: HomeStructuredPrompt,
    response: HomePromptResponse
) -> Bool {
    switch response {
    case .approval(let choice, _):
        return prompt.kind == .approval && !choice.isEmpty
    case .clarification(let answer):
        return prompt.kind == .clarification && !answer.isEmpty
    case .secret(let value):
        return prompt.kind == .secret && prompt.sensitive && !value.isEmpty
    case .sudo(let password):
        return prompt.kind == .sudo && prompt.sensitive && !password.isEmpty
    }
}
