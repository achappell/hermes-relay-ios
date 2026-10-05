import AVFAudio
import Foundation

/// How the output checks and restarts its engine. Tests replace it to
/// simulate a system-stopped engine without audio hardware.
struct AudioOutputEngineControl: Sendable {
    var isRunning: @Sendable (AVAudioEngine) -> Bool
    var start: @Sendable (AVAudioEngine) throws -> Void

    static let system = AudioOutputEngineControl(
        isRunning: { $0.isRunning },
        start: { try $0.start() }
    )
}

actor AppleAudioOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let diagnostics: any AudioPlaybackDiagnostics
    private let audioSessionCoordinator: AppleAudioSessionCoordinator
    private let playbackDrain = AudioPlaybackDrain()
    private var audioFormat: AVAudioFormat?
    private var pcmFrameAccumulator: PCMFrameAccumulator?
    private var scheduledAudioBytes = 0
    private var isAcceptingAudio = false
    private var playbackStarted = false
    /// Survives `stop()`/`start(format:)`: a pause requested before the next
    /// stream starts must hold it. Only `resume()` clears it.
    private var isPaused = false
    /// Set when a resume could not restart the engine; the pending drain
    /// then reports a playback failure instead of success.
    private var resumeFailed = false
    private let engineControl: AudioOutputEngineControl
    private let journal: DiagnosticsJournal
    private var configurationObserver: AudioEngineConfigurationObserver?
    /// Engine configuration changes are coalesced into one restart pass.
    private var isHandlingConfigurationChange = false
    private var configurationChangeRecheck = false
    private static let maximumConfigurationPasses = 3

    init(
        diagnostics: any AudioPlaybackDiagnostics = NoopAudioPlaybackDiagnostics(),
        audioSessionCoordinator: AppleAudioSessionCoordinator = AppleAudioSessionCoordinator(),
        engineControl: AudioOutputEngineControl = .system,
        journal: DiagnosticsJournal = .shared
    ) {
        self.diagnostics = diagnostics
        self.audioSessionCoordinator = audioSessionCoordinator
        self.engineControl = engineControl
        self.journal = journal
        engine.attach(playerNode)
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        await stopResources()
        resumeFailed = false

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw AudioOutputError.unsupportedFormat
        }

        do {
            try await audioSessionCoordinator.activateOutput()

            engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
            engine.prepare()
            try engine.start()
            audioFormat = avFormat
            pcmFrameAccumulator = PCMFrameAccumulator(
                bytesPerFrame: format.channels * format.sampleWidth
            )
            isAcceptingAudio = true
            installConfigurationObserver()
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
        if resumeFailed {
            resumeFailed = false
            throw AudioOutputError.outputFailed
        }
        if scheduledAudioBytes > 0 {
            await diagnostics.record(.playbackCompleted(bytes: scheduledAudioBytes))
        }
    }

    func stop() async {
        await stopResources()
    }

    func pause() async {
        guard !isPaused else { return }
        isPaused = true
        if playbackStarted {
            playerNode.pause()
        }
    }

    /// After an interruption the system has stopped the engine; restart it
    /// on the reactivated session before the player continues.
    func resume() async {
        guard isPaused else { return }
        isPaused = false
        guard audioFormat != nil else { return }
        try? await audioSessionCoordinator.reactivateOutput()
        if !engine.isRunning {
            try? engine.start()
        }
        // Playing a node on a stopped engine raises an exception; report a
        // playback failure through the pending drain instead.
        guard engine.isRunning else {
            resumeFailed = true
            await stopResources()
            return
        }
        if playbackStarted {
            playerNode.play()
        } else if scheduledAudioBytes > 0 {
            startPlaybackIfNeeded()
        }
    }

    /// iOS stops the engine when the session's I/O is reconfigured. Without a
    /// restart, scheduled buffers never play and `finish()` waits forever.
    ///
    /// Notifications can arrive in bursts, and a restart that re-applied the
    /// session category used to post the next one (the 2026-10-05 device runs
    /// restarted two to three times in a row). Concurrent notifications are
    /// therefore coalesced into one restart, and the restart only re-activates
    /// the session: it never sets the category again.
    func handleEngineConfigurationChange() async {
        if isHandlingConfigurationChange {
            configurationChangeRecheck = true
            return
        }
        isHandlingConfigurationChange = true
        defer { isHandlingConfigurationChange = false }
        var passes = 0
        repeat {
            configurationChangeRecheck = false
            await restartEngineIfStopped()
            passes += 1
        } while configurationChangeRecheck && passes < Self.maximumConfigurationPasses
    }

    private func restartEngineIfStopped() async {
        guard audioFormat != nil, !isPaused, isAcceptingAudio || playbackStarted else {
            return
        }
        guard !engineControl.isRunning(engine) else { return }
        try? await audioSessionCoordinator.reactivateOutput()
        do {
            try engineControl.start(engine)
        } catch {
            journal.record("audio output engine stopped restart=failed")
            resumeFailed = true
            await stopResources()
            return
        }
        journal.record("audio output engine stopped restart=ok")
        if playbackStarted {
            playerNode.play()
        } else if scheduledAudioBytes > 0 {
            startPlaybackIfNeeded()
        }
    }

    private func installConfigurationObserver() {
        guard configurationObserver == nil else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, journal] _ in
            journal.record("audio output engine configuration change notification")
            Task {
                await self?.handleEngineConfigurationChange()
            }
        }
        configurationObserver = AudioEngineConfigurationObserver(observer)
    }

    func playbackPosition() async -> TimeInterval? {
        guard playbackStarted,
              let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0,
              playerTime.sampleTime >= 0 else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
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
        guard !playbackStarted, !isPaused else { return }
        playerNode.play()
        playbackStarted = true
    }

    private func stopResources() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver.token)
            self.configurationObserver = nil
        }
        isAcceptingAudio = false
        pcmFrameAccumulator = nil
        scheduledAudioBytes = 0
        await playbackDrain.reset()
        playbackStarted = false
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        audioFormat = nil

        await audioSessionCoordinator.deactivateOutput()
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver.token)
        }
    }
}
