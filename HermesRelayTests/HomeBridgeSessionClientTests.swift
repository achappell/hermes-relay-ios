import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeBridgeSessionClientTests: XCTestCase {
    func testURLSessionClientUsesOneDeviceSocketAndSharedEventReader() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, let capabilities) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        XCTAssertEqual(binding.conversationHandle, fixture.claim.conversationHandle)
        XCTAssertEqual(capabilities.timing, .absent)

        let submission = await client.submitPrompt("hello", binding: binding)
        guard case .accepted(let turn) = submission else {
            return XCTFail("The fake JSON-RPC response must accept the prompt")
        }

        let standard = HomeStandardEvent(
            type: .messageDelta,
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: turn.turnID,
                correlationID: turn.correlationID
            ),
            payload: .delta(
                rendered: "Hello from Home",
                text: nil,
                replace: false,
                kind: .assistant
            )
        )
        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: binding.conversationHandle,
            turnID: turn.turnID,
            correlationID: turn.correlationID,
            type: "message.delta",
            payload: [
                "rendered": "Hello from Home",
                "kind": "assistant",
            ]
        )))
        let standardEvent = try await events.next()
        XCTAssertEqual(standardEvent, .standard(standard))

        let recordedRequest = await fixture.requests.first()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Device device-secret"
        )
        let requestCount = await fixture.requests.count()
        XCTAssertEqual(requestCount, 1)
        let sentMethods = try await fixture.socket.sentMethods()
        XCTAssertEqual(sentMethods, ["conversation.open", "prompt.submit"])

        await client.close()
        await client.close()
        let closeCount = await fixture.socket.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testURLSessionClientAcceptsContractNestedEventNotification() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can deliver events")
        }

        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.start",
            payload: ["kind": "assistant"]
        )))

        let event = try await events.next()
        XCTAssertEqual(
            event,
            .standard(HomeStandardEvent(
                type: .messageStart,
                scope: scope,
                payload: .start(kind: .assistant)
            ))
        )

        await client.close()
    }

    func testURLSessionClientMapsNumericJSONRPCErrorUsingStableHomeCode() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }

        await fixture.socket.setNextError(
            for: "prompt.submit",
            jsonRPCCode: -32_000,
            homeCode: "request_rejected"
        )
        let outcome = await client.submitPrompt("synthetic prompt", binding: binding)

        XCTAssertEqual(
            outcome,
            .rejected(.home(code: .requestRejected, phase: .submission))
        )
        await client.close()
    }

    func testURLSessionClientMapsKnownOpenErrorToUnavailable() async throws {
        let fixture = try await makeFixture()
        await fixture.socket.setNextError(
            for: "conversation.open",
            jsonRPCCode: -32_000,
            homeCode: "unauthorized"
        )

        let outcome = await fixture.client.open(claim: fixture.claim)

        XCTAssertEqual(
            outcome,
            .unavailable(.home(code: .unauthorized, phase: .open))
        )
        await fixture.client.close()
    }

    func testURLSessionClientMapsKnownReconnectErrorToUnavailable() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.setNextError(
            for: "conversation.reconnect",
            jsonRPCCode: -32_000,
            homeCode: "stale_conversation"
        )

        let outcome = await client.reconnect(binding: binding)

        XCTAssertEqual(
            outcome,
            .unavailable(.home(code: .staleConversation, phase: .reconnect))
        )
        await client.close()
    }

    func testURLSessionClientAcceptsLiveHomeOpenAndSubmissionReplies() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        // Shapes observed from the deployed Home adapter: `unresolved_turn: false`,
        // an `audio` capability, no `heartbeat`, and a submission without a correlation ID.
        await fixture.socket.setNextResultJSON(for: "conversation.open", """
        {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
        "route":{"class":"home","id":"home-a"},\
        "capabilities":{"commands":[],"timing":"absent","interrupt":true,"audio":true},\
        "unresolved_turn":false}
        """)
        await fixture.socket.setNextResultJSON(for: "prompt.submit", """
        {"schema":1,"conversation_handle":"opaque-home-conversation","turn_id":"turn-live","status":"submitted"}
        """)

        guard case .ready(let binding, let capabilities) = await client.open(claim: fixture.claim) else {
            return XCTFail("The live Home ready reply must open the bridge")
        }
        XCTAssertFalse(capabilities.heartbeat)
        XCTAssertTrue(capabilities.interrupt)
        XCTAssertEqual(capabilities.timing, .absent)

        guard case .accepted(let turn) = await client.submitPrompt("hello", binding: binding) else {
            return XCTFail("The live Home submission reply must accept the prompt")
        }
        XCTAssertEqual(turn.turnID, "turn-live")
        XCTAssertNil(turn.correlationID)

        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: binding.conversationHandle,
            turnID: turn.turnID,
            correlationID: "standard-request-1",
            type: "message.delta",
            payload: ["rendered": "Hello from Home", "kind": "assistant"]
        )))
        let event = try await events.next()
        guard case .standard(let standard) = event else {
            return XCTFail("The turn's Standard event must be delivered")
        }
        XCTAssertEqual(standard.scope.turnID, turn.turnID)
        XCTAssertTrue(homeCorrelationMatches(expected: turn.correlationID, received: standard.scope.correlationID))
        await client.close()
    }

    func testURLSessionClientRequiresReconnectWhenOpenReportsAnUnresolvedTurn() async throws {
        let fixture = try await makeFixture()
        await fixture.socket.setNextResultJSON(for: "conversation.open", """
        {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
        "route":{"class":"home","id":"home-a"},\
        "capabilities":{"commands":[],"timing":"absent","interrupt":true,"audio":true},\
        "unresolved_turn":{"turn_id":"turn-old","resume_cursor":"cursor-1"}}
        """)

        let outcome = await fixture.client.open(claim: fixture.claim)

        XCTAssertEqual(outcome, .unavailable(.reconnectRequired))
        await fixture.client.close()

        let wrongRoute = try await makeFixture()
        await wrongRoute.socket.setNextResultJSON(for: "conversation.open", """
        {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
        "route":{"class":"home","id":"other-route"},\
        "capabilities":{"commands":[],"timing":"absent"},"unresolved_turn":true}
        """)

        let wrongRouteOutcome = await wrongRoute.client.open(claim: wrongRoute.claim)

        XCTAssertEqual(wrongRouteOutcome, .unavailable(.route(.identityMismatch)))
        await wrongRoute.client.close()
    }

    func testURLSessionClientStillRejectsUnknownReadyCapabilityAndMalformedUnresolvedTurn() async throws {
        for result in [
            """
            {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
            "route":{"class":"home","id":"home-a"},\
            "capabilities":{"commands":[],"timing":"absent","speech":true}}
            """,
            """
            {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
            "route":{"class":"home","id":"home-a"},\
            "capabilities":{"commands":[],"timing":"absent"},"unresolved_turn":"yes"}
            """,
        ] {
            let fixture = try await makeFixture()
            await fixture.socket.setNextResultJSON(for: "conversation.open", result)

            let outcome = await fixture.client.open(claim: fixture.claim)

            XCTAssertEqual(outcome, .unavailable(.home(code: .protocolError, phase: .open)))
            await fixture.client.close()
        }
    }

    func testURLSessionClientRejectsEmptySubmissionCorrelationID() async throws {
        let fixture = try await makeFixture()
        guard case .ready(let binding, _) = await fixture.client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.setNextResultJSON(for: "prompt.submit", """
        {"schema":1,"conversation_handle":"opaque-home-conversation","turn_id":"turn-1",\
        "correlation_id":"","status":"accepted"}
        """)

        let outcome = await fixture.client.submitPrompt("hello", binding: binding)

        XCTAssertEqual(outcome, .rejected(.home(code: .protocolError, phase: .submission)))
        await fixture.client.close()
    }

    func testCorrelationMatchingFallsBackToTurnIDOnlyWhenEitherSideIsAbsent() {
        XCTAssertTrue(homeCorrelationMatches(expected: nil, received: "standard-request-1"))
        XCTAssertTrue(homeCorrelationMatches(expected: "correlation-1", received: nil))
        XCTAssertTrue(homeCorrelationMatches(expected: "correlation-1", received: "correlation-1"))
        XCTAssertFalse(homeCorrelationMatches(expected: "correlation-1", received: "correlation-2"))
        XCTAssertFalse(homeCorrelationMatches(expected: "unresolved", received: "correlation-1"))
    }

    func testURLSessionClientRejectsNumericBooleanEventField() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.delta",
            payload: [
                "rendered": "synthetic preview",
                "replace": 0,
            ]
        )))

        do {
            _ = try await events.next()
            XCTFail("Numeric values must not be accepted as Boolean event fields")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }
        await client.close()
    }

    func testURLSessionClientRejectsFractionalEventSchema() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.start",
            payload: ["kind": "assistant"],
            outerSchema: 1,
            paramsSchema: 1.5
        )))

        do {
            _ = try await events.next()
            XCTFail("Fractional Home event schemas must be rejected")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }
        await client.close()
    }

    func testURLSessionClientRejectsBooleanAudioSchema() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try audioFrame(
            scope: scope,
            kind: "start",
            paramsSchema: true
        )))

        do {
            _ = try await events.next()
            XCTFail("Boolean Home audio schemas must be rejected")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidAudioFrame)
        }
        await client.close()
    }

    func testURLSessionClientRejectsMalformedJSONRPCErrorCodes() async throws {
        let cases: [TestJSONRPCCode] = [
            .string("-32000"),
            .boolean(true),
            .fractional(-32_000.5),
            .missing,
        ]

        for code in cases {
            let fixture = try await makeFixture()
            let client = fixture.client
            guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
                return XCTFail("A valid Home bridge response must become ready")
            }
            await fixture.socket.setNextRawError(
                for: "prompt.submit",
                code: code,
                homeCode: "request_rejected"
            )

            let outcome = await client.submitPrompt("synthetic prompt", binding: binding)
            XCTAssertEqual(
                outcome,
                .rejected(.home(code: .protocolError, phase: .submission)),
                "Malformed JSON-RPC code case: \(code)"
            )
            await client.close()
        }
    }

    func testURLSessionClientMapsJSONRPCErrorWithoutStableHomeCodeToProtocolError() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }

        await fixture.socket.setNextRawError(
            for: "prompt.submit",
            code: .integer(-32_000),
            homeCode: nil
        )
        let outcome = await client.submitPrompt("synthetic prompt", binding: binding)

        XCTAssertEqual(
            outcome,
            .rejected(.home(code: .protocolError, phase: .submission))
        )
        await client.close()
    }

    func testURLSessionClientAcceptsFractionalStructuredPromptExpiry() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }

        let expiryFormatter = ISO8601DateFormatter()
        expiryFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiryText = "2100-01-01T00:00:00.123Z"
        let expectedExpiry = try XCTUnwrap(expiryFormatter.date(from: expiryText))
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-1"
        )
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "approval.request",
            payload: [
                "options": ["yes", "no"],
                "expires_at": expiryText,
                "sensitive": false,
            ]
        )))

        guard case .structuredPrompt(let prompt) = try await events.next() else {
            return XCTFail("The fractional expiry must remain a typed prompt")
        }
        XCTAssertEqual(prompt.expiresAt, expectedExpiry)
        await client.close()
    }

    func testURLSessionClientDropsAnUnknownFailureReasonWithoutEndingTheTurn() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.complete",
            payload: [
                "rendered": "synthetic response",
                "failure_reason": "future_failure",
            ]
        )))

        let event = try await events.next()
        XCTAssertEqual(event, .standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: "synthetic response",
                text: nil,
                status: nil,
                reasoning: nil,
                failureReason: nil
            )
        )))
        await client.close()
    }

    func testURLSessionClientRejectsMalformedStructuredPromptExpiry() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "approval-1"
            ),
            type: "approval.request",
            payload: [
                "options": ["yes"],
                "expires_at": "not-an-iso8601-date",
                "sensitive": false,
            ]
        )))

        do {
            _ = try await events.next()
            XCTFail("Malformed structured prompt expiry must be rejected")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }
        await client.close()
    }

    func testURLSessionClientSafelyMapsUnknownOptionalEventKindToAbsent() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.start",
            payload: ["kind": "future-kind"]
        )))

        let event = try await events.next()
        XCTAssertEqual(
            event,
            .standard(HomeStandardEvent(
                type: .messageStart,
                scope: scope,
                payload: .start(kind: nil)
            ))
        )
        await client.close()
    }

    func testURLSessionClientRejectsConversationMismatchWithTypedError() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: "wrong-conversation",
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.start",
            payload: ["kind": "assistant"]
        )))

        do {
            _ = try await events.next()
            XCTFail("A mismatched Home conversation must not reach the event stream")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .conversationMismatch)
        }
        await client.close()
    }

    func testURLSessionClientIgnoresUnknownEventTypesAndKeepsReading() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "future.event",
            payload: [:]
        )))
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.start",
            payload: [:]
        )))

        let event = try await events.next()
        XCTAssertEqual(
            event,
            .standard(HomeStandardEvent(type: .messageStart, scope: scope, payload: .start(kind: nil)))
        )
        await client.close()
    }

    func testURLSessionClientAcceptsTheLiveHomeReconnectReply() async throws {
        let fixture = try await makeFixture()
        guard case .ready(let binding, _) = await fixture.client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        // The deployed adapter answers reconnect with the full ready shape.
        await fixture.socket.setNextResultJSON(for: "conversation.reconnect", """
        {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
        "route":{"class":"home","id":"home-a"},\
        "capabilities":{"commands":["status"],"heartbeat":true,"interrupt":true,"audio":true,"timing":"absent"},\
        "unresolved_turn":false}
        """)

        let outcome = await fixture.client.reconnect(binding: binding)

        XCTAssertEqual(outcome, .ready(binding: binding, unresolvedTurn: nil))
        await fixture.client.close()
    }

    func testURLSessionClientRejectsAReconnectReplyForAnotherRoute() async throws {
        let fixture = try await makeFixture()
        guard case .ready(let binding, _) = await fixture.client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.setNextResultJSON(for: "conversation.reconnect", """
        {"schema":1,"status":"ready","conversation_handle":"opaque-home-conversation",\
        "route":{"class":"home","id":"other-route"},\
        "capabilities":{"commands":[],"timing":"absent"},"unresolved_turn":false}
        """)

        let outcome = await fixture.client.reconnect(binding: binding)

        XCTAssertEqual(outcome, .unavailable(.route(.identityMismatch)))
        await fixture.client.close()
    }

    func testURLSessionClientRendersTheLiveStandardEventVocabulary() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        let global = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: nil,
            correlationID: nil
        )
        let turn = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: nil
        )
        // Shapes emitted by the Standard gateway (tui_gateway) and forwarded by Home.
        for (scope, type, payload) in [
            (global, "session.info", ["model": "model-a", "tools": ["web": ["search"]]] as [String: Any]),
            (global, "sessions.changed", [:]),
            (turn, "tool.start", ["name": "search"]),
            (turn, "status.update", ["kind": "process", "text": "Searching"]),
            (turn, "reasoning.delta", ["text": "Considering", "verbose": true]),
            (turn, "message.complete", [
                "text": "Done", "usage": ["input": 1], "status": "complete",
                "warning": "note", "failure_reason": "billing_blocked",
            ]),
            (turn, "error", ["message": "server detail that must not surface"]),
        ] {
            // eventFrame omits absent turn/correlation IDs, as the live adapter does.
            await fixture.socket.enqueue(.text(try eventFrame(
                conversationHandle: scope.conversationHandle,
                turnID: scope.turnID,
                correlationID: scope.correlationID,
                type: type,
                payload: payload
            )))
        }

        let status = try await events.next()
        XCTAssertEqual(status, .standard(HomeStandardEvent(
            type: .status,
            scope: turn,
            payload: .activity(text: "Searching", status: nil, reasoning: nil, kind: nil)
        )))
        let reasoning = try await events.next()
        XCTAssertEqual(reasoning, .standard(HomeStandardEvent(
            type: .reasoning,
            scope: turn,
            payload: .activity(text: "Considering", status: nil, reasoning: nil, kind: nil)
        )))
        let complete = try await events.next()
        XCTAssertEqual(complete, .standard(HomeStandardEvent(
            type: .messageComplete,
            scope: turn,
            payload: .final(rendered: nil, text: "Done", status: "complete", reasoning: nil, failureReason: nil)
        )))
        let error = try await events.next()
        XCTAssertEqual(error, .standard(HomeStandardEvent(
            type: .error,
            scope: turn,
            payload: .error(HomeSafeError(code: .hermesUnavailable, phase: .submission))
        )))
        await client.close()
    }

    func testURLSessionClientRejectsUnknownNestedEventFields() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.start",
            payload: ["kind": "assistant"],
            extraEventFields: ["session_id": "server-only"]
        )))

        do {
            _ = try await events.next()
            XCTFail("Server-only nested event fields must not reach the event stream")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .unknownField)
        }
        await client.close()
    }

    func testURLSessionClientRejectsMalformedTypedEventPayload() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.delta",
            payload: [
                "rendered": "synthetic preview",
                "replace": "not-a-boolean",
            ]
        )))

        do {
            _ = try await events.next()
            XCTFail("Malformed typed event fields must not be normalized by default")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }
        await client.close()
    }

    func testURLSessionClientRejectsMalformedStructuredPromptPayload() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: "turn-1",
                correlationID: "approval-1"
            ),
            type: "approval.request",
            payload: [
                "options": "not-an-array",
                "sensitive": false,
            ]
        )))

        do {
            _ = try await events.next()
            XCTFail("Malformed structured prompt fields must not become a typed prompt")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }
        await client.close()
    }

    func testURLSessionClientJoinsBinaryPCMOnlyInsideAValidatedAudioScope() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can accept audio")
        }

        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "start")))
        await fixture.socket.enqueue(.binary(Data([0x01, 0x02])))
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "end")))

        let audioStart = try await events.next()
        XCTAssertEqual(
            audioStart,
            .audioStart(scope, HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2))
        )
        let audioPCM = try await events.next()
        XCTAssertEqual(audioPCM, .binaryPCM(scope, Data([0x01, 0x02])))
        let audioEnd = try await events.next()
        XCTAssertEqual(audioEnd, .audioTerminal(scope, .end))
        await client.close()
    }

    func testURLSessionClientKeepsTextEventsAfterAudioUnavailable() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can deliver audio")
        }

        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "start")))
        await fixture.socket.enqueue(.text(try audioFrame(
            scope: scope,
            kind: "unavailable",
            reason: "synthetic-sidecar-failure"
        )))

        let audioStart = try await events.next()
        XCTAssertEqual(
            audioStart,
            .audioStart(scope, HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2))
        )
        let audioFailure = try await events.next()
        XCTAssertEqual(audioFailure, .audioTerminal(scope, .unavailable))

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.complete",
            payload: [
                "rendered": "text survives",
                "status": "completed",
            ]
        )))
        let textEvent = try await events.next()
        XCTAssertEqual(
            textEvent,
            .standard(HomeStandardEvent(
                type: .messageComplete,
                scope: scope,
                payload: .final(
                    rendered: "text survives",
                    text: nil,
                    status: "completed",
                    reasoning: nil,
                    failureReason: nil
                )
            ))
        )
        await client.close()
    }

    func testURLSessionClientSurfacesInvalidAudioAndKeepsTheReaderAlive() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can deliver audio")
        }
        let submission = await client.submitPrompt("synthetic prompt", binding: binding)
        guard case .accepted(let turn) = submission else {
            return XCTFail("The prompt must establish the audio scope")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: turn.turnID,
            correlationID: turn.correlationID
        )

        await fixture.socket.enqueue(.text(try audioFrame(
            scope: scope,
            kind: "start",
            sampleWidth: 3
        )))
        let invalidAudio = try await events.next()
        XCTAssertEqual(invalidAudio, .audioTerminal(scope, .invalid))

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.complete",
            payload: ["rendered": "text survives", "status": "completed"]
        )))
        let textEvent = try await events.next()
        guard case .standard(let standard) = textEvent else {
            return XCTFail("The invalid audio must not end the Home reader")
        }
        XCTAssertEqual(standard.type, .messageComplete)
        await client.close()
    }

    func testURLSessionClientClassifiesBinaryBeforeStartAsInvalidAudio() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can accept a prompt")
        }
        let submission = await client.submitPrompt("synthetic prompt", binding: binding)
        guard case .accepted(let turn) = submission else {
            return XCTFail("The prompt must establish the audio scope")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: turn.turnID,
            correlationID: turn.correlationID
        )

        await fixture.socket.enqueue(.binary(Data([0x01, 0x02])))
        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.complete",
            payload: ["rendered": "text survives", "status": "completed"]
        )))

        let invalidAudioEvent = try await events.next()
        XCTAssertEqual(invalidAudioEvent, .audioTerminal(scope, .invalid))
        let textEvent = try await events.next()
        guard case .standard(let standard) = textEvent else {
            return XCTFail("The Home reader must continue after invalid PCM")
        }
        XCTAssertEqual(standard.type, .messageComplete)
        await client.close()
    }

    func testURLSessionClientReopensAfterTransportLossInsteadOfUsingCachedBinding() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before transport loss")
        }

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: HomeEventScope(
                conversationHandle: fixture.claim.conversationHandle,
                turnID: "turn-1",
                correlationID: "correlation-1"
            ),
            type: "message.start",
            payload: [:],
            paramsSchema: 2
        )))
        do {
            _ = try await events.next()
            XCTFail("A malformed event envelope must close the current reader")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }

        guard case .ready = await client.open(claim: fixture.claim) else {
            return XCTFail("A second open must establish a fresh binding")
        }
        let factoryOpenCount = await fixture.factory.openCount
        let secondSentMethods = try await fixture.secondSocket.sentMethods()
        XCTAssertEqual(factoryOpenCount, 2)
        XCTAssertEqual(secondSentMethods, ["conversation.open"])
        await client.close()
    }

    func testURLSessionClientAcceptsFreshAudioStartAfterTransportLoss() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can deliver audio")
        }
        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "start")))
        let firstAudioEvent = try await events.next()
        XCTAssertEqual(firstAudioEvent, .audioStart(
            scope,
            HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        ))

        await fixture.socket.enqueue(.text(try contractEventFrame(
            scope: scope,
            type: "message.start",
            payload: [:],
            paramsSchema: 2
        )))
        do {
            _ = try await events.next()
            XCTFail("A malformed event envelope must close the current reader")
        } catch {
            XCTAssertEqual(error as? HomeWireDecodingError, .invalidShape)
        }

        let reconnectOutcome = await client.reconnect(binding: binding)
        guard case .ready = reconnectOutcome else {
            return XCTFail("The binding must reconnect: \(reconnectOutcome)")
        }
        let reconnectedStream = await client.events()
        var reconnectedEvents = reconnectedStream.makeAsyncIterator()
        await fixture.secondSocket.enqueue(.text(try audioFrame(scope: scope, kind: "start")))

        let reconnectedAudioEvent = try await reconnectedEvents.next()
        XCTAssertEqual(
            reconnectedAudioEvent,
            .audioStart(scope, HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2))
        )
        await client.close()
    }

    func testStructuredPromptIsCorrelatedAndResponsesUseTheFixedOperation() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must be ready before prompts are accepted")
        }

        let prompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-1",
            options: ["yes", "no"],
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            sensitive: false
        )
        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: prompt.conversationHandle,
            turnID: prompt.turnID,
            correlationID: prompt.correlationID,
            type: prompt.eventType,
            payload: [
                "options": prompt.options,
                "expires_at": ISO8601DateFormatter().string(from: prompt.expiresAt!),
                "sensitive": false,
            ]
        )))
        let promptEvent = try await events.next()
        XCTAssertEqual(promptEvent, .structuredPrompt(prompt))

        let responseOutcome = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(responseOutcome, .accepted)
        let sentMethods = try await fixture.socket.sentMethods()
        XCTAssertEqual(sentMethods, ["conversation.open", "prompt.respond"])
        await client.close()
    }

    func testURLSessionClientRejectsEmptyTypedStructuredResponses() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must be ready before prompts are accepted")
        }

        let cases: [(HomeStructuredPromptKind, HomePromptResponse, Bool)] = [
            (.approval, .approval(choice: "", all: nil), false),
            (.clarification, .clarification(answer: ""), false),
            (.secret, .secret(value: ""), true),
            (.sudo, .sudo(password: ""), true),
        ]
        for (index, item) in cases.enumerated() {
            let prompt = HomeStructuredPrompt(
                kind: item.0,
                conversationHandle: binding.conversationHandle,
                turnID: "turn-\(index + 1)",
                correlationID: "empty-\(index + 1)",
                options: item.0 == .approval ? ["yes"] : [],
                expiresAt: nil,
                sensitive: item.2
            )
            await fixture.socket.enqueue(.text(try eventFrame(
                conversationHandle: prompt.conversationHandle,
                turnID: prompt.turnID,
                correlationID: prompt.correlationID,
                type: prompt.eventType,
                payload: [
                    "options": prompt.options,
                    "sensitive": item.2,
                ]
            )))
            _ = try await events.next()
            let outcome = await client.respond(to: prompt, with: item.1)
            XCTAssertEqual(
                outcome,
                .rejected(.home(code: .invalidRequest, phase: .structuredResponse)),
                "Empty response for \(prompt.eventType) must be rejected locally"
            )
        }
        await client.close()
    }

    func testURLSessionClientRejectsPromptResolutionWithoutAcceptanceProof() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must be ready before prompts are accepted")
        }
        let prompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-status",
            options: ["yes"],
            expiresAt: nil,
            sensitive: false
        )
        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: prompt.conversationHandle,
            turnID: prompt.turnID,
            correlationID: prompt.correlationID,
            type: prompt.eventType,
            payload: ["options": prompt.options, "sensitive": false]
        )))
        _ = try await events.next()
        await fixture.socket.setNextPromptResponseStatus("rejected")

        let outcome = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            outcome,
            .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        )
        await client.close()
    }

    func testProductionFactoryStopsAtThePublicAdapterGate() async {
        let dependencies = HomeBridgeClientDependencies(
            routeProvider: StaticRouteProvider(route: nil),
            credentialStore: InMemoryHomeCredentialStore(),
            publicAdapterEnabled: false
        )
        let client = DefaultHomeBridgeSessionClientFactory(dependencies: dependencies)
            .make(profileID: UUID(), mode: .home)

        let outcome = await client.open(
            claim: HomeConversationClaim(
                profileID: UUID(),
                conversationHandle: "opaque",
                approvedRoute: HomeApprovedRoute(
                    endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
                    identity: HomeRouteIdentity(routeClass: .home, id: "home"),
                    householdBinding: "household"
                )
            )
        )

        XCTAssertEqual(outcome, .unavailable(.publicAdapterUnavailable))
    }

    func testFakeExercisesAcceptedStaleExpiredRejectedAndUncertainControls() async {
        let profileID = UUID()
        let claim = HomeDemoFixtures.claim(for: profileID)
        let client = FakeHomeBridgeSessionClient(
            claim: claim,
            capabilities: HomeBridgeCapabilities(
                commands: ["open"],
                heartbeat: true,
                interrupt: true,
                timing: .absent
            )
        )
        guard case .ready(let binding, _) = await client.open(claim: claim) else {
            return XCTFail("The deterministic fake must open")
        }

        let prompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-1",
            options: ["yes", "no"],
            expiresAt: nil,
            sensitive: false
        )
        await client.emit(.structuredPrompt(prompt))
        let accepted = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(accepted, .accepted)
        let stale = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            stale,
            .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        )

        let expiredPrompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-expired",
            options: ["yes"],
            expiresAt: Date(timeIntervalSince1970: 0),
            sensitive: false
        )
        await client.emit(.structuredPrompt(expiredPrompt))
        let expired = await client.respond(
            to: expiredPrompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            expired,
            .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        )

        let uncertainPrompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-uncertain",
            options: ["yes"],
            expiresAt: nil,
            sensitive: false
        )
        await client.emit(.structuredPrompt(uncertainPrompt))
        await client.setNextResponseOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        )
        let uncertain = await client.respond(
            to: uncertainPrompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            uncertain,
            .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        )

        let command = HomeCommandRequest(binding: binding, name: "open", argument: nil)
        await client.setNextCommandOutcome(
            .rejected(.home(code: .requestRejected, phase: .command))
        )
        let rejectedCommand = await client.dispatch(command)
        XCTAssertEqual(
            rejectedCommand,
            .rejected(.home(code: .requestRejected, phase: .command))
        )
        await client.setNextCommandOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .command))
        )
        let uncertainCommand = await client.dispatch(command)
        XCTAssertEqual(
            uncertainCommand,
            .uncertain(.home(code: .transportTimeout, phase: .command))
        )
    }

    private func makeFixture() async throws -> Fixture {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "home-a"),
            householdBinding: "household-a"
        )
        let claim = HomeConversationClaim(
            profileID: profileID,
            conversationHandle: "opaque-home-conversation",
            approvedRoute: route
        )
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profileID),
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 90 * 24 * 60 * 60),
            renewAfter: Date(timeIntervalSince1970: 76 * 24 * 60 * 60),
            overlapUntil: nil
        )
        let credentialStore = InMemoryHomeCredentialStore()
        await credentialStore.seed(
            credential: Data("device-secret".utf8),
            reference: reference,
            for: profileID
        )
        let socket = TestHomeSocket(claim: claim)
        let secondSocket = TestHomeSocket(claim: claim)
        let requests = TestHomeRequestRecorder()
        let socketFactory = TestHomeSocketFactory(
            sockets: [socket, secondSocket],
            recorder: requests
        )
        let dependencies = HomeBridgeClientDependencies(
            routeProvider: StaticRouteProvider(route: route),
            credentialStore: credentialStore,
            socketFactory: socketFactory,
            publicAdapterEnabled: true
        )
        return Fixture(
            claim: claim,
            client: URLSessionHomeBridgeSessionClient(dependencies: dependencies),
            socket: socket,
            secondSocket: secondSocket,
            factory: socketFactory,
            requests: requests
        )
    }

    private func eventFrame(
        conversationHandle: String,
        turnID: String?,
        correlationID: String?,
        type: String,
        payload: [String: Any]
    ) throws -> String {
        var params: [String: Any] = [
            "schema": 1,
            "conversation_handle": conversationHandle,
            "event": [
                "type": type,
                "payload": payload,
            ],
        ]
        if let turnID { params["turn_id"] = turnID }
        if let correlationID { params["correlation_id"] = correlationID }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": 1,
            "method": "event",
            "params": params,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func contractEventFrame(
        scope: HomeEventScope,
        type: String,
        payload: [String: Any],
        outerSchema: Any = 1,
        paramsSchema: Any = 1,
        extraEventFields: [String: Any] = [:]
    ) throws -> String {
        var event: [String: Any] = [
            "type": type,
            "payload": payload,
        ]
        event.merge(extraEventFields) { current, _ in current }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": outerSchema,
            "method": "event",
            "params": [
                "schema": paramsSchema,
                "conversation_handle": scope.conversationHandle,
                "turn_id": scope.turnID as Any,
                "correlation_id": scope.correlationID as Any,
                "event": event,
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func audioFrame(
        scope: HomeEventScope,
        kind: String,
        reason: String? = nil,
        outerSchema: Any = 1,
        paramsSchema: Any = 1,
        sampleWidth: Int = 2
    ) throws -> String {
        var params: [String: Any] = [
            "schema": paramsSchema,
            "conversation_handle": scope.conversationHandle,
            "turn_id": scope.turnID as Any,
            "frame": ["kind": kind],
        ]
        if let correlationID = scope.correlationID { params["correlation_id"] = correlationID }
        if kind == "start" {
            params["frame"] = [
                "kind": kind,
                "sample_rate": 24_000,
                "channels": 1,
                "sample_width": sampleWidth,
                "byte_order": "little",
            ]
        }
        if kind == "unavailable", let reason {
            params["frame"] = ["kind": kind, "reason": reason]
        }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": outerSchema,
            "method": "audio.frame",
            "params": params,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private struct Fixture: Sendable {
    let claim: HomeConversationClaim
    let client: URLSessionHomeBridgeSessionClient
    let socket: TestHomeSocket
    let secondSocket: TestHomeSocket
    let factory: TestHomeSocketFactory
    let requests: TestHomeRequestRecorder
}

private struct StaticRouteProvider: HomeApprovedRouteProvider, Sendable {
    let route: HomeApprovedRoute?

    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? {
        route
    }
}

private enum TestJSONRPCCode: Sendable {
    case integer(Int)
    case boolean(Bool)
    case fractional(Double)
    case string(String)
    case missing
}

private actor TestHomeRequestRecorder {
    private var values: [URLRequest] = []

    func record(_ request: URLRequest) { values.append(request) }
    func first() -> URLRequest? { values.first }
    func count() -> Int { values.count }
}

private actor TestHomeSocketFactory: WebSocketConnectionFactory {
    private let sockets: [TestHomeSocket]
    private let recorder: TestHomeRequestRecorder
    private var nextSocketIndex = 0
    private(set) var openCount = 0

    init(sockets: [TestHomeSocket], recorder: TestHomeRequestRecorder) {
        self.sockets = sockets
        self.recorder = recorder
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        await recorder.record(urlRequest)
        openCount += 1
        let index = min(nextSocketIndex, sockets.count - 1)
        nextSocketIndex += 1
        return sockets[index]
    }
}

private actor TestHomeSocket: WebSocketConnection {
    private let claim: HomeConversationClaim
    private var frames: [WebSocketFrame] = []
    private var receivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var sent: [String] = []
    private var closed = false
    private var closes = 0
    private var nextError: (method: String, jsonRPCCode: TestJSONRPCCode, homeCode: String?)?
    private var nextPromptResponseStatus: String?
    private var resultOverrides: [String: String] = [:]

    init(claim: HomeConversationClaim) {
        self.claim = claim
    }

    func send(text: String) async throws {
        sent.append(text)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(object["id"] as? String)
        let method = try XCTUnwrap(object["method"] as? String)
        let params = object["params"] as? [String: Any] ?? [:]
        if let nextError, nextError.method == method {
            self.nextError = nil
            var error: [String: Any] = ["message": "ignored"]
            switch nextError.jsonRPCCode {
            case .integer(let value): error["code"] = value
            case .boolean(let value): error["code"] = value
            case .fractional(let value): error["code"] = value
            case .string(let value): error["code"] = value
            case .missing: break
            }
            if let homeCode = nextError.homeCode {
                error["data"] = [
                    "schema": 1,
                    "code": homeCode,
                    "delivery": "known",
                ]
            }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "schema": 1,
                "id": id,
                "error": error,
            ]
            enqueue(.text(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)))
            return
        }
        if let override = resultOverrides.removeValue(forKey: method) {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "schema": 1,
                "id": id,
                "result": try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(override.utf8)) as? [String: Any]
                ),
            ]
            enqueue(.text(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)))
            return
        }
        let result: [String: Any]
        switch method {
        case "conversation.open":
            result = [
                "schema": 1,
                "status": "ready",
                "conversation_handle": claim.conversationHandle,
                "route": ["class": "home", "id": "home-a"],
                "capabilities": [
                    "commands": ["open"],
                    "heartbeat": true,
                    "timing": "absent",
                    "interrupt": true,
                ],
            ]
        case "conversation.reconnect":
            result = [
                "schema": 1,
                "status": "ready",
                "conversation_handle": claim.conversationHandle,
            ]
        case "prompt.submit":
            result = [
                "schema": 1,
                "status": "accepted",
                "conversation_handle": claim.conversationHandle,
                "turn_id": "turn-1",
                "correlation_id": "correlation-1",
            ]
        case "session.interrupt":
            result = ["status": "acknowledged"]
        case "prompt.respond":
            result = [
                "schema": 1,
                "status": nextPromptResponseStatus ?? "accepted",
                "conversation_handle": params["conversation_handle"] as? String ?? claim.conversationHandle,
                "turn_id": params["turn_id"] as? String ?? "turn-1",
                "correlation_id": params["correlation_id"] as? String ?? "correlation-1",
            ]
            nextPromptResponseStatus = nil
        case "command.dispatch":
            result = [
                "schema": 1,
                "conversation_handle": claim.conversationHandle,
                "correlation_id": "command-1",
                "name": params["name"] as? String ?? "open",
                "status": "completed",
            ]
        case "bridge.ping":
            result = ["status": "alive"]
        default:
            throw TestHomeSocketError.unexpectedMethod
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": 1,
            "id": id,
            "result": result,
        ]
        enqueue(.text(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)))
    }

    func receive() async throws -> WebSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw TestHomeSocketError.closed }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }

    func close() async {
        closes += 1
        closed = true
        let waiters = receivers
        receivers.removeAll()
        frames.removeAll()
        for waiter in waiters { waiter.resume(throwing: TestHomeSocketError.closed) }
    }

    func enqueue(_ frame: WebSocketFrame) {
        if let receiver = receivers.first {
            receivers.removeFirst()
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func sentMethods() throws -> [String] {
        try sent.map { text in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(object["method"] as? String)
        }
    }

    func setNextError(for method: String, jsonRPCCode: Int, homeCode: String) {
        nextError = (method, .integer(jsonRPCCode), homeCode)
    }

    func setNextRawError(
        for method: String,
        code: TestJSONRPCCode,
        homeCode: String?
    ) {
        nextError = (method, code, homeCode)
    }

    func setNextPromptResponseStatus(_ status: String) {
        nextPromptResponseStatus = status
    }

    /// Replaces the next `result` for `method` with a raw JSON object, e.g. a live Home reply.
    func setNextResultJSON(for method: String, _ json: String) {
        resultOverrides[method] = json
    }

    func closeCount() -> Int { closes }
}

private enum TestHomeSocketError: Error {
    case closed
    case unexpectedMethod
}
