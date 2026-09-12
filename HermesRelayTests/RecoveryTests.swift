import Foundation
import XCTest
@testable import HermesRelayIOS

final class RecoveryTests: XCTestCase {
    @MainActor
    func testFailedSendPreservesDraftAndPersistsIt() async {
        let persistence = RecordingConversationPersistence()
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client, persistence: persistence)
        await store.connect()
        store.draft = "Do not lose this"

        await store.sendDraft()

        XCTAssertEqual(store.draft, "Do not lose this")
        XCTAssertEqual(store.unconfirmedTurnText, "Do not lose this")
        let saved = await persistence.lastSaved()
        XCTAssertEqual(saved?.draft, "Do not lose this")
    }

    @MainActor
    func testReconnectDoesNotReplayAnUnconfirmedTurn() async {
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client)
        await store.connect()

        await store.sendTurn(text: "Maybe sent")
        await store.connect()

        XCTAssertEqual(client.sentTurns, ["Maybe sent"])
        XCTAssertEqual(store.unconfirmedTurnText, "Maybe sent")
    }

    @MainActor
    func testCompletedTurnClearsTheUnconfirmedMarker() async {
        let client = RecoveryHermesSessionClient(mode: .disconnect)
        let store = ConversationStore(client: client)
        await store.connect()
        await store.sendTurn(text: "First attempt")

        client.mode = .complete
        await store.connect()
        await store.sendTurn(text: "Second attempt")

        XCTAssertEqual(client.sentTurns, ["First attempt", "Second attempt"])
        XCTAssertNil(store.unconfirmedTurnText)
    }
}

private actor RecordingConversationPersistence: ConversationPersistence {
    private var savedConversation: PersistedConversation?

    func load() async throws -> PersistedConversation {
        savedConversation ?? PersistedConversation(messages: [], draft: "")
    }

    func save(_ conversation: PersistedConversation) async throws {
        savedConversation = conversation
    }

    func lastSaved() -> PersistedConversation? {
        savedConversation
    }
}

private final class RecoveryHermesSessionClient: HermesSessionClient, @unchecked Sendable {
    enum Mode {
        case disconnect
        case complete
    }

    var mode: Mode
    private(set) var sentTurns: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func connect() async throws -> SessionMetadata {
        SessionMetadata(sessionID: "session-1", model: nil)
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        let mode = mode
        return AsyncThrowingStream { continuation in
            switch mode {
            case .disconnect:
                continuation.finish(throwing: RelaySessionError.disconnected)
            case .complete:
                continuation.yield(.messageStart)
                continuation.yield(.textDelta("Confirmed"))
                continuation.yield(.turnComplete(turnID: "turn-1"))
                continuation.finish()
            }
        }
    }

    func disconnect() async {}
}
