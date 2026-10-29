import Foundation
import XCTest
@testable import HermesRelayIOS

@MainActor
final class StandardSessionClientTests: XCTestCase {
    func testAuthenticatedSetupProbeCreatesNoConversationAndDoesNotAdvertiseVoice() async throws {
        let socket = StandardTestSocket()
        let factory = StandardTestFactory([socket])
        let token = "private-token/+?&=sentinel"
        let client = try makeClient(factory, token: token)
        try await client.checkConnection()
        XCTAssertEqual(socket.methods, ["gateway.ping"])
        XCTAssertTrue(socket.closed)
        let request = try XCTUnwrap(factory.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "token", value: token)])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(url.path, "/api/ws")
    }

    func testCreateUsesNativeContractAndKeepsForkSessionFieldNil() async throws {
        let socket = StandardTestSocket()
        let client = try makeClient(StandardTestFactory([socket]), targetProfile: "work")
        let metadata = try await client.connect()
        XCTAssertNil(metadata.sessionID)
        XCTAssertEqual(metadata.binding, .standard(sessionID: "conversation", storedSessionID: "conversation"))
        XCTAssertEqual(metadata.capabilities, ["text_stream", "interrupt"])
        let create = try XCTUnwrap(socket.frames.first { $0["method"] as? String == "session.create" })
        let params = try XCTUnwrap(create["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["profile"])
        XCTAssertEqual(params["profile"] as? String, "work")
        _ = try await client.connect()
        XCTAssertEqual(socket.methods, ["gateway.ping", "session.create"])
        await client.disconnect()
    }

    func testEventsBeforeAcknowledgementAreCorrelatedBufferedAndNormalizedByOneReader() async throws {
        let socket = StandardTestSocket()
        socket.onPrompt = { request in
            socket.event("message.start", payload: ["turn_id": "remote-turn"], sequence: 1)
            socket.event("reasoning.delta", payload: ["text": "considering"], sequence: 2)
            socket.event("tool.start", payload: ["tool_id": "tool", "name": "terminal", "args": ["private": "not a status"]], sequence: 3)
            socket.event("message.delta", payload: ["text": "Hello", "turn_id": "remote-turn", "segment": 0, "offset": 0], sequence: 4)
            socket.event("message.delta", payload: ["text": " world", "rendered": "Hello world", "turn_id": "remote-turn", "segment": 0, "offset": 5], sequence: 5)
            socket.event("tool.complete", payload: ["tool_id": "tool", "name": "terminal", "result": "private result"], sequence: 6)
            socket.complete(text: "Hello world", sequence: 7)
            socket.accept(request)
        }
        socket.delaySendCompletion = true
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let result = await standardCapture(await client.sendTurn(text: "one deliberate prompt"))
        XCTAssertNil(result.error)
        XCTAssertTrue(result.events.contains(.messageStart))
        XCTAssertTrue(result.events.contains(.thinkingDelta("considering")))
        XCTAssertTrue(result.events.contains(.textDelta("Hello")))
        XCTAssertTrue(result.events.contains(.textDelta(" world")))
        XCTAssertTrue(result.events.contains(.status(text: "Hermes is using a tool…", kind: "tool")))
        XCTAssertTrue(result.events.contains(.messageComplete(text: "Hello world", reasoning: "", failureReason: "")))
        XCTAssertEqual(result.events.filter { if case .turnComplete = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(socket.maximumConcurrentReceives, 1)
        XCTAssertFalse(socket.closed, "A reply before send completion must not cancel the healthy sender")
        let prompt = try XCTUnwrap(socket.frames.first { $0["method"] as? String == "prompt.submit" })
        let params = try XCTUnwrap(prompt["params"] as? [String: Any])
        XCTAssertEqual(params["submission_id"] as? String, prompt["id"] as? String)
        XCTAssertEqual(params["text"] as? String, "one deliberate prompt")
        await client.disconnect()
    }

    func testWrongSessionAdmissionGenerationEpochAndDuplicateEventsNeverReachTranscript() async throws {
        let socket = StandardTestSocket()
        socket.onPrompt = { request in
            socket.event("message.delta", payload: ["text": "other session"], sequence: 10, session: "other")
            socket.event("message.delta", payload: ["text": "old admission"], sequence: 11, admission: "old")
            socket.event("message.delta", payload: ["text": "wrong execution"], sequence: 12, execution: 2)
            socket.event("message.delta", payload: ["text": "old authority"], sequence: 13, epoch: 6)
            socket.event("message.delta", payload: ["text": "old replay"], sequence: 14, replay: "old")
            socket.event("message.start", payload: ["turn_id": "own"], sequence: 1)
            socket.event("message.delta", payload: ["text": "wrong turn", "turn_id": "not-own"], sequence: 2)
            socket.event("message.delta", payload: ["text": "safe", "turn_id": "own", "segment": 0, "offset": 0], sequence: 3)
            socket.event("message.delta", payload: ["text": "safe", "turn_id": "own", "segment": 0, "offset": 0], sequence: 4)
            socket.event("message.delta", payload: ["text": "duplicate sequence"], sequence: 3)
            socket.complete(text: "safe", sequence: 5)
            socket.accept(request, started: true)
        }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let result = await standardCapture(await client.sendTurn(text: "prompt"))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }, ["safe"])
        await client.disconnect()
    }

    func testUTF16OffsetGapFailsVisiblyWithoutInventingOrReplayingText() async throws {
        let socket = StandardTestSocket()
        socket.onPrompt = { request in
            socket.event("message.delta", payload: ["text": "🤖", "segment": 0, "offset": 0], sequence: 1)
            socket.event("message.delta", payload: ["text": "missing prefix", "segment": 0, "offset": 3], sequence: 2)
            socket.accept(request)
        }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let result = await standardCapture(await client.sendTurn(text: "prompt"))
        XCTAssertEqual(result.error, .invalidResponse)
        XCTAssertEqual(result.events, [.textDelta("🤖")])
        let blocked = await standardCapture(await client.sendTurn(text: "not replayed"))
        XCTAssertEqual(blocked.error, .deliveryUncertain)
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
        await client.disconnect()
    }

    func testTransportLossResumesDurableConversationWithoutReplayAndKeepsUncertainty() async throws {
        let first = StandardTestSocket()
        let second = StandardTestSocket()
        let loss = expectation(description: "Unexpected transport loss")
        let client = try makeClient(StandardTestFactory([first, second]), onLoss: { loss.fulfill() })
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "must not be replayed")
        var iterator = stream.makeAsyncIterator()
        first.event("message.start", payload: [:], sequence: 1)
        let start = try await iterator.next()
        XCTAssertEqual(start, .messageStart)
        first.fail(NSError(domain: "private endpoint?token=secret", code: 401))
        await fulfillment(of: [loss], timeout: 1)
        do {
            _ = try await iterator.next()
            XCTFail("Transport loss must finish the stream")
        } catch { XCTAssertEqual(error as? StandardSessionError, .disconnected) }
        let resumed = try await client.connect()
        XCTAssertEqual(resumed.binding, .standard(sessionID: "conversation", storedSessionID: "conversation"))
        XCTAssertEqual(second.methods, ["gateway.ping", "session.resume"])
        let resume = try XCTUnwrap(second.frames.last?["params"] as? [String: Any])
        XCTAssertEqual(Set(resume.keys), ["session_id", "profile", "omit_messages"])
        XCTAssertEqual(resume["session_id"] as? String, "conversation")
        let blocked = await standardCapture(await client.sendTurn(text: "not sent"))
        XCTAssertEqual(blocked.error, .deliveryUncertain)
        XCTAssertEqual(first.methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertFalse(second.methods.contains("prompt.submit"))
        await client.disconnect()
    }

    func testFailedResumeNeverCreatesReplacementEvenAcrossRepeatedAttempts() async throws {
        let sockets = [StandardTestSocket(), StandardTestSocket()]
        for socket in sockets { socket.rejectResume = true }
        let client = try makeClient(StandardTestFactory(sockets), durable: "saved-durable")
        for _ in sockets {
            do { _ = try await client.connect(); XCTFail("Resume must fail visibly") }
            catch { XCTAssertEqual(error as? StandardSessionError, .resumeFailed) }
        }
        for socket in sockets {
            XCTAssertEqual(socket.methods, ["gateway.ping", "session.resume"])
            XCTAssertTrue(socket.closed)
        }
        await client.disconnect()
    }

    func testResumeDoesNotImportHistoryOrPendingPromptsAndBlocksUnsupportedInteraction() async throws {
        let socket = StandardTestSocket()
        socket.snapshot = standardSnapshot(extra: [
            "messages": [["role": "user", "content": "old prompt never replay"]],
            "prompts": [["kind": "approval", "prompt_id": "protected", "choices": ["approve"]]],
        ])
        let client = try makeClient(StandardTestFactory([socket]), durable: "conversation")
        do { _ = try await client.connect(); XCTFail("Pending protected prompts are unsupported") }
        catch { XCTAssertEqual(error as? StandardSessionError, .unsupportedInteraction) }
        XCTAssertEqual(socket.methods, ["gateway.ping", "session.resume"])
        XCTAssertFalse(socket.sentText.contains("old prompt never replay"))
        await client.disconnect()
    }

    func testUnsupportedStructuredNotificationsFailVisiblyWithoutSendingAnApproval() async throws {
        for type in ["approval.request", "clarify.request", "secret.request", "sudo.request", "connection.request"] {
            let socket = StandardTestSocket()
            socket.onPrompt = { request in
                socket.event(type, payload: ["request_id": "protected", "choices": ["yes"], "text": "secret-sentinel"], sequence: 1)
                socket.accept(request)
            }
            let client = try makeClient(StandardTestFactory([socket]))
            _ = try await client.connect()
            let failed = await standardCapture(await client.sendTurn(text: "prompt"))
            XCTAssertEqual(failed.error, .unsupportedInteraction)
            XCTAssertTrue(failed.events.isEmpty)
            let blocked = await standardCapture(await client.sendTurn(text: "never approve or resend"))
            XCTAssertEqual(blocked.error, .deliveryUncertain)
            XCTAssertEqual(socket.methods, ["gateway.ping", "session.create", "prompt.submit"])
            await client.disconnect()
        }
    }

    func testServerRequestsReceiveOnlyMethodNotFoundAndNoProtectedPayloadIsEchoed() async throws {
        let socket = StandardTestSocket()
        socket.onPrompt = { request in
            socket.accept(request)
            socket.enqueue(.text(standardJSON([
                "jsonrpc": "2.0", "id": "server-request", "method": "sudo",
                "params": ["session_id": "conversation", "password": "protected-sentinel"],
            ])))
        }
        let rejection = expectation(description: "Server request safely declined")
        socket.onServerResponse = { rejection.fulfill() }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let result = await standardCapture(await client.sendTurn(text: "prompt"))
        XCTAssertEqual(result.error, .unsupportedInteraction)
        await fulfillment(of: [rejection], timeout: 1)
        let response = try XCTUnwrap(socket.frames.first { $0["id"] as? String == "server-request" })
        XCTAssertNil(response["result"])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertFalse(socket.sentText.contains("protected-sentinel"))
        await client.disconnect()
    }

    func testInterruptUsesExecutionFenceWaitsForTerminalAndMultiplexesWithText() async throws {
        let socket = StandardTestSocket()
        let interrupted = expectation(description: "Interrupt sent")
        socket.onInterrupt = { request in
            let params = standardObject(request)["params"] as? [String: Any]
            XCTAssertEqual(params?["execution_generation"] as? Int, 1)
            socket.reply(request, result: [
                "ref": ["profile_id": "private-profile", "session_id": "conversation"],
                "instance_id": "instance", "authority_epoch": 7, "revision": 2,
                "execution_generation": 1, "execution_state": "running",
            ])
            socket.complete(text: "wrong session", sequence: 2, session: "other", status: "interrupted")
            socket.event("message.delta", payload: ["text": "partial"], sequence: 2)
            interrupted.fulfill()
        }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "prompt")
        var iterator = stream.makeAsyncIterator()
        socket.event("message.start", payload: [:], sequence: 1)
        _ = try await iterator.next()
        let stopping = Task { await client.interruptActiveTurnOutcome() }
        await fulfillment(of: [interrupted], timeout: 1)
        let blocked = await standardCapture(await client.sendTurn(text: "must not queue"))
        XCTAssertEqual(blocked.error, .turnAlreadyActive)
        socket.complete(text: "partial", sequence: 3, status: "interrupted")
        let outcome = await stopping.value
        XCTAssertEqual(outcome, .confirmed)
        var tail: [HermesEvent] = []
        while let event = try await iterator.next() { tail.append(event) }
        XCTAssertTrue(tail.contains(.textDelta("partial")))
        XCTAssertEqual(tail.filter { if case .turnInterrupted = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(socket.methods.filter { $0 == "session.interrupt" }.count, 1)
        XCTAssertEqual(socket.maximumConcurrentReceives, 1)
        await client.disconnect()
    }

    func testUnconfirmedInterruptTimesOutWithoutClaimingCancellationOrResending() async throws {
        let socket = StandardTestSocket()
        socket.onInterrupt = { request in
            socket.reply(request, result: [
                "ref": ["session_id": "conversation"], "authority_epoch": 7,
                "execution_generation": 1, "execution_state": "running",
            ])
        }
        let client = try makeClient(StandardTestFactory([socket]), timeout: 80_000_000)
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "prompt")
        var iterator = stream.makeAsyncIterator()
        socket.event("message.start", payload: [:], sequence: 1)
        _ = try await iterator.next()
        let outcome = await client.interruptActiveTurnOutcome()
        XCTAssertEqual(outcome, .uncertain)
        let blocked = await standardCapture(await client.sendTurn(text: "must not queue"))
        XCTAssertEqual(blocked.error, .turnAlreadyActive)
        await client.disconnect()
        do { _ = try await iterator.next(); XCTFail("Disconnect must end the observer") }
        catch { XCTAssertEqual(error as? StandardSessionError, .disconnected) }
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
    }

    func testCancellingStreamDoesNotFreeRemoteBusyFence() async throws {
        let socket = StandardTestSocket()
        let observed = expectation(description: "Observer saw start")
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "prompt")
        let observing = Task {
            do {
                for try await event in stream {
                    if event == .messageStart { observed.fulfill() }
                }
            } catch {}
        }
        socket.event("message.start", payload: [:], sequence: 1)
        await fulfillment(of: [observed], timeout: 1)
        observing.cancel()
        await observing.value
        let blocked = await standardCapture(await client.sendTurn(text: "must not queue"))
        XCTAssertEqual(blocked.error, .turnAlreadyActive)
        socket.complete(text: "", sequence: 2)
        await client.disconnect()
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
    }

    func testNewConversationFailureKeepsUncertaintyAndExplicitLeaveSendsNothing() async throws {
        let first = StandardTestSocket()
        let second = StandardTestSocket()
        second.rejectCreate = true
        let client = try makeClient(StandardTestFactory([first, second]))
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "uncertain prompt")
        await client.disconnect()
        _ = await standardCapture(stream)
        do { _ = try await client.createNewConversation(); XCTFail("New failed") }
        catch { XCTAssertEqual(error as? StandardSessionError, .requestRejected) }
        let blocked = await standardCapture(await client.sendTurn(text: "not sent"))
        XCTAssertEqual(blocked.error, .deliveryUncertain)
        let sent = first.sentText + second.sentText
        await client.leaveConversation()
        XCTAssertEqual(first.sentText + second.sentText, sent)
        XCTAssertEqual(second.methods, ["gateway.ping", "session.create"])
    }

    func testSuccessfulDeliberateNewConversationIsOnlyAutomaticUncertaintyReset() async throws {
        let first = StandardTestSocket()
        let replacement = StandardTestSocket()
        replacement.snapshot = standardSnapshot(session: "new-conversation")
        replacement.onPrompt = { request in
            replacement.accept(request, session: "new-conversation")
            replacement.complete(text: "new answer", sequence: 1, session: "new-conversation")
        }
        let client = try makeClient(StandardTestFactory([first, replacement]))
        _ = try await client.connect()
        let old = await client.sendTurn(text: "old uncertain")
        await client.disconnect()
        _ = await standardCapture(old)
        let metadata = try await client.createNewConversation()
        XCTAssertEqual(metadata.binding, .standard(sessionID: "new-conversation", storedSessionID: "new-conversation"))
        let answer = await standardCapture(await client.sendTurn(text: "new deliberate"))
        XCTAssertNil(answer.error)
        XCTAssertTrue(answer.events.contains(.textDelta("new answer")))
        XCTAssertFalse(replacement.sentText.contains("old uncertain"))
        await client.disconnect()
    }

    func testTimeoutMalformedFrameAndServerErrorsAreBoundedAndContentSafe() async throws {
        let sentinel = "SENTINEL-TOKEN-private"
        for failure in 0..<4 {
            let socket = StandardTestSocket()
            socket.onPrompt = { request in
                switch failure {
                case 0: break // Missing reply: bounded request timeout.
                case 1: socket.enqueue(.text("not-json-" + sentinel))
                case 2: socket.reply(request, error: ["code": 401, "message": "wss://private/api/ws?token=" + sentinel])
                default:
                    socket.event("error", payload: ["message": "wss://private/api/ws?token=" + sentinel], sequence: 1)
                    socket.accept(request)
                }
            }
            let client = try makeClient(StandardTestFactory([socket]), token: sentinel, timeout: 80_000_000)
            _ = try await client.connect()
            let result = await standardCapture(await client.sendTurn(text: "prompt"))
            XCTAssertNotNil(result.error)
            XCTAssertFalse(result.error?.localizedDescription.contains(sentinel) ?? true)
            XCTAssertFalse(String(describing: result.events).contains(sentinel))
            XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
            await client.disconnect()
        }
    }

    func testFailureCompletionDoesNotRenderProviderExceptionAsResponseText() async throws {
        let socket = StandardTestSocket()
        socket.onPrompt = { request in
            socket.event("message.complete", payload: [
                "text": "wss://private/api/ws?token=SENTINEL", "reasoning": "SENTINEL",
                "failure_reason": "SENTINEL", "status": "error",
            ], sequence: 1)
            socket.accept(request)
        }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let result = await standardCapture(await client.sendTurn(text: "prompt"))
        XCTAssertEqual(result.error, .turnFailed)
        XCTAssertFalse(String(describing: result.events).contains("SENTINEL"))
        await client.disconnect()
    }

    func testDisconnectAndCallerCancellationReleasePendingConnectRequests() async throws {
        let socket = StandardTestSocket()
        socket.ignoreCreate = true
        let createSent = expectation(description: "Create awaiting response")
        socket.onCreate = { createSent.fulfill() }
        let client = try makeClient(StandardTestFactory([socket]))
        let connecting = Task { try await client.connect() }
        await fulfillment(of: [createSent], timeout: 1)
        await client.disconnect()
        do { _ = try await connecting.value; XCTFail("Disconnect must release connect") }
        catch { XCTAssertEqual(error as? StandardSessionError, .disconnected) }
        XCTAssertTrue(socket.closed)

        let second = StandardTestSocket()
        second.ignoreCreate = true
        let secondSent = expectation(description: "Second create awaiting response")
        second.onCreate = { secondSent.fulfill() }
        let secondClient = try makeClient(StandardTestFactory([second]))
        let cancelled = Task { try await secondClient.connect() }
        await fulfillment(of: [secondSent], timeout: 1)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancel must release connect") }
        catch { XCTAssertTrue(error is CancellationError || error as? StandardSessionError == .disconnected) }
        await secondClient.disconnect()
        XCTAssertTrue(second.closed)
    }

    func testAuthenticationUpgradeFailureNeverExposesAuthenticatedURLOrUnderlyingError() async throws {
        let token = "AUTH-PRIVACY-SENTINEL"
        let failure = NSError(domain: "Upgrade wss://private/api/ws?token=\(token)", code: 403)
        let factory = StandardFailingFactory(error: failure)
        let client = try makeClient(factory, token: token)
        do {
            try await client.checkConnection()
            XCTFail("Authentication must fail")
        } catch {
            XCTAssertEqual(error as? StandardSessionError, .connectionFailed)
            XCTAssertFalse(error.localizedDescription.contains(token))
            XCTAssertFalse(error.localizedDescription.contains("wss://"))
        }
    }

    func testOpenTimeoutClosesLateSocketWithoutInstallingOrLeakingIt() async throws {
        let socket = StandardTestSocket()
        let closed = expectation(description: "Late open closed")
        socket.onClose = { closed.fulfill() }
        let factory = StandardHoldingFactory(socket: socket)
        let client = try makeClient(factory, timeout: 80_000_000)
        do { _ = try await client.connect(); XCTFail("Open must be bounded") }
        catch { XCTAssertEqual(error as? StandardSessionError, .requestTimedOut) }
        factory.release()
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertTrue(socket.methods.isEmpty)
        XCTAssertTrue(socket.closed)
    }

    func testDisconnectResolvesConcurrentInterruptWaitersWithOneRemoteRequest() async throws {
        let socket = StandardTestSocket()
        let sent = expectation(description: "One interrupt awaiting response")
        socket.onInterrupt = { _ in sent.fulfill() }
        let client = try makeClient(StandardTestFactory([socket]))
        _ = try await client.connect()
        let stream = await client.sendTurn(text: "prompt")
        var iterator = stream.makeAsyncIterator()
        socket.event("message.start", payload: [:], sequence: 1)
        _ = try await iterator.next()
        let first = Task { await client.interruptActiveTurnOutcome() }
        let second = Task { await client.interruptActiveTurnOutcome() }
        await fulfillment(of: [sent], timeout: 1)
        await client.disconnect()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertTrue(firstOutcome == .uncertain || firstOutcome == .unavailable)
        XCTAssertTrue(secondOutcome == .uncertain || secondOutcome == .unavailable)
        XCTAssertEqual(socket.methods.filter { $0 == "session.interrupt" }.count, 1)
    }

    func testMissingStandardTokenOpensNoSocketAndReadsNoOtherCredential() async throws {
        let factory = StandardTestFactory([])
        let client = try makeClient(factory, token: "  ")
        do { _ = try await client.connect(); XCTFail("A Standard token is required") }
        catch { XCTAssertEqual(error as? StandardSessionError, .missingToken) }
        XCTAssertTrue(factory.requests.isEmpty)
    }

    func testUnknownNativeBaselineIsRejectedWithoutCreatingOrFallingBack() async throws {
        let socket = StandardTestSocket(canonical: false)
        let client = try makeClient(StandardTestFactory([socket]))
        do { _ = try await client.connect(); XCTFail("Unsupported baseline must not create") }
        catch { XCTAssertEqual(error as? StandardSessionError, .unsupportedBaseline) }
        XCTAssertFalse(socket.methods.contains("session.create"))
        XCTAssertFalse(socket.methods.contains("hello"))
        await client.disconnect()
    }

    func testProfileValidationRejectsInsecureAndCredentialBearingEndpointsBeforeAnySocketOpens() throws {
        for endpoint in [
            "ws://example.invalid/api/ws", "wss://user:password@example.invalid/api/ws",
            "wss://example.invalid/api/ws?token=private", "wss://example.invalid/api/ws?%74oken=private",
            "wss://example.invalid/api/ws?access_token=private", "wss://example.invalid/api/ws?key=private",
            "wss://example.invalid/api/ws?%2574oken=private", "wss://example.invalid/api/ws?access%5ftoken=private",
            "wss://example.invalid/api/ws#private", "wss://example.invalid/other",
        ] {
            XCTAssertThrowsError(try RelayProfile.standard(endpoint: XCTUnwrap(URL(string: endpoint))))
        }
    }

    private func makeClient(
        _ factory: any WebSocketConnectionFactory,
        token: String = "standard-test-token",
        targetProfile: String = "default",
        durable: String? = nil,
        timeout: UInt64 = 1_000_000_000,
        onLoss: (@MainActor @Sendable () -> Void)? = nil
    ) throws -> StandardSessionClient {
        StandardSessionClient(
            profile: try RelayProfile.standard(endpoint: XCTUnwrap(URL(string: "wss://example.invalid/api/ws")), targetProfile: targetProfile),
            token: token, connectionFactory: factory, storedSessionID: durable,
            requestTimeoutNanoseconds: timeout, onTransportDisconnected: onLoss
        )
    }
}

