import Foundation
import XCTest
@testable import HermesRelayIOS

final class ConversationStoreReconnectTests: XCTestCase {
    @MainActor
    func testUnexpectedLossRetriesWithBoundedBackoffThenReportsExhaustion() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = Array(repeating: .failure(ReconnectFakeError.offline), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(
            sleeps.recorded,
            [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
        )
        XCTAssertEqual(client.connectCount, 6)
        XCTAssertEqual(store.connectionState, .failed("The test relay is offline."))
    }

    @MainActor
    func testExhaustedReconnectStillAllowsAManualRetry() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.connectResults = Array(repeating: .failure(ReconnectFakeError.offline), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()
        client.connectResults = []
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testReconnectRecoversAndSurfacesReconnectingProgress() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = [
            .failure(ReconnectFakeError.offline),
            .failure(ReconnectFakeError.offline),
        ]
        var observed: [ConnectionState] = []
        sleeps.onSleep = { @MainActor in observed.append(store.connectionState) }

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(
            observed,
            [.reconnecting(attempt: 1, of: 5), .reconnecting(attempt: 2, of: 5), .reconnecting(attempt: 3, of: 5)]
        )
        XCTAssertEqual(sleeps.recorded, [500_000_000, 1_000_000_000, 2_000_000_000])
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.sessionMetadata?.sessionID, "session-4")
    }

    @MainActor
    func testReconnectPreservesTranscriptAndDraft() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        await store.sendTurn(text: "keep me")
        store.draft = "half typed"

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(store.messages.first?.text, "keep me")
        XCTAssertEqual(store.draft, "half typed")
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testReconnectNeverReplaysAnInFlightTurn() async {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.sendError = RelaySessionError.disconnected

        await store.sendTurn(text: "did this arrive")
        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(client.sentTurns, ["did this arrive"])
        XCTAssertEqual(store.unconfirmedTurnText, "did this arrive")
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    func testResendingTheUnconfirmedTurnSendsItOnceAndClearsTheMarker() async throws {
        let client = ReconnectingFakeClient()
        let store = makeStore(client: client, sleeps: SleepRecorder())
        await store.connect()
        client.sendError = RelaySessionError.disconnected
        await store.sendTurn(text: "did this arrive")
        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()
        client.sendError = nil

        let unconfirmed = try XCTUnwrap(store.unconfirmedTurnText)
        await store.sendTurn(text: unconfirmed)

        XCTAssertEqual(client.sentTurns, ["did this arrive", "did this arrive"])
        XCTAssertNil(store.unconfirmedTurnText)
    }

    @MainActor
    func testUnrecoverableConfigurationFailureStopsRetrying() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = Array(repeating: .failure(RelayUnavailableError()), count: 5)

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(sleeps.recorded, [500_000_000])
        XCTAssertEqual(client.connectCount, 2)
        XCTAssertEqual(store.connectionState, .failed(RelayUnavailableError().localizedDescription))
    }

    @MainActor
    func testInterruptingATurnDoesNotStartAReconnectLoop() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()

        _ = await store.interruptActiveTurn()

        XCTAssertEqual(sleeps.recorded, [])
        XCTAssertFalse(store.isReconnecting)
    }

    @MainActor
    func testASecondLossWhileReconnectingDoesNotStackAttempts() async {
        let client = ReconnectingFakeClient()
        let sleeps = SleepRecorder()
        let store = makeStore(client: client, sleeps: sleeps)
        await store.connect()
        client.connectResults = [.failure(ReconnectFakeError.offline)]
        sleeps.onSleep = { @MainActor in store.handleUnexpectedTransportLoss() }

        store.handleUnexpectedTransportLoss()
        await store.waitForReconnectToFinish()

        XCTAssertEqual(sleeps.recorded, [500_000_000, 1_000_000_000])
        XCTAssertEqual(client.connectCount, 3)
        XCTAssertEqual(store.connectionState, .connected)
    }

    @MainActor
    private func makeStore(client: ReconnectingFakeClient, sleeps: SleepRecorder) -> ConversationStore {
        ConversationStore(
            client: client,
            reconnectPolicy: .default,
            sleep: { nanoseconds in await sleeps.record(nanoseconds) }
        )
    }
}

private enum ReconnectFakeError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? { "The test relay is offline." }
}

@MainActor
private final class SleepRecorder {
    private(set) var recorded: [UInt64] = []
    var onSleep: (@MainActor () -> Void)?

    func record(_ nanoseconds: UInt64) async {
        recorded.append(nanoseconds)
        onSleep?()
    }
}

@MainActor
private final class ReconnectingFakeClient: HermesSessionClient {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var sentTurns: [String] = []
    var connectResults: [Result<SessionMetadata, Error>] = []
    var sendError: Error?

    nonisolated func connect() async throws -> SessionMetadata {
        try await MainActor.run {
            connectCount += 1
            if !connectResults.isEmpty {
                let result = connectResults.removeFirst()
                return try result.get()
            }
            return SessionMetadata(sessionID: "session-\(connectCount)", model: nil)
        }
    }

    nonisolated func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        let failure = await MainActor.run { () -> Error? in
            sentTurns.append(text)
            return sendError
        }
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(.turnComplete(turnID: "turn-1"))
                continuation.finish()
            }
        }
    }

    nonisolated func disconnect() async {
        await MainActor.run { disconnectCount += 1 }
    }
}
