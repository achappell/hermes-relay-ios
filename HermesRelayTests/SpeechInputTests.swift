import Foundation
import Speech
import XCTest
@testable import HermesRelayIOS

final class SpeechInputTests: XCTestCase {
    func testAuthorizedStartStreamsPartialAndFinalUpdates() async throws {
        let input = FakeSpeechInput(authorization: .authorized)
        let stream = try await input.start()
        input.emit(SpeechRecognitionUpdate(text: "Hel", isFinal: false))
        input.emit(SpeechRecognitionUpdate(text: "Hello", isFinal: true))
        await input.finish()

        let updates = try await collect(stream)
        XCTAssertEqual(
            updates,
            [
                SpeechRecognitionUpdate(text: "Hel", isFinal: false),
                SpeechRecognitionUpdate(text: "Hello", isFinal: true),
            ]
        )
    }

    func testDeniedPermissionPreventsCapture() async {
        let input = FakeSpeechInput(authorization: .microphoneDenied)

        do {
            _ = try await input.start()
            XCTFail("Denied microphone or speech permission must prevent capture")
        } catch let error as SpeechInputError {
            XCTAssertEqual(error, .notAuthorized)
        } catch {
            XCTFail("Unexpected speech error: \(error)")
        }
    }

    func testRequestAuthorizationReturnsTheTypedOutcome() async {
        let input = FakeSpeechInput(authorization: .notDetermined, requestedAuthorization: .authorized)

        let outcome = await input.requestAuthorization()
        XCTAssertEqual(outcome, .authorized)
    }

    func testCaptureErrorIsPropagated() async {
        let input = FakeSpeechInput(authorization: .authorized, startError: .captureFailed)

        do {
            _ = try await input.start()
            XCTFail("Capture errors must reach the caller")
        } catch let error as SpeechInputError {
            XCTAssertEqual(error, .captureFailed)
        } catch {
            XCTFail("Unexpected speech error: \(error)")
        }
    }

    func testCancellationEmitsNoFinalText() async throws {
        let input = FakeSpeechInput(authorization: .authorized)
        let stream = try await input.start()
        input.emit(SpeechRecognitionUpdate(text: "Draft", isFinal: false))
        await input.cancel()

        var updates: [SpeechRecognitionUpdate] = []
        do {
            for try await update in stream {
                updates.append(update)
            }
        } catch let error as SpeechInputError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(updates, [SpeechRecognitionUpdate(text: "Draft", isFinal: false)])
        XCTAssertFalse(updates.contains(where: \.isFinal))
    }

    func testPermissionResolverDistinguishesSpeechAndMicrophoneDenial() {
        XCTAssertEqual(
            AppleSpeechInput.resolveAuthorization(
                speech: .denied,
                microphone: .authorized
            ),
            .speechDenied
        )
        XCTAssertEqual(
            AppleSpeechInput.resolveAuthorization(
                speech: .authorized,
                microphone: .microphoneDenied
            ),
            .microphoneDenied
        )
    }

    func testNoSpeechRecognitionErrorIsClassifiedSeparately() {
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 1110)

        XCTAssertEqual(
            AppleSpeechInput.mapRecognitionError(error),
            .noSpeech
        )
        XCTAssertEqual(
            AppleSpeechInput.mapRecognitionError(SpeechInputError.captureFailed),
            .captureFailed
        )
        XCTAssertEqual(
            AppleSpeechInput.mapRecognitionError(
                NSError(domain: "kAFAssistantErrorDomain", code: 1101)
            ),
            .captureFailed
        )
    }

    func testSpeechRecognitionSessionNoSpeechFinishesStreamAndReportsMicrophoneEnded() async throws {
        let activityStore = AudioActivityStore()
        let session = SpeechRecognitionSession(activityReporter: activityStore)
        let stream = await session.makeStream()

        let handled = await session.handle(
            text: nil,
            isFinal: false,
            error: .noSpeech
        )
        XCTAssertTrue(handled)

        do {
            _ = try await collect(stream)
            XCTFail("No-speech recognition must terminate the stream with its typed error")
        } catch let error as SpeechInputError {
            XCTAssertEqual(error, .noSpeech)
        }

        let snapshot = await activityStore.currentSnapshot()
        XCTAssertEqual(snapshot.microphoneActivity, .silence)
    }

    func testSpeechBackedHandsFreeInputMergesActivityAndRecognition() async throws {
        let activityStore = AudioActivityStore(minimumEmissionIntervalNanoseconds: 0)
        let speechInput = FakeSpeechInput(authorization: .authorized)
        let handsFreeInput = SpeechBackedHandsFreeInput(
            speechInput: speechInput,
            activityStore: activityStore
        )
        let stream = try await handsFreeInput.start()
        let collector = HandsFreeEventCollector()
        let collectorTask = Task {
            do {
                for try await event in stream {
                    await collector.append(event)
                }
            } catch {
                // The test only cares about the events delivered before finish.
            }
        }

        await activityStore.reportMicrophone(level: 0.20)
        speechInput.emit(SpeechRecognitionUpdate(text: "Hello", isFinal: false))
        await collector.waitForExpectedEvents()
        await handsFreeInput.finish()
        await collectorTask.value

        let events = await collector.snapshot()
        XCTAssertTrue(events.contains(.activity(AudioActivitySnapshot(
            microphoneLevel: 0.20,
            microphoneActivity: .speech,
            playbackLevel: 0,
            playbackActive: false
        ))))
        XCTAssertTrue(events.contains(.recognition(
            SpeechRecognitionUpdate(text: "Hello", isFinal: false)
        )))
    }

    private func collect(
        _ stream: AsyncThrowingStream<SpeechRecognitionUpdate, Error>
    ) async throws -> [SpeechRecognitionUpdate] {
        var updates: [SpeechRecognitionUpdate] = []
        for try await update in stream {
            updates.append(update)
        }
        return updates
    }

}

private final class FakeSpeechInput: SpeechInput, @unchecked Sendable {
    private let currentAuthorization: SpeechAuthorization
    private let requestedAuthorization: SpeechAuthorization
    private let startError: SpeechInputError?
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?

    init(
        authorization: SpeechAuthorization,
        requestedAuthorization: SpeechAuthorization? = nil,
        startError: SpeechInputError? = nil
    ) {
        self.currentAuthorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.startError = startError
    }

    func authorization() async -> SpeechAuthorization {
        currentAuthorization
    }

    func requestAuthorization() async -> SpeechAuthorization {
        requestedAuthorization
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        if let startError { throw startError }
        guard currentAuthorization == .authorized else {
            throw SpeechInputError.notAuthorized
        }
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func cancel() async {
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private actor HandsFreeEventCollector {
    private var events: [HandsFreeInputEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func append(_ event: HandsFreeInputEvent) {
        events.append(event)
        guard hasExpectedEvents else { return }

        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForExpectedEvents() async {
        guard !hasExpectedEvents else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func snapshot() -> [HandsFreeInputEvent] {
        events
    }

    private var hasExpectedEvents: Bool {
        let expectedActivity = AudioActivitySnapshot(
            microphoneLevel: 0.20,
            microphoneActivity: .speech,
            playbackLevel: 0,
            playbackActive: false
        )
        return events.contains(.activity(expectedActivity))
            && events.contains(.recognition(
                SpeechRecognitionUpdate(text: "Hello", isFinal: false)
            ))
    }
}
