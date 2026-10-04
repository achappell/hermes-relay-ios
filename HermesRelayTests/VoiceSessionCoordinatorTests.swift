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
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        while !condition() {
            let change = ObservationFlag()
            withObservationTracking {
                _ = condition()
            } onChange: {
                change.markChanged()
            }

            let didChange = await change.waitUntilChanged(
                timeoutNanoseconds: UInt64(timeout * 1_000_000_000)
            )
            guard didChange else {
                XCTFail("Timed out waiting for observed condition", file: file, line: line)
                return
            }
        }
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
        _ = await observationFlag.waitUntilChanged()

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
        await waitUntil { coordinator.provisionalText == "Hello Herm" }
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
    func testATappedRecordingSendsItselfAfterAPause() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true))
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Hello back"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            handsFreeSilenceDurationNanoseconds: 20_000_000
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Hello Herm", isFinal: false))

        // No second tap: the pause after the last word sends the turn.
        await waitUntil { coordinator.state == .complete }
        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
    }

    @MainActor
    func testATapAndThePauseEndingTheSameRecordingSendOnce() async {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true))
        let client = CoordinatorHermesSessionClient(events: [
            .messageStart,
            .textDelta("Hello back"),
            .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
            .audioChunk(Data([0, 1])),
            .audioEnd,
            .turnComplete(turnID: "turn-1"),
        ])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(store: store, input: input, output: CoordinatorAudioOutput())

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Hello Herm", isFinal: false))
        await waitUntil { coordinator.provisionalText == "Hello Herm" }

        // The user taps to send just as the pause timer fires.
        async let tap: Void = coordinator.endCaptureAndSend()
        async let pause: Void = coordinator.endCaptureAndSend()
        _ = await (tap, pause)

        XCTAssertEqual(client.sentTurns, ["Hello Hermes"])
        XCTAssertEqual(coordinator.state, .complete)
        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
    }

    @MainActor
    func testNoPauseClockRunsBeforeTheFirstWord() async throws {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true))
        let client = CoordinatorHermesSessionClient(events: [.turnComplete(turnID: "turn-1")])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            handsFreeSilenceDurationNanoseconds: 20_000_000
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "  ", isFinal: false))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(client.sentTurns, [], "Silence before speaking must not send")
        XCTAssertTrue(coordinator.state.isCaptureActive)
        await coordinator.cancelCapture()
    }

    @MainActor
    func testCancelStopsThePauseClockWithoutSending() async throws {
        let input = CoordinatorSpeechInput(finalUpdate: SpeechRecognitionUpdate(text: "Hello Hermes", isFinal: true))
        let client = CoordinatorHermesSessionClient(events: [.turnComplete(turnID: "turn-1")])
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput(),
            handsFreeSilenceDurationNanoseconds: 20_000_000
        )

        await coordinator.beginCapture()
        await input.emit(SpeechRecognitionUpdate(text: "Never mind", isFinal: false))
        await waitUntil { coordinator.provisionalText == "Never mind" }
        await coordinator.cancelCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(client.sentTurns, [])
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testLateProcessingAndUnknownEventsDoNotRegressSpeaking() async throws {
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
        let activeAssistantID = try XCTUnwrap(store.activeAssistantID)
        let projection = RecentTranscriptProjection(
            messages: store.messages,
            provisionalText: coordinator.provisionalText,
            isResponseActive: coordinator.state.isResponseActive,
            activeAssistantID: store.activeAssistantID
        )
        XCTAssertTrue(
            projection.entries.contains {
                $0.id == activeAssistantID.uuidString && $0.isLive
            },
            "The assistant response remains live while playback drains."
        )

        await output.allowFinish()
        await responseTask.value
        XCTAssertEqual(coordinator.state.label, "Complete")
        XCTAssertNil(store.activeAssistantID)
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

    // Distinct from the `.noSpeech` error path (see
    // testNoSpeechCaptureReturnsToReadyWithoutSubmittingOrReportingFailure):
    // here the recognition stream simply closes with no final and no partial
    // text at all, exercising the plain `guard !text.isEmpty` branch in
    // `endCaptureAndSend()` rather than the recognizer-error branch.
    @MainActor
    func testEmptyFinalRecognitionEndsCaptureWithoutSubmittingATurn() async {
        let input = CoordinatorSpeechInput()
        let client = CoordinatorHermesSessionClient()
        let store = await connectedStore(client)
        let coordinator = VoiceSessionCoordinator(
            store: store,
            input: input,
            output: CoordinatorAudioOutput()
        )

        await coordinator.beginCapture()
        XCTAssertEqual(coordinator.state, .listening)

        await coordinator.endCaptureAndSend()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(client.sentTurns, [])
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(coordinator.provisionalText, "")
        XCTAssertNil(store.transientError)
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
        await waitUntil { coordinator.state == .idle }

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
        await waitUntil { coordinator.speechTimings == [timing] }

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
        await waitUntil { coordinator.speechTimings.count == 2 }

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
        await recorder.waitUntilRecorded()

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
    func testHomeVoiceInvalidAudioPreservesTextAndReportsPlaybackFailure() async throws {
        let fixture = try await makeHomeVoiceReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()

        let output = CoordinatorAudioOutput()
        let coordinator = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: output
        )
        fixture.store.draft = "Home voice request"

        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 1)

        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.client.emit(.audioTerminal(scope, .invalid))
        await fixture.client.emit(
            .standard(
                HomeStandardEvent(
                    type: .messageComplete,
                    scope: scope,
                    payload: .final(
                        rendered: nil,
                        text: "Home text survives invalid audio",
                        status: "complete",
                        reasoning: nil,
                        failureReason: nil
                    )
                )
            )
        )
        await fixture.client.emit(
            .standard(
                HomeStandardEvent(
                    type: .turnComplete,
                    scope: scope,
                    payload: .terminal(kind: .terminal)
                )
            )
        )
        await responseTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
        XCTAssertEqual(fixture.store.messages.last?.text, "Home text survives invalid audio")
        let submittedTexts = await fixture.client.submittedTexts
        XCTAssertEqual(submittedTexts, ["Home voice request"])
    }

    @MainActor
    func testHomeAudioLongerThanTheSilenceDeadlinePlaysThrough() async throws {
        // Pilot 2026-09-27: Home streams speech at about real time, and every
        // reply whose audio took over 30 s to arrive was cut off as
        // "Audio playback failed" while its audio was still arriving.
        let fixture = try await makeHomeVoiceReviewFixture(
            audioDeadlines: HomeTurnAudioDeadlines(
                audioStart: .seconds(5),
                controlTerminal: .seconds(30),
                audioTerminal: .milliseconds(300),
                playbackDrain: .seconds(5)
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()
        let coordinator = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput()
        )
        fixture.store.draft = "Tell me a long story"
        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.client.emit(.audioStart(
            scope,
            HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        ))
        // Nine chunks 100 ms apart: 900 ms of streaming, three times the
        // deadline, with no silence longer than it.
        for _ in 0..<9 {
            await fixture.client.emit(.binaryPCM(scope, Data([0, 1, 2, 3])))
            try await Task.sleep(for: .milliseconds(100))
        }
        await fixture.client.emit(.audioTerminal(scope, .end))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: nil,
                text: "Once upon a time",
                status: "complete",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        await responseTask.value

        XCTAssertNotEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
    }

    @MainActor
    func testHomeSlowTextReplyStillPlaysAudioThatStartsAfterTheTurnCompletes() async throws {
        let fixture = try await makeHomeVoiceReviewFixture(
            audioDeadlines: HomeTurnAudioDeadlines(
                audioStart: .milliseconds(200),
                controlTerminal: .seconds(30),
                audioTerminal: .seconds(5),
                playbackDrain: .seconds(5)
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()
        let output = CoordinatorAudioOutput()
        let coordinator = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: output
        )
        fixture.store.draft = "Think about it for a while"
        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        try await Task.sleep(for: .milliseconds(600))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: nil,
                text: "Here is my answer",
                status: "complete",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        await fixture.client.emit(.audioStart(
            scope,
            HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        ))
        await fixture.client.emit(.binaryPCM(scope, Data([0, 1, 2, 3])))
        await fixture.client.emit(.audioTerminal(scope, .end))
        await responseTask.value

        XCTAssertNotEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
        let operations = await output.operations()
        XCTAssertTrue(operations.contains(.append), "Home audio was not delivered: \(operations)")
    }

    @MainActor
    func testHomeAudioThatNeverStartsAfterTheTurnCompletesStillFails() async throws {
        let fixture = try await makeHomeVoiceReviewFixture(
            audioDeadlines: HomeTurnAudioDeadlines(
                audioStart: .milliseconds(200),
                controlTerminal: .seconds(30),
                audioTerminal: .seconds(5),
                playbackDrain: .seconds(5)
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()
        let output = CoordinatorAudioOutput()
        let coordinator = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: output
        )
        fixture.store.draft = "Say something"
        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: nil,
                text: "Here is my answer",
                status: "complete",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        let completionTime = ContinuousClock.now
        await responseTask.value

        XCTAssertGreaterThanOrEqual(
            ContinuousClock.now - completionTime,
            .milliseconds(150),
            "The no-audio failure should be delayed until the post-completion deadline"
        )
        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )
        let operations = await output.operations()
        XCTAssertFalse(operations.contains(.append))
    }

    @MainActor
    func testHomePlaybackDrainFailureReleasesTurnForNextRequest() async throws {
        let fixture = try await makeHomeVoiceReviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent()) }
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()

        let coordinator = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: CoordinatorAudioOutput(finishError: .outputFailed)
        )
        fixture.store.draft = "Home voice request"
        let responseTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 1)

        let scope = HomeEventScope(
            conversationHandle: fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.client.emit(.audioStart(
            scope,
            HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        ))
        await fixture.client.emit(.binaryPCM(scope, Data([0, 1, 2, 3])))
        await fixture.client.emit(.audioTerminal(scope, .end))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: nil,
                text: "Answer",
                status: "complete",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await fixture.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        await responseTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed("Audio playback failed. The response text is still available.")
        )

        // Home delivered the turn; failed local playback must not leave it
        // in flight, or the next turn is refused as already in progress.
        fixture.store.draft = "Second Home request"
        let secondTask = Task { @MainActor in
            await coordinator.sendDraft()
        }
        await waitForHomeVoiceSubmission(fixture.client, atLeast: 2)
        secondTask.cancel()
        let allSubmitted = await fixture.client.submittedTexts
        XCTAssertEqual(allSubmitted, ["Home voice request", "Second Home request"])
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
            HandsFreeBargeInPolicy.shouldInterrupt(state: .speaking, route: .echoSafe, interruptByTalking: true)
        )
        XCTAssertFalse(
            HandsFreeBargeInPolicy.shouldInterrupt(state: .speaking, route: .notEchoSafe, interruptByTalking: true)
        )
        XCTAssertFalse(
            HandsFreeBargeInPolicy.shouldInterrupt(state: .speaking, route: .unknown, interruptByTalking: true)
        )
        XCTAssertTrue(
            HandsFreeBargeInPolicy.shouldInterrupt(state: .thinking, route: .notEchoSafe, interruptByTalking: true)
        )
    }

    func testVoiceInterruptionIsOffUnlessOptedIn() {
        for state in [VoiceState.thinking, .buffering, .speaking] {
            for route in [HandsFreeAudioRouteSafety.echoSafe, .notEchoSafe, .unknown] {
                XCTAssertFalse(
                    HandsFreeBargeInPolicy.shouldInterrupt(state: state, route: route, interruptByTalking: false),
                    "Without the opt-in only a tap interrupts (\(state), \(route))"
                )
            }
        }
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

        await coordinator.disableHandsFree()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(client.sentTurns, [])
        let finishCount = await handsFreeInput.finishCount()
        XCTAssertEqual(finishCount, 0)
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
        await handsFreeInput.waitUntilStartCount(2)

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
        await waitUntil { coordinator.isHandsFreeCaptureActive }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        // Speech.framework can end its recognition stream after a final
        // result even while the activity endpoint is still open.
        await handsFreeInput.endStream()
        await handsFreeInput.waitUntilStartCount(2)

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
        await waitUntil { coordinator.isHandsFreeCaptureActive }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await handsFreeInput.fail(with: .noSpeech)
        await handsFreeInput.waitUntilStartCount(2)

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
        await waitUntil { coordinator.provisionalText == "Hello Hermes" }

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
        await waitUntil { coordinator.state == .complete }

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
        await waitUntil { coordinator.state == .complete }

        XCTAssertEqual(client.sentTurns, ["First question"])
        XCTAssertEqual(coordinator.state, .complete)

        // This is the text Speech.framework can produce from Hermes's own
        // answer after playback. It must not wake a second turn by itself.
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Hermes answer", isFinal: true))
        )
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))

        XCTAssertEqual(client.sentTurns, ["First question"])
        XCTAssertTrue(coordinator.isHandsFreeArmed)
        XCTAssertFalse(coordinator.isHandsFreeCaptureActive)

        // A real post-response speech-activity event still opens the next
        // capture window, even though recognizer-only wake remains suppressed.
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.speech)))
        await waitUntil { coordinator.isHandsFreeCaptureActive }

        XCTAssertEqual(client.sentTurns, ["First question"])
        XCTAssertTrue(coordinator.isHandsFreeArmed)
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
        await waitUntil { coordinator.isHandsFreeCaptureActive }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
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
        await waitUntil { coordinator.isHandsFreeCaptureActive }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)
        await handsFreeInput.emit(.activity(handsFreeSnapshot(.backgroundNoise)))
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Still talking", isFinal: false))
        )
        await waitUntil { coordinator.provisionalText == "Still talking" }
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
        await waitUntil { coordinator.isHandsFreeCaptureActive }
        XCTAssertTrue(coordinator.isHandsFreeCaptureActive)

        await handsFreeInput.emit(.activity(handsFreeSnapshot(.silence)))
        try? await Task.sleep(nanoseconds: 20_000_000)
        await handsFreeInput.emit(
            .recognition(SpeechRecognitionUpdate(text: "Still speaking", isFinal: false))
        )
        await waitUntil { coordinator.provisionalText == "Still speaking" }
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
        await waitUntil { coordinator.provisionalText == "Draft" }
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
            handsFreeSilenceDurationNanoseconds: 0,
            interruptByTalking: { true }
        )

        let responseTask = Task { await coordinator.sendDraft() }
        await client.waitUntilTurnStarted()
        await waitUntil { coordinator.state == .speaking }
        XCTAssertEqual(coordinator.state, .speaking)
        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(
            .activity(handsFreeSnapshot(.speech, playbackActive: true))
        )
        await waitUntil { coordinator.handsFreeStatus == .blockedByAudioRoute }

        let interruptCount = await client.interruptCount
        XCTAssertEqual(interruptCount, 0)
        XCTAssertEqual(coordinator.handsFreeStatus, .blockedByAudioRoute)
        XCTAssertEqual(coordinator.state, .speaking)

        await coordinator.disableHandsFree()
        _ = await coordinator.interruptActiveTurn()
        await responseTask.value
    }

    @MainActor
    func testWithoutTheOptInSpeechDuringAReplyIsIgnoredEvenOnHeadphones() async throws {
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
            handsFreeSilenceDurationNanoseconds: 0,
            interruptByTalking: { false }
        )

        let responseTask = Task { await coordinator.sendDraft() }
        await client.waitUntilTurnStarted()
        await waitUntil { coordinator.state == .speaking }

        await coordinator.toggleHandsFree()
        // Someone talks (or the TV) while Hermes speaks.
        await handsFreeInput.emit(
            .activity(handsFreeSnapshot(.speech, playbackActive: true))
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        let interruptCount = await client.interruptCount
        XCTAssertEqual(interruptCount, 0, "Only a tap interrupts without the opt-in")
        XCTAssertEqual(coordinator.state, .speaking)
        XCTAssertNotEqual(coordinator.handsFreeStatus, .blockedByAudioRoute, "Nothing is blocked; speech is simply ignored")

        // A tap still interrupts.
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
            handsFreeSilenceDurationNanoseconds: 0,
            interruptByTalking: { true }
        )

        let responseTask = Task { await coordinator.sendDraft() }
        await client.waitUntilTurnStarted()
        await waitUntil { coordinator.state == .speaking }
        XCTAssertEqual(coordinator.state, .speaking)

        await coordinator.toggleHandsFree()
        await handsFreeInput.emit(
            .activity(handsFreeSnapshot(.speech, playbackActive: true))
        )
        await waitUntil { coordinator.state == .listening }

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

    // MARK: IOS-HOME-07 background voice work

    @MainActor
    func testBackgroundKeepsAPlayingHomeReplyAliveThenTearsDownWhenItFinishes() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")

        let inactive = await harness.lifecycle.handle(.inactive)
        let background = await harness.lifecycle.handle(.background)

        XCTAssertEqual(inactive, .completed)
        XCTAssertEqual(background, .completed)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertTrue(harness.store.connectionState.isConnected, "The transport stays up mid-reply")
        var closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 0)
        var operations = await output.operations()
        XCTAssertFalse(operations.contains(.stop), "Locking must not cut the reply off")
        XCTAssertEqual(harness.nowPlaying.shownTitles, ["Hermes conversation"])
        var policy = await harness.policy.values()
        XCTAssertEqual(policy, [true], "Backgrounded voice work is non-mixable")

        await output.allowFinish()
        await responseTask.value
        await pollUntil { harness.store.connectionState == .disconnected }

        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.store.isLifecycleActive)
        closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 1, "Home sees the claim parked after the reply")
        XCTAssertFalse(harness.nowPlaying.isShowing, "Teardown clears Now Playing")
        policy = await harness.policy.values()
        XCTAssertEqual(policy.last, false)
        let submitted = await harness.client.submittedTexts
        XCTAssertEqual(submitted, ["Read me the news"], "No replay")
        operations = await output.operations()
        XCTAssertTrue(operations.contains(.finish))
    }

    @MainActor
    func testInactiveAloneNeverStopsPlaybackOrCapture() async throws {
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        XCTAssertTrue(harness.voice.isHandsFreeArmed)

        let result = await harness.lifecycle.handle(.inactive)

        XCTAssertEqual(result, .completed)
        XCTAssertTrue(harness.voice.isHandsFreeArmed)
        let cancels = await handsFree.cancelCount()
        XCTAssertEqual(cancels, 0)
        XCTAssertTrue(harness.store.isLifecycleActive)
        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertTrue(harness.nowPlaying.shownTitles.isEmpty)
        await harness.voice.stopForLifecycle()
    }

    @MainActor
    func testInactiveSnapshotFailureStillBlocksActivationWithoutStoppingAudio() async throws {
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(
            handsFreeInput: handsFree,
            persistence: FailingBackgroundPersistence()
        )
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()

        let result = await harness.lifecycle.handle(.inactive)

        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertTrue(harness.voice.isHandsFreeArmed)
        let active = await harness.lifecycle.handle(.active)
        XCTAssertEqual(active, .persistenceFailed, "A failed snapshot still blocks activation")
        await harness.voice.stopForLifecycle()
    }

    @MainActor
    func testBackgroundHandsFreeSessionEndsAfterSixtyIdleSeconds() async throws {
        let clock = ManualBackgroundClock()
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree, clock: clock)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        XCTAssertTrue(harness.voice.isHandsFreeArmed)

        let result = await harness.lifecycle.handle(.background)

        XCTAssertEqual(result, .completed)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertEqual(harness.nowPlaying.shownPlaying, [false], "No reply output is playing")
        await pollUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(59))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(harness.voice.isHandsFreeArmed, "The mic stays up inside the idle window")
        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork, "No teardown at 59 s")
        let closeCountAt59 = await harness.client.closeCount
        XCTAssertEqual(closeCountAt59, 0)

        clock.advance(by: .seconds(1))
        await pollUntil { harness.store.connectionState == .disconnected }

        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork, "Teardown at 60 s")
        XCTAssertFalse(harness.voice.isBackgrounded)
        XCTAssertFalse(harness.voice.isHandsFreeArmed)
        XCTAssertEqual(harness.voice.handsFreeStatus, .disarmed)
        let cancels = await handsFree.cancelCount()
        XCTAssertGreaterThan(cancels, 0, "The background mic stops at the timeout")
        let closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(harness.nowPlaying.isShowing)
    }

    @MainActor
    func testBackgroundSpeechRestartsTheIdleWindow() async throws {
        let clock = ManualBackgroundClock()
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree, clock: clock)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        _ = await harness.lifecycle.handle(.background)
        await pollUntil { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(30))
        await handsFree.emit(.activity(AudioActivitySnapshot(
            microphoneLevel: 0.5,
            microphoneActivity: .speech,
            playbackLevel: 0,
            playbackActive: false
        )))
        await pollUntil { harness.voice.isHandsFreeCaptureActive }
        await pollUntil { clock.sleeperCount == 0 }

        await harness.voice.cancelCapture()
        await pollUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(59))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork, "Voice activity restarts the 60 s window")
        XCTAssertTrue(harness.store.connectionState.isConnected)

        clock.advance(by: .seconds(1))
        await pollUntil { harness.store.connectionState == .disconnected }
    }

    @MainActor
    func testIdleBackgroundTearsDownImmediately() async throws {
        let harness = try await makeBackgroundVoiceHarness()
        defer { harness.cleanUp() }

        _ = await harness.lifecycle.handle(.inactive)
        let result = await harness.lifecycle.handle(.background)

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertFalse(harness.store.isLifecycleActive)
        let closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(harness.nowPlaying.shownTitles.isEmpty)
        let policy = await harness.policy.values()
        XCTAssertFalse(policy.contains(true), "Idle backgrounding never takes a non-mixable session")
    }

    @MainActor
    func testForegroundWithAKeptTransportIsANoOp() async throws {
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)
        let openCount = await harness.client.openCount

        _ = await harness.lifecycle.handle(.inactive)
        let result = await harness.lifecycle.handle(.active)

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        let reopened = await harness.client.openCount
        XCTAssertEqual(reopened, openCount, "No reconnect over a kept transport")
        let closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 0)
        XCTAssertTrue(harness.voice.isHandsFreeArmed, "The conversation is intact")
        XCTAssertFalse(harness.voice.isBackgrounded)
        XCTAssertFalse(harness.nowPlaying.isShowing)
        let policy = await harness.policy.values()
        XCTAssertEqual(policy, [true, false], "The foreground ducks others again")
        await harness.voice.stopForLifecycle()
    }

    @MainActor
    func testInterruptionEndsTheMicSessionAndResumesTheReply() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(output: output, handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        XCTAssertTrue(harness.voice.isHandsFreeArmed)
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Tell me a story")

        harness.events.send(.interruptionBegan)
        await pollUntil { !harness.voice.isHandsFreeArmed && harness.voice.isReplyOutputPaused }
        var operations = await output.operations()
        XCTAssertTrue(operations.contains(.pause))

        harness.events.send(.interruptionEnded(shouldResume: true))
        await pollUntil { !harness.voice.isReplyOutputPaused }
        operations = await output.operations()
        XCTAssertTrue(operations.contains(.resume))
        XCTAssertFalse(harness.voice.isHandsFreeArmed, "The mic session is not restarted")

        await output.allowFinish()
        await responseTask.value
        let submitted = await harness.client.submittedTexts
        XCTAssertEqual(submitted, ["Tell me a story"])
    }

    @MainActor
    func testBackgroundInterruptionThatCannotResumeTearsDown() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)

        harness.events.send(.interruptionBegan)
        await pollUntil { harness.voice.isReplyOutputPaused }
        harness.events.send(.interruptionEnded(shouldResume: false))
        await pollUntil { harness.store.connectionState == .disconnected }

        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.nowPlaying.isShowing)
        let operations = await output.operations()
        // Teardown releases the held pause only after stopping playback.
        let stopIndex = operations.firstIndex(of: .stop)
        let resumeIndex = operations.firstIndex(of: .resume)
        XCTAssertNotNil(stopIndex)
        if let stopIndex, let resumeIndex {
            XCTAssertGreaterThan(resumeIndex, stopIndex, "The interrupted reply never resumed")
        }
        await output.allowFinish()
        await responseTask.value
        let submitted = await harness.client.submittedTexts
        XCTAssertEqual(submitted, ["Read me the news"], "Teardown never resends")
    }

    @MainActor
    func testRouteLossPausesReplyOutput() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")

        harness.events.send(.oldDeviceUnavailable)
        await pollUntil { harness.voice.isReplyOutputPaused }

        let operations = await output.operations()
        XCTAssertTrue(operations.contains(.pause))
        XCTAssertFalse(operations.contains(.stop), "The reply is held, not moved to the speaker")
        await harness.voice.stopForLifecycle()
        await output.allowFinish()
        await responseTask.value
    }

    @MainActor
    func testBackgroundNeverStartsTheMicrophone() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(output: output, handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.voice.isBackgrounded)

        await harness.voice.toggleHandsFree()
        await harness.voice.beginCapture()

        XCTAssertFalse(harness.voice.isHandsFreeArmed)
        let starts = await handsFree.startCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(harness.voice.backgroundRetention, .reply)
        await output.allowFinish()
        await responseTask.value
        await pollUntil { harness.store.connectionState == .disconnected }
    }

    @MainActor
    func testLockScreenControlsPauseResumeAndStopTheSession() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")
        _ = await harness.lifecycle.handle(.background)

        harness.nowPlaying.send(.pause)
        await pollUntil { harness.voice.isReplyOutputPaused }
        harness.nowPlaying.send(.play)
        await pollUntil { !harness.voice.isReplyOutputPaused }
        XCTAssertEqual(harness.nowPlaying.playingUpdates, [false, true])

        harness.nowPlaying.send(.stop)
        await pollUntil { harness.store.connectionState == .disconnected }

        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.nowPlaying.isShowing, "Stop clears Now Playing")
        XCTAssertGreaterThan(harness.nowPlaying.clearCount, 0)
        await output.allowFinish()
        await responseTask.value
    }

    @MainActor
    func testForegroundAfterTheRetainedTransportDroppedReactivates() async throws {
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)
        let openCount = await harness.client.openCount
        // The transport is lost while backgrounded.
        _ = harness.store.takeHomeClientForLifecycle()
        XCTAssertFalse(harness.store.hasLiveTransport)

        let result = await harness.lifecycle.handle(.active)

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.voice.isBackgrounded)
        let reopened = await harness.client.openCount
        XCTAssertEqual(reopened, openCount + 1, "Foreground reconnects over a dropped transport")
        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertTrue(harness.store.isLifecycleActive)
    }

    @MainActor
    func testSocketDropDuringABackgroundReplyKeepsTheUncertainTurnWithoutResending() async throws {
        let harness = try await makeBackgroundVoiceHarness()
        defer { harness.cleanUp() }
        harness.store.draft = "Read me the news"
        let voice = harness.voice
        let responseTask = Task { @MainActor in await voice.sendDraft() }
        await waitForHomeVoiceSubmission(harness.client, atLeast: 1)
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)

        await harness.client.failEvents()
        await pollUntil { harness.store.unconfirmedTurnText == "Read me the news" }

        // The drop marked the turn uncertain; the retry ladder reconnects
        // the kept claim while the reply is still retained.
        await pollUntil { await harness.client.reconnectCount >= 1 }
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)
        let submitted = await harness.client.submittedTexts
        XCTAssertEqual(submitted, ["Read me the news"], "No resend")

        _ = await harness.lifecycle.handle(.suspended)
        await responseTask.value
        XCTAssertEqual(harness.store.unconfirmedTurnText, "Read me the news", "Kept for Resend/Continue")
        let submittedAfter = await harness.client.submittedTexts
        XCTAssertEqual(submittedAfter, ["Read me the news"])
    }

    @MainActor
    func testLockBeforeAudioStartsStillHonoursTheAudioDeadlineThenTearsDown() async throws {
        let harness = try await makeBackgroundVoiceHarness(
            audioDeadlines: HomeTurnAudioDeadlines(
                audioStart: .milliseconds(200),
                controlTerminal: .seconds(30),
                audioTerminal: .seconds(5),
                playbackDrain: .seconds(5)
            )
        )
        defer { harness.cleanUp() }
        harness.store.draft = "Say something"
        let voice = harness.voice
        let responseTask = Task { @MainActor in await voice.sendDraft() }
        await waitForHomeVoiceSubmission(harness.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: harness.fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await harness.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(rendered: nil, text: "Answer", status: "complete", reasoning: nil, failureReason: nil)
        )))
        await harness.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        await pollUntil { harness.store.messages.contains { $0.text == "Answer" } }

        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork, "Pending audio keeps the reply alive")

        await responseTask.value
        await pollUntil { harness.store.connectionState == .disconnected }
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        let closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 1, "Deadline expiry tears down")
    }

    @MainActor
    func testStaleBackgroundAfterTheWorkEndedTearsDown() async throws {
        let handsFree = CoordinatorHandsFreeInput()
        let harness = try await makeBackgroundVoiceHarness(handsFreeInput: handsFree)
        defer { harness.cleanUp() }
        await harness.voice.toggleHandsFree()
        _ = await harness.lifecycle.handle(.background)
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)

        // Lock-screen Stop queues `.backgroundWorkEnded`; a newer phase that
        // supersedes it must still finish the teardown.
        await harness.voice.handleNowPlayingCommand(.stop)
        for _ in 0..<5 { await Task.yield() }
        _ = await harness.lifecycle.handle(.background)

        await pollUntil { harness.store.connectionState == .disconnected }
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.store.isLifecycleActive)
        let closeCount = await harness.client.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testPausedBackgroundReplyTimesOutAfterSixtySeconds() async throws {
        let clock = ManualBackgroundClock()
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output, clock: clock)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")
        _ = await harness.lifecycle.handle(.background)
        XCTAssertEqual(clock.sleeperCount, 0, "A playing reply has no idle timeout")

        await harness.voice.handleNowPlayingCommand(.pause)
        await pollUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(59))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(harness.lifecycle.isRetainingBackgroundWork)

        clock.advance(by: .seconds(1))
        await pollUntil { harness.store.connectionState == .disconnected }
        XCTAssertFalse(harness.lifecycle.isRetainingBackgroundWork)
        XCTAssertFalse(harness.nowPlaying.isShowing)
        await responseTask.value
    }

    @MainActor
    func testInterruptionEndDoesNotResumeARouteLossPause() async throws {
        let output = CoordinatorAudioOutput(waitsForFinish: true, stopReleasesFinish: true)
        let harness = try await makeBackgroundVoiceHarness(output: output)
        defer { harness.cleanUp() }
        let responseTask = try await startPlayingHomeReply(harness, prompt: "Read me the news")

        harness.events.send(.oldDeviceUnavailable)
        await pollUntil { harness.voice.replyPauseReason == .routeLoss }
        harness.events.send(.interruptionEnded(shouldResume: true))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(harness.voice.replyPauseReason, .routeLoss, "Never resume onto the speaker")
        var operations = await output.operations()
        XCTAssertFalse(operations.contains(.resume))

        harness.events.send(.newDeviceAvailable)
        await pollUntil { !harness.voice.isReplyOutputPaused }
        operations = await output.operations()
        XCTAssertTrue(operations.contains(.resume), "Reconnected headphones resume the reply")

        await harness.voice.stopForLifecycle()
        await responseTask.value
    }

    func testMacOSLifecycleNeverRetainsBackgroundWork() {
        #if os(macOS)
        XCTAssertFalse(AppleLifecycleCoordinator.platformSupportsBackgroundRetention)
        #else
        XCTAssertTrue(AppleLifecycleCoordinator.platformSupportsBackgroundRetention)
        #endif
    }

    @MainActor
    private func makeBackgroundVoiceHarness(
        output: CoordinatorAudioOutput = CoordinatorAudioOutput(),
        handsFreeInput: CoordinatorHandsFreeInput? = nil,
        clock: any HomeMonotonicClock = ContinuousHomeMonotonicClock(),
        persistence: (any ConversationPersistence)? = nil,
        audioDeadlines: HomeTurnAudioDeadlines = .default
    ) async throws -> BackgroundVoiceHarness {
        let fixture = try await makeHomeVoiceReviewFixture(
            audioDeadlines: audioDeadlines,
            persistence: persistence
        )
        let configured = await fixture.store.loadConfiguredClient()
        XCTAssertTrue(configured)
        await fixture.store.connect()
        XCTAssertTrue(fixture.store.connectionState.isConnected)
        let nowPlaying = RecordingNowPlaying()
        let policy = RecordingAudioSessionPolicy()
        let events = ScriptedAudioSessionEvents()
        let voice = VoiceSessionCoordinator(
            store: fixture.store,
            input: CoordinatorSpeechInput(),
            output: output,
            handsFreeInput: handsFreeInput,
            clock: clock,
            audioSessionPolicy: policy,
            audioSessionEvents: events,
            nowPlaying: nowPlaying
        )
        let lifecycle = AppleLifecycleCoordinator(
            store: fixture.store,
            voice: voice,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: fixture.client),
            clock: clock,
            backgroundRetentionEnabled: true
        )
        return BackgroundVoiceHarness(
            fixture: fixture,
            voice: voice,
            lifecycle: lifecycle,
            nowPlaying: nowPlaying,
            policy: policy,
            events: events,
            output: output
        )
    }

    /// Submits a Home voice turn and drives it until its audio is playing.
    @MainActor
    private func startPlayingHomeReply(
        _ harness: BackgroundVoiceHarness,
        prompt: String
    ) async throws -> Task<Void, Never> {
        harness.store.draft = prompt
        let voice = harness.voice
        let responseTask = Task { @MainActor in
            await voice.sendDraft()
        }
        await waitForHomeVoiceSubmission(harness.client, atLeast: 1)
        let scope = HomeEventScope(
            conversationHandle: harness.fixture.claim.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await harness.client.emit(.audioStart(
            scope,
            HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        ))
        await harness.client.emit(.binaryPCM(scope, Data([0, 1, 2, 3])))
        await harness.client.emit(.standard(HomeStandardEvent(
            type: .messageComplete,
            scope: scope,
            payload: .final(
                rendered: nil,
                text: "Here is the answer",
                status: "complete",
                reasoning: nil,
                failureReason: nil
            )
        )))
        await harness.client.emit(.audioTerminal(scope, .end))
        await harness.client.emit(.standard(HomeStandardEvent(
            type: .turnComplete,
            scope: scope,
            payload: .terminal(kind: .terminal)
        )))
        await harness.output.waitUntilFinishRequested()
        XCTAssertEqual(harness.voice.backgroundRetention, .reply)
        return responseTask
    }

    @MainActor
    private func pollUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func makeHomeVoiceReviewFixture(
        audioDeadlines: HomeTurnAudioDeadlines = .default,
        persistence: (any ConversationPersistence)? = nil
    ) async throws -> HomeVoiceReviewFixture {
        let profileID = UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")!
        let profile = try RelayProfile(
            id: profileID,
            endpoint: URL(string: "wss://legacy.example/session")!,
            clientID: "hermes-apple",
            deviceID: "apple-device",
            displayName: "Voice Home"
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRelayIOS-HomeVoiceReview-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let configurationStore = RelayConfigurationStore(
            secureStore: HomeVoiceReviewSecureValueStore(),
            profileURL: profileURL
        )
        let journal = HomeMigrationJournal(
            schemaVersion: 1,
            profileID: profileID,
            phase: .homeSelected,
            selectedMode: .home,
            credential: nil,
            legacyCredentialRetained: true,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try await configurationStore.saveCollection(
            RelayProfileCollection(
                profiles: [profile],
                selectedID: profileID,
                homeMigrations: [profileID: journal]
            )
        )
        let claim = HomeDemoFixtures.claim(for: profileID)
        let client = FakeHomeBridgeSessionClient(claim: claim)
        let store = ConversationStore(
            configurationStore: configurationStore,
            persistence: persistence,
            homeClientFactory: FakeHomeBridgeSessionClientFactory(client: client),
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim),
            homeTurnAudioDeadlines: audioDeadlines
        )
        return HomeVoiceReviewFixture(
            store: store,
            client: client,
            claim: claim,
            profileURL: profileURL
        )
    }

    @MainActor
    private func waitForHomeVoiceSubmission(
        _ client: FakeHomeBridgeSessionClient,
        atLeast count: Int
    ) async {
        for _ in 0..<100 {
            if (await client.submittedTexts).count >= count { return }
            await Task.yield()
        }
        XCTFail("The Home voice fake did not receive the prompt")
    }
}

@MainActor
private struct HomeVoiceReviewFixture {
    let store: ConversationStore
    let client: FakeHomeBridgeSessionClient
    let claim: HomeConversationClaim
    let profileURL: URL
}

private final class HomeVoiceReviewSecureValueStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

@MainActor
private struct BackgroundVoiceHarness {
    let fixture: HomeVoiceReviewFixture
    let voice: VoiceSessionCoordinator
    let lifecycle: AppleLifecycleCoordinator
    let nowPlaying: RecordingNowPlaying
    let policy: RecordingAudioSessionPolicy
    let events: ScriptedAudioSessionEvents
    let output: CoordinatorAudioOutput

    var store: ConversationStore { fixture.store }
    var client: FakeHomeBridgeSessionClient { fixture.client }

    func cleanUp() {
        try? FileManager.default.removeItem(at: fixture.profileURL.deletingLastPathComponent())
    }
}

@MainActor
private final class RecordingNowPlaying: NowPlayingPresenting {
    private(set) var shownTitles: [String] = []
    private(set) var shownPlaying: [Bool] = []
    private(set) var playingUpdates: [Bool] = []
    private(set) var clearCount = 0
    private(set) var isShowing = false
    private var onCommand: (@MainActor @Sendable (NowPlayingCommand) -> Void)?

    func show(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @MainActor @Sendable (NowPlayingCommand) -> Void
    ) {
        shownTitles.append(title)
        shownPlaying.append(isPlaying)
        isShowing = true
        self.onCommand = onCommand
    }

    func update(isPlaying: Bool) {
        playingUpdates.append(isPlaying)
    }

    func clear() {
        clearCount += 1
        isShowing = false
        onCommand = nil
    }

    func send(_ command: NowPlayingCommand) {
        onCommand?(command)
    }
}

private actor RecordingAudioSessionPolicy: BackgroundAudioSessionPolicy {
    private var recorded: [Bool] = []
    private var current = false

    func setBackgroundVoiceActive(_ active: Bool) {
        // Record transitions only, as the real coordinator re-applies the
        // category only when the mixing rule changes.
        guard active != current else { return }
        current = active
        recorded.append(active)
    }

    func values() -> [Bool] { recorded }
}

private final class ScriptedAudioSessionEvents: AudioSessionEventSource, @unchecked Sendable {
    private let stream: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream<AudioSessionEvent>.makeStream()
    }

    func events() -> AsyncStream<AudioSessionEvent> { stream }

    func send(_ event: AudioSessionEvent) {
        continuation.yield(event)
    }
}

