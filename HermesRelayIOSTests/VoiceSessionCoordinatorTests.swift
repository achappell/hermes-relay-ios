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
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(coordinator.provisionalText, "Hello Herm")
        XCTAssertTrue(store.messages.isEmpty)
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
    func testReleaseWaitsForCaptureStartBeforeSending() async {
        let input = DelayedStartCoordinatorSpeechInput(
            finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true)
        )
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        let beginTask = Task { @MainActor in
            await coordinator.beginCapture()
        }
        await input.waitUntilStartRequested()

        let endTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await Task.yield()
        XCTAssertEqual(client.sentTurns, [])

        await input.allowStart()
        await beginTask.value
        await endTask.value

        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
    }

    @MainActor
    func testReleaseDoesNotStayTranscribingWhenRecognitionNeverFinishes() async {
        let input = HangingFinishCoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            recognitionFinishTimeoutNanoseconds: 10_000_000
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Partial phrase", isFinal: false))

        let endTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.sentTurns, ["Partial phrase"])

        await input.cancel()
        await endTask.value
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testReleaseDoesNotStayTranscribingWhenSpeechFinishBlocks() async {
        let input = BlockingFinishCoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            recognitionFinishTimeoutNanoseconds: 10_000_000
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Partial phrase", isFinal: false))

        let endTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(client.sentTurns, ["Partial phrase"])

        await input.allowFinish()
        await endTask.value
        XCTAssertEqual(coordinator.state, .idle)
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
    func testRecognitionFailureDoesNotSubmitProvisionalText() async {
        let input = FailingAfterPartialCoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Do not send this", isFinal: false))
        await input.fail()

        await coordinator.endCaptureAndSend()

        XCTAssertEqual(client.sentTurns, [])
        XCTAssertEqual(
            coordinator.state,
            .failed("The voice capture could not be started.")
        )
    }

    @MainActor
    func testRecognitionFailureReleasesTheCaptureSlotForRetry() async {
        let input = FailingAfterPartialCoordinatorSpeechInput()
        let store = await connectedStore(CoordinatorHermesSessionClient())
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await input.fail()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            coordinator.state,
            .failed("The voice capture could not be started.")
        )

        await coordinator.beginCapture()

        XCTAssertEqual(coordinator.state, .listening)
        await coordinator.cancelCapture()
    }

    @MainActor
    func testCancelDuringCaptureStartDoesNotEnterListening() async {
        let input = DelayedStartCoordinatorSpeechInput(
            finalUpdate: SpeechRecognitionUpdate(text: "Do not send this", isFinal: true)
        )
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        let beginTask = Task { @MainActor in
            await coordinator.beginCapture()
        }
        await input.waitUntilStartRequested()

        await coordinator.cancelCapture()
        let wasCancelled = await input.wasCancelled()
        XCTAssertTrue(wasCancelled)

        await input.allowStart()
        await beginTask.value

        XCTAssertEqual(client.sentTurns, [])
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testDeniedPermissionHasActionableFailureState() async {
        let input = CoordinatorSpeechInput(authorization: .microphoneDenied)
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
    func testSpeechPermissionHasActionableFailureState() async {
        let input = CoordinatorSpeechInput(authorization: .speechDenied)
        let store = await connectedStore(CoordinatorHermesSessionClient())
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()

        XCTAssertEqual(
            coordinator.state,
            .failed("Speech recognition access is denied. Allow speech recognition access in Settings.")
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
    func testFinishPlaybackFailureKeepsAssistantTextVisible() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let output = CoordinatorAudioOutput(finishError: .outputFailed)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Visible response"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
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

private actor FailingAfterPartialCoordinatorSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?

    func authorization() async -> SpeechAuthorization { .authorized }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }

    func fail() {
        continuation?.finish(throwing: SpeechInputError.captureFailed)
        continuation = nil
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
    }

    func cancel() async {
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }
}

private actor DelayedStartCoordinatorSpeechInput: SpeechInput {
    private let finalUpdate: SpeechRecognitionUpdate
    private var didRequestStart = false
    private var wasCancelRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var inputContinuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?

    init(finalUpdate: SpeechRecognitionUpdate) {
        self.finalUpdate = finalUpdate
    }

    func authorization() async -> SpeechAuthorization { .authorized }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        didRequestStart = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }

        if wasCancelRequested {
            throw SpeechInputError.cancelled
        }

        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        inputContinuation = continuation
        return stream
    }

    func waitUntilStartRequested() async {
        if didRequestStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func allowStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func wasCancelled() -> Bool {
        wasCancelRequested
    }

    func finish() async {
        inputContinuation?.yield(finalUpdate)
        inputContinuation?.finish()
        inputContinuation = nil
    }

    func cancel() async {
        wasCancelRequested = true
        startContinuation?.resume()
        startContinuation = nil
        inputContinuation?.finish(throwing: SpeechInputError.cancelled)
        inputContinuation = nil
    }
}

private actor HangingFinishCoordinatorSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?

    func authorization() async -> SpeechAuthorization { .authorized }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }

    func finish() async {}

    func cancel() async {
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }
}

private actor BlockingFinishCoordinatorSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func authorization() async -> SpeechAuthorization { .authorized }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            finishWaiter = continuation
        }
    }

    func allowFinish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    func cancel() async {
        finishWaiter?.resume()
        finishWaiter = nil
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
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
    private let finishError: AudioOutputError?
    private var recordedOperations: [Operation] = []

    init(
        appendError: AudioOutputError? = nil,
        finishError: AudioOutputError? = nil
    ) {
        self.appendError = appendError
        self.finishError = finishError
    }

    func start(format: AudioFormat) async throws {
        recordedOperations.append(.start(format))
    }

    func append(_ pcm: Data) async throws {
        if let appendError { throw appendError }
        recordedOperations.append(.append)
    }

    func finish() async throws {
        if let finishError { throw finishError }
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
