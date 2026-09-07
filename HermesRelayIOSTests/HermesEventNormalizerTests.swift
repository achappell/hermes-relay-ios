import Foundation
import XCTest
@testable import HermesRelayIOS

final class HermesEventNormalizerTests: XCTestCase {
    func testTextDeltaUsesOnlyTheUnseenCumulativeSuffix() throws {
        var normalizer = HermesEventNormalizer()

        let first = try normalizer.normalizeJSON(
            json(["type": "text_delta", "text": "Hel"]),
            turnID: "turn-1"
        )
        let second = try normalizer.normalizeJSON(
            json(["type": "text_delta", "text": "Hello"]),
            turnID: "turn-1"
        )

        XCTAssertEqual(first, [.textDelta("Hel")])
        XCTAssertEqual(second, [.textDelta("lo")])
    }

    func testTextFinalMatchingThePreviewProducesNoDuplicateText() throws {
        var normalizer = HermesEventNormalizer()

        _ = try normalizer.normalizeJSON(
            json(["type": "text_delta", "text": "Hello"]),
            turnID: "turn-1"
        )
        let events = try normalizer.normalizeJSON(
            json(["type": "text_final", "text": "Hello"]),
            turnID: "turn-1"
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testTextReplacementReplacesARevisedPreview() throws {
        var normalizer = HermesEventNormalizer()

        _ = try normalizer.normalizeJSON(
            json(["type": "text_delta", "text": "The weather"]),
            turnID: "turn-1"
        )
        let events = try normalizer.normalizeJSON(
            json(["type": "text_delta", "text": "Weather", "replace": true]),
            turnID: "turn-1"
        )

        XCTAssertEqual(events, [.textReplace("Weather")])
    }

    func testStatusAndThinkingActivityRemainTyped() throws {
        var normalizer = HermesEventNormalizer()

        let status = try normalizer.normalizeJSON(
            json([
                "type": "status.update",
                "payload": ["text": "Working", "kind": "tool"]
            ]),
            turnID: "turn-1"
        )
        let thinking = try normalizer.normalizeJSON(
            json(["type": "thinking.delta", "payload": ["text": "Reasoning"]]),
            turnID: "turn-1"
        )

        XCTAssertEqual(status, [.status(text: "Working", kind: "tool")])
        XCTAssertEqual(thinking, [.thinkingDelta("Reasoning")])
    }

    func testAudioStartUsesDeclaredDefaultsAndAudioChunksRemainBinary() throws {
        var normalizer = HermesEventNormalizer()

        let start = try normalizer.normalizeJSON(
            json(["type": "audio_start", "payload": [String: Any]()]),
            turnID: "turn-1"
        )
        let chunk = normalizer.normalizeBinary(Data([0, 1, 2, 3]), audioFileActive: false)

        XCTAssertEqual(start, [.audioStart(AudioFormat(sampleRate: 24000, channels: 1, sampleWidth: 2))])
        XCTAssertEqual(chunk, .audioChunk(Data([0, 1, 2, 3])))
    }

    func testAudioFileFramesRemainTypedUntilTheFileEnds() throws {
        var normalizer = HermesEventNormalizer()

        let start = try normalizer.normalizeJSON(
            json(["type": "audio_file_start", "content_type": "audio/wav"]),
            turnID: "turn-1"
        )
        let chunk = normalizer.normalizeBinary(Data([0, 1, 2, 3]), audioFileActive: true)
        let end = try normalizer.normalizeJSON(
            json(["type": "audio_file_end"]),
            turnID: "turn-1"
        )

        XCTAssertEqual(start, [.audioFileStart(contentType: "audio/wav")])
        XCTAssertEqual(chunk, .audioFileChunk(Data([0, 1, 2, 3])))
        XCTAssertEqual(end, [.audioFileEnd])
    }

    func testInterruptEventsRemainTypedWithTheirTurnIdentity() throws {
        var normalizer = HermesEventNormalizer()

        let audioAbort = try normalizer.normalizeJSON(
            json([
                "type": "audio_abort",
                "turn_id": "turn-7",
                "session_id": "session-1",
                "error": "client interrupt",
            ]),
            turnID: "turn-7"
        )
        let interrupted = try normalizer.normalizeJSON(
            json([
                "type": "turn_interrupted",
                "turn_id": "turn-7",
                "session_id": "session-1",
                "reason": "turn interrupted",
            ]),
            turnID: "turn-7"
        )

        XCTAssertEqual(
            audioAbort,
            [.audioAbort(turnID: "turn-7", reason: "client interrupt")]
        )
        XCTAssertEqual(
            interrupted,
            [.turnInterrupted(turnID: "turn-7", reason: "turn interrupted")]
        )
    }

    func testSpeechTimingNormalizesWordBoundariesInMilliseconds() throws {
        var normalizer = HermesEventNormalizer()

        let events = try normalizer.normalizeJSON(
            json([
                "type": "speech_timing",
                "payload": [
                    "segment_id": "segment-1",
                    "text": "Hermes keeps moving.",
                    "timing_source": "alignment",
                    "audio_offset_ms": 0,
                    "duration_ms": 920,
                    "words": [
                        ["text": "Hermes", "start_ms": 0, "end_ms": 280],
                        ["text": "keeps", "start_ms": 280, "end_ms": 510],
                        ["text": "moving.", "start_ms": 510, "end_ms": 920],
                    ],
                ] as [String: Any],
            ]),
            turnID: "turn-1"
        )

        XCTAssertEqual(
            events,
            [
                .speechTiming(
                    SpeechTiming(
                        segmentID: "segment-1",
                        text: "Hermes keeps moving.",
                        timingSource: .alignment,
                        audioOffset: 0,
                        duration: 0.92,
                        fallbackReason: nil,
                        words: [
                            SpeechTimingWord(text: "Hermes", startTime: 0, endTime: 0.28),
                            SpeechTimingWord(text: "keeps", startTime: 0.28, endTime: 0.51),
                            SpeechTimingWord(text: "moving.", startTime: 0.51, endTime: 0.92),
                        ]
                    )
                ),
            ]
        )
    }

    func testInvalidSpeechTimingIsIgnoredAsAnUnknownEvent() throws {
        var normalizer = HermesEventNormalizer()

        let events = try normalizer.normalizeJSON(
            json([
                "type": "speech_timing",
                "payload": [
                    "words": [
                        ["text": "Hermes", "start_ms": 400, "end_ms": 200],
                    ],
                ],
            ] as [String: Any]),
            turnID: "turn-1"
        )

        XCTAssertEqual(events, [.unknown(type: "speech_timing")])
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

    func testErrorStopsWithTheServerMessageOrFallback() throws {
        var normalizer = HermesEventNormalizer()

        let serverError = try normalizer.normalizeJSON(
            json(["type": "error", "payload": ["message": "connection lost"]]),
            turnID: "turn-1"
        )
        let fallbackError = try normalizer.normalizeJSON(
            json(["type": "error", "payload": [String: Any]()]),
            turnID: "turn-1"
        )

        XCTAssertEqual(serverError, [.error("connection lost")])
        XCTAssertEqual(fallbackError, [.error("voice-session error")])
    }

    func testUnknownEventsAreContentSafe() throws {
        var normalizer = HermesEventNormalizer()

        let events = try normalizer.normalizeJSON(
            json(["type": "future.secret_event", "payload": ["text": "do not retain"]]),
            turnID: "turn-1"
        )

        XCTAssertEqual(events, [.unknown(type: "future.secret_event")])
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
