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

    private func makeClient(
        socket: FakeWebSocketConnection? = nil,
        factory: FakeWebSocketConnectionFactory? = nil
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
            socketFactory: selectedFactory
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
    let socket: FakeWebSocketConnection
    var lastRequest: URLRequest?

    init(socket: FakeWebSocketConnection) {
        self.socket = socket
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        lastRequest = urlRequest
        return socket
    }
}

private final class FakeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private var queuedFrames: [WebSocketFrame] = []
    private var pendingReceives: [CheckedContinuation<WebSocketFrame, Error>] = []
    private(set) var sentTexts: [String] = []
    private(set) var closeCalled = false

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> WebSocketFrame {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceives.append(continuation)
        }
    }

    func close() async {
        closeCalled = true
        let continuations = pendingReceives
        pendingReceives.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: RelaySessionError.disconnected)
        }
    }

    func enqueue(_ frame: WebSocketFrame) {
        if let continuation = pendingReceives.first {
            pendingReceives.removeFirst()
            continuation.resume(returning: frame)
        } else {
            queuedFrames.append(frame)
        }
    }
}

private extension String {
    func jsonObject() throws -> [String: Any] {
        let data = Data(utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