/// A monotonic clock that only moves when the test advances it.
private final class ManualBackgroundClock: HomeMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = [:]

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if origin + offset >= deadline {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            offset += duration
            let now = origin + offset
            let ready = sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys {
                sleepers.removeValue(forKey: id)
            }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

private actor FailingBackgroundPersistence: ConversationPersistence {
    func load() async throws -> PersistedConversation {
        PersistedConversation(messages: [], draft: "")
    }

    func save(_ conversation: PersistedConversation) async throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor CoordinatorHandsFreeInput: HandsFreeInput {
    private let authorizationResult: SpeechAuthorization
    private let finishUpdate: SpeechRecognitionUpdate?
    private var continuation: AsyncThrowingStream<HandsFreeInputEvent, Error>.Continuation?
    private var starts = 0
    private var startCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
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
        let readyWaiters = startCountWaiters.filter { $0.0 <= starts }
        startCountWaiters.removeAll { $0.0 <= starts }
        readyWaiters.forEach { $0.1.resume() }
        let (stream, continuation) = AsyncThrowingStream<HandsFreeInputEvent, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func startCount() -> Int {
        starts
    }

    func waitUntilStartCount(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { continuation in
            startCountWaiters.append((expected, continuation))
        }
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
    private let lock = NSLock()
    private var changed = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    var didChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }

    func markChanged() {
        lock.lock()
        changed = true
        let waiter = self.waiter
        self.waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        waiter?.resume(returning: true)
    }

    func waitUntilChanged(timeoutNanoseconds: UInt64? = nil) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if changed {
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiter = continuation
                    if let timeoutNanoseconds {
                        timeoutTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                            self?.timeout()
                        }
                    }
                    lock.unlock()
                }
            }
        } onCancel: {
            timeout()
        }
    }

    private func timeout() {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        timeoutTask = nil
        lock.unlock()
        waiter?.resume(returning: false)
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
    private var recordWaiters: [CheckedContinuation<Void, Never>] = []

    func recordAfterCurrentWork() {
        // `handle` runs serially on the MainActor and has no suspension point
        // between `output.finish()` returning and the state assignment that
        // follows it, so a task enqueued here observes the settled state.
        Task { @MainActor in
            guard let provider else { return }
            self.statesAfterSegmentEnd.append(provider())
            let waiters = self.recordWaiters
            self.recordWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRecorded() async {
        guard statesAfterSegmentEnd.isEmpty else { return }
        await withCheckedContinuation { continuation in
            recordWaiters.append(continuation)
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
        case pause
        case resume
    }

    private let appendError: AudioOutputError?
    private let finishError: AudioOutputError?
    private let appendReadiness: AudioPlaybackReadiness
    private let waitsForFinish: Bool
    private let reportedPlaybackPosition: TimeInterval?
    /// Mirrors `AudioPlaybackDrain.reset()`: stopping releases a pending drain.
    private let stopReleasesFinish: Bool
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
        playbackPosition: TimeInterval? = nil,
        stopReleasesFinish: Bool = false
    ) {
        self.appendError = appendError
        self.finishError = finishError
        self.appendReadiness = appendReadiness
        self.waitsForFinish = waitsForFinish
        self.reportedPlaybackPosition = playbackPosition
        self.stopReleasesFinish = stopReleasesFinish
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
        if stopReleasesFinish {
            finishWaiter?.resume()
            finishWaiter = nil
        }
    }

    func playbackPosition() async -> TimeInterval? { reportedPlaybackPosition }
    func pause() async { recordedOperations.append(.pause) }
    func resume() async { recordedOperations.append(.resume) }

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

extension StateRecordingAudioOutput {
    func pause() async {}
    func resume() async {}
}

extension StartGatedAudioOutput {
    func pause() async {}
    func resume() async {}
}
