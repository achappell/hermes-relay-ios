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
