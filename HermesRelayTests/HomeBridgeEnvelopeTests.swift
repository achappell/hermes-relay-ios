import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeBridgeEnvelopeTests: XCTestCase {
    func testRouteWireShapeUsesClassAndRejectsUnknownKeys() throws {
        let route = HomeWireRoute(routeClass: .home, id: "home-a")
        let encoded = try JSONEncoder().encode(route)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["class", "id"])
        XCTAssertEqual(try JSONDecoder().decode(HomeWireRoute.self, from: encoded), route)

        let withUnknownKey = try JSONSerialization.data(withJSONObject: [
            "class": "home",
            "id": "home-a",
            "household_binding": "must-not-cross-the-wire",
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(HomeWireRoute.self, from: withUnknownKey)
        ) { error in
            XCTAssertEqual(error as? HomeWireDecodingError, .unknownField)
        }
    }

    func testJSONRPCEnvelopeIsSchemaOneAndResponseRequiresExactlyOneOutcome() throws {
        let request = HomeJSONRPCRequest(
            id: "request-1",
            method: "conversation.open",
            params: ["conversation_handle": .string("opaque-home-conversation")]
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(HomeJSONRPCRequest.self, from: requestData)
        XCTAssertEqual(decodedRequest, request)
        XCTAssertTrue(String(decoding: requestData, as: UTF8.self).contains("\"schema\":1"))

        let response = HomeJSONRPCResponse(
            id: "request-1",
            result: ["status": .string("ready")]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                HomeJSONRPCResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )

        let bothOutcomes = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "schema": 1,
            "id": "request-1",
            "result": ["status": "ready"],
            "error": ["code": "request_rejected"],
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(HomeJSONRPCResponse.self, from: bothOutcomes)
        )
    }

    func testJSONRPCErrorUsesNumericCodeAndStableDataCode() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "schema": 1,
            "id": "request-1",
            "error": [
                "code": -32_000,
                "message": "ignored",
                "data": [
                    "schema": 1,
                    "code": "transport_timeout",
                    "delivery": "uncertain",
                ],
            ],
        ])

        let response = try JSONDecoder().decode(HomeJSONRPCResponse.self, from: data)

        let code = try XCTUnwrap(response.error?.code)
        XCTAssertEqual("\(code)", "-32000")
        XCTAssertEqual(response.error?.data?["code"], .string("transport_timeout"))
    }

    func testHomeNormalizerPreservesCumulativePreviewSemanticsAndHidesGlobalTerminal() {
        let scope = HomeEventScope(
            conversationHandle: "opaque-home-conversation",
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        var normalizer = HermesEventNormalizer()

        XCTAssertEqual(
            normalizer.normalizeHome(
                HomeStandardEvent(
                    type: .messageStart,
                    scope: scope,
                    payload: .start(kind: .assistant)
                )
            ),
            [.messageStart]
        )
        XCTAssertEqual(
            normalizer.normalizeHome(
                HomeStandardEvent(
                    type: .messageDelta,
                    scope: scope,
                    payload: .delta(
                        rendered: "Hello",
                        text: nil,
                        replace: false,
                        kind: .assistant
                    )
                )
            ),
            [.textDelta("Hello")]
        )
        XCTAssertEqual(
            normalizer.normalizeHome(
                HomeStandardEvent(
                    type: .messageDelta,
                    scope: scope,
                    payload: .delta(
                        rendered: "Hello, world",
                        text: nil,
                        replace: false,
                        kind: .assistant
                    )
                )
            ),
            [.textDelta(", world")]
        )

        let globalTerminalScope = HomeEventScope(
            conversationHandle: scope.conversationHandle,
            turnID: nil,
            correlationID: nil
        )
        XCTAssertEqual(
            normalizer.normalizeHome(
                HomeStandardEvent(
                    type: .turnComplete,
                    scope: globalTerminalScope,
                    payload: .terminal(kind: .terminal)
                )
            ),
            []
        )
    }

    func testHomeMessageCompleteEndsOnlyATerminalTurn() {
        let scope = HomeEventScope(
            conversationHandle: "opaque-home-conversation",
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        var completedNormalizer = HermesEventNormalizer()

        XCTAssertEqual(
            completedNormalizer.normalizeHome(
                HomeStandardEvent(
                    type: .messageComplete,
                    scope: scope,
                    payload: .final(
                        rendered: "Done.",
                        text: nil,
                        status: "completed",
                        reasoning: nil,
                        failureReason: nil
                    )
                )
            ),
            [
                .textDelta("Done."),
                .messageComplete(text: "Done.", reasoning: "", failureReason: ""),
                .turnComplete(turnID: "turn-1"),
            ]
        )

        var streamingNormalizer = HermesEventNormalizer()
        let streamingEvents = streamingNormalizer.normalizeHome(
            HomeStandardEvent(
                type: .messageComplete,
                scope: scope,
                payload: .final(
                    rendered: "Still working",
                    text: nil,
                    status: "streaming",
                    reasoning: nil,
                    failureReason: nil
                )
            )
        )

        XCTAssertFalse(streamingEvents.contains { event in
            if case .turnComplete = event { return true }
            if case .turnInterrupted = event { return true }
            return false
        })
    }

    func testHomeNormalizerEndsTheTurnOnATerminalStandardMessageComplete() {
        let turn = HomeEventScope(
            conversationHandle: "opaque-home-conversation",
            turnID: "home-turn-1",
            correlationID: nil
        )
        func complete(status: String?, scope: HomeEventScope = turn) -> [HermesEvent] {
            var normalizer = HermesEventNormalizer()
            return normalizer.normalizeHome(HomeStandardEvent(
                type: .messageComplete,
                scope: scope,
                payload: .final(rendered: nil, text: "OK", status: status, reasoning: nil, failureReason: nil)
            ))
        }

        XCTAssertEqual(complete(status: "complete").last, .turnComplete(turnID: "home-turn-1"))
        XCTAssertEqual(complete(status: nil).last, .turnComplete(turnID: "home-turn-1"))
        XCTAssertEqual(
            Array(complete(status: "error").suffix(2)),
            [
                .error("error"),
                .turnInterrupted(turnID: "home-turn-1", reason: "error"),
            ]
        )
        XCTAssertEqual(
            complete(status: "interrupted").last,
            .turnInterrupted(turnID: "home-turn-1", reason: "interrupted")
        )
        XCTAssertFalse(complete(status: "streaming").contains(.turnComplete(turnID: "home-turn-1")))
        let global = HomeEventScope(conversationHandle: turn.conversationHandle, turnID: nil, correlationID: nil)
        XCTAssertFalse(complete(status: "complete", scope: global).contains { event in
            if case .turnComplete = event { return true }
            return false
        })
    }

    func testPersistedRecoveryContainsOpaqueBindingOnly() throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recovery = PersistedHomeRecovery(
            profileID: profileID,
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            route: HomeRouteIdentity(routeClass: .home, id: "home-a"),
            householdBinding: "household-a",
            conversationHandle: "opaque-home-conversation",
            turnID: "turn-1",
            correlationID: "correlation-1",
            submissionAttemptID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"),
            resumeCursor: "cursor-1",
            deliveryState: .accepted,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(recovery)
            ) as? [String: Any]
        )

        XCTAssertFalse(object.keys.contains("text"))
        XCTAssertFalse(object.keys.contains("credential"))
        XCTAssertFalse(object.keys.contains("audio"))
        XCTAssertFalse(object.keys.contains("prompt"))
    }

    func testUnknownMigrationPhaseFallsBackToLegacyRollbackState() throws {
        let profileID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "profileID": profileID.uuidString,
            "phase": "future_phase",
            "selectedMode": "home",
            "legacyCredentialRetained": true,
        ])

        let journal = try JSONDecoder().decode(HomeMigrationJournal.self, from: data)

        XCTAssertEqual(journal.phase, .rollbackPending)
        XCTAssertEqual(journal.selectedMode, .legacy)
        XCTAssertTrue(journal.legacyCredentialRetained)
    }
}
