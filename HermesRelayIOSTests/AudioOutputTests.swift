import Foundation
import XCTest
@testable import HermesRelayIOS

final class AudioOutputTests: XCTestCase {
    func testSigned16PCMFormatIsAccepted() throws {
        XCTAssertNoThrow(
            try PCMFormatValidator.validate(
                AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
            )
        )
    }

    func testFakeOutputPreservesChunkOrder() async throws {
        let output = RecordingAudioOutput()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)

        try await output.start(format: format)
        try await output.append(Data([0, 1]))
        try await output.append(Data([2, 3]))
        await output.finish()

        let chunks = await output.recordedChunks()
        let operations = await output.operations()
        XCTAssertEqual(chunks, [Data([0, 1]), Data([2, 3])])
        XCTAssertEqual(operations, [.start(format), .append, .append, .finish])
    }

    func testFinishAndStopCleanUpTheOutput() async throws {
        let output = RecordingAudioOutput()
        let format = AudioFormat(sampleRate: 16_000, channels: 2, sampleWidth: 2)

        try await output.start(format: format)
        await output.finish()
        await output.stop()

        let operations = await output.operations()
        let isActive = await output.isActive()
        XCTAssertEqual(operations, [.start(format), .finish, .stop])
        XCTAssertFalse(isActive)
    }

    func testOutputFailureReachesTheCaller() async throws {
        let output = RecordingAudioOutput(appendError: .outputFailed)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)

        do {
            try await output.append(Data([0, 1]))
            XCTFail("A playback failure must reach the caller")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }
    }

    func testRecoveringOutputWritesBufferedPCMWhenLiveOutputFails() async throws {
        let liveOutput = RecordingAudioOutput(appendError: .outputFailed)
        let output = RecoveringAudioOutput(liveOutput: liveOutput)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)

        do {
            try await output.append(Data([0x01, 0x02]))
            XCTFail("The configured live output must fail")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }

        let fallbackURL = await output.fallbackURL()
        XCTAssertNotNil(fallbackURL)
        if let fallbackURL {
            defer { try? FileManager.default.removeItem(at: fallbackURL) }
            let wav = try Data(contentsOf: fallbackURL)
            XCTAssertEqual(Data(wav[44...]), Data([0x01, 0x02]))
        }
    }

    func testRecoveringOutputWritesBufferedPCMWhenLiveOutputFailsOnFinish() async throws {
        let liveOutput = FinishFailingAudioOutput()
        let output = RecoveringAudioOutput(liveOutput: liveOutput)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        try await output.append(Data([0x01, 0x02]))

        do {
            try await output.finish()
            XCTFail("A finish-time playback failure must reach the caller")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }

        let fallbackURL = await output.fallbackURL()
        XCTAssertNotNil(fallbackURL)
        if let fallbackURL {
            defer { try? FileManager.default.removeItem(at: fallbackURL) }
            let wav = try Data(contentsOf: fallbackURL)
            XCTAssertEqual(Data(wav[44...]), Data([0x01, 0x02]))
        }
    }

    func testWAVFallbackContainsDeclaredFrameValues() throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 2, sampleWidth: 2)
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let url = try writer.write(pcm: pcm, format: format)
        defer { try? FileManager.default.removeItem(at: url) }

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(littleEndianUInt16(wav, offset: 20), 1)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 22), 2)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 24), 24_000)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 28), 96_000)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 32), 4)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 34), 16)
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(littleEndianUInt32(wav, offset: 40), UInt32(pcm.count))
        XCTAssertEqual(Data(wav[44...]), pcm)
    }

    func testWAVDecoderExtractsDeclaredFormatAndPCM() throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let url = try writer.write(pcm: pcm, format: format)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try WAVAudioDecoder().decode(Data(contentsOf: url))

        XCTAssertEqual(decoded.format, format)
        XCTAssertEqual(decoded.pcm, pcm)
    }

    func testWAVFallbackRejectsUnsupportedSampleWidth() {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 4)

        XCTAssertThrowsError(try writer.write(pcm: Data([0, 1]), format: format)) { error in
            XCTAssertEqual(error as? AudioOutputError, .unsupportedFormat)
        }
    }

    private func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private actor RecordingAudioOutput: AudioOutput {
    enum Operation: Equatable {
        case start(AudioFormat)
        case append
        case finish
        case stop
    }

    private let appendError: AudioOutputError?
    private var active = false
    private var chunks: [Data] = []
    private var recordedOperations: [Operation] = []

    init(appendError: AudioOutputError? = nil) {
        self.appendError = appendError
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        active = true
        recordedOperations.append(.start(format))
    }

    func append(_ pcm: Data) async throws {
        if let appendError { throw appendError }
        guard active else { throw AudioOutputError.notStarted }
        chunks.append(pcm)
        recordedOperations.append(.append)
    }

    func finish() async {
        active = false
        recordedOperations.append(.finish)
    }

    func stop() async {
        active = false
        recordedOperations.append(.stop)
    }

    func recordedChunks() -> [Data] { chunks }
    func operations() -> [Operation] { recordedOperations }
    func isActive() -> Bool { active }
}

private actor FinishFailingAudioOutput: AudioOutput {
    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
    }

    func append(_ pcm: Data) async throws {}

    func finish() async throws {
        throw AudioOutputError.outputFailed
    }

    func stop() async {}
}
