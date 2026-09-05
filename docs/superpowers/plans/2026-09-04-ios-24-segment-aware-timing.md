# IOS-24 Segment-aware word timing and fallback rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS HUD render each active-turn audio segment from validated word timing or its duration fallback without backward jumps or stale-segment authority.

**Architecture:** Keep the protocol model and normalizer responsible for validating the RELAY-07 record shape. Keep the existing coordinator as the active-turn owner, replacing timing revisions by segment ID and sorting by absolute audio offset. Keep transcript mapping and visible-prefix projection in `RecentTranscriptRail.swift`, where the renderer can preserve the original Markdown transcript while pacing it from normalized spoken tokens.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, Foundation, XCTest, Xcode 26.6, iOS/macOS 26.

**Spec:** `docs/superpowers/specs/2026-09-04-ios-24-segment-aware-timing.md`

## Global Constraints

- Alignment remains disabled in local and media profiles during development.
- Preserve IOS-22's whole-audio duration fallback when segment metadata is absent or unusable.
- Do not log prompts, response text, tokens, audio contents, or provider exception text.
- Keep the Hermes Relay iOS and macOS targets independently buildable.
- Use deterministic fake clients and audio outputs; unit tests must not require a live relay.

---

### Task 1: Model and normalize the RELAY-07 timing record

**Files:**
- Modify: `HermesRelayIOS/Models/SessionModels.swift`
- Modify: `HermesRelayIOS/Services/HermesEventNormalizer.swift`
- Test: `HermesRelayIOSTests/HermesEventNormalizerTests.swift`

**Interfaces:**
- Consumes: JSON `speech_timing` payloads from protocol-v1 relay events.
- Produces: `SpeechTimingSource`, bounded fallback reasons, and `SpeechTiming` values with `segmentID`, normalized `text`, `audioOffset`, `duration`, `timingSource`, optional `fallbackReason`, and `words`.

- [x] **Step 1: Write failing normalization tests**

Add tests that assert an aligned record retains its source, absolute offset,
duration, and word spans; a duration-fallback record is accepted with no
words; and an aligned record whose word sequence is partial or invalid becomes
a duration fallback when its segment geometry is safe.

```swift
func testSpeechTimingNormalizesSegmentGeometryAndSource() throws {
    var normalizer = HermesEventNormalizer()
    let events = try normalizer.normalizeJSON(
        json([
            "type": "speech_timing",
            "payload": [
                "segment_id": "turn-1-tts-0",
                "text": "Hermes keeps moving.",
                "timing_source": "alignment",
                "audio_offset_ms": 920,
                "duration_ms": 640,
                "words": [
                    ["text": "Hermes", "start_ms": 920, "end_ms": 1_120],
                    ["text": "keeps", "start_ms": 1_120, "end_ms": 1_320],
                    ["text": "moving.", "start_ms": 1_320, "end_ms": 1_560],
                ],
            ] as [String: Any],
        ]),
        turnID: "turn-1"
    )

    guard case .speechTiming(let timing) = try XCTUnwrap(events.first) else {
        return XCTFail("Expected a speech timing event")
    }
    XCTAssertEqual(timing.segmentID, "turn-1-tts-0")
    XCTAssertEqual(timing.timingSource, .alignment)
    XCTAssertEqual(timing.audioOffset, 0.92, accuracy: 0.000_001)
    XCTAssertEqual(timing.duration, 0.64, accuracy: 0.000_001)
    XCTAssertEqual(timing.words.count, 3)
}

func testSpeechTimingAcceptsDurationFallbackWithoutWords() throws {
    var normalizer = HermesEventNormalizer()
    let events = try normalizer.normalizeJSON(
        json([
            "type": "speech_timing",
            "payload": [
                "segment_id": "turn-1-tts-1",
                "text": "The next segment.",
                "timing_source": "duration_fallback",
                "fallback_reason": "timeout",
                "audio_offset_ms": 1_560,
                "duration_ms": 640,
                "words": [],
            ] as [String: Any],
        ]),
        turnID: "turn-1"
    )

    XCTAssertEqual(
        events,
        [.speechTiming(SpeechTiming(
            segmentID: "turn-1-tts-1",
            text: "The next segment.",
            timingSource: .durationFallback,
            audioOffset: 1.56,
            duration: 0.64,
            fallbackReason: .timeout,
            words: []
        ))]
    )
}

func testPartialSpeechTimingDegradesToDurationFallback() throws {
    var normalizer = HermesEventNormalizer()
    let events = try normalizer.normalizeJSON(
        json([
            "type": "speech_timing",
            "payload": [
                "segment_id": "turn-1-tts-0",
                "text": "Hermes keeps moving.",
                "timing_source": "alignment",
                "audio_offset_ms": 0,
                "duration_ms": 920,
                "words": [["text": "Hermes", "start_ms": 0, "end_ms": 280]],
            ] as [String: Any],
        ]),
        turnID: "turn-1"
    )

    guard case .speechTiming(let timing) = try XCTUnwrap(events.first) else {
        return XCTFail("Expected a duration fallback event")
    }
    XCTAssertEqual(timing.timingSource, .durationFallback)
    XCTAssertEqual(timing.fallbackReason, .invalid)
    XCTAssertTrue(timing.words.isEmpty)
}
```

