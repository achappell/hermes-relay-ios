import Foundation
import XCTest
@testable import HermesRelayIOS

final class VoiceSessionCoordinatorTests: XCTestCase {
    @MainActor
    func testReleaseSubmitsOneFinalRecognitionAndStreamsPlayback() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true))
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Hello back"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Hello Herm", isFinal: false))
        await coordinator.endCaptureAndSend()

        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "Hello back")
        let operations = await output.operations()
        XCTAssertEqual(operations, [
            .start(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .append,
            .finish,
        ])
    }

    @MainActor
    func testCancelSubmitsNothingAndPreservesTheDraft() async {
        let input = CoordinatorSpeechInput()
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        store.draft = "Keep this draft"
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Unsubmitted", isFinal: false))
        await coordinator.cancelCapture()

        XCTAssertEqual(client.sentTurns, [])
        XCTAssertEqual(store.draft, "Keep this draft")
        XCTAssertEqual(coordinator.provisionalText, "")
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testDeniedPermissionHasActionableFailureState() async {
        let input = CoordinatorSpeechInput(authorization: .denied)
        let store = await connectedStore(CoordinatorHermesSessionClient())
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()

        XCTAssertEqual(
            coordinator.state,
            .failed("Microphone access is denied. Allow microphone and speech recognition access in Settings.")
        )
    }

    @MainActor
    func testPlaybackFailureKeepsAssistantTextVisible() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let output = CoordinatorAudioOutput(appendError: .outputFailed)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Visible response"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        await coordinator.endCaptureAndSend()

        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertEqual(store.messages.last?.text, "Visible response")
        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
    }

    @MainActor
    func testTypedDraftSendsSlashCommandAndPlaysWAVResponse() async throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let wavURL = try writer.write(pcm: Data([0x01, 0x02, 0x03, 0x04]), format: format)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let input = CoordinatorSpeechInput()
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Voice replies enabled"),
            .audioFileStart(contentType: "audio/wav"),
            .audioFileChunk(try Data(contentsOf: wavURL)),
            .audioFileEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "/voice tts"
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.sendDraft()

        XCTAssertEqual(client.sentTurns, ["/voice tts"])
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(coordinator.state, .idle)
        let operations = await output.operations()
        XCTAssertEqual(operations, [.start(format), .append, .finish])
    }

    @MainActor
    private func connectedStore(_ client: CoordinatorHermesSessionClient) async -> ConversationStore {
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        let store = ConversationStore(client: client)
        await store.connect()
        return store
    }
}

private actor CoordinatorSpeechInput: SpeechInput {
    private let authorizationResult: SpeechAuthorization
    private let finalUpdate: SpeechRecognitionUpdate?
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?

    init(
        authorization: SpeechAuthorization = .authorized,
        finalUpdate: SpeechRecognitionUpdate? = nil
    ) {
        authorizationResult = authorization
        self.finalUpdate = finalUpdate
    }

    func authorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func requestAuthorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish() async {
        if let finalUpdate {
            continuation?.yield(finalUpdate)
        }
        continuation?.finish()
        continuation = nil
    }

    func cancel() async {
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }
}

private actor CoordinatorAudioOutput: AudioOutput {
    enum Operation: Equatable {
        case start(AudioFormat)
        case append
        case finish
        case stop
    }

    private let appendError: AudioOutputError?
    private var recordedOperations: [Operation] = []

    init(appendError: AudioOutputError? = nil) {
        self.appendError = appendError
    }

    func start(format: AudioFormat) async throws {
        recordedOperations.append(.start(format))
    }

    func append(_ pcm: Data) async throws {
        if let appendError { throw appendError }
        recordedOperations.append(.append)
    }

    func finish() async {
        recordedOperations.append(.finish)
    }

    func stop() async {
        recordedOperations.append(.stop)
    }

    func operations() -> [Operation] {
        recordedOperations
    }
}

private final class CoordinatorHermesSessionClient: HermesSessionClient, @unchecked Sendable {
    var connectResult: Result<SessionMetadata, Error> = .failure(CoordinatorClientError.offline)
    var events: [HermesEvent] = [.turnComplete(turnID: "turn-1")]
    private(set) var sentTurns: [String] = []

    init(events: [HermesEvent] = [.turnComplete(turnID: "turn-1")]) {
        self.events = events
    }

    func connect() async throws -> SessionMetadata {
        try connectResult.get()
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        let events = events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func disconnect() async {}
}

private enum CoordinatorClientError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? { "The test relay is offline." }
}
