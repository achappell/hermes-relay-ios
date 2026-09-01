import Foundation
import XCTest
@testable import HermesRelayIOS

final class URLSessionHermesSessionClientTests: XCTestCase {
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
        sendTimeoutNanoseconds: UInt64 = 10_000_000_000
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
            sendTimeoutNanoseconds: sendTimeoutNanoseconds
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

private final class FakeWebSocketConnectionFactory: WebSocketConnectionFactory, @unchecked Sendable {
    private var sockets: [FakeWebSocketConnection]
    var lastRequest: URLRequest?
    private(set) var openCount = 0

    init(socket: FakeWebSocketConnection) {
        self.sockets = [socket]
    }

    init(sockets: [FakeWebSocketConnection]) {
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
    private(set) var sentTexts: [String] = []
    private(set) var closeCalled = false

    func send(text: String) async throws {
        if let sendDelayNanoseconds {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        appendSentText(text)
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
