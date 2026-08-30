import Foundation
import XCTest
@testable import HermesRelayIOS

final class ConversationStoreTransportTests: XCTestCase {
    @MainActor
    func testConnectStoresMetadataWhenClientConnects() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: "test-model"))
        let store = ConversationStore(client: client)

        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.sessionMetadata, SessionMetadata(sessionID: "session-1", model: "test-model"))
    }

    @MainActor
    func testConnectionFailureIsVisible() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .failure(FakeClientError.offline)
        let store = ConversationStore(client: client)

        await store.connect()

        XCTAssertEqual(store.connectionState, .failed("The test relay is offline."))
        XCTAssertEqual(store.transientError, "The test relay is offline.")
        XCTAssertNil(store.sessionMetadata)
    }

    @MainActor
    func testSendTurnUpdatesOneAssistantForStreamedText() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["Hello Hermes"] = [
            .messageStart,
            .textDelta("Hello "),
            .textDelta("Hermes"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "Hello Hermes")

        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "Hello Hermes")
        XCTAssertFalse(store.isSending)
    }

    @MainActor
    func testTextReplacementChangesActiveAssistantWithoutAppending() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["revise"] = [
            .messageStart,
            .textDelta("Draft"),
            .textReplace("Final"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "revise")

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.text, "Final")
    }

    @MainActor
    func testStatusDoesNotBecomeTranscript() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["status"] = [
            .status(text: "Working", kind: "tool"),
            .messageStart,
            .textDelta("Done"),
            .turnComplete(turnID: "turn-1"),
        ]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "status")

        XCTAssertEqual(store.activityText, "Working")
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertFalse(store.messages.contains { $0.text == "Working" })
    }

    @MainActor
    func testServerErrorIsVisibleAndTurnEndsSendingState() async {
        let client = FakeHermesSessionClient()
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        client.eventsByText["fail"] = [.error("Relay failed")]
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "fail")

        XCTAssertEqual(store.transientError, "Relay failed")
        XCTAssertEqual(store.messages.last?.role, .error)
        XCTAssertFalse(store.isSending)
    }
}

private enum FakeClientError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? {
        "The test relay is offline."
    }
}

private final class FakeHermesSessionClient: HermesSessionClient, @unchecked Sendable {
    var connectResult: Result<SessionMetadata, Error> = .success(
        SessionMetadata(sessionID: "session-1", model: nil)
    )
    var eventsByText: [String: [HermesEvent]] = [:]
    private(set) var sentTurns: [String] = []

    func connect() async throws -> SessionMetadata {
        try connectResult.get()
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        let events = eventsByText[text] ?? [.turnComplete(turnID: "turn-1")]
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func disconnect() async {}
}
