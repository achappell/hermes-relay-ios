import Foundation
import Observation
import XCTest
@testable import HermesRelayIOS

final class VoiceSessionCoordinatorTests: XCTestCase {
    @MainActor
    func testVoiceCaptureFailsClosedBeforeMicrophoneWhenSessionIsNotVerified() async {
        let input = CoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = ConversationStore(client: client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()

        XCTAssertEqual(
            coordinator.state,
            .failed("Connect to the Hermes relay before starting a voice turn.")
        )
        let startCount = await input.startCount()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(client.sentTurns, [])
        XCTAssertTrue(store.messages.isEmpty)
    }

    @MainActor
    func testCaptureDoesNotSubmitAfterVerifiedSessionChanges() async {
        let input = CoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Do not retarget", isFinal: false))
        store.sessionMetadata = SessionMetadata(sessionID: "replacement-session", model: nil)

        await coordinator.endCaptureAndSend()

        XCTAssertEqual(
            coordinator.state,
            .failed("The selected Hermes Profile changed. Start a new turn.")
        )
        XCTAssertEqual(store.transientError, "The selected Hermes Profile changed. Start a new turn.")
        XCTAssertEqual(client.sentTurns, [])
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testVoiceControlRemainsEnabledToInterruptAfterCaptureActionStarted() {
        XCTAssertTrue(
            VoiceControlInteractionPolicy.isDisabled(
                isActionInFlight: true,
                state: .transcribing
            )
        )
        XCTAssertFalse(
            VoiceControlInteractionPolicy.isDisabled(
                isActionInFlight: true,
                state: .speaking
            )
        )
    }

    @MainActor
    func testAmbientHUDTracksLiveRecognitionUpdatesFromCoordinator() async {
        let input = CoordinatorSpeechInput()
        let store = await connectedStore(CoordinatorHermesSessionClient())
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )
        await coordinator.beginCapture()

        let view = AmbientHUDView(
            presentation: AmbientHUDPresentation(
                voiceState: .listening,
                activity: .safe,
                provisionalText: "",
                messages: []
            ),
            connectionState: .connected,
            sessionStartedAt: nil,
            transcriptMessages: [],
            provisionalText: "",
            isResponseActive: false,
            activeAssistantID: nil,
            voiceCoordinator: coordinator,
            speechTimings: [],
            playbackDuration: nil,
            playbackPosition: nil,
            isPlaybackDurationFinal: false,
            hasTranscript: false,
            canConfigure: false,
            unconfirmedTurnText: nil,
            onResendUnconfirmedTurn: {},
            onConfigure: {},
            onConnect: {},
            onShowHistory: {}
        )

        let observationFlag = ObservationFlag()
        withObservationTracking {
            _ = view.body
        } onChange: {
            observationFlag.markChanged()
        }

        await input.emit(SpeechRecognitionUpdate(text: "Live phrase", isFinal: false))
        for _ in 0..<3 { await Task.yield() }

        XCTAssertTrue(observationFlag.didChange)
        await coordinator.cancelCapture()
    }

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
        XCTAssertEqual(coordinator.state, .complete)
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
    func testLateProcessingAndUnknownEventsDoNotRegressSpeaking() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let output = CoordinatorAudioOutput(
            appendReadiness: .ready,
            waitsForFinish: true
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("A streamed answer."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .status(text: "Still thinking", kind: nil),
            .thinkingDelta("Still thinking"),
            .unknown(type: "future.secret_event"),
            .turnComplete(turnID: "turn-1"),
            .audioEnd,
        ])
        let store = await connectedStore(client)
        store.draft = "Ask Hermes"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await output.waitUntilFinishRequested()

        XCTAssertEqual(coordinator.state.label, "Speaking")

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state.label, "Complete")
    }

    @MainActor
    func testLateProcessingAndUnknownEventsDoNotRegressBuffering() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let output = CoordinatorAudioOutput(
            appendReadiness: .buffering,
            waitsForFinish: true
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("A buffered answer."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .status(text: "Still thinking", kind: nil),
            .thinkingDelta("Still thinking"),
            .unknown(type: "future.secret_event"),
            .turnComplete(turnID: "turn-1"),
            .audioEnd,
        ])
        let store = await connectedStore(client)
        store.draft = "Ask Hermes to buffer"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await output.waitUntilFinishRequested()

        XCTAssertEqual(coordinator.state.label, "Buffering")

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state.label, "Complete")
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
        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
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
        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
    }

    @MainActor
    func testNewCaptureWaitsForPreviousSpeechFinishToComplete() async {
        let input = NoSpeechBlockingFinishCoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()

        let endTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await input.waitUntilFinishStarted()
        await endTask.value

        let beginTask = Task { @MainActor in
            await coordinator.beginCapture()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let startsBeforeRelease = await input.startCount()
        XCTAssertEqual(startsBeforeRelease, 1)

        await input.allowFinish()
        await beginTask.value

        let startsAfterRelease = await input.startCount()
        XCTAssertEqual(startsAfterRelease, 2)
        XCTAssertEqual(coordinator.state, .listening)
        await coordinator.cancelCapture()
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
    func testNoSpeechCaptureReturnsToReadyWithoutSubmittingOrReportingFailure() async {
        let input = CoordinatorSpeechInput(finishError: .noSpeech)
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await coordinator.endCaptureAndSend()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(store.transientError)
        XCTAssertEqual(client.sentTurns, [])
    }

    @MainActor
    func testUnexpectedNoSpeechResetsCaptureAndAllowsRetryWithoutSendingPartialText() async {
        let input = CoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Partial phrase", isFinal: false))
        await input.emitError(.noSpeech)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.provisionalText, "")
        XCTAssertEqual(client.sentTurns, [])

        await coordinator.beginCapture()

        let startCount = await input.startCount()
        XCTAssertEqual(startCount, 2)
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
            .failed(.permission(.microphoneDenied))
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
            .failed(.permission(.speechDenied))
        )
    }

    @MainActor
    func testPermissionRevokedDuringStartPreservesSettingsRecovery() async {
        let input = AuthorizationRaceCoordinatorSpeechInput()
        let store = await connectedStore(CoordinatorHermesSessionClient())
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()

        XCTAssertEqual(
            coordinator.state,
            .failed(.permission(.microphoneDenied))
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
    func testMessageCompletionFailurePreservesTextAndReportsFailure() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("The text is still available."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .messageComplete(
                text: "The text is still available.",
                reasoning: "",
                failureReason: "Audio response unavailable."
            ),
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Ask without audio"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.sendDraft()

        XCTAssertEqual(store.messages.last?.text, "The text is still available.")
        XCTAssertEqual(coordinator.state.label, "Audio response unavailable.")
        let operations = await output.operations()
        XCTAssertTrue(operations.contains(.stop))
        XCTAssertFalse(operations.contains(.finish))
    }

    @MainActor
    func testTextWithoutAudioPreservesTheResponseAndReportsUnavailablePlayback() async {
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("A text-only response."),
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Ask for text"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.sendDraft()

        XCTAssertEqual(store.messages.last?.text, "A text-only response.")
        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
        let operations = await output.operations()
        XCTAssertEqual(operations, [.stop])
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
    func testAudioDiagnosticsExposeContentSafeStreamPhases() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let diagnostics = RecordingAudioPlaybackDiagnostics()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Visible response"),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            diagnostics: diagnostics
        )

        await coordinator.beginCapture()
        await coordinator.endCaptureAndSend()

        let events = await diagnostics.events()
        XCTAssertEqual(events, [
            .segmentBoundary(index: 0, phase: .started, playbackPositionMilliseconds: nil),
            .streamStarted(format: format),
            .chunkReceived(bytes: 4),
            .streamEnded(bytes: 4),
            .segmentBoundary(index: 0, phase: .ended, playbackPositionMilliseconds: nil),
        ])
    }

    @MainActor
    func testCoordinatorStaysBufferingUntilAudioOutputReportsReadiness() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let output = CoordinatorAudioOutput(
            appendReadiness: .buffering,
            waitsForFinish: true
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilFinishRequested()

        XCTAssertEqual(coordinator.state, .buffering)

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state, .complete)
    }

    @MainActor
    func testCoordinatorReportsSpeakingAfterFirstAudioBufferIsReady() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let output = CoordinatorAudioOutput(
            appendReadiness: .ready,
            waitsForFinish: true
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilFinishRequested()

        XCTAssertEqual(coordinator.state, .speaking)

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state, .complete)
    }

    @MainActor
    func testCoordinatorPublishesPlaybackPositionForSpeechTiming() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let timing = SpeechTiming(
            segmentID: "segment-1",
            text: "Hermes keeps speaking.",
            timingSource: .alignment,
            audioOffset: 0,
            duration: 0.9,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
                SpeechTimingWord(text: "speaking.", startTime: 0.48, endTime: 0.9),
            ]
        )
        let output = CoordinatorAudioOutput(
            waitsForFinish: true,
            playbackPosition: 0.58
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Hermes keeps speaking."),
            .speechTiming(timing),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data(repeating: 0, count: 48_000)),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilFinishRequested()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(coordinator.speechTimings, [timing])
        XCTAssertNil(
            coordinator.playbackDuration,
            "The partial stream must not publish a duration before audioEnd."
        )
        XCTAssertFalse(coordinator.isPlaybackDurationFinal)
        XCTAssertEqual(coordinator.playbackPosition ?? -1, 0.58, accuracy: 0.001)

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.playbackDuration ?? -1, 1.0, accuracy: 0.001)
        XCTAssertTrue(coordinator.isPlaybackDurationFinal)
    }

    @MainActor
    func testCoordinatorReplacesTimingRevisionAndSortsSegments() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true))
        let output = CoordinatorAudioOutput(waitsForFinish: true)
        let initialSegment = SpeechTiming(
            segmentID: "segment-1",
            text: "keeps",
            timingSource: .durationFallback,
            audioOffset: 0.25,
            duration: 0.4,
            fallbackReason: .timeout,
            words: []
        )
        let revisedSegment = SpeechTiming(
            segmentID: "segment-1",
            text: "keeps",
            timingSource: .alignment,
            audioOffset: 0.25,
            duration: 0.4,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.65),
            ]
        )
        let firstSegment = SpeechTiming(
            segmentID: "segment-0",
            text: "Hermes",
            timingSource: .alignment,
            audioOffset: 0,
            duration: 0.25,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
            ]
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Hermes keeps"),
            .speechTiming(initialSegment),
            .speechTiming(firstSegment),
            .speechTiming(revisedSegment),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data(repeating: 0, count: 48_000)),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilFinishRequested()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(coordinator.speechTimings.map(\.segmentID), ["segment-0", "segment-1"])
        XCTAssertEqual(coordinator.speechTimings.last?.timingSource, .alignment)

        await output.allowFinish()
        await responseTask.value
    }

    @MainActor
    func testInterruptStopsPlaybackReconnectsAndBeginsNewCapture() async {
        let input = CoordinatorSpeechInput(
            finalUpdate: SpeechRecognitionUpdate(text: "Interrupt me", isFinal: true)
        )
        let output = CoordinatorAudioOutput()
        let client = InterruptibleCoordinatorHermesSessionClient()
        let store = ConversationStore(client: client)
        await store.connect()
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilAppendRequested()

        XCTAssertEqual(coordinator.state, .speaking)
        XCTAssertEqual(coordinator.speechTimings.map(\.segmentID), ["interrupt-segment"])

        await coordinator.interruptAndBeginCapture()

        let disconnectCount = await client.disconnectCount
        let connectCount = await client.connectCount
        let sentTurns = await client.sentTurns
        let operations = await output.operations()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(sentTurns, ["Interrupt me"])
        XCTAssertTrue(operations.contains(.stop))
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertEqual(store.connectionState, .connected)

        await coordinator.cancelCapture()
        await responseTask.value
    }

    @MainActor
    func testServerConfirmedInterruptStopsPlaybackWithoutDisconnecting() async {
        let input = CoordinatorSpeechInput(
            finalUpdate: SpeechRecognitionUpdate(text: "Interrupt me", isFinal: true)
        )
        let output = CoordinatorAudioOutput()
        let client = InterruptibleCoordinatorHermesSessionClient(supportsInterrupt: true)
        let store = ConversationStore(client: client)
        await store.connect()
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilAppendRequested()

        await coordinator.interruptAndBeginCapture()

        let disconnectCount = await client.disconnectCount
        let interruptCount = await client.interruptCount
        let operations = await output.operations()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(interruptCount, 1)
        XCTAssertTrue(operations.contains(.stop))
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "partial response")
        XCTAssertNil(store.unconfirmedTurnText)
        XCTAssertEqual(coordinator.state, .listening)

        await coordinator.cancelCapture()
        await responseTask.value
    }

    @MainActor
    func testStopPlaybackUsesServerInterruptWithoutStartingCapture() async {
        let input = CoordinatorSpeechInput(
            finalUpdate: SpeechRecognitionUpdate(text: "Interrupt me", isFinal: true)
        )
        let output = CoordinatorAudioOutput()
        let client = InterruptibleCoordinatorHermesSessionClient(supportsInterrupt: true)
        let store = ConversationStore(client: client)
        await store.connect()
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

        await coordinator.beginCapture()
        let responseTask = Task { @MainActor in
            await coordinator.endCaptureAndSend()
        }
        await output.waitUntilAppendRequested()

        await coordinator.stopPlayback()

        let interruptCount = await client.interruptCount
        let disconnectCount = await client.disconnectCount
        XCTAssertEqual(interruptCount, 1)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(coordinator.state, .interrupted)

        await responseTask.value
    }

    @MainActor
    func testAudioAbortStopsPlaybackWithoutTurningAnIntentionalInterruptIntoFailure() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("partial response"),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioAbort(turnID: "turn-1", reason: "client interrupt"),
            .turnInterrupted(turnID: "turn-1", reason: "turn interrupted"),
        ])
        let store = await connectedStore(client)
        store.draft = "interrupt this"
        let output = CoordinatorAudioOutput()
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.sendDraft()

        XCTAssertEqual(coordinator.state, .interrupted)
        if case .failed = coordinator.state {
            XCTFail("An intentional interruption must not be reported as playback failure")
        }
        let operations = await output.operations()
        XCTAssertTrue(operations.contains(.stop))
        XCTAssertFalse(operations.contains(.finish))
        XCTAssertEqual(store.messages.last?.text, "partial response")
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
        XCTAssertEqual(coordinator.state, .complete)
        XCTAssertEqual(
            coordinator.playbackDuration ?? -1,
            Double(4) / Double(format.sampleRate * format.channels * format.sampleWidth),
            accuracy: 0.000_001
        )
        let operations = await output.operations()
        XCTAssertEqual(operations, [.start(format), .append, .finish])
    }

    @MainActor
    func testResendingAnUnconfirmedTurnPlaysTheResponseLikeAnyOtherTurn() async throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let wavURL = try writer.write(pcm: Data([0x01, 0x02, 0x03, 0x04]), format: format)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Answering the resent turn"),
            .audioFileStart(contentType: "audio/wav"),
            .audioFileChunk(try Data(contentsOf: wavURL)),
            .audioFileEnd,
            .turnComplete(turnID: "turn-2"),
        ])
        let store = await connectedStore(client)
        store.unconfirmedTurnText = "Did this one arrive"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.resendUnconfirmedTurn()

        XCTAssertEqual(client.sentTurns, ["Did this one arrive"])
        XCTAssertNil(store.unconfirmedTurnText)
        XCTAssertEqual(coordinator.state, .complete)
        let operations = await output.operations()
        XCTAssertEqual(operations, [.start(format), .append, .finish])
    }

    @MainActor
    func testResendingWithNoUnconfirmedTurnSendsNothing() async {
        let client = CoordinatorHermesSessionClient(events: [.turnComplete(turnID: "turn-1")])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput()
        )

        await coordinator.resendUnconfirmedTurn()

        XCTAssertEqual(client.sentTurns, [])
    }

    // A multi-segment answer emits audio_start/audio_end per paragraph. Each
    // audio_end used to report the whole response finished, so the HUD said
    // "Ready" and the reveal froze while Hermes was still talking.
    @MainActor
    func testSegmentEndDoesNotEndTheResponse() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let recorder = SegmentBoundaryStateRecorder()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("First paragraph."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .textDelta(" Second paragraph."),
            .audioStart(format),
            .audioChunk(Data([4, 5, 6, 7])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Tell me something long"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: StateRecordingAudioOutput(recorder: recorder)
        )
        recorder.provider = { [weak coordinator] in coordinator?.state ?? .idle }

        await coordinator.sendDraft()
        await Task.yield()

        // The gap between paragraphs stays "Speaking": the answer is ongoing.
        XCTAssertEqual(recorder.statesAfterSegmentEnd, [.speaking, .speaking])
        XCTAssertEqual(coordinator.state, .complete)
    }

    @MainActor
    func testSingleSegmentAnswerStillEndsComplete() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("One paragraph."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Say one thing"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.sendDraft()

        XCTAssertEqual(coordinator.state.label, "Complete")
        let operations = await output.operations()
        XCTAssertEqual(operations, [.start(format), .append, .finish])
    }

    @MainActor
    func testFileAudioKeepsResponseActiveUntilFileDeliveryFinishes() async throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let wavURL = try writer.write(pcm: Data([0x01, 0x02, 0x03, 0x04]), format: format)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let output = StartGatedAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("File-backed answer."),
            .audioFileStart(contentType: "audio/wav"),
            .audioFileChunk(try Data(contentsOf: wavURL)),
            .turnComplete(turnID: "turn-1"),
            .audioFileEnd,
        ])
        let store = await connectedStore(client)
        store.draft = "Ask with file audio"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await output.waitUntilStartRequested()

        XCTAssertEqual(coordinator.state.label, "Buffering")

        await output.allowStart()
        await output.waitUntilFinishRequested()
        XCTAssertEqual(coordinator.state.label, "Speaking")

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state.label, "Complete")
        XCTAssertEqual(store.messages.last?.text, "File-backed answer.")
    }

    @MainActor
    func testTerminalStateIgnoresLateEventsAndKeepsTheDeliveredResponse() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let timing = SpeechTiming(
            segmentID: "late-segment",
            text: "late",
            timingSource: .durationFallback,
            audioOffset: 0,
            duration: 0.1,
            fallbackReason: .invalid,
            words: []
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Delivered response."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
            .status(text: "late status", kind: nil),
            .thinkingDelta("late thinking"),
            .speechTiming(timing),
            .error("late error"),
            .audioAbort(turnID: "turn-1", reason: "late abort"),
            .turnInterrupted(turnID: "turn-1", reason: "late interruption"),
            .messageComplete(
                text: "Delivered response.",
                reasoning: "",
                failureReason: "late failure"
            ),
            .textDelta(" invented tail"),
            .unknown(type: "future.secret_event"),
        ])
        let store = await connectedStore(client)
        store.draft = "Keep the settled response"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput()
        )

        await coordinator.sendDraft()

        XCTAssertEqual(coordinator.state, .complete)
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.text, "Delivered response.")
        XCTAssertNil(store.transientError)
        XCTAssertTrue(coordinator.speechTimings.isEmpty)
    }

    // Completion can arrive before the last segment's audio has drained.
    @MainActor
    func testCompletionBeforeTheFinalSegmentStillEndsComplete() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Answer."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .turnComplete(turnID: "turn-1"),
            .audioEnd,
        ])
        let store = await connectedStore(client)
        store.draft = "Say something"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput()
        )

        await coordinator.sendDraft()

        XCTAssertEqual(coordinator.state, .complete)
    }

    // The end of the response stream is terminal: no further audio can arrive.
    // Requiring a trailing audio_end to leave Speaking left the HUD stuck.
    @MainActor
    func testResponseEndsCompleteWhenTheStreamClosesWithoutATrailingAudioEnd() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("An answer."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(
                finalUpdate: SpeechRecognitionUpdate(text: "Say something", isFinal: true)
            ),
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        await coordinator.endCaptureAndSend()

        XCTAssertEqual(coordinator.state, .complete)
    }

    // IOS-32 instrumentation: one run must show whether the playback clock
    // restarts per segment while timing offsets keep climbing.
    @MainActor
    func testSegmentBoundariesAndSpeechTimingAreRecordedForDiagnosis() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let diagnostics = RecordingAudioPlaybackDiagnostics()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .audioStart(format),
            .speechTiming(
                SpeechTiming(
                    segmentID: "segment-0",
                    text: "First",
                    timingSource: .alignment,
                    audioOffset: 0,
                    duration: 1.5,
                    fallbackReason: nil,
                    words: [SpeechTimingWord(text: "First", startTime: 0, endTime: 1.5)]
                )
            ),
            .audioChunk(Data([0, 1, 2, 3])),
            .audioEnd,
            .audioStart(format),
            .speechTiming(
                SpeechTiming(
                    segmentID: "segment-1",
                    text: "Second",
                    timingSource: .durationFallback,
                    audioOffset: 1.5,
                    duration: 2.0,
                    fallbackReason: .invalid,
                    words: []
                )
            ),
            .audioChunk(Data([4, 5, 6, 7])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Tell me something long"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            diagnostics: diagnostics
        )

        await coordinator.sendDraft()

        let recorded = await diagnostics.events()
        var boundaryIndexes: [Int] = []
        var boundaryPhases: [AudioSegmentPhase] = []
        for event in recorded {
            guard case .segmentBoundary(let index, let phase, _) = event else { continue }
            boundaryIndexes.append(index)
            boundaryPhases.append(phase)
        }
        XCTAssertEqual(boundaryIndexes, [0, 0, 1, 1])
        XCTAssertEqual(
            boundaryPhases,
            [AudioSegmentPhase.started, .ended, .started, .ended]
        )

        var timingSegments: [Int] = []
        var timingOffsets: [Int] = []
        var timingFallbacks: [String?] = []
        for event in recorded {
            guard case .speechTimingReceived(
                let segmentIndex,
                let audioOffsetMilliseconds,
                _,
                _,
                _,
                let fallbackReason
            ) = event else { continue }
            timingSegments.append(segmentIndex)
            timingOffsets.append(audioOffsetMilliseconds)
            timingFallbacks.append(fallbackReason)
        }
        XCTAssertEqual(timingSegments, [0, 1])
        XCTAssertEqual(timingOffsets, [0, 1500])
        XCTAssertEqual(timingFallbacks, [nil, "invalid"])
    }

    // The relay streams audio far faster than it plays: a 76-second answer
    // arrives in seconds. Ending the response when the event stream closes
    // therefore announced Ready — and froze the caption — while the phone was
    // still speaking. The response ends when playback drains.
    @MainActor
    func testResponseWaitsForPlaybackToDrainWhenTheStreamClosesEarly() async {
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let output = CoordinatorAudioOutput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("A long answer."),
            .audioStart(format),
            .audioChunk(Data([0, 1, 2, 3])),
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        store.draft = "Tell me something long"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: output
        )

        await coordinator.sendDraft()

        // finish() is what waits for the scheduled buffers to play out.
        let operations = await output.operations()
        XCTAssertEqual(operations, [.start(format), .append, .finish])
        XCTAssertEqual(coordinator.state, .complete)
    }

    func testHandsFreeBargeInRequiresAnEchoSafeAudioRoute() {
        XCTAssertTrue(
            HandsFreeBargeInPolicy.shouldInterrupt(
                state: .speaking,
                route: .echoSafe
            )
        )
        XCTAssertFalse(
            HandsFreeBargeInPolicy.shouldInterrupt(
                state: .speaking,
                route: .notEchoSafe
            )
        )
        XCTAssertFalse(
            HandsFreeBargeInPolicy.shouldInterrupt(
                state: .speaking,
                route: .unknown
            )
        )
        XCTAssertTrue(
            HandsFreeBargeInPolicy.shouldInterrupt(
                state: .thinking,
                route: .notEchoSafe
            )
        )
    }

    @MainActor
    func testHandsFreeDoesNotStartUntilExplicitlyArmed() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        XCTAssertFalse(coordinator.isHandsFreeArmed)
        let initialStartCount = await handsFreeInput.startCount()
        XCTAssertEqual(initialStartCount, 0)

        await coordinator.toggleHandsFree()

        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertEqual(coordinator.handsFreeStatus, .armed)
        let armedStartCount = await handsFreeInput.startCount()
        XCTAssertEqual(armedStartCount, 1)

        await coordinator.disableHandsFree()
        XCTAssertFalse(coordinator.isHandsFreeArmed)
        XCTAssertEqual(coordinator.handsFreeStatus, .disarmed)
    }

    @MainActor
    func testHandsFreeSilenceAndBackgroundNoiseNeverSubmitATurn() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.backgroundNoise)))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(client.sentTurns, [])
        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeQuietMonitoringDoesNotCycleTheMicrophone() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)
        let startCount = await handsFreeInput.startCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(client.sentTurns, [])
        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertEqual(coordinator.state, .idle)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeRecognizerTerminationRestartsMonitoringWithoutSubmitting() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.fail(with: .noSpeech)
        for _ in 0..<20 { await Task.yield() }

        let startCount = await handsFreeInput.startCount()
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(client.sentTurns, [])
        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertEqual(coordinator.state, .idle)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeRecognizerTerminationDuringCaptureWaitsForSilence() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 20_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "First turn", isFinal: true))
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        // Speech.framework can end its recognition stream after a final
        // result even while the activity endpoint is still open.
        await handsFreeInput.endStream()
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.handsFreeStatus, .listening)
        XCTAssertEqual(coordinator.provisionalText, "First turn")
        XCTAssertEqual(client.sentTurns, [])
        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)

        // A later recognition request must be allowed to replace the text
        // from the request that terminated; the first request's final result
        // is not the hands-free turn boundary.
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Complete first turn", isFinal: false))
        )
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(client.sentTurns, ["Complete first turn"])

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeNoSpeechDuringCapturePreservesPartialUntilSilence() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 1_000_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "First turn", isFinal: false))
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await handsFreeInput.fail(with: .noSpeech)
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.handsFreeStatus, .listening)
        XCTAssertEqual(coordinator.provisionalText, "First turn")
        XCTAssertEqual(client.sentTurns, [])

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeRecognitionWakesCaptureWhenActivityGateMissesSpeech() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 1_000_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: false))
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertEqual(coordinator.provisionalText, "Hello Hermes")

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreePermissionFailureNamesTheRequiredAction() async {
        let handsFreeInput = CoordinatorHandsFreeInput(authorization: .microphoneDenied)
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()

        XCTAssertFalse(coordinator.isHandsFreeArmed)
        XCTAssertEqual(
            coordinator.handsFreeStatus,
            .failed(.permission(.microphoneDenied))
        )
        XCTAssertEqual(
            coordinator.state,
            .failed(.permission(.microphoneDenied))
        )
    }

    @MainActor
    func testHandsFreeSpeechSubmitsOneTurnAfterSilenceAndKeepsMonitoring() async {
        let handsFreeInput = CoordinatorHandsFreeInput(
            finishUpdate: SpeechRecognitionUpdate(text: "Final Hermes", isFinal: true)
        )
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Answer"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "  Hello Hermes  ", isFinal: false))
        )
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        for _ in 0..<30 { await Task.yield() }

        XCTAssertEqual(client.sentTurns, ["Final Hermes"])
        XCTAssertEqual(coordinator.state, .complete)
        XCTAssertTrue(coordinator.isHandsFreeArmed)
        let startCount = await handsFreeInput.startCount()
        XCTAssertGreaterThanOrEqual(startCount, 2)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeDoesNotResubmitHermesResponseAsTheNextTurn() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Answer"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            routeSafetyProvider: FixedHandsFreeRouteSafetyProvider(.notEchoSafe),
            handsFreeSilenceDurationNanoseconds: 0
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "First question", isFinal: true))
        )
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        for _ in 0..<60 { await Task.yield() }

        XCTAssertEqual(client.sentTurns, ["First question"])
        XCTAssertEqual(coordinator.state, .complete)

        // This is the text Speech.framework can produce from Hermes's own
        // answer after playback. It must not wake a second turn by itself.
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        for _ in 0..<20 { await Task.yield() }
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Hermes answer", isFinal: true))
        )
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        for _ in 0..<60 { await Task.yield() }

        XCTAssertEqual(client.sentTurns, ["First question"])
        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertFalse(coordinator.isHandsFreeCaptureActive)

        // A real post-response speech-activity event still opens the next
        // capture window, even though recognizer-only wake remains suppressed.
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeAllowsAOneSecondPauseBeforeEndingCapture() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 900_000_000)

        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.handsFreeStatus, .listening)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeBackgroundNoiseDoesNotEndAnActiveCapture() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 100_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.backgroundNoise)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Still talking", isFinal: false))
        )
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.provisionalText, "Still talking")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeRecognitionCancelsAStaleSilenceEndpoint() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 100_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Still speaking", isFinal: false))
        )
        try? await Task.sleep(nanoseconds: 150_000_000)

        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.provisionalText, "Still speaking")

        await coordinator.disableHandsFree()
    }

    @MainActor
    func testHandsFreeRepeatedSilenceDoesNotResetTheEndpoint() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 80_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))

        let silenceTask = Task {
            for _ in 0..<20 {
                await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let finishCount = await handsFreeInput.finishCount()
        XCTAssertGreaterThanOrEqual(finishCount, 1)

        silenceTask.cancel()
        await silenceTask.value
        await coordinator.disableHandsFree()
    }

    @MainActor
    func testDisarmingHandsFreeCancelsAnActiveCaptureAndReturnsToReady() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            handsFreeSilenceDurationNanoseconds: 1_000_000_000
        )

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Draft", isFinal: false))
        )
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await coordinator.disableHandsFree()

        let cancelCount = await handsFreeInput.cancelCount()
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        XCTAssertFalse(coordinator.isHandsFreeArmed)
        XCTAssertFalse(coordinator.isHandsFreeCaptureActive)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.provisionalText, "")
    }

    @MainActor
    func testHandsFreeBargeInStaysBlockedOnAnUnsafePlaybackRoute() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = InterruptibleCoordinatorHermesSessionClient(supportsInterrupt: true)
        let store = ConversationStore(client: client)
        await store.connect()
        store.draft = "Start the answer"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            routeSafetyProvider: FixedHandsFreeRouteSafetyProvider(.notEchoSafe),
            handsFreeSilenceDurationNanoseconds: 0
        )

        let responseTask = Task { await coordinator.sendDraft() }
        await client.waitUntilTurnStarted()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.state, .speaking)
        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(
            .activity(handsFreeSnapshot(.speech, playbackActive: true))
        )
        for _ in 0..<20 { await Task.yield() }

        let interruptCount = await client.interruptCount
        XCTAssertEqual(interruptCount, 0)
        XCTAssertEqual(coordinator.handsFreeStatus, .blockedByAudioRoute)
        XCTAssertEqual(coordinator.state, .speaking)

        await coordinator.disableHandsFree()
        _ = await coordinator.interruptActiveTurn()
        await responseTask.value
    }

    @MainActor
    func testHandsFreeBargeInInterruptsSafelyAndStartsOneNewCapture() async {
        let handsFreeInput = CoordinatorHandsFreeInput()
        let client = InterruptibleCoordinatorHermesSessionClient(supportsInterrupt: true)
        let store = ConversationStore(client: client)
        await store.connect()
        store.draft = "Start the answer"
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(),
            handsFreeInput: handsFreeInput,
            routeSafetyProvider: FixedHandsFreeRouteSafetyProvider(.echoSafe),
            handsFreeSilenceDurationNanoseconds: 0
        )

        let responseTask = Task { await coordinator.sendDraft() }
        await client.waitUntilTurnStarted()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.state, .speaking)

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(
            .activity(handsFreeSnapshot(.speech, playbackActive: true))
        )
        for _ in 0..<30 { await Task.yield() }

        let interruptCount = await client.interruptCount
        XCTAssertEqual(interruptCount, 1)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await coordinator.disableHandsFree()
        await responseTask.value
    }

    @MainActor
    private func connectedStore(_ client: CoordinatorHermesSessionClient) async -> ConversationStore {
        client.connectResult = .success(SessionMetadata(sessionID: "session-1", model: nil))
        let store = ConversationStore(client: client)
        await store.connect()
        return store
    }
}

