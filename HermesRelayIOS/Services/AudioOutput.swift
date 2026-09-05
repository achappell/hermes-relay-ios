import Foundation
import os

enum AudioOutputError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case notStarted
    case outputFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Hermes returned an unsupported PCM audio format."
        case .notStarted:
            return "Audio playback has not started."
        case .outputFailed:
            return "Audio playback failed."
        }
    }
}

enum PCMFormatValidator {
    static func validate(_ format: AudioFormat) throws {
        guard format.sampleRate > 0,
              format.channels > 0,
              format.sampleWidth == 2 else {
            throw AudioOutputError.unsupportedFormat
        }
    }
}

struct PCMFrameAccumulator: Sendable {
    private let bytesPerFrame: Int
    private var pending = Data()

    init(bytesPerFrame: Int) {
        self.bytesPerFrame = bytesPerFrame
    }

    mutating func append(_ pcm: Data) throws -> Data? {
        guard bytesPerFrame > 0 else {
            throw AudioOutputError.unsupportedFormat
        }

        pending.append(pcm)
        let completeByteCount = pending.count - (pending.count % bytesPerFrame)
        guard completeByteCount > 0 else { return nil }

        let completePCM = Data(pending.prefix(completeByteCount))
        pending.removeFirst(completeByteCount)
        return completePCM
    }

    mutating func finish() throws {
        guard pending.isEmpty else {
            throw AudioOutputError.outputFailed
        }
    }
}

enum AudioPlaybackReadiness: Equatable, Sendable {
    case buffering
    case ready
}

actor AudioPlaybackDrain {
    private var scheduledBufferCount = 0
    private var completionWaiter: CheckedContinuation<Void, Never>?

    func scheduleBuffer() {
        scheduledBufferCount += 1
    }

    func waitForCompletion() async {
        guard scheduledBufferCount > 0 else { return }
        await withCheckedContinuation { continuation in
            completionWaiter = continuation
        }
    }

    func bufferDidComplete() {
        guard scheduledBufferCount > 0 else { return }
        scheduledBufferCount -= 1
        guard scheduledBufferCount == 0, let completionWaiter else { return }
        self.completionWaiter = nil
        completionWaiter.resume()
    }

    func reset() {
        scheduledBufferCount = 0
        completionWaiter?.resume()
        completionWaiter = nil
    }
}

enum AudioPlaybackDiagnostic: Equatable, Sendable {
    case streamStarted(format: AudioFormat)
    case chunkReceived(bytes: Int)
    case chunkScheduled(bytes: Int)
    case firstAudioScheduled(bytes: Int)
    case streamEnded(bytes: Int)
    case playbackCompleted(bytes: Int)
    case playbackFailed
    // IOS-32: separates a per-segment playback clock reset from timing
    // segments the normalizer could not map. Numbers and enum names only —
    // never transcript text.
    case segmentBoundary(
        index: Int,
        phase: AudioSegmentPhase,
        playbackPositionMilliseconds: Int?
    )
    case speechTimingReceived(
        segmentIndex: Int,
        audioOffsetMilliseconds: Int,
        durationMilliseconds: Int,
        wordCount: Int,
        source: String,
        fallbackReason: String?
    )
}

enum AudioSegmentPhase: String, Equatable, Sendable {
    case started
    case ended
}

protocol AudioPlaybackDiagnostics: Sendable {
    func record(_ event: AudioPlaybackDiagnostic) async
}

struct NoopAudioPlaybackDiagnostics: AudioPlaybackDiagnostics {
    func record(_ event: AudioPlaybackDiagnostic) async {}
}

struct OSLogAudioPlaybackDiagnostics: AudioPlaybackDiagnostics, Sendable {
    private let logger = Logger(
        subsystem: "com.achappell.HermesRelayIOS",
        category: "audio-playback"
    )