private struct StandardCapturedTurn: Sendable {
    var events: [HermesEvent] = []
    var error: StandardSessionError?
}

private func standardCapture(_ stream: AsyncThrowingStream<HermesEvent, Error>) async -> StandardCapturedTurn {
    var result = StandardCapturedTurn()
    do { for try await event in stream { result.events.append(event) } }
    catch { result.error = error as? StandardSessionError ?? .invalidResponse }
    return result
}

private func standardJSON(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func standardObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

private func standardSnapshot(session: String = "conversation", extra: [String: Any] = [:]) -> [String: Any] {
    [
        "session_id": session, "stored_session_id": session, "authority_epoch": 7,
        "replay_epoch": "epoch", "last_sequence": 0, "execution_generation": 0,
        "running": false, "pending": [], "prompts": [], "open_requests": [],
        "messages": [], "info": ["model": "test-model"],
    ].merging(extra) { _, new in new }
}

private final class StandardTestFactory: WebSocketConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [StandardTestSocket]
    private var capturedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { capturedRequests } }

    init(_ sockets: [StandardTestSocket]) { self.sockets = sockets }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        try lock.withLock {
            capturedRequests.append(urlRequest)
            guard !sockets.isEmpty else { throw StandardSessionError.connectionFailed }
            return sockets.removeFirst()
        }
    }
}

