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

/// Start-of-stream playback cushion. Home streams speech at about real time
/// and the player used to start on the first scheduled buffer, so any late
/// chunk (for example while the scene changes and the main actor is busy)
/// starved the player and was heard as stutter. Playback now starts once
/// `lead` seconds of audio are scheduled, when the stream ends first, or when
/// `maximumHold` has passed since the first buffer, so a short or stalled
/// reply still starts promptly. A real-time stream keeps roughly `lead`
/// seconds of audio queued ahead of the renderer from then on.
struct AudioPlaybackCushion: Sendable, Equatable {
    var lead: TimeInterval
    var maximumHold: Duration

    /// About 300 ms of added start latency, never more than 500 ms.
    static let standard = AudioPlaybackCushion(lead: 0.3, maximumHold: .milliseconds(500))
    /// Start on the first buffer, as before the cushion existed.
    static let none = AudioPlaybackCushion(lead: 0, maximumHold: .zero)
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
    /// Bytes of scheduled audio the renderer has finished (`.dataPlayedBack`).
    /// The queued lead is scheduled minus completed. The node's own timeline
    /// keeps running through an underrun, so position-based lead reads zero
    /// for as long as the stream has been silent in total.
    private var completedAudioBytes = 0
    private var streamGeneration = 0
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
    private let cushion: AudioPlaybackCushion
    private var cushionTimer: Task<Void, Never>?
    private var cushionGeneration = 0

    init(
        diagnostics: any AudioPlaybackDiagnostics = NoopAudioPlaybackDiagnostics(),
        audioSessionCoordinator: AppleAudioSessionCoordinator = AppleAudioSessionCoordinator(),
        engineControl: AudioOutputEngineControl = .system,
        journal: DiagnosticsJournal = .shared,
        cushion: AudioPlaybackCushion = .standard
    ) {
        self.diagnostics = diagnostics
        self.audioSessionCoordinator = audioSessionCoordinator
        self.engineControl = engineControl
        self.journal = journal
        self.cushion = cushion
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
            try await schedule(completePCM, format: audioFormat, bytesPerFrame: bytesPerFrame)
            // Audio held back by the cushion is not audibly playing yet.
            readiness = playbackStarted ? .ready : .buffering
            let firstBufferScheduled = scheduledAudioBytes == completePCM.count
            await diagnostics.record(.chunkScheduled(bytes: completePCM.count))
            if firstBufferScheduled {
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
        // A stream shorter than the cushion starts here, or the drain below
        // would wait for audio that was never played.
        startCushionedPlayback(reason: "finish")
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

    /// Whether the player node is playing (false while the cushion holds it).
    var hasStartedPlayback: Bool { playbackStarted }

    /// Seconds of scheduled audio the renderer has not reached yet.
    func playbackLead() async -> TimeInterval? {
        guard let audioFormat, audioFormat.sampleRate > 0 else { return nil }
        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, scheduledAudioBytes > 0 else { return nil }
        let queuedBytes = max(0, scheduledAudioBytes - completedAudioBytes)
        return Double(queuedBytes / bytesPerFrame) / audioFormat.sampleRate
    }

    private var scheduledSeconds: TimeInterval? {
        guard let audioFormat, audioFormat.sampleRate > 0 else { return nil }
        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, scheduledAudioBytes > 0 else { return nil }
        return Double(scheduledAudioBytes / bytesPerFrame) / audioFormat.sampleRate
    }

    private func bufferPlayed(bytes: Int, generation: Int) async {
        // A stopped stream's buffers complete after the reset; ignore them.
        if generation == streamGeneration {
            completedAudioBytes += bytes
        }
        await playbackDrain.bufferDidComplete()
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
        let generation = streamGeneration
        let byteCount = pcm.count
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task {
                await self?.bufferPlayed(bytes: byteCount, generation: generation)
            }
        }
        releaseCushionIfReady()
    }

    private func startPlaybackIfNeeded() {
        guard !playbackStarted, !isPaused else { return }
        playerNode.play()
        playbackStarted = true
    }

    private func releaseCushionIfReady() {
        guard !playbackStarted else { return }
        guard cushion.lead > 0 else {
            startPlaybackIfNeeded()
            return
        }
        if (scheduledSeconds ?? 0) >= cushion.lead {
            startCushionedPlayback(reason: "threshold")
        } else if cushionTimer == nil {
            armCushionTimer()
        }
    }

    private func armCushionTimer() {
        cushionGeneration += 1
        let generation = cushionGeneration
        let hold = cushion.maximumHold
        cushionTimer = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await self?.cushionTimerFired(generation: generation)
        }
    }

    private func cushionTimerFired(generation: Int) {
        guard generation == cushionGeneration else { return }
        startCushionedPlayback(reason: "cap")
    }

    /// Starts playback of everything scheduled so far. Paused output stays
    /// held; `resume()` starts it.
    private func startCushionedPlayback(reason: String) {
        guard !playbackStarted, !isPaused, scheduledAudioBytes > 0 else { return }
        cushionTimer?.cancel()
        cushionTimer = nil
        cushionGeneration += 1
        let leadMilliseconds = Int(((scheduledSeconds ?? 0) * 1000).rounded())
        startPlaybackIfNeeded()
        if cushion.lead > 0 {
            journal.record("audio output cushion started lead_ms=\(leadMilliseconds) reason=\(reason)")
        }
    }

    private func stopResources() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver.token)
            self.configurationObserver = nil
        }
        cushionTimer?.cancel()
        cushionTimer = nil
        cushionGeneration += 1
        isAcceptingAudio = false
        pcmFrameAccumulator = nil
        scheduledAudioBytes = 0
        completedAudioBytes = 0
        streamGeneration += 1
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
