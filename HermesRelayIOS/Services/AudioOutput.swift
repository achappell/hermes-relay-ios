import Foundation

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

protocol AudioOutput: Sendable {
    func start(format: AudioFormat) async throws
    func append(_ pcm: Data) async throws
    func finish() async
    func stop() async
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

    func append(_ pcm: Data) async throws {
        guard format != nil else { throw AudioOutputError.notStarted }
        bufferedPCM.append(pcm)

        do {
            try await liveOutput.append(pcm)
        } catch {
            await liveOutput.stop()
            if let format {
                lastFallbackURL = try? fallbackWriter.write(pcm: bufferedPCM, format: format)
            }
            throw error
        }
    }

    func finish() async {
        await liveOutput.finish()
        format = nil
        bufferedPCM.removeAll(keepingCapacity: false)
    }

    func stop() async {
        await liveOutput.stop()
        format = nil
        bufferedPCM.removeAll(keepingCapacity: false)
    }

    func fallbackURL() -> URL? {
        lastFallbackURL
    }
}