/// Deterministic peer exercising the actual canonical JSON-RPC consumer seam.
/// No implementation path uses this peer; production opens URLSession sockets.
private final class StandardTestSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<WebSocketFrame, Error>] = []
    private var waiter: CheckedContinuation<WebSocketFrame, Error>?
    private var sent: [String] = []
    private var isClosed = false
    private var receiveCount = 0
    private var maximumReceives = 0
    var snapshot = standardSnapshot()
    var rejectResume = false
    var rejectCreate = false
    var ignoreCreate = false
    var delaySendCompletion = false
    var onPrompt: (@Sendable (String) -> Void)?
    var onInterrupt: (@Sendable (String) -> Void)?
    var onCreate: (@Sendable () -> Void)?
    var onServerResponse: (@Sendable () -> Void)?
    var onClose: (@Sendable () -> Void)?
    var closed: Bool { lock.withLock { isClosed } }
    var sentText: String { lock.withLock { sent.joined(separator: "\n") } }
    var frames: [[String: Any]] { lock.withLock { sent }.map(standardObject) }
    var methods: [String] { frames.compactMap { $0["method"] as? String } }
    var maximumConcurrentReceives: Int { lock.withLock { maximumReceives } }

    init(canonical: Bool = true) {
        enqueue(.text(standardJSON([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": ["session_authority": canonical]],
        ])))
    }

    func send(text: String) async throws {
        try lock.withLock {
            guard !isClosed else { throw StandardSessionError.disconnected }
            sent.append(text)
        }
        let request = standardObject(text)
        switch request["method"] as? String {
        case "gateway.ping": reply(text, result: ["ok": true])
        case "session.create":
            onCreate?()
            if rejectCreate { reply(text, error: ["code": 4001, "message": "private rejected create"]) }
            else if !ignoreCreate { reply(text, result: snapshot) }
        case "session.resume":
            if rejectResume { reply(text, error: ["code": 4001, "message": "private missing session"]) }
            else { reply(text, result: snapshot) }
        case "prompt.submit":
            if let onPrompt { onPrompt(text) } else { accept(text) }
        case "session.interrupt": onInterrupt?(text)
        default: onServerResponse?()
        }
        if delaySendCompletion { try await Task.sleep(nanoseconds: 40_000_000) }
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<WebSocketFrame, Error>? = lock.withLock {
                if isClosed { return .failure(StandardSessionError.disconnected) }
                if !queue.isEmpty { return queue.removeFirst() }
                receiveCount += 1
                maximumReceives = max(maximumReceives, receiveCount)
                precondition(waiter == nil, "Only one transport reader is permitted")
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func close() async {
        let pending = lock.withLock {
            isClosed = true
            let pending = waiter
            waiter = nil
            receiveCount = 0
            return pending
        }
        pending?.resume(throwing: StandardSessionError.disconnected)
        onClose?()
    }

    func enqueue(_ frame: WebSocketFrame) { deliver(.success(frame)) }
    func fail(_ error: Error) { deliver(.failure(error)) }

    private func deliver(_ result: Result<WebSocketFrame, Error>) {
        let pending: CheckedContinuation<WebSocketFrame, Error>? = lock.withLock {
            if let pending = waiter {
                waiter = nil
                receiveCount -= 1
                return pending
            }
            queue.append(result)
            return nil
        }
        pending?.resume(with: result)
    }

    func reply(_ request: String, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var frame: [String: Any] = ["jsonrpc": "2.0", "id": standardObject(request)["id"] ?? "missing"]
        if let result { frame["result"] = result }
        if let error { frame["error"] = error }
        enqueue(.text(standardJSON(frame)))
    }

    func accept(_ request: String, session: String = "conversation", started: Bool = false) {
        reply(request, result: [
            "admission_id": "admission", "ref": ["profile_id": "private-profile", "session_id": session],
            "sequence": 1, "status": started ? "started" : "queued", "authority_epoch": 7,
            "execution_generation": started ? (1 as Any) : NSNull(),
        ])
    }

    func event(
        _ type: String, payload: [String: Any], sequence: Int,
        session: String = "conversation", admission: String = "admission",
        execution: Int = 1, epoch: Int = 7, replay: String = "epoch"
    ) {
        enqueue(.text(standardJSON([
            "jsonrpc": "2.0", "method": "event", "params": [
                "type": type, "session_id": session, "payload": payload,
                "seq": sequence, "replay_epoch": replay, "authority_epoch": epoch,
                "admission_id": admission, "execution_generation": execution,
            ],
        ])))
    }

    func complete(text: String, sequence: Int, session: String = "conversation", status: String = "complete") {
        event("message.complete", payload: ["text": text, "status": status], sequence: sequence, session: session)
    }
}

private struct StandardFailingFactory: WebSocketConnectionFactory {
    let error: NSError
    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection { throw error }
}

private final class StandardHoldingFactory: WebSocketConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let socket: StandardTestSocket
    private var waiter: CheckedContinuation<any WebSocketConnection, Error>?
    init(socket: StandardTestSocket) { self.socket = socket }
    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiter = continuation }
        }
    }
    func release() {
        let pending = lock.withLock {
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.resume(returning: socket)
    }
}
