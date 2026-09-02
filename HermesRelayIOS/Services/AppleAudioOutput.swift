import AVFAudio
import Foundation

actor AppleAudioOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let diagnostics: any AudioPlaybackDiagnostics
    private let playbackDrain = AudioPlaybackDrain()
    private var audioFormat: AVAudioFormat?
    private var pcmFrameAccumulator: PCMFrameAccumulator?
    private var scheduledAudioBytes = 0
    private var isAcceptingAudio = false
    private var playbackStarted = false

    init(
        diagnostics: any AudioPlaybackDiagnostics = NoopAudioPlaybackDiagnostics()
    ) {
        self.diagnostics = diagnostics
        engine.attach(playerNode)
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        await stopResources()

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw AudioOutputError.unsupportedFormat
        }

        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try audioSession.setActive(true)
            #endif

            engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
            engine.prepare()
            try engine.start()
            audioFormat = avFormat
            pcmFrameAccumulator = PCMFrameAccumulator(
                bytesPerFrame: format.channels * format.sampleWidth
            )
            isAcceptingAudio = true
        } catch {
            await stopResources()
            throw AudioOutputError.outputFailed
        }
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        guard isAcceptingAudio, let audioFormat else {
            throw AudioOutputError.notStarted
        }

        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw AudioOutputError.outputFailed
        }
        guard !pcm.isEmpty else { return .buffering }

        guard let pcmFrameAccumulator else {
            throw AudioOutputError.notStarted
        }
        var accumulator = pcmFrameAccumulator
        var readiness: AudioPlaybackReadiness = .buffering
        if let completePCM = try accumulator.append(pcm) {
            let wasPlaybackStarted = playbackStarted
            try await schedule(completePCM, format: audioFormat, bytesPerFrame: bytesPerFrame)
            readiness = .ready
            await diagnostics.record(.chunkScheduled(bytes: completePCM.count))
            if !wasPlaybackStarted {
                await diagnostics.record(.firstAudioScheduled(bytes: completePCM.count))
            }
        }
        self.pcmFrameAccumulator = accumulator
        return readiness
    }

    func finish() async throws {
        do {
            try pcmFrameAccumulator?.finish()
        } catch {
            await stopResources()
            throw error
        }
        pcmFrameAccumulator = nil
        isAcceptingAudio = false
        await playbackDrain.waitForCompletion()
        if scheduledAudioBytes > 0 {
            await diagnostics.record(.playbackCompleted(bytes: scheduledAudioBytes))
        }
    }

    func stop() async {
        await stopResources()
    }

    private func schedule(
        _ pcm: Data,
        format: AVAudioFormat?,
        bytesPerFrame: Int
    ) async throws {
        guard let format else { throw AudioOutputError.notStarted }
        guard !pcm.isEmpty, pcm.count % bytesPerFrame == 0 else {
            throw AudioOutputError.outputFailed
        }

        let frameCapacity = AVAudioFrameCount(pcm.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw AudioOutputError.outputFailed
        }
        buffer.frameLength = frameCapacity

        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw AudioOutputError.outputFailed
        }
        pcm.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(destination, source, pcm.count)
        }
        await playbackDrain.scheduleBuffer()
        scheduledAudioBytes += pcm.count
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task {
                await self?.playbackDrain.bufferDidComplete()
            }
        }
        startPlaybackIfNeeded()
    }

    private func startPlaybackIfNeeded() {
        guard !playbackStarted else { return }
        playerNode.play()
        playbackStarted = true
    }

    private func stopResources() async {
        isAcceptingAudio = false
        pcmFrameAccumulator = nil
        scheduledAudioBytes = 0
        await playbackDrain.reset()
        playbackStarted = false
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        audioFormat = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}