private actor CoordinatorHandsFreeInput: HandsFreeInput {
    private let authorizationResult: SpeechAuthorization
    private let finishUpdate: SpeechRecognitionUpdate?
    private var continuation: AsyncThrowingStream<HandsFreeInputEvent, Error>.Continuation?
    private var starts = 0
    private var finishes = 0
    private var cancels = 0

    init(
        authorization: SpeechAuthorization = .authorized,
        finishUpdate: SpeechRecognitionUpdate? = nil
    ) {
        authorizationResult = authorization
        self.finishUpdate = finishUpdate
    }

    func authorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func requestAuthorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func start() async throws -> AsyncThrowingStream<HandsFreeInputEvent, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<HandsFreeInputEvent, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func startCount() -> Int {
        starts
    }

    func finishCount() -> Int {
        finishes
    }

    func cancelCount() -> Int {
        cancels
    }

    func finish() async {
        finishes += 1
        if let finishUpdate {
            continuation?.yield(.recognition(finishUpdate))
        }
        continuation?.finish()
        continuation = nil
    }

    func cancel() async {
        cancels += 1
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }

    func emit(_ event: HandsFreeInputEvent) {
        continuation?.yield(event)
    }

    func fail(with error: SpeechInputError) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func endStream() {
        continuation?.finish()
        continuation = nil
    }
}

