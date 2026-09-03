import XCTest
@testable import HermesRelayIOS

final class HermesRelayIOSTests: XCTestCase {
    func testUnavailableClientExplainsMissingRelayConfiguration() async {
        do {
            _ = try await UnavailableHermesSessionClient().connect()
            XCTFail("The foundation client must not claim a connection")
        } catch let error as RelayUnavailableError {
            XCTAssertEqual(error.errorDescription, "Configure a Hermes relay before connecting.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testStoreKeepsDraftWhenRelayIsUnavailable() async {
        let store = ConversationStore()
        store.draft = "Hello Hermes"

        await store.sendDraft()

        XCTAssertEqual(store.draft, "Hello Hermes")
        XCTAssertEqual(store.transientError, "Connect to the Hermes relay before sending.")
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testConnectionStateLabelsAreActionable() {
        XCTAssertEqual(ConnectionState.disconnected.label, "Not connected")
        XCTAssertEqual(ConnectionState.connecting.label, "Connecting…")
        XCTAssertEqual(ConnectionState.connected.label, "Connected")
        XCTAssertEqual(ConnectionState.failed("offline").label, "Unavailable")
    }

    func testVoiceStatesExposeStableStatusPresentation() {
        let expected: [(VoiceState, String, String)] = [
            (.idle, "Ready", "mic"),
            (.listening, "Listening", "mic.fill"),
            (.transcribing, "Transcribing", "waveform"),
            (.thinking, "Thinking", "ellipsis"),
            (.speaking, "Speaking", "speaker.wave.2.fill"),
            (.buffering, "Buffering", "arrow.down.circle"),
            (.interrupted, "Interrupted", "pause.circle"),
            (.failed("Audio playback failed."), "Audio playback failed.", "exclamationmark.triangle"),
        ]

        for (state, label, systemImage) in expected {
            XCTAssertEqual(state.label, label)
            XCTAssertEqual(state.systemImage, systemImage)
        }
    }

    func testAmbientHUDProjectsVoiceStateAndAudioLevel() {
        let snapshot = AudioActivitySnapshot(
            microphoneLevel: 0.72,
            microphoneActivity: .speech,
            playbackLevel: 0.81,
            playbackActive: true
        )
        let presentation = AmbientHUDPresentation(
            voiceState: .speaking,
            activity: snapshot,
            provisionalText: "",
            messages: [TranscriptMessage(role: .assistant, text: "The answer is ready.")]
        )

        XCTAssertEqual(presentation.mode, .speaking)
        XCTAssertEqual(presentation.caption, "The answer is ready.")
        XCTAssertEqual(presentation.captionSource, .hermes)
        XCTAssertEqual(presentation.intensity, 0.81, accuracy: 0.001)
        XCTAssertEqual(presentation.accessibilityLabel, "Hermes speaking")
    }

    func testAmbientHUDUsesLiveUserCaptionUntilHermesHasText() {
        let messages = [TranscriptMessage(role: .user, text: "What is next?")]
        let listening = AmbientHUDPresentation(
            voiceState: .listening,
            activity: .safe,
            provisionalText: "What is next",
            messages: messages
        )
        let thinking = AmbientHUDPresentation(
            voiceState: .thinking,
            activity: .safe,
            provisionalText: "",
            messages: messages
        )

        XCTAssertEqual(listening.caption, "What is next")
        XCTAssertEqual(listening.captionSource, .user)
        XCTAssertEqual(thinking.caption, "What is next?")
        XCTAssertEqual(thinking.captionSource, .user)
    }

    func testAmbientHUDPrefersStreamingHermesCaptionAndHidesIdleHistory() {
        let messages = [
            TranscriptMessage(role: .user, text: "Hello"),
            TranscriptMessage(role: .assistant, text: "Hello, Amanda.")
        ]
        let speaking = AmbientHUDPresentation(
            voiceState: .speaking,
            activity: .safe,
            provisionalText: "",
            messages: messages
        )
        let idle = AmbientHUDPresentation(
            voiceState: .idle,
            activity: .safe,
            provisionalText: "",
            messages: messages
        )

        XCTAssertEqual(speaking.caption, "Hello, Amanda.")
        XCTAssertEqual(speaking.captionSource, .hermes)
        XCTAssertNil(idle.caption)
        XCTAssertNil(idle.captionSource)
    }

    func testRecentTranscriptKeepsLatestExchangeAndDoesNotTruncateLongText() {
        let longResponse = String(repeating: "Hermes keeps explaining the important detail. ", count: 18)
        let messages = [
            TranscriptMessage(role: .user, text: "Earlier question"),
            TranscriptMessage(role: .assistant, text: "Earlier answer"),
            TranscriptMessage(role: .user, text: "Current question"),
            TranscriptMessage(role: .assistant, text: longResponse)
        ]

        let projection = RecentTranscriptProjection(messages: messages, provisionalText: "")

        XCTAssertEqual(projection.entries.map(\.text), [
            "Earlier question",
            "Earlier answer",
            "Current question",
            longResponse
        ])
        XCTAssertEqual(projection.entries.last?.role, .assistant)
        XCTAssertFalse(projection.entries.last?.isLive ?? true)
        XCTAssertEqual(projection.entries.count, 4)
    }

    func testRecentTranscriptIncludesLiveUserTextAtTheNewestAnchor() {
        let messages = [TranscriptMessage(role: .assistant, text: "Previous answer")]

        let projection = RecentTranscriptProjection(
            messages: messages,
            provisionalText: "A new question in progress"
        )

        XCTAssertEqual(projection.entries.last?.text, "A new question in progress")
        XCTAssertEqual(projection.entries.last?.role, .user)
        XCTAssertTrue(projection.entries.last?.isLive ?? false)
        XCTAssertEqual(projection.latestEntryID, projection.entries.last?.id)
    }

    func testRecentTranscriptFollowStatePausesAndResumesExplicitly() {
        var state = RecentTranscriptFollowState()

        XCTAssertTrue(state.isFollowingLatest)

        state.pauseFollowing()
        XCTAssertFalse(state.isFollowingLatest)

        state.resumeFollowing()
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testRecentTranscriptRevealAdvancesByWordsInsteadOfDumpingTheResponse() {
        let response = "Hermes keeps the answer moving while the audio is speaking."

        let firstStep = RecentTranscriptReveal.nextText(
            current: "",
            target: response,
            characterBudget: 1
        )
        let secondStep = RecentTranscriptReveal.nextText(
            current: firstStep,
            target: response,
            characterBudget: 1
        )

        XCTAssertEqual(firstStep, "Hermes ")
        XCTAssertEqual(secondStep, "Hermes keeps ")
        XCTAssertLessThan(secondStep.count, response.count)
    }

    func testRecentTranscriptMarksOnlyLatestAssistantAsLiveDuringActiveResponse() {
        let projection = RecentTranscriptProjection(
            messages: [
                TranscriptMessage(role: .assistant, text: "Earlier answer"),
                TranscriptMessage(role: .user, text: "Current question"),
                TranscriptMessage(role: .assistant, text: "Current answer")
            ],
            provisionalText: "",
            isResponseActive: true
        )

        XCTAssertEqual(projection.entries.map(\.isLive), [false, false, true])
    }

    func testSessionDurationFormatsMinuteAndHourDurations() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            SessionDurationFormatter.string(
                startedAt: now.addingTimeInterval(-252),
                now: now
            ),
            "04:12"
        )
        XCTAssertEqual(
            SessionDurationFormatter.string(
                startedAt: now.addingTimeInterval(-3_723),
                now: now
            ),
            "01:02:03"
        )
        XCTAssertEqual(
            SessionDurationFormatter.string(startedAt: nil, now: now),
            "00:00"
        )
    }

    @MainActor
    func testAmbientHUDModelReceivesNewestActivitySnapshot() async {
        let activityStore = AudioActivityStore(minimumEmissionIntervalNanoseconds: 0)
        let model = AmbientHUDModel()
        model.start(observing: activityStore)

        await activityStore.reportMicrophone(level: 0.68)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(model.snapshot.microphoneLevel, 0.68, accuracy: 0.001)
        XCTAssertEqual(model.snapshot.microphoneActivity, .speech)
        model.stop()
    }
}