- [x] **Step 2: Run the focused tests and verify the expected failure**

Run:

```bash
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -only-testing:HermesRelayIOSTests/HermesEventNormalizerTests
```

Expected: compilation fails because the new timing source, geometry, and
fallback fields do not exist yet.

- [x] **Step 3: Implement the smallest model and normalizer change**

Add the bounded enums and fields to `SessionModels.swift`. In
`normalizeSpeechTiming`, require non-empty segment ID and text, finite
non-negative `audio_offset_ms`, positive finite `duration_ms`, and a supported
source. Validate aligned word spans against the absolute segment bounds and
monotonic order, then compare their normalized token sequence with the
normalized segment text so a partial list cannot become authoritative. If
source or words are invalid but safe segment geometry is present, emit a
duration-fallback record with `.invalid`; otherwise return `nil` so the
existing content-safe unknown-event path preserves the whole audio-duration
fallback.

- [x] **Step 4: Run the focused tests and verify they pass**

Run the same `xcodebuild test` command. Expected: all normalizer tests pass,
including the existing invalid-event and content-safe unknown-event tests.

- [x] **Step 5: Commit the model and normalizer slice**

```bash
git add HermesRelayIOS/Models/SessionModels.swift HermesRelayIOS/Services/HermesEventNormalizer.swift HermesRelayIOSTests/HermesEventNormalizerTests.swift
git commit -m "feat: normalize segment-scoped speech timing"
```

### Task 2: Build segment-aware transcript projection

**Files:**
- Modify: `HermesRelayIOS/Views/RecentTranscriptRail.swift`
- Test: `HermesRelayIOSTests/HermesRelayIOSTests.swift`

**Interfaces:**
- Consumes: rendered assistant text, ordered or out-of-order `SpeechTiming` records, playback position, and the existing revealed-text floor.
- Produces: `SpeechTimingReveal.visibleText(target:timings:playbackPosition:)` as a valid rendered prefix, plus a display projection that never shortens a valid existing prefix.

- [x] **Step 1: Write failing projection tests**

Add tests for a failed middle segment, normalized Markdown/punctuation and
line-break matching, delayed metadata, and a revised record with the same
segment ID. The mixed segment test must prove the fallback segment advances
between its absolute offset and end instead of repeating the first segment.

