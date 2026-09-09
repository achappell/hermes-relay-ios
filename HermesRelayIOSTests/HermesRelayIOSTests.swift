import XCTest
@testable import HermesRelayIOS

final class HermesRelayIOSTests: XCTestCase {
    func testTranscriptExportPreservesRolesAndTimestampsInPlainTextAndMarkdown() {
        let firstDate = Date(timeIntervalSince1970: 1_704_110_400)
        let secondDate = firstDate.addingTimeInterval(61)
        let messages = [
            TranscriptMessage(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, role: .user, text: "Hello Hermes", createdAt: firstDate),
            TranscriptMessage(id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!, role: .assistant, text: "Hello, Amanda.", createdAt: secondDate)
        ]
        let formatter = TranscriptExportFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertEqual(
            formatter.plainText(for: messages),
            "[2024-01-01 12:00:00 GMT] You\nHello Hermes\n\n[2024-01-01 12:01:01 GMT] Hermes\nHello, Amanda."
        )
        XCTAssertEqual(
            formatter.markdown(for: messages),
            "## Conversation\n\n### You — 2024-01-01 12:00:00 GMT\n\nHello Hermes\n\n### Hermes — 2024-01-01 12:01:01 GMT\n\nHello, Amanda."
        )
    }

    func testEmptyTranscriptExportIsReadableAndContainsNoPlaceholderConversation() {
        let formatter = TranscriptExportFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertEqual(formatter.plainText(for: []), "No conversation yet.")
        XCTAssertEqual(formatter.markdown(for: []), "## Conversation\n\n_No conversation yet._")
    }

    func testTranscriptExportKeepsLongConversationBoundaries() {
        let messages = (0..<100).map { index in
            TranscriptMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Entry \(index): " + String(repeating: "detail ", count: 30)
            )
        }
        let plainText = TranscriptExportFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
            .plainText(for: messages)

