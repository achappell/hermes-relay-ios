import Foundation
import XCTest
@testable import HermesRelayIOS

final class URLSessionHermesSessionClientTests: XCTestCase {
    @MainActor
    func testNativeRemoteClosesEndThinkingPreserveTextAndReconnectWithoutReplay() async throws {
        for code: URLSessionWebSocketTask.CloseCode in [.normalClosure, .goingAway, .policyViolation] {
            let task = CloseNotificationWebSocketTask()
            let replacementTask = CloseNotificationWebSocketTask()
            let factory = FakeWebSocketConnectionFactory(sockets: [
                URLSessionWebSocketConnection(task: task),
                URLSessionWebSocketConnection(task: replacementTask),
            ])
            let loss = expectation(description: "Native close reported")
            let bridge = TransportLossBridge()
            let client = try makeClient(factory: factory, onTransportDisconnected: {
                bridge.store?.handleUnexpectedTransportLoss()
                loss.fulfill()
            })
            let barrier = ReconnectBarrier()
            let store = ConversationStore(client: client, sleep: { _ in await barrier.wait() })
            bridge.store = store
            await store.connect()
            store.draft = "pending turn"
            let coordinator = VoiceSessionCoordinator(
                store: store, input: CloseTestSpeechInput(), output: CloseTestAudioOutput()
            )
            let turnSent = expectation(description: "Turn sent")
            task.onTurnSend = { turnSent.fulfill() }
            let sending = Task { @MainActor in await coordinator.sendDraft() }
            await fulfillment(of: [turnSent], timeout: 1)
            let readingAgain = expectation(description: "Reader receives partial frame")
            task.onReceive = { readingAgain.fulfill() }
            task.deliver(.success(.string(json(["type": "text_delta", "text": "partial response"]))))
            await fulfillment(of: [readingAgain], timeout: 1)
            task.onReceive = nil
            task.notifyClose(code)
            await fulfillment(of: [loss], timeout: 1)
            await sending.value

            XCTAssertFalse(store.isSending)
            XCTAssertEqual(coordinator.state, .failed(RelaySessionError.disconnected.localizedDescription))
            XCTAssertEqual(store.messages.first(where: { $0.role == .assistant })?.text, "partial response")
            XCTAssertEqual(store.unconfirmedTurnText, "pending turn")
            XCTAssertEqual(store.draft, "pending turn")

            await barrier.release()
            await store.waitForReconnectToFinish()
            XCTAssertEqual(store.connectionState, .connected)
            XCTAssertEqual(factory.openCount, 2)
            XCTAssertEqual(task.sendCount, 2)
            XCTAssertEqual(replacementTask.sendCount, 1, "Reconnect sends hello, never replays the turn")
            await client.disconnect()
        }
    }

    @MainActor
    func testNativeCloseWhileIdleReconnectsButLocalDisconnectDoesNot() async throws {
        let task = CloseNotificationWebSocketTask()
        let replacement = CloseNotificationWebSocketTask()
        let factory = FakeWebSocketConnectionFactory(sockets: [
            URLSessionWebSocketConnection(task: task), URLSessionWebSocketConnection(task: replacement),
        ])
        let bridge = TransportLossBridge()
        let loss = expectation(description: "Idle close reported once")
        let client = try makeClient(factory: factory, onTransportDisconnected: {
            bridge.store?.handleUnexpectedTransportLoss()
            loss.fulfill()
        })
        let store = ConversationStore(client: client, sleep: { _ in })
        bridge.store = store
        await store.connect()
        task.notifyClose(.normalClosure)
        await fulfillment(of: [loss], timeout: 1)
        await store.waitForReconnectToFinish()
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(factory.openCount, 2)
        await client.disconnect()
        replacement.notifyClose(.normalClosure)
        XCTAssertFalse(store.isReconnecting)
    }

    func testNativeCloseFinishesPendingReceiveAndRejectsLaterOperations() async throws {
        for code: URLSessionWebSocketTask.CloseCode in [.normalClosure, .goingAway, .policyViolation] {
            let task = CloseNotificationWebSocketTask()
            let socket = URLSessionWebSocketConnection(task: task)
            let receiving = expectation(description: "Receive registered")
            task.onReceive = { receiving.fulfill() }
            let reader = Task { try await socket.receive() }
            await fulfillment(of: [receiving], timeout: 1)

            task.notifyClose(code)
            // A delayed receive callback must not double-resume or deliver data.
            task.deliver(.success(.string("late frame")))
            do {
                _ = try await reader.value
                XCTFail("Close must fail the pending receive")
            } catch let error as RelaySessionError {
                XCTAssertEqual(error, .disconnected)
            }
            do {
                try await socket.send(text: "must not be sent")
                XCTFail("Closed sockets must reject send")
            } catch let error as RelaySessionError {
                XCTAssertEqual(error, .disconnected)
            }
            do {
                _ = try await socket.receive()
                XCTFail("Closed sockets must reject receive")
            } catch let error as RelaySessionError {
                XCTAssertEqual(error, .disconnected)
            }
            XCTAssertEqual(task.sendCount, 0)
            await socket.close()
        }
    }