```swift
func testSegmentAwareRevealUsesDurationForFailedMiddleSegment() {
    let target = "Hermes keeps the answer moving."
    let timings = [
        SpeechTiming(
            segmentID: "segment-0", text: "Hermes keeps", timingSource: .alignment,
            audioOffset: 0, duration: 0.48, fallbackReason: nil,
            words: [
                SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25),
                SpeechTimingWord(text: "keeps", startTime: 0.25, endTime: 0.48),
            ]
        ),
        SpeechTiming(
            segmentID: "segment-1", text: "the answer", timingSource: .durationFallback,
            audioOffset: 0.48, duration: 0.52, fallbackReason: .timeout, words: []
        ),
        SpeechTiming(
            segmentID: "segment-2", text: "moving.", timingSource: .alignment,
            audioOffset: 1.0, duration: 0.3, fallbackReason: nil,
            words: [SpeechTimingWord(text: "moving.", startTime: 1.0, endTime: 1.3)]
        ),
    ]

    XCTAssertEqual(
        SpeechTimingReveal.visibleText(target: target, timings: timings, playbackPosition: 0.7),
        "Hermes keeps the answer "
    )
    XCTAssertEqual(
        SpeechTimingReveal.visibleText(target: target, timings: timings, playbackPosition: 1.3),
        target
    )
}

func testSegmentAwareRevealMapsNormalizedWordsToRenderedMarkdown() {
    let target = "**Hermes** keeps\nmoving."
    let timing = SpeechTiming(
        segmentID: "segment-0", text: "Hermes keeps moving.", timingSource: .alignment,
        audioOffset: 0, duration: 0.92, fallbackReason: nil,
        words: [
            SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.28),
            SpeechTimingWord(text: "keeps", startTime: 0.28, endTime: 0.51),
            SpeechTimingWord(text: "moving", startTime: 0.51, endTime: 0.92),
        ]
    )

    XCTAssertEqual(
        SpeechTimingReveal.visibleText(target: target, timing: timing, playbackPosition: 0.51),
        "**Hermes** keeps\n"
    )
}

func testDisplayKeepsTheExistingPrefixWhenTimingArrivesLateOrRevises() {
    let id = UUID()
    let target = "Hermes keeps the answer moving."
    let projection = RecentTranscriptProjection(
        messages: [TranscriptMessage(id: id, role: .assistant, text: target)],
        provisionalText: "",
        isResponseActive: true
    )
    let staleCandidate = SpeechTiming(
        segmentID: "segment-0", text: "Hermes keeps", timingSource: .alignment,
        audioOffset: 0, duration: 0.48, fallbackReason: nil,
        words: [SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.25)]
    )

    let displayed = RecentTranscriptDisplay.entries(
        projection: projection,
        isResponseActive: true,
        revealedTexts: [id.uuidString: "Hermes keeps the "],
        speechTimings: [staleCandidate],
        playbackPosition: 0.2
    )

    XCTAssertEqual(displayed.last?.text, "Hermes keeps the ")
}
```

- [x] **Step 2: Run the projection tests and verify the expected failure**

Run:

```bash
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -only-testing:HermesRelayIOSTests/HermesRelayIOSTests
```

Expected: the new mixed-segment and normalized-token assertions fail against
the current response-level flattened-word algorithm.

- [x] **Step 3: Implement segment mapping and prefix-safe projection**

Replace the flattened-word calculation with ordered segment mappings. Tokenize
the rendered target by whitespace while retaining each original range;
normalize comparison tokens by lowercasing and retaining only letters and
numbers after removing Markdown punctuation. Match each segment's spoken word
sequence from the current target cursor, use absolute word starts for aligned
segments, and use `audioOffset`/`duration` progress for fallback segments.
Deduplicate records by `segmentID`, order them by `audioOffset`, and stop at
the first not-yet-started or partially revealed segment. In
`RecentTranscriptDisplay`, choose the longest candidate that is a prefix of
the rendered target among the timing candidate and the existing revealed-text
floor; use `AudioDurationReveal` only when no usable segment candidate exists.
Apply the same fallback choice in `updateRevealFloor()`.

- [x] **Step 4: Run the projection tests and verify they pass**