private struct FixedHandsFreeRouteSafetyProvider: HandsFreeAudioRouteSafetyProvider {
    let safety: HandsFreeAudioRouteSafety

    init(_ safety: HandsFreeAudioRouteSafety) {
        self.safety = safety
    }

    func currentSafety() async -> HandsFreeAudioRouteSafety {
        safety
    }
}

private func handsFreeSnapshot(
    _ activity: MicrophoneActivity,
    playbackActive: Bool = false
) -> AudioActivitySnapshot {
    let microphoneLevel: Float
    switch activity {
    case .silence:
        microphoneLevel = 0
    case .backgroundNoise:
        microphoneLevel = 0.04
    case .speech:
        microphoneLevel = 0.20
    case .unavailable:
        microphoneLevel = 0
    }

    return AudioActivitySnapshot(
        microphoneLevel: microphoneLevel,
        microphoneActivity: activity,
        playbackLevel: playbackActive ? 0.8 : 0,
        playbackActive: playbackActive
    )
}

private final class ObservationFlag: @unchecked Sendable {
    private(set) var didChange = false

    func markChanged() {
        didChange = true
    }
}

private actor CoordinatorSpeechInput: SpeechInput {
    private let authorizationResult: SpeechAuthorization
    private let finalUpdate: SpeechRecognitionUpdate?
    private let finishError: SpeechInputError?
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?
    private var starts = 0

    init(
        authorization: SpeechAuthorization = .authorized,
        finalUpdate: SpeechRecognitionUpdate? = nil,
        finishError: SpeechInputError? = nil
    ) {
        authorizationResult = authorization
        self.finalUpdate = finalUpdate
        self.finishError = finishError
    }

    func authorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func requestAuthorization() async -> SpeechAuthorization {
        authorizationResult
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func startCount() -> Int {
        starts
    }

    func finish() async {
        if let finishError {
            continuation?.finish(throwing: finishError)
        } else if let finalUpdate {
            continuation?.yield(finalUpdate)
            continuation?.finish()
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    func cancel() async {
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }

    func emit(_ update: SpeechRecognitionUpdate) {
        continuation?.yield(update)
    }

    func emitError(_ error: SpeechInputError) {
        continuation?.finish(throwing: error)
        continuation = nil
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

private actor NoSpeechBlockingFinishCoordinatorSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?
    private var finishStarted = false
    private var finishStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishReleaseWaiter: CheckedContinuation<Void, Never>?
    private var starts = 0

    func authorization() async -> SpeechAuthorization { .authorized }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func startCount() -> Int {
        starts
    }

    func waitUntilFinishStarted() async {
        if finishStarted { return }
        await withCheckedContinuation { continuation in
            finishStartWaiters.append(continuation)
        }
    }

    func finish() async {
        finishStarted = true
        for waiter in finishStartWaiters {
            waiter.resume()
        }
        finishStartWaiters.removeAll()
        continuation?.finish(throwing: SpeechInputError.noSpeech)
        continuation = nil

        await withCheckedContinuation { continuation in
            finishReleaseWaiter = continuation
        }
    }

    func allowFinish() {
        finishReleaseWaiter?.resume()
        finishReleaseWaiter = nil
    }

    func cancel() async {
        finishReleaseWaiter?.resume()
        finishReleaseWaiter = nil
        continuation?.finish(throwing: SpeechInputError.cancelled)
        continuation = nil
    }
}

private actor AuthorizationRaceCoordinatorSpeechInput: SpeechInput {
    private var authorizationResults: [SpeechAuthorization] = [
        .authorized,
        .microphoneDenied,
    ]

    func authorization() async -> SpeechAuthorization {
        if authorizationResults.count > 1 {
            return authorizationResults.removeFirst()
        }
        return authorizationResults[0]
    }

    func requestAuthorization() async -> SpeechAuthorization {
        .microphoneDenied
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        throw SpeechInputError.notAuthorized
    }

    func finish() async {}

    func cancel() async {}
}

@MainActor
final class SegmentBoundaryStateRecorder {
    private(set) var statesAfterSegmentEnd: [VoiceState] = []
    var provider: (@MainActor () -> VoiceState)?

    func recordAfterCurrentWork() {
        // `handle` runs serially on the MainActor and has no suspension point
        // between `output.finish()` returning and the state assignment that
        // follows it, so a task enqueued here observes the settled state.
        Task { @MainActor in
            guard let provider else { return }
            self.statesAfterSegmentEnd.append(provider())
        }
    }
}

private actor StateRecordingAudioOutput: AudioOutput {
    private let recorder: SegmentBoundaryStateRecorder

    init(recorder: SegmentBoundaryStateRecorder) {
        self.recorder = recorder
    }

    func start(format: AudioFormat) async throws {}

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        .ready
    }

    func finish() async throws {
        await recorder.recordAfterCurrentWork()
    }

    func stop() async {}

    func playbackPosition() async -> TimeInterval? { nil }
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
    private let appendReadiness: AudioPlaybackReadiness
    private let waitsForFinish: Bool
    private let reportedPlaybackPosition: TimeInterval?
    private var finishRequested = false
    private var finishRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendRequested = false
    private var appendRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var recordedOperations: [Operation] = []

    init(
        appendError: AudioOutputError? = nil,
        finishError: AudioOutputError? = nil,
        appendReadiness: AudioPlaybackReadiness = .ready,
        waitsForFinish: Bool = false,
        playbackPosition: TimeInterval? = nil
    ) {
        self.appendError = appendError
        self.finishError = finishError
        self.appendReadiness = appendReadiness
        self.waitsForFinish = waitsForFinish
        self.reportedPlaybackPosition = playbackPosition
    }

    func start(format: AudioFormat) async throws {
        recordedOperations.append(.start(format))
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        if let appendError { throw appendError }
        recordedOperations.append(.append)
        appendRequested = true
        for waiter in appendRequestWaiters {
            waiter.resume()
        }
        appendRequestWaiters.removeAll()
        return appendReadiness
    }

    func finish() async throws {
        if let finishError { throw finishError }
        recordedOperations.append(.finish)
        finishRequested = true
        for waiter in finishRequestWaiters {
            waiter.resume()
        }
        finishRequestWaiters.removeAll()
        guard waitsForFinish else { return }
        await withCheckedContinuation { continuation in
            finishWaiter = continuation
        }
    }

    func stop() async {
        recordedOperations.append(.stop)
    }

    func playbackPosition() async -> TimeInterval? { reportedPlaybackPosition }

    func operations() -> [Operation] {
        recordedOperations
    }

    func waitUntilFinishRequested() async {
        if finishRequested { return }
        await withCheckedContinuation { continuation in
            finishRequestWaiters.append(continuation)
        }
    }

    func waitUntilAppendRequested() async {
        if appendRequested { return }
        await withCheckedContinuation { continuation in
            appendRequestWaiters.append(continuation)
        }
    }

    func allowFinish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

private actor StartGatedAudioOutput: AudioOutput {
    private var startRequested = false
    private var startRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishRequested = false
    private var finishRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func start(format: AudioFormat) async throws {
        startRequested = true
        for waiter in startRequestWaiters {
            waiter.resume()
        }
        startRequestWaiters.removeAll()
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        .ready
    }

    func finish() async throws {
        finishRequested = true
        for waiter in finishRequestWaiters {
            waiter.resume()
        }
        finishRequestWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishWaiter = continuation
        }
    }

    func stop() async {}

    func playbackPosition() async -> TimeInterval? { nil }

    func waitUntilStartRequested() async {
        if startRequested { return }
        await withCheckedContinuation { continuation in
            startRequestWaiters.append(continuation)
        }
    }

    func allowStart() {
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitUntilFinishRequested() async {
        if finishRequested { return }
        await withCheckedContinuation { continuation in
            finishRequestWaiters.append(continuation)
        }
    }

    func allowFinish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

private actor RecordingAudioPlaybackDiagnostics: AudioPlaybackDiagnostics {
    private var recordedEvents: [AudioPlaybackDiagnostic] = []

    func record(_ event: AudioPlaybackDiagnostic) async {
        recordedEvents.append(event)
    }

    func events() -> [AudioPlaybackDiagnostic] {
        recordedEvents
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

private actor InterruptibleCoordinatorHermesSessionClient: HermesSessionClient {
    private let supportsInterrupt: Bool
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var interruptCount = 0
    private(set) var sentTurns: [String] = []
    private var turnContinuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var turnStarted = false
    private var turnStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(supportsInterrupt: Bool = false) {
        self.supportsInterrupt = supportsInterrupt
    }

    func connect() async throws -> SessionMetadata {
        connectCount += 1
        return SessionMetadata(
            sessionID: "session-\(connectCount)",
            model: nil,
            capabilities: supportsInterrupt ? ["interrupt"] : []
        )
    }

    func sendTurn(text: String) async -> AsyncThrowingStream<HermesEvent, Error> {
        sentTurns.append(text)
        let (stream, continuation) = AsyncThrowingStream<HermesEvent, Error>.makeStream()
        turnContinuation = continuation
        turnStarted = true
        turnStartWaiters.forEach { $0.resume() }
        turnStartWaiters.removeAll()
        continuation.yield(.messageStart)
        continuation.yield(.textDelta("partial response"))
        continuation.yield(
            .speechTiming(
                SpeechTiming(
                    segmentID: "interrupt-segment",
                    text: "Interrupt me",
                    timingSource: .durationFallback,
                    audioOffset: 0,
                    duration: 0.4,
                    fallbackReason: .timeout,
                    words: []
                )
            )
        )
        continuation.yield(
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2))
        )
        continuation.yield(.audioChunk(Data([0, 1, 2, 3])))
        return stream
    }

    func interruptActiveTurn() async -> Bool {
        guard supportsInterrupt else { return false }
        interruptCount += 1
        turnContinuation?.yield(.audioAbort(turnID: "turn-1", reason: "client interrupt"))
        turnContinuation?.yield(.turnInterrupted(turnID: "turn-1", reason: "turn interrupted"))
        turnContinuation?.finish()
        turnContinuation = nil
        return true
    }

    func disconnect() async {
        disconnectCount += 1
        turnContinuation?.yield(.textDelta("late response"))
        turnContinuation?.finish(throwing: RelaySessionError.disconnected)
        turnContinuation = nil
    }

    func waitUntilTurnStarted() async {
        if turnStarted { return }
        await withCheckedContinuation { continuation in
            turnStartWaiters.append(continuation)
        }
    }
}

private enum CoordinatorClientError: LocalizedError, Sendable {
    case offline

    var errorDescription: String? { "The test relay is offline." }
}
