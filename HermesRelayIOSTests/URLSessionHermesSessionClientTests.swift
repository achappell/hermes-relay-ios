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

    func testInterruptSendsTheActiveTurnCommandAndWaitsForConfirmation() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json([
            "type": "hello_ack",
            "capabilities": ["text_stream", "interrupt"],
        ])))
        let encode: @Sendable ([String: Any]) -> String = { object in
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        socket.onSendText = { text in
            guard let object = try? text.jsonObject(),
                  object["type"] as? String == "interrupt",
                  let turnID = object["turn_id"] as? String,
                  let sessionID = object["session_id"] as? String else {
                return
            }
            socket.enqueue(.text(encode([
                "type": "audio_abort",
                "turn_id": turnID,
                "session_id": sessionID,
                "error": "client interrupt",
            ])))
            socket.enqueue(.binary(Data([9, 8, 7, 6])))
            socket.enqueue(.text(encode([
                "type": "turn_interrupted",
                "turn_id": turnID,
                "session_id": sessionID,
                "reason": "turn interrupted",
            ])))
        }
        let client = try makeClient(socket: socket)
        let metadata = try await client.connect()
        XCTAssertEqual(metadata.capabilities, ["text_stream", "interrupt"])

        let stream = await client.sendTurn(text: "stop this")
        let interruptConfirmed = await client.interruptActiveTurn()
        XCTAssertTrue(interruptConfirmed)

        let events = try await collect(stream)
        XCTAssertEqual(events.count, 2)
        guard case .audioAbort(let turnID, let reason) = events[0] else {
            return XCTFail("Expected typed audio abort")
        }
        XCTAssertFalse(turnID.isEmpty)
        XCTAssertEqual(reason, "client interrupt")
        guard case .turnInterrupted(let confirmedTurnID, let confirmedReason) = events[1] else {
            return XCTFail("Expected typed interruption confirmation")
        }
        XCTAssertEqual(confirmedTurnID, turnID)
        XCTAssertEqual(confirmedReason, "turn interrupted")

        let interrupt = try XCTUnwrap(socket.sentTexts.last).jsonObject()
        XCTAssertEqual(interrupt["type"] as? String, "interrupt")
        XCTAssertEqual(interrupt["protocol_version"] as? Int, 1)
        XCTAssertEqual(interrupt["session_id"] as? String, metadata.sessionID)
        XCTAssertEqual(interrupt["turn_id"] as? String, turnID)

        // A terminal interruption must not poison the still-connected reader
        // if one stale binary frame was already buffered by the socket.
        socket.enqueue(.text(encode([
            "type": "text_delta",
            "turn_id": turnID,
            "text": "stale response",
        ])))
        socket.enqueue(.text(encode(["type": "turn_end", "turn_id": turnID])))
        socket.enqueue(.binary(Data([0, 1, 2, 3])))
        let nextStream = await client.sendTurn(text: "next turn")
        socket.enqueue(.text(json(["type": "turn_end"])))
        let nextEvents = try await collect(nextStream)
        XCTAssertEqual(nextEvents.count, 1)
        guard case .turnComplete = nextEvents[0] else {
            return XCTFail("Expected the next turn to remain usable")
        }
        await client.disconnect()
    }

    func testInterruptCapabilityCanBeReadFromNestedHelloAckPayload() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json([
            "type": "hello_ack",
            "payload": ["capabilities": ["interrupt"]] as [String: Any],
        ])))
        let client = try makeClient(socket: socket)

        let metadata = try await client.connect()

        XCTAssertTrue(metadata.supportsInterrupt)
        await client.disconnect()
    }

    func testInterruptConfirmationTimeoutFallsBackWithoutClosingTheSocket() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack", "capabilities": ["interrupt"]])))
        let client = try makeClient(
            socket: socket,
            interruptionConfirmationTimeoutNanoseconds: 10_000_000
        )
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "timeout")

        let interruptionConfirmed = await client.interruptActiveTurn()
        XCTAssertFalse(interruptionConfirmed)
        XCTAssertFalse(socket.closeCalled)
        XCTAssertEqual(try XCTUnwrap(socket.sentTexts.last).jsonObject()["type"] as? String, "interrupt")
        _ = stream
        await client.disconnect()
    }

    func testInterruptCapabilityAbsentDoesNotSendAnInterrupt() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack", "capabilities": ["text_stream"]])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        _ = await client.sendTurn(text: "legacy stop")

        let interruptSent = await client.interruptActiveTurn()
        XCTAssertFalse(interruptSent)
        XCTAssertEqual(socket.sentTexts.count, 2)
        XCTAssertEqual(try XCTUnwrap(socket.sentTexts.last).jsonObject()["type"] as? String, "turn")
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

    func testSendTurnIgnoresLateFramesForAnotherTurn() async throws {
        let socket = FakeWebSocketConnection()
        socket.enqueue(.text(json(["type": "hello_ack"])))
        let client = try makeClient(socket: socket)
        _ = try await client.connect()

        let stream = await client.sendTurn(text: "current")
        let turnID = try XCTUnwrap(socket.sentTexts.last?.jsonObject()["turn_id"] as? String)
        socket.enqueue(.text(json([
            "type": "text_delta",
            "turn_id": "stale-turn",
            "text": "stale response",
        ])))
        socket.enqueue(.text(json([
            "type": "text_delta",
            "turn_id": turnID,
            "text": "fresh response",
        ])))
        socket.enqueue(.text(json(["type": "turn_end", "turn_id": turnID])))

        let events = try await collect(stream)

        XCTAssertEqual(events, [
            .textDelta("fresh response"),
            .turnComplete(turnID: turnID),
        ])
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
        socket.enqueue(.text(json(["type": "turn_end"])))
        // Hermes can announce turn completion before the file boundary. The
        // transport must keep the typed stream open until that file is
        // delivered, or the coordinator cannot play the response.
        socket.enqueue(.text(json(["type": "audio_file_end"])))

        let events = try await collect(stream)

        XCTAssertEqual(events, [
            .audioFileStart(contentType: "audio/wav"),
            .audioFileChunk(Data([0, 1, 2, 3])),
            .turnComplete(turnID: try XCTUnwrap(socket.sentTexts.last?.jsonObject()["turn_id"] as? String)),
            .audioFileEnd,
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

    func testReplacementSocketStartsAFreshSessionAndIgnoresLateOldFrames() async throws {
        let firstSocket = FakeWebSocketConnection()
        firstSocket.enqueue(.text(json(["type": "hello_ack"])))
        let replacementSocket = FakeWebSocketConnection()
        replacementSocket.enqueue(.text(json(["type": "hello_ack"])))
        let factory = FakeWebSocketConnectionFactory(sockets: [firstSocket, replacementSocket])
        let client = try makeClient(factory: factory)

        let firstMetadata = try await client.connect()
        let oldStream = await client.sendTurn(text: "old turn")
        firstSocket.failNextReceive()

        do {
            _ = try await collect(oldStream)
            XCTFail("The old turn must finish when its socket fails")
        } catch let error as RelaySessionError {
            XCTAssertEqual(error, .disconnected)
        }

        let replacementMetadata = try await client.connect()
        XCTAssertNotEqual(replacementMetadata.sessionID, firstMetadata.sessionID)

        let newStream = await client.sendTurn(text: "new turn")
        let newTurnID = try XCTUnwrap(
            replacementSocket.sentTexts.last?.jsonObject()["turn_id"] as? String
        )
        firstSocket.enqueue(.text(json([
            "type": "text_delta",
            "turn_id": newTurnID,
            "text": "stale old response",
        ])))
        replacementSocket.enqueue(.text(json([
            "type": "text_delta",
            "turn_id": newTurnID,
            "text": "fresh response",
        ])))
        replacementSocket.enqueue(.text(json(["type": "turn_end", "turn_id": newTurnID])))

        let events = try await collect(newStream)

        XCTAssertEqual(events, [
            .textDelta("fresh response"),
            .turnComplete(turnID: newTurnID),
        ])
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
        interruptionConfirmationTimeoutNanoseconds: UInt64 = 2_000_000_000,
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
            interruptionConfirmationTimeoutNanoseconds: interruptionConfirmationTimeoutNanoseconds,
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
    var onSendText: (@Sendable (String) -> Void)?
    private(set) var sentTexts: [String] = []
    private(set) var closeCalled = false

    func send(text: String) async throws {
        if let sendDelayNanoseconds {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        appendSentText(text)
        onSend?()
        onSendText?(text)
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