    func record(_ event: AudioPlaybackDiagnostic) async {
        switch event {
        case .streamStarted(let format):
            logger.debug(
                "audio stream started sample_rate=\(format.sampleRate, privacy: .public) channels=\(format.channels, privacy: .public) sample_width=\(format.sampleWidth, privacy: .public)"
            )
        case .chunkReceived(let bytes):
            logger.debug("audio chunk received bytes=\(bytes, privacy: .public)")
        case .chunkScheduled(let bytes):
            logger.debug("audio chunk scheduled bytes=\(bytes, privacy: .public)")
        case .firstAudioScheduled(let bytes):
            logger.debug("audio first buffer scheduled bytes=\(bytes, privacy: .public)")
        case .streamEnded(let bytes):
            logger.debug("audio stream ended bytes=\(bytes, privacy: .public)")
        case .playbackCompleted(let bytes):
            logger.debug("audio playback completed bytes=\(bytes, privacy: .public)")
        case .playbackFailed:
            logger.error("audio playback failed")
        case .segmentBoundary(let index, let phase, let positionMilliseconds):
            // Info rather than debug: OSLog does not persist debug messages,
            // and Console hides them unless the user opts in. These two lines
            // exist to be read after a run.
            logger.info(
                "audio segment \(phase.rawValue, privacy: .public) index=\(index, privacy: .public) playback_position_ms=\(positionMilliseconds ?? -1, privacy: .public)"
            )
        case .speechTimingReceived(
            let segmentIndex,
            let audioOffsetMilliseconds,
            let durationMilliseconds,
            let wordCount,
            let source,
            let fallbackReason
        ):
            logger.info(
                "speech timing segment_index=\(segmentIndex, privacy: .public) audio_offset_ms=\(audioOffsetMilliseconds, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) words=\(wordCount, privacy: .public) source=\(source, privacy: .public) fallback=\(fallbackReason ?? "none", privacy: .public)"
            )
        }
    }
}

enum AudioPlaybackDiagnosticsFactory {
    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any AudioPlaybackDiagnostics {
        #if DEBUG
        return OSLogAudioPlaybackDiagnostics()
        #else
        return NoopAudioPlaybackDiagnostics()
        #endif
    }
}

protocol AudioOutput: Sendable {
    func start(format: AudioFormat) async throws
    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness
    func finish() async throws
    func stop() async
    func playbackPosition() async -> TimeInterval?
}

actor AudioActivityReportingOutput: AudioOutput {
    private let wrapped: any AudioOutput
    private let reporter: any AudioActivityReporter

    init(
        wrapped: any AudioOutput,
        reporter: any AudioActivityReporter
    ) {
        self.wrapped = wrapped
        self.reporter = reporter
    }

    func start(format: AudioFormat) async throws {
        do {
            try await wrapped.start(format: format)
        } catch {
            await reporter.reportPlaybackEnded()
            throw error
        }
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        do {
            let readiness = try await wrapped.append(pcm)
            if !pcm.isEmpty {
                await reporter.reportPlayback(
                    level: PCMActivityAnalyzer.normalizedRMS(pcm)
                )
            }
            return readiness
        } catch {
            await reporter.reportPlaybackEnded()
            throw error
        }
    }

    func finish() async throws {
        do {
            try await wrapped.finish()
            await reporter.reportPlaybackEnded()
        } catch {
            await reporter.reportPlaybackEnded()
            throw error
        }
    }

    func stop() async {
        await wrapped.stop()
        await reporter.reportPlaybackEnded()
    }

    func playbackPosition() async -> TimeInterval? {
        await wrapped.playbackPosition()
    }
}

actor RecoveringAudioOutput: AudioOutput {
    private let liveOutput: any AudioOutput
    private let fallbackWriter: WAVFallbackWriter
    private var format: AudioFormat?
    private var bufferedPCM = Data()
    private var lastFallbackURL: URL?

    init(
        liveOutput: any AudioOutput,
        fallbackWriter: WAVFallbackWriter = WAVFallbackWriter()
    ) {
        self.liveOutput = liveOutput
        self.fallbackWriter = fallbackWriter
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        await liveOutput.stop()
        self.format = format
        bufferedPCM.removeAll(keepingCapacity: false)
        lastFallbackURL = nil
        try await liveOutput.start(format: format)
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        guard format != nil else { throw AudioOutputError.notStarted }
        bufferedPCM.append(pcm)

        do {
            return try await liveOutput.append(pcm)
        } catch {
            await liveOutput.stop()
            if let format {
                lastFallbackURL = try? fallbackWriter.write(pcm: bufferedPCM, format: format)
            }
            throw error
        }
    }

    func finish() async throws {
        do {
            try await liveOutput.finish()
        } catch {
            await liveOutput.stop()
            if let format {
                lastFallbackURL = try? fallbackWriter.write(pcm: bufferedPCM, format: format)
            }
            self.format = nil
            bufferedPCM.removeAll(keepingCapacity: false)
            throw error
        }

        format = nil
        bufferedPCM.removeAll(keepingCapacity: false)
    }

    func stop() async {
        await liveOutput.stop()
        format = nil
        bufferedPCM.removeAll(keepingCapacity: false)
    }

    func playbackPosition() async -> TimeInterval? {
        await liveOutput.playbackPosition()
    }

    func fallbackURL() -> URL? {
        lastFallbackURL
    }
}
