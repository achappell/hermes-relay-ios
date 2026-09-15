import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeBridgeAudioTests: XCTestCase {
    func testHomePCMAccumulatorJoinsOddBinaryChunksAndRejectsOddTerminal() throws {
        var accumulator = HomePCMAccumulator()

        XCTAssertEqual(try accumulator.append(transportChunk: Data([0x01])), Data())
        XCTAssertEqual(
            try accumulator.append(transportChunk: Data([0x02, 0x03])),
            Data([0x01, 0x02])
        )
        XCTAssertThrowsError(try accumulator.finish()) { error in
            XCTAssertEqual(error as? HomePCMError, .invalidTerminalAlignment)
        }
    }

    func testHomeAudioFormatAcceptsOnlySignedMonoLittleEndianPCM16() {
        XCTAssertTrue(
            HomeAudioFormat(
                sampleRate: 24_000,
                channels: 1,
                sampleWidth: 2,
                byteOrder: .little
            ).isValidSignedPCM
        )
        XCTAssertFalse(
            HomeAudioFormat(
                sampleRate: 24_000,
                channels: 2,
                sampleWidth: 2,
                byteOrder: .little
            ).isValidSignedPCM
        )
        XCTAssertFalse(
            HomeAudioFormat(
                sampleRate: 24_000,
                channels: 1,
                sampleWidth: 4,
                byteOrder: .little
            ).isValidSignedPCM
        )
    }

    func testHomePlaybackFailureDoesNotCreateWAVFallback() async throws {
        let liveOutput = FailingHomeAudioOutput()
        let recovering = RecoveringAudioOutput(
            liveOutput: liveOutput,
            fallbackPolicy: .legacyWAV
        )
        let output = HomeAwareAudioOutput(
            wrapped: recovering,
            isHomeMode: { @MainActor in true }
        )
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)

        try await output.start(format: format)
        do {
            _ = try await output.append(Data([0x01, 0x02]))
            XCTFail("The fake live output must fail")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }

        let fallbackURL = await recovering.fallbackURL()
        XCTAssertNil(fallbackURL)
        await output.stop()
    }

    func testHomeFallbackTerminalBecomesSafeAudioAbort() {
        let scope = HomeEventScope(
            conversationHandle: "conversation-a",
            turnID: "turn-a",
            correlationID: "correlation-a"
        )
        var normalizer = HermesEventNormalizer()

        XCTAssertEqual(
            normalizer.normalizeHomeAudio(
                .audioTerminal(scope, .unavailable)
            ),
            [.audioAbort(turnID: "home", reason: "unavailable")]
        )
    }
}

private actor FailingHomeAudioOutput: AudioOutput {
    func start(format: AudioFormat) async throws {}

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        throw AudioOutputError.outputFailed
    }

    func finish() async throws {}
    func stop() async {}
    func playbackPosition() async -> TimeInterval? { nil }
}