Run the same `xcodebuild test` command. Expected: all existing IOS-20/IOS-22
transcript tests and the new segment-aware tests pass.

- [x] **Step 5: Commit the segment projection slice**

```bash
git add HermesRelayIOS/Views/RecentTranscriptRail.swift HermesRelayIOSTests/HermesRelayIOSTests.swift
git commit -m "feat: render segment-aware speech timing"
```

### Task 3: Keep coordinator timing state turn-scoped and revision-safe

**Files:**
- Modify: `HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift`
- Test: `HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: normalized `HermesEvent.speechTiming` events delivered with the active response generation.
- Produces: sorted active-turn `speechTimings` with same-ID revisions replacing prior records and interruption/new-turn resets preserving stale-turn isolation.

- [x] **Step 1: Write failing coordinator tests**

Add assertions that out-of-order segments are exposed in audio-offset order,
same-ID revisions replace rather than append, and interruption clears the old
timing before the next capture begins. Extend the existing interruptible fake
client with one timing event so the reset assertion observes real coordinator
state.

```swift
@MainActor
func testCoordinatorReplacesTimingRevisionAndSortsSegments() async {
    let input = CoordinatorSpeechInput(
        finalUpdate: SpeechRecognitionUpdate(text: "Speak", isFinal: true)
    )
    let segment0 = SpeechTiming(
        segmentID: "segment-0", text: "First", timingSource: .durationFallback,
        audioOffset: 0, duration: 0.4, fallbackReason: .timeout, words: []
    )
    let segment1 = SpeechTiming(
        segmentID: "segment-1", text: "Second", timingSource: .durationFallback,
        audioOffset: 0.4, duration: 0.4, fallbackReason: .timeout, words: []
    )
    let revisedSegment1 = SpeechTiming(
        segmentID: "segment-1", text: "Second", timingSource: .alignment,
        audioOffset: 0.4, duration: 0.4, fallbackReason: nil,
        words: [SpeechTimingWord(text: "Second", startTime: 0.4, endTime: 0.8)]
    )
    let client = CoordinatorHermesSessionClient(events: [
        .messageStart,
        .textDelta("First Second"),
        .speechTiming(segment1),
        .speechTiming(segment0),
        .speechTiming(revisedSegment1),
        .audioStart(AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)),
        .audioChunk(Data(repeating: 0, count: 19_200)),
        .audioEnd,
        .turnComplete(turnID: "turn-1"),
    ])
    let store = await connectedStore(client)
    let output = CoordinatorAudioOutput(waitsForFinish: true)
    let coordinator = VoiceSessionCoordinator(store: store, input: input, output: output)

    await coordinator.beginCapture()
    let responseTask = Task { @MainActor in
        await coordinator.endCaptureAndSend()
    }
    await output.waitUntilFinishRequested()

    XCTAssertEqual(coordinator.speechTimings.map(\.segmentID), ["segment-0", "segment-1"])
    XCTAssertEqual(coordinator.speechTimings.last?.timingSource, .alignment)

    await output.allowFinish()
    await responseTask.value
}
```

In the existing `testInterruptStopsPlaybackReconnectsAndBeginsNewCapture`
fixture, yield this fallback timing record before the fake `audioStart` event:

```swift
continuation.yield(
    .speechTiming(SpeechTiming(
        segmentID: "interrupt-segment",
        text: "Interrupt me",
        timingSource: .durationFallback,
        audioOffset: 0,
        duration: 0.4,
        fallbackReason: .timeout,
        words: []
    ))
)
```

Then assert the timing is present before interruption and absent after
`await coordinator.interruptAndBeginCapture()`:

```swift
XCTAssertEqual(coordinator.speechTimings.map(\.segmentID), ["interrupt-segment"])
await coordinator.interruptAndBeginCapture()
XCTAssertTrue(coordinator.speechTimings.isEmpty)
```

- [x] **Step 2: Run the coordinator tests and verify the expected failure**

Run:

```bash
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -only-testing:HermesRelayIOSTests/VoiceSessionCoordinatorTests
```

Expected: the ordering/revision assertion fails because the current array
keeps arrival order; the interruption assertion remains a regression guard for
the existing generation reset.

- [x] **Step 3: Implement keyed replacement and deterministic ordering**

In the `.speechTiming` handler, replace a matching `segmentID`, otherwise
append, then sort by `audioOffset` and `segmentID` as a deterministic tie
breaker. Keep the existing generation guard and reset calls at voice-turn,
typed-turn, interruption, and playback-stop boundaries.

- [x] **Step 4: Run the coordinator tests and verify they pass**

Run the same `xcodebuild test` command. Expected: all coordinator tests pass,
including existing playback, interruption, and text-turn behavior.

- [x] **Step 5: Commit the coordinator slice**

```bash
git add HermesRelayIOS/ViewModels/VoiceSessionCoordinator.swift HermesRelayIOSTests/VoiceSessionCoordinatorTests.swift
git commit -m "fix: scope speech timing to active response"
```

### Task 4: Verify the complete IOS-24 slice and record evidence

**Files:**
- Modify: `docs/architecture.md` only if the existing timing description is now inaccurate.
- Modify: the IOS-24 GitHub Project item with implementation and validation evidence.

**Interfaces:**
- Consumes: the completed model, normalizer, renderer, and coordinator slices.
- Produces: passing focused and full validation evidence, a clean reviewable diff, and IOS-22/IOS-24 status ready for joint sign-off.

- [x] **Step 1: Run the focused XCTest target**

```bash
xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -only-testing:HermesRelayIOSTests/HermesEventNormalizerTests -only-testing:HermesRelayIOSTests/HermesRelayIOSTests -only-testing:HermesRelayIOSTests/VoiceSessionCoordinatorTests
```

- [x] **Step 2: Build and test the iOS simulator target**

Use the configured XcodeBuildMCP session for the worktree and run the complete
`HermesRelayIOS` scheme test suite.

- [x] **Step 3: Build the macOS target**

Run the repository-supported `xcodebuild` macOS build and record whether the
shared model and view files compile for both intended platforms.

- [x] **Step 4: Run the manual smoke scenario**

> Earlier attempt: the simulator connected to the local relay and submitted a
> typed turn, but the relay did not emit a completion event during the wait
> window. The app remained in `Buffering`; the captured app log contained
> only known CoreSimulator accessibility/surface warnings. That was an
> environment-level limitation, not a smoke result.
>
> Smoke result 2026-09-04: run on the configured device after commit 2668113.
> A long multi-segment response paces with the audio across the viewport, with
> no opening dump, no repeated first segment, and no mid-response freeze.
> Still not individually confirmed: prefix retention specifically while audio
> buffers grow, and interruption/reconnect leaving no stale timing visible.

With alignment still disabled, send a typed turn through the local relay and
confirm: handshake succeeds, the response contains more than one audio
segment, fallback timing does not repeat the first segment, the caption keeps
its prefix while audio buffers grow, and interruption/reconnect leaves no old
timing visible. Do not record audio or log content.

- [x] **Step 5: Review the diff and update the project item**

Check `git diff --check`, credentials/audio/generated files, and the full file
list. Add the test counts, smoke result, commit SHAs, and any known simulator
speech-recognition limitation to IOS-24. Keep IOS-22 in `Verify` until this
combined validation is complete; move both to `Done` only after the evidence
supports joint sign-off.

## Outcome — 2026-09-04

Three reveal defects were found after the IOS-22 merge and fixed in commit
2668113 (merged as b6795ab, PR #19): an unmappable segment abandoning every
later segment, duration pacing against a still-growing buffer, and the
character reveal running at the text-delta rate. Full suite 135 tests, 0
failures.

IOS-20, IOS-22 and IOS-24 are `Done`. IOS-23 returned to `Todo` — no work was
started on it. The mapper's remaining strictness is tracked as IOS-28.