    func testNativeTaskCompletionWithoutReceiveCallbackFinishesReceive() async throws {
        let task = CloseNotificationWebSocketTask()
        let socket = URLSessionWebSocketConnection(task: task)
        let receiving = expectation(description: "Receive registered")
        task.onReceive = { receiving.fulfill() }
        let reader = Task { try await socket.receive() }
        await fulfillment(of: [receiving], timeout: 1)

        task.notifyCompletion()
        do {
            _ = try await reader.value
            XCTFail("Task completion must finish receive even without an error")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .disconnected)
        }
        await socket.close()
    }

    func testReceiveCallbackBeforeCloseDoesNotLoseDeliveredFrame() async throws {
        let task = CloseNotificationWebSocketTask()
        let socket = URLSessionWebSocketConnection(task: task)
        let receiving = expectation(description: "Receive registered")
        task.onReceive = { receiving.fulfill() }
        let reader = Task { try await socket.receive() }
        await fulfillment(of: [receiving], timeout: 1)
        task.deliver(.success(.string("partial response")))
        task.notifyClose(.normalClosure)

        let frame = try await reader.value
        XCTAssertEqual(frame, .text("partial response"))
        await socket.close()
    }

    @MainActor
    func testRemoteLossPreservesPartialResponseAndMarksTurnUnconfirmed() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let loss = expectation(description: "Transport loss reported")
        let client = try makeClient(socket: socket, onTransportDisconnected: { loss.fulfill() })
        let store = ConversationStore(client: client)
        await store.connect()
        store.draft = "pending turn"
        let receivedPartial = expectation(description: "Partial response received")
        let sent = expectation(description: "Turn sent")
        socket.onSend = { sent.fulfill() }
        let send = Task { @MainActor in
            await store.sendDraft { event in
                if case .textDelta = event { receivedPartial.fulfill() }
            }
        }
        await fulfillment(of: [sent], timeout: 1)
        socket.enqueue(.text(json(["type": "text_delta", "text": "partial response"])))
        await fulfillment(of: [receivedPartial], timeout: 1)
        socket.failNextReceive(with: CancellationError())
        await fulfillment(of: [loss], timeout: 1)
        await client.disconnect()
        _ = await send.value
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.messages.first(where: { $0.role == .assistant })?.text, "partial response")
        XCTAssertEqual(store.unconfirmedTurnText, "pending turn")
        XCTAssertEqual(store.draft, "pending turn")
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(socket.sentTexts.count, 2, "Only hello and the original turn were sent")
    }

    func testUnexpectedReceiveCancellationReportsTransportLoss() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let disconnected = expectation(description: "Unexpected cancellation reports transport loss")
        let client = try makeClient(socket: socket, onTransportDisconnected: { disconnected.fulfill() })
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "pending turn")

        socket.failNextReceive(with: CancellationError())
        await fulfillment(of: [disconnected], timeout: 1)
        // Cleanup also bounds the failing regression: never leave collect hung.
        await client.disconnect()
        do {
            _ = try await collect(stream)
            XCTFail("Unexpected cancellation must fail the turn")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testConnectSendsProtocolV1HelloAndWaitsForHelloAck() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack", "model": "test-model"])))
        let factory = FakeWebSocketConnectionFactory(socket: socket)
        let client = try makeClient(factory: factory)

        let metadata = try await client.connect()

        let hello = try XCTUnwrap(socket.sentTexts.first).jsonObject()
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["protocol_version"] as? Int, 1)
        XCTAssertEqual(hello["client_id"] as? String, "hermes-ios")
        XCTAssertEqual(hello["device_id"] as? String, "device-123")
        XCTAssertEqual(hello["display_name"] as? String, "Test Mac")
        XCTAssertEqual(metadata.model, "test-model")
        XCTAssertEqual(factory.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        await client.disconnect()
    }

    func testConnectRejectsAnAckWithTheWrongType() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "status", "text": "not an ack"])))
        let client = try makeClient(socket: socket)

        do {
            _ = try await client.connect()
            XCTFail("A connection must not succeed without hello_ack")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .helloAckMissing)
        }

        XCTAssertTrue(socket.closeCalled)
    }

    func testSendTurnIncludesUniqueTurnIDSessionIDTextAndLocalSTTSource() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        let metadata = try await client.connect()

        let first = await client.sendTurn(text: "first turn")
        let firstTurn = try XCTUnwrap(socket.sentTexts.last).jsonObject()
        socket.enqueue(.text(json(["type": "turn_end"])))
        _ = try await collect(first)

        let second = await client.sendTurn(text: "second turn")
        let secondTurn = try XCTUnwrap(socket.sentTexts.last).jsonObject()
        socket.enqueue(.text(json(["type": "turn_end"])))
        _ = try await collect(second)

        let firstTurnID = try XCTUnwrap(firstTurn["turn_id"] as? String)
        let secondTurnID = try XCTUnwrap(secondTurn["turn_id"] as? String)

        XCTAssertEqual(firstTurn["type"] as? String, "turn")
        XCTAssertEqual(firstTurn["protocol_version"] as? Int, 1)
        XCTAssertEqual(firstTurn["session_id"] as? String, metadata.sessionID)
        XCTAssertEqual(firstTurn["text"] as? String, "first turn")
        XCTAssertEqual(firstTurn["stt_source"] as? String, "local")
        XCTAssertNotEqual(firstTurnID, secondTurnID)

        await client.disconnect()
    }

    func testSendTurnStreamsNormalizedTextAndTurnCompletion() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "hello")
        socket.enqueue(.text(json(["type": "text_delta", "text": "Hel"])))
        socket.enqueue(.text(json(["type": "text_delta", "text": "Hello"])))
        socket.enqueue(.text(json(["type": "turn_end"])))

        let events = try await collect(stream)
        let turnID = try XCTUnwrap(socket.sentTexts.last).jsonObject()["turn_id"] as? String
        let completedTurnID = try XCTUnwrap(turnID)

        XCTAssertEqual(events, [.textDelta("Hel"), .textDelta("lo"), .turnComplete(turnID: completedTurnID)])

        await client.disconnect()
    }

    func testBinaryFramesBecomeAudioChunksOnlyAfterAudioStart() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "speak")
        socket.enqueue(.text(json(["type": "audio_start", "payload": [:] as [String: Any]])))
        socket.enqueue(.binary(Data([0, 1, 2, 3])))
        socket.enqueue(.text(json(["type": "audio_end"])))
        socket.enqueue(.text(json(["type": "turn_end"])))

        let events = try await collect(stream)

        XCTAssertEqual(events[0], .audioStart(AudioFormat(sampleRate: 24000, channels: 1, sampleWidth: 2)))
        XCTAssertEqual(events[1], .audioChunk(Data([0, 1, 2, 3])))
        XCTAssertEqual(events[2], .audioEnd)

        await client.disconnect()
    }

    func testWAVFileFramesDoNotBecomeUnexpectedBinaryAudio() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "/voice tts")
        socket.enqueue(.text(json(["type": "audio_file_start", "content_type": "audio/wav"])))
        socket.enqueue(.binary(Data([0, 1, 2, 3])))
        socket.enqueue(.text(json(["type": "audio_file_end"])))
        socket.enqueue(.text(json(["type": "turn_end"])))

        let events = try await collect(stream)

        XCTAssertEqual(events, [
            .audioFileStart(contentType: "audio/wav"),
            .audioFileChunk(Data([0, 1, 2, 3])),
            .audioFileEnd,
            .turnComplete(turnID: try XCTUnwrap(socket.sentTexts.last?.jsonObject()["turn_id"] as? String)),
        ])

        await client.disconnect()
    }

    func testServerErrorFinishesTheTurnWithAnActionableError() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "fail")
        socket.enqueue(.text(json(["type": "error", "payload": ["message": "relay unavailable"] as [String: Any]])))

        let events = try await collect(stream)
        XCTAssertEqual(events, [.error("relay unavailable")])

        await client.disconnect()
    }

    func testMalformedJSONFinishesTheTurnWithAContentSafeNormalizationError() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "malformed")
        socket.enqueue(.text("not-json"))

        do {
            _ = try await collect(stream)
            XCTFail("Malformed JSON must finish the active stream with an error")
        } catch let error as HermesEventNormalizationError {
            XCTAssertEqual(error, .invalidJSON)
        }

        XCTAssertTrue(socket.closeCalled)
        await client.disconnect()
    }

    func testNonObjectJSONFinishesTheTurnWithAContentSafeNormalizationError() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "array frame")
        socket.enqueue(.text("[]"))

        do {
            _ = try await collect(stream)
            XCTFail("Non-object JSON must finish the active stream with an error")
        } catch let error as HermesEventNormalizationError {
            XCTAssertEqual(error, .nonObjectJSON)
        }

        XCTAssertTrue(socket.closeCalled)
        await client.disconnect()
    }

    func testDisconnectClosesTheSocketAndCancelsTheSingleReader() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "cancel me")

        await client.disconnect()

        XCTAssertTrue(socket.closeCalled)
        do {
            _ = try await collect(stream)
            XCTFail("Disconnect must finish the active stream with cancellation")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    func testReceiveFailureClearsTheSessionSoTheNextConnectOpensANewSocket() async throws {
        let firstSocket = FakeWebSocketConnection()
        firstSocket.enqueue(.text(json(["type": "hello_ack"])))
        let secondSocket = FakeWebSocketConnection()
        secondSocket.enqueue(.text(json(["type": "hello_ack"])))
        let factory = FakeWebSocketConnectionFactory(sockets: [firstSocket, secondSocket])
        let client = try makeClient(factory: factory)

        _ = try await client.connect()
        let stream = await client.sendTurn(text: "connection failure")
        firstSocket.failNextReceive()

        do {
            _ = try await collect(stream)
            XCTFail("A receive failure must finish the active stream")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .disconnected)
        }

        _ = try await client.connect()

        XCTAssertEqual(factory.openCount, 2)
        XCTAssertTrue(firstSocket.closeCalled)
        await client.disconnect()
    }

    func testSendTimeoutClearsTheSessionAndFinishesTheActiveStream() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        socket.sendDelayNanoseconds = 100_000_000
        let client = try makeClient(socket: socket, sendTimeoutNanoseconds: 1_000_000)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "network unavailable")

        do {
            _ = try await collect(stream)
            XCTFail("A send timeout must finish the active stream")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .connectionTimedOut)
        }

        XCTAssertTrue(socket.closeCalled)
        await client.disconnect()
    }

    private func makeClient(
        socket: FakeWebSocketConnection? = nil,
        factory: FakeWebSocketConnectionFactory? = nil,
        sendTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onTransportDisconnected: (@MainActor @Sendable () -> Void)? = nil
    ) throws -> URLSessionHermesSessionClient {
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://relay.example.test/session")!,
            clientID: "hermes-ios",
            deviceID: "device-123",
            displayName: "Test Mac"
        )
        let selectedFactory: any WebSocketConnectionFactory
        if let factory {
            selectedFactory = factory
        } else {
            selectedFactory = FakeWebSocketConnectionFactory(socket: try XCTUnwrap(socket))
        }
        return URLSessionHermesSessionClient(
            profile: profile,
            token: "test-token",
            socketFactory: selectedFactory,
            sendTimeoutNanoseconds: sendTimeoutNanoseconds,
            onTransportDisconnected: onTransportDisconnected
        )
    }

    private func collect(_ stream: AsyncThrowingStream<HermesEvent, Error>) async throws -> [HermesEvent] {
        var events: [HermesEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class CloseNotificationWebSocketTask: WebSocketTask, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode
    var delegate: (any URLSessionTaskDelegate)?
    private let lock = NSLock()
    private var receiveCallback: (@Sendable (Result<Message, Error>) -> Void)?
    private var queued: [Result<Message, Error>] = []
    private var receiveObserver: (@Sendable () -> Void)?
    private var turnObserver: (@Sendable () -> Void)?
    var onReceive: (@Sendable () -> Void)? {
        get { lock.withLock { receiveObserver } }
        set { lock.withLock { receiveObserver = newValue } }
    }
    var onTurnSend: (@Sendable () -> Void)? {
        get { lock.withLock { turnObserver } }
        set { lock.withLock { turnObserver = newValue } }
    }
    private var sends = 0
    var sendCount: Int { lock.withLock { sends } }

    func receive(completionHandler: @escaping @Sendable (Result<Message, Error>) -> Void) {
        let result: Result<Message, Error>? = lock.withLock {
            if !queued.isEmpty { return queued.removeFirst() }
            receiveCallback = completionHandler
            return nil
        }
        if let result { completionHandler(result) }
        onReceive?()
    }

    func send(_ message: Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { sends += 1 }
        if case .string(let text) = message,
           let object = try? text.jsonObject(), object["type"] as? String == "hello" {
            deliver(.success(.string("{\"type\":\"hello_ack\"}")))
        } else {
            onTurnSend?()
        }
        completionHandler(nil)
    }

    func cancel(with closeCode: CloseCode, reason: Data?) {}

    func notifyCompletion() {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost")!)
        delegate?.urlSession?(URLSession.shared, task: task, didCompleteWithError: nil)
    }

    func notifyClose(_ code: CloseCode) {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost")!)
        (delegate as? URLSessionWebSocketDelegate)?.urlSession?(
            URLSession.shared, webSocketTask: task, didCloseWith: code,
            reason: Data("server-controlled private reason".utf8)
        )
    }

    func deliver(_ result: Result<Message, Error>) {
        let callback = lock.withLock {
            if receiveCallback == nil { queued.append(result) }
            let callback = receiveCallback
            receiveCallback = nil
            return callback
        }
        callback?(result)
    }

}

@MainActor
private final class TransportLossBridge {
    weak var store: ConversationStore?
}

private actor ReconnectBarrier {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private struct CloseTestSpeechInput: SpeechInput {
    func authorization() async -> SpeechAuthorization { .notDetermined }
    func requestAuthorization() async -> SpeechAuthorization { .notDetermined }
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> { throw SpeechInputError.notAuthorized }
    func finish() async {}
    func cancel() async {}
}

private struct CloseTestAudioOutput: AudioOutput {
    func start(format: AudioFormat) async throws {}
    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness { .ready }
    func finish() async throws {}
    func stop() async {}
    func playbackPosition() async -> TimeInterval? { nil }
}

private final class FakeWebSocketConnectionFactory: WebSocketConnectionFactory, @unchecked Sendable {
    private var sockets: [any WebSocketConnection]
    var lastRequest: URLRequest?
    private(set) var openCount = 0

    init(socket: FakeWebSocketConnection) {
        self.sockets = [socket]
    }

    init(sockets: [any WebSocketConnection]) {
        self.sockets = sockets
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        openCount += 1
        lastRequest = urlRequest
        return sockets.removeFirst()
    }
}

private final class FakeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let stateLock = NSLock()
    private var queuedFrames: [WebSocketFrame] = []
    private var pendingReceives: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var nextReceiveError: Error?
    var sendDelayNanoseconds: UInt64?
    var onSend: (@Sendable () -> Void)?
    private(set) var sentTexts: [String] = []
    private(set) var closeCalled = false

    func send(text: String) async throws {
        if let sendDelayNanoseconds {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        appendSentText(text)
        onSend?()
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            receive(using: continuation)
        }
    }

    func close() async {
        let continuations = closeState()
        for continuation in continuations {
            continuation.resume(throwing: RelaySessionError.disconnected)
        }
    }

    func enqueue(_ frame: WebSocketFrame) {
        stateLock.lock()
        guard !pendingReceives.isEmpty else {
            queuedFrames.append(frame)
            stateLock.unlock()
            return
        }
        let continuation = pendingReceives.removeFirst()
        stateLock.unlock()
        continuation.resume(returning: frame)
    }

    func failNextReceive(with error: Error = RelaySessionError.disconnected) {
        stateLock.lock()
        guard !pendingReceives.isEmpty else {
            nextReceiveError = error
            stateLock.unlock()
            return
        }
        let continuation = pendingReceives.removeFirst()
        stateLock.unlock()
        continuation.resume(throwing: error)
    }

    private func appendSentText(_ text: String) {
        stateLock.lock()
        sentTexts.append(text)
        stateLock.unlock()
    }

    private func receive(using continuation: CheckedContinuation<WebSocketFrame, Error>) {
        stateLock.lock()
        if let nextReceiveError {
            self.nextReceiveError = nil
            stateLock.unlock()
            continuation.resume(throwing: nextReceiveError)
            return
        }
        if !queuedFrames.isEmpty {
            let frame = queuedFrames.removeFirst()
            stateLock.unlock()
            continuation.resume(returning: frame)
            return
        }
        pendingReceives.append(continuation)
        stateLock.unlock()
    }

    private func closeState() -> [CheckedContinuation<WebSocketFrame, Error>] {
        stateLock.lock()
        closeCalled = true
        let continuations = pendingReceives
        pendingReceives.removeAll()
        stateLock.unlock()
        return continuations
    }
}

private extension String {
    func jsonObject() throws -> [String: Any] {
        let data = Data(utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