        XCTAssertEqual(plainText.components(separatedBy: "\n\n").count, 100)
        XCTAssertTrue(plainText.hasPrefix("["))
        XCTAssertTrue(plainText.contains("Entry 99:"))
    }

    func testLegacyTranscriptMessageDecodesWithoutTimestamp() throws {
        let data = Data("{\"id\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"role\":\"user\",\"text\":\"Legacy\"}".utf8)

        let message = try JSONDecoder().decode(TranscriptMessage.self, from: data)

        XCTAssertEqual(message.text, "Legacy")
        XCTAssertNil(message.createdAt)
    }

    func testPromptHistoryIsBoundedAndRestoresTheDraftAtTheEnd() {
        var history = PromptHistory(limit: 2)
        history.record("first")
        history.record("second")
        history.record("third")

        XCTAssertEqual(history.previous(currentDraft: "unsent"), "third")
        XCTAssertEqual(history.previous(currentDraft: "ignored while browsing"), "second")
        XCTAssertEqual(history.previous(currentDraft: "ignored at oldest"), "second")
        XCTAssertEqual(history.next(), "third")
        XCTAssertEqual(history.next(), "unsent")
        XCTAssertEqual(history.next(), "unsent")
    }

    func testPromptHistoryReturnsNoEntryWhenEmpty() {
        var history = PromptHistory(limit: 5)

        XCTAssertNil(history.previous(currentDraft: "draft"))
        XCTAssertNil(history.next())
    }

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
            (.complete, "Complete", "checkmark.circle"),
            (.interrupted, "Interrupted", "pause.circle"),
            (.failed("Audio playback failed."), "Audio playback failed.", "exclamationmark.triangle"),
        ]

        for (state, label, systemImage) in expected {
            XCTAssertEqual(state.label, label)
            XCTAssertEqual(state.systemImage, systemImage)
        }
    }

    func testCompletePresentationIsSettledAndKeepsHermesText() {
        let presentation = AmbientHUDPresentation(
            voiceState: .complete,
            activity: .safe,
            provisionalText: "",
            messages: [TranscriptMessage(role: .assistant, text: "The answer is ready.")]
        )

        XCTAssertEqual(presentation.mode, .complete)
        XCTAssertEqual(presentation.caption, "The answer is ready.")
        XCTAssertEqual(presentation.captionSource, .hermes)
        XCTAssertEqual(presentation.intensity, 0.10, accuracy: 0.001)
        XCTAssertEqual(presentation.accessibilityLabel, "Hermes complete")
        XCTAssertFalse(VoiceControlInteractionPolicy.isResponseActive(.complete))
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

        let projection = RecentTranscriptProjection(
            messages: messages,
            provisionalText: "",
            isResponseActive: false,
            activeAssistantID: nil
        )

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

    func testRecentTranscriptExcludesSystemAndErrorMessagesFromConversationRail() {
        let messages = [
            TranscriptMessage(role: .user, text: "What is the status?"),
            TranscriptMessage(role: .error, text: "Setup is incomplete."),
            TranscriptMessage(role: .assistant, text: "The system is ready.")
        ]

        let projection = RecentTranscriptProjection(
            messages: messages,
            provisionalText: "",
            isResponseActive: false,
            activeAssistantID: nil
        )

        XCTAssertEqual(projection.entries.map(\.role), [.user, .assistant])
        XCTAssertFalse(projection.entries.contains { $0.text == "Setup is incomplete." })
    }

    func testRecentTranscriptIncludesLiveUserTextAtTheNewestAnchor() {
        let messages = [TranscriptMessage(role: .assistant, text: "Previous answer")]

        let projection = RecentTranscriptProjection(
            messages: messages,
            provisionalText: "A new question in progress",
            isResponseActive: false,
            activeAssistantID: nil
        )

        XCTAssertEqual(projection.entries.last?.text, "A new question in progress")
        XCTAssertEqual(projection.entries.last?.role, .user)
        XCTAssertTrue(projection.entries.last?.isLive ?? false)
        XCTAssertEqual(projection.latestEntryID, projection.entries.last?.id)
    }

    func testRecentTranscriptPinsTheActiveLiveEntryOutsideHistory() {
        let entries = [
            RecentTranscriptEntry(id: "older", role: .assistant, text: "Older answer"),
            RecentTranscriptEntry(id: "live-user", role: .user, text: "Current words", isLive: true),
        ]

        XCTAssertEqual(
            RecentTranscriptDisplay.liveEntry(from: entries)?.text,
            "Current words"
        )
        XCTAssertEqual(
            RecentTranscriptDisplay.historyEntries(from: entries).map(\.id),
            ["older"]
        )
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

    func testRecentTranscriptRevealDoesNotDumpAStreamedPartialWord() {
        let current = "Hermes keeps "
        let streamedTarget = "Hermes keeps the"

        let nextStep = RecentTranscriptReveal.nextText(
            current: current,
            target: streamedTarget,
            characterBudget: 1
        )

        XCTAssertEqual(nextStep, current)
    }

    func testTimedTranscriptRevealsWordsAtAudioPlaybackPosition() {
        let response = "Hermes keeps the answer moving."
        let timing = SpeechTiming(
            segmentID: "segment-1",
            text: response,
            timingSource: .alignment,
            audioOffset: 0,
            duration: 1.3,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
                SpeechTimingWord(text: "the", startTime: 0.48, endTime: 0.58),
                SpeechTimingWord(text: "answer", startTime: 0.58, endTime: 0.92),
                SpeechTimingWord(text: "moving.", startTime: 0.92, endTime: 1.3),
            ]
        )

        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: response,
                timing: timing,
                playbackPosition: 0.24
            ),
            "Hermes "
        )
        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: response,
                timing: timing,
                playbackPosition: 0.58
            ),
            "Hermes keeps the answer "
        )
        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: response,
                timing: timing,
                playbackPosition: 1.3
            ),
            response
        )
    }

    func testAudioDurationRevealTracksPlaybackWhenWordTimingIsUnavailable() {
        let response = "Hermes keeps the answer moving."

        XCTAssertEqual(
            AudioDurationReveal.visibleText(
                target: response,
                playbackPosition: 0.26,
                audioDuration: 1.3
            ),
            "Hermes "
        )
        XCTAssertEqual(
            AudioDurationReveal.visibleText(
                target: response,
                playbackPosition: 0.52,
                audioDuration: 1.3
            ),
            "Hermes keeps "
        )
        XCTAssertEqual(
            AudioDurationReveal.visibleText(
                target: response,
                playbackPosition: 1.3,
                audioDuration: 1.3
            ),
            response
        )
    }

    // A turn is submitted before its first text arrives. During that window
    // the newest assistant message still belongs to the PREVIOUS turn, and it
    // must be left alone — a spoken answer never records a revealed prefix, so
    // re-pacing it collapsed it to one word and re-typed the whole thing.
    func testCompletedAnswerIsNotRePacedWhileTheNextTurnBuffers() {
        let previous = TranscriptMessage(role: .assistant, text: "Lima is the capital of Peru.")
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(role: .user, text: "capital of Peru"), previous],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: nil
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: nil,
            revealedTexts: [:],
            speechTimings: [],
            playbackDuration: nil,
            playbackPosition: nil,
            isPlaybackDurationFinal: false
        )

        XCTAssertEqual(displayedEntries.last?.text, "Lima is the capital of Peru.")
        XCTAssertFalse(displayedEntries.contains { $0.isLive })
    }

    // Once the new answer exists, it alone is paced; the earlier one stays whole.
    func testOnlyTheActiveAssistantMessageIsPaced() {
        let previous = TranscriptMessage(role: .assistant, text: "Lima is the capital of Peru.")
        let current = TranscriptMessage(role: .assistant, text: "Bogota is the capital of Colombia.")
        let projection = RecentTranscriptProjection(
            messages: [previous, current],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: current.id
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: current.id,
            revealedTexts: [current.id.uuidString: "Bogota is "],
            speechTimings: [],
            playbackDuration: nil,
            playbackPosition: nil,
            isPlaybackDurationFinal: false
        )

        XCTAssertEqual(displayedEntries.first?.text, "Lima is the capital of Peru.")
        XCTAssertEqual(displayedEntries.last?.text, "Bogota is ")
        XCTAssertEqual(displayedEntries.filter(\.isLive).map(\.text), ["Bogota is "])
    }

    func testRecentTranscriptDisplayUsesAudioDurationWithoutSpeechTiming() {
        let messageID = UUID()
        let response = "Hermes keeps the answer moving."
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(id: messageID, role: .assistant, text: response)],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: messageID
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: messageID,
            revealedTexts: [:],
            playbackDuration: 1.3,
            playbackPosition: 0.52,
            isPlaybackDurationFinal: true
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes keeps ")
    }

    func testRecentTranscriptDisplayDoesNotRegressWhenAudioBufferGrows() {
        let messageID = UUID()
        let response = "Hermes keeps the answer moving."
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(id: messageID, role: .assistant, text: response)],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: messageID
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: messageID,
            revealedTexts: [messageID.uuidString: "Hermes keeps the "],
            playbackDuration: 2.0,
            playbackPosition: 0.4,
            isPlaybackDurationFinal: true
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes keeps the ")
    }

    // One segment the mapper cannot place must not abandon every segment after
    // it; the reveal has to keep following the audio it can still explain.
    func testSpeechTimingRevealSkipsUnmappableSegment() {
        let target = "Alpha beta gamma delta epsilon"
        let segments = [
            SpeechTiming(
                segmentID: "s1",
                text: "Alpha beta",
                timingSource: .durationFallback,
                audioOffset: 0,
                duration: 1,
                fallbackReason: .missing,
                words: []
            ),
            SpeechTiming(
                segmentID: "s2",
                text: "zeta eta",
                timingSource: .durationFallback,
                audioOffset: 1,
                duration: 1,
                fallbackReason: .missing,
                words: []
            ),
            SpeechTiming(
                segmentID: "s3",
                text: "delta epsilon",
                timingSource: .durationFallback,
                audioOffset: 2,
                duration: 1,
                fallbackReason: .missing,
                words: []
            )
        ]

        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: target,
                timings: segments,
                playbackPosition: 3.0
            ),
            target
        )
    }

    // A streaming duration only covers the bytes received so far, so pacing
    // against it makes an early playhead look almost complete and dumps the
    // whole response in one frame.
    func testRecentTranscriptDisplayIgnoresStillGrowingAudioDuration() {
        let messageID = UUID()
        let response = "Hermes keeps the answer moving."
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(id: messageID, role: .assistant, text: response)],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: messageID
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: messageID,
            revealedTexts: [:],
            playbackDuration: 0.2,
            playbackPosition: 0.18,
            isPlaybackDurationFinal: false
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes ")
    }

    func testPlaybackTextPrefersSpeechTimingWhileDurationIsStillGrowing() {
        let response = "Hermes keeps the answer moving."
        let timing = SpeechTiming(
            segmentID: "segment-1",
            text: "Hermes keeps",
            timingSource: .durationFallback,
            audioOffset: 0,
            duration: 1.0,
            fallbackReason: .missing,
            words: []
        )

        XCTAssertEqual(
            RecentTranscriptDisplay.playbackText(
                target: response,
                speechTimings: [timing],
                playbackDuration: 0.2,
                playbackPosition: 0.6,
                isPlaybackDurationFinal: false
            ),
            "Hermes keeps "
        )
    }

    func testTimedTranscriptAccumulatesSegmentsAndDoesNotUseMismatchedTiming() {
        let response = "Hermes keeps the answer moving."
        let firstSegment = SpeechTiming(
            segmentID: "segment-1",
            text: "Hermes keeps",
            timingSource: .alignment,
            audioOffset: 0,
            duration: 0.48,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
            ]
        )
        let secondSegment = SpeechTiming(
            segmentID: "segment-2",
            text: "the answer moving.",
            timingSource: .alignment,
            audioOffset: 0.48,
            duration: 0.82,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "the", startTime: 0.48, endTime: 0.58),
                SpeechTimingWord(text: "answer", startTime: 0.58, endTime: 0.92),
                SpeechTimingWord(text: "moving.", startTime: 0.92, endTime: 1.3),
            ]
        )

        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: response,
                timings: [secondSegment, firstSegment],
                playbackPosition: 0.91
            ),
            "Hermes keeps the answer "
        )
        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: response,
                timings: [
                    SpeechTiming(
                        segmentID: "wrong",
                        text: "Something else",
                        timingSource: .alignment,
                        audioOffset: 0,
                        duration: 0.3,
                        fallbackReason: nil,
                        words: [SpeechTimingWord(text: "Something", startTime: 0, endTime: 0.3)]
                    ),
                ],
                playbackPosition: 0.3
            ),
            ""
        )
    }

    func testRecentTranscriptDisplayUsesPlaybackTimingWhenAvailable() {
        let messageID = UUID()
        let response = "Hermes keeps the answer moving."
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(id: messageID, role: .assistant, text: response)],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: messageID
        )
        let timing = SpeechTiming(
            segmentID: "segment-1",
            text: response,
            timingSource: .alignment,
            audioOffset: 0,
            duration: 1.3,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
                SpeechTimingWord(text: "the", startTime: 0.48, endTime: 0.58),
                SpeechTimingWord(text: "answer", startTime: 0.58, endTime: 0.92),
                SpeechTimingWord(text: "moving.", startTime: 0.92, endTime: 1.3),
            ]
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: messageID,
            revealedTexts: [messageID.uuidString: "Hermes "],
            speechTimings: [timing],
            playbackPosition: 0.58
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes keeps the answer ")
    }

    func testSegmentAwareRevealUsesDurationForFailedMiddleSegment() {
        let target = "Hermes keeps the answer moving."
        let timings = [
            SpeechTiming(
                segmentID: "segment-0",
                text: "Hermes keeps",
                timingSource: .alignment,
                audioOffset: 0,
                duration: 0.48,
                fallbackReason: nil,
                words: [
                    SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                    SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
                ]
            ),
            SpeechTiming(
                segmentID: "segment-1",
                text: "the answer",
                timingSource: .durationFallback,
                audioOffset: 0.48,
                duration: 0.52,
                fallbackReason: .timeout,
                words: []
            ),
            SpeechTiming(
                segmentID: "segment-2",
                text: "moving.",
                timingSource: .alignment,
                audioOffset: 1.0,
                duration: 0.3,
                fallbackReason: nil,
                words: [SpeechTimingWord(text: "moving.", startTime: 1.0, endTime: 1.3)]
            ),
        ]

        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: target,
                timings: timings,
                playbackPosition: 0.9
            ),
            "Hermes keeps the answer "
        )
        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: target,
                timings: timings,
                playbackPosition: 1.3
            ),
            target
        )
    }

    func testSegmentAwareRevealMapsNormalizedWordsToRenderedMarkdown() {
        let target = "**Hermes** keeps\nmoving."
        let timing = SpeechTiming(
            segmentID: "segment-0",
            text: "Hermes keeps moving.",
            timingSource: .alignment,
            audioOffset: 0,
            duration: 0.92,
            fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.28),
                SpeechTimingWord(text: "keeps", startTime: 0.28, endTime: 0.51),
                SpeechTimingWord(text: "moving", startTime: 0.51, endTime: 0.92),
            ]
        )

        XCTAssertEqual(
            SpeechTimingReveal.visibleText(
                target: target,
                timing: timing,
                playbackPosition: 0.50
            ),
            "**Hermes** keeps\n"
        )
    }

    func testDisplayKeepsTheExistingPrefixWhenTimingArrivesLateOrRevises() {
        let id = UUID()
        let target = "Hermes keeps the answer moving."
        let projection = RecentTranscriptProjection(
            messages: [TranscriptMessage(id: id, role: .assistant, text: target)],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: id
        )
        let staleCandidate = SpeechTiming(
            segmentID: "segment-0",
            text: "Hermes keeps",
            timingSource: .alignment,
            audioOffset: 0,
            duration: 0.48,
            fallbackReason: nil,
            words: [SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25)]
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: id,
            revealedTexts: [id.uuidString: "Hermes keeps the "],
            speechTimings: [staleCandidate],
            playbackPosition: 0.2
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes keeps the ")
    }

    func testRecentTranscriptRevealKeepsAnInitialFragmentVisible() {
        let firstFragment = "The"

        let firstStep = RecentTranscriptReveal.nextText(
            current: "",
            target: firstFragment,
            characterBudget: 1
        )

        XCTAssertEqual(firstStep, firstFragment)
    }

    func testRecentTranscriptMarksOnlyTheActiveAssistantAsLiveDuringActiveResponse() {
        let current = TranscriptMessage(role: .assistant, text: "Current answer")
        let projection = RecentTranscriptProjection(
            messages: [
                TranscriptMessage(role: .assistant, text: "Earlier answer"),
                TranscriptMessage(role: .user, text: "Current question"),
                current
            ],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: current.id
        )

        XCTAssertEqual(projection.entries.map(\.isLive), [false, false, true])
    }

    func testRecentTranscriptShowsFirstWordBeforeRevealTaskPublishesState() {
        let response = "Hermes keeps the answer visible while speaking."
        let message = TranscriptMessage(role: .assistant, text: response)
        let projection = RecentTranscriptProjection(
            messages: [message],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: message.id
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: message.id,
            revealedTexts: [:]
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes ")
    }

    func testRecentTranscriptDisplayDoesNotHideAssistantForAnEmptyRevealCursor() {
        let messageID = UUID()
        let projection = RecentTranscriptProjection(
            messages: [
                TranscriptMessage(id: messageID, role: .assistant, text: "Hermes is speaking now.")
            ],
            provisionalText: "",
            isResponseActive: true,
            activeAssistantID: messageID
        )

        let displayedEntries = RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: true,
            activeAssistantID: messageID,
            revealedTexts: [messageID.uuidString: ""]
        )

        XCTAssertEqual(displayedEntries.last?.text, "Hermes ")
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

    // The project had no SWIFT_ACTIVE_COMPILATION_CONDITIONS, so `#if DEBUG`
    // was false in every configuration and the audio diagnostics silently
    // compiled down to the no-op recorder. Pin the gate itself.
    func testDebugBuildsSelectTheLoggingDiagnostics() {
        #if DEBUG
        XCTAssertTrue(
            AudioPlaybackDiagnosticsFactory.make() is OSLogAudioPlaybackDiagnostics
        )
        #else
        // Tests run against the Debug configuration. Reaching this branch
        // means DEBUG is not defined and every #if DEBUG in the app is dead.
        XCTFail("The Debug configuration must define DEBUG.")
        #endif
    }

    // Ported from the TUI's timing.py, which paces noticeably better than the
    // iOS rail did. Before a segment's timing record arrives, the caption must
    // still advance against the PLAYBACK clock — not a wall clock, which
    // cannot track speech and drifts further the longer a segment runs.
    // Expected values mirror tests/test_timing.py in hermes-relay-tui.
    func testFallbackRevealPacesFromThePlaybackClock() {
        let target = "one two three four five six"

        XCTAssertEqual(
            FallbackReveal.visibleText(target: target, elapsed: 0, wordsPerSecond: 2),
            ""
        )
        XCTAssertEqual(
            FallbackReveal.visibleText(target: target, elapsed: 0.5, wordsPerSecond: 2),
            "one "
        )
        XCTAssertEqual(
            FallbackReveal.visibleText(target: target, elapsed: 1.1, wordsPerSecond: 2),
            "one two three "
        )
        XCTAssertEqual(
            FallbackReveal.visibleText(target: target, elapsed: 3.0, wordsPerSecond: 2),
            target
        )
    }

    func testFallbackRevealRejectsNonsenseInput() {
        XCTAssertEqual(FallbackReveal.visibleText(target: "", elapsed: 1), "")
        XCTAssertEqual(
            FallbackReveal.visibleText(target: "word", elapsed: .infinity),
            ""
        )
        XCTAssertEqual(
            FallbackReveal.visibleText(target: "word", elapsed: 1, wordsPerSecond: 0),
            ""
        )
    }

    // The window this closes: audio is playing, no timing record has arrived,
    // and the total duration is not yet final. That returned nil, which sent
    // the rail to the 320ms wall-clock reveal.
    func testPlaybackTextBridgesBeforeAnyTimingRecordArrives() {
        let target = "one two three four five six"

        let bridged = RecentTranscriptDisplay.playbackText(
            target: target,
            speechTimings: [],
            playbackDuration: nil,
            playbackPosition: 1.6,
            isPlaybackDurationFinal: false,
            fallbackPlaybackOrigin: 0.5
        )

        XCTAssertEqual(
            bridged,
            FallbackReveal.visibleText(target: target, elapsed: 1.1)
        )
        XCTAssertNotNil(bridged)
    }

    func testPlaybackTextStillNeedsAnOriginBeforeBridging() {
        XCTAssertNil(
            RecentTranscriptDisplay.playbackText(
                target: "one two three",
                speechTimings: [],
                playbackDuration: nil,
                playbackPosition: 1.6,
                isPlaybackDurationFinal: false,
                fallbackPlaybackOrigin: nil
            )
        )
    }
}
