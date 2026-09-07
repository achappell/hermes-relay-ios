import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionCoordinator {
    private let store: ConversationStore
    nonisolated private let input: any SpeechInput
    private let output: any AudioOutput
    nonisolated private let diagnostics: any AudioPlaybackDiagnostics
    private let recognitionFinishTimeoutNanoseconds: UInt64
    nonisolated private let captureStartGate = CaptureStartGate()

    private(set) var state: VoiceState = .idle
    private(set) var provisionalText = ""
    // The relay emits audio_start/audio_end per segment, so a drained audio
    // stream means "this paragraph ended", not "the answer ended". Only
    // turn completion ends the response.
    private var turnDidComplete = false
    // IOS-32 instrumentation: which audio segment of the current answer is
    // playing, so a boundary can be correlated with the playback clock.
    private var audioSegmentIndex = 0
    private(set) var speechTimings: [SpeechTiming] = []
    private(set) var playbackDuration: TimeInterval?
    private(set) var playbackPosition: TimeInterval?
    // While audio is still streaming, `playbackDuration` only covers the bytes
    // received so far. Pacing text against that partial value overshoots wildly,
    // so the duration clock stays unusable until the stream is complete.
    private(set) var isPlaybackDurationFinal = false

    private var finalText: String?
    private var captureTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var playbackFailed = false
    private var audioStreamActive = false
    private var audioFormat: AudioFormat?
    private var audioFileBuffer = Data()
    private var streamedAudioBytes = 0
    private var captureFailureMessage: String?
    private var playbackPositionTask: Task<Void, Never>?
    // Event handlers may outlive a cancelled response task, so every response
    // is allowed to mutate state only while its generation is current.
    private var responseGeneration: UInt64 = 0

    init(
        store: ConversationStore,
        input: any SpeechInput,
        output: any AudioOutput,
        diagnostics: any AudioPlaybackDiagnostics = NoopAudioPlaybackDiagnostics(),
        recognitionFinishTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.store = store
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        self.recognitionFinishTimeoutNanoseconds = recognitionFinishTimeoutNanoseconds
    }

    nonisolated func beginCapture() async {
        let canStart = await MainActor.run { [weak self] in
            guard let self else { return false }
            return self.captureTask == nil && self.responseTask == nil
        }
        guard canStart, let startRequest = await captureStartGate.begin(input: input) else { return }

        let result = await startRequest.task.value
        guard await captureStartGate.isCurrent(startRequest.id) else { return }
        await MainActor.run { [weak self] in
            self?.applyCaptureStart(result)
        }
        await captureStartGate.clear(id: startRequest.id)
    }

    func endCaptureAndSend() async {
        if let pendingStart = await captureStartGate.result(),
           await captureStartGate.isCurrent(pendingStart.id) {
            let result = pendingStart.result
            applyCaptureStart(result)
            await captureStartGate.clear(id: pendingStart.id)
        }
        guard let captureTask else { return }
        state = .transcribing
        requestInputFinish()
        await waitForRecognitionCompletion(captureTask)
        self.captureTask = nil

        if let captureFailureMessage {
            provisionalText = ""
            finalText = nil
            state = .failed(captureFailureMessage)
            self.captureFailureMessage = nil
            return
        }

        let text = (finalText ?? provisionalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        provisionalText = ""
        finalText = nil

        guard !text.isEmpty else {
            state = .idle
            return
        }

        playbackFailed = false
        resetSpeechTiming()
        responseGeneration &+= 1
        let generation = responseGeneration
        responseTask = Task { [weak self] in
            await self?.submitVoiceTurn(text, generation: generation)
        }
        await responseTask?.value
        responseTask = nil
    }

    private func requestInputFinish() {
        let input = self.input

        Task.detached(priority: .userInitiated) {
            await input.finish()
        }
    }

    private func applyCaptureStart(_ result: CaptureStartResult) {
        guard captureTask == nil, responseTask == nil else { return }
        if case .failed = state {
            state = .idle
        }
        captureFailureMessage = nil

        switch result {
        case .started(let stream):
            provisionalText = ""
            finalText = nil
            state = .listening
            captureTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.consumeRecognition(stream)
            }
        case .failed(let failure):
            switch failure {
            case .permission(let authorization):
                state = .failed(permissionMessage(for: authorization))
            case .input(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    fileprivate nonisolated static func startInput(_ input: any SpeechInput) async -> CaptureStartResult {
        if Task.isCancelled {
            return .failed(.input(.cancelled))
        }

        var authorization = await input.authorization()
        if Task.isCancelled {
            return .failed(.input(.cancelled))
        }
        if authorization == .notDetermined {
            authorization = await input.requestAuthorization()
            if Task.isCancelled {
                return .failed(.input(.cancelled))
            }
        }
        guard authorization == .authorized else {
            return .failed(.permission(authorization))
        }

        do {
            let stream = try await input.start()
            if Task.isCancelled {
                await input.cancel()
                return .failed(.input(.cancelled))
            }
            return .started(stream)
        } catch let error as SpeechInputError {
            return .failed(.input(error))
        } catch {
            return .failed(.input(.captureFailed))
        }
    }

    private func waitForRecognitionCompletion(_ captureTask: Task<Void, Never>) async {
        let input = self.input
        let timeoutNanoseconds = recognitionFinishTimeoutNanoseconds

        let gate = CompletionGate()
        let completionTask = Task {
            await captureTask.value
            await gate.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resolve(false)
            } catch {
                // The recognition task completed first.
            }
        }

        let didComplete = await gate.wait()
        timeoutTask.cancel()
        if !didComplete {
            completionTask.cancel()
            captureTask.cancel()
            await input.cancel()
        }
    }

    func cancelCapture() async {
        if await captureStartGate.cancel() {
            await input.cancel()
            provisionalText = ""
            finalText = nil
            captureFailureMessage = nil
            state = .idle
            return
        }

        guard let captureTask else { return }
        await input.cancel()
        captureTask.cancel()
        await captureTask.value
        self.captureTask = nil
        provisionalText = ""
        finalText = nil
        captureFailureMessage = nil
        state = .idle
    }

    func stopPlayback() async {
        if responseTask != nil {
            _ = await interruptActiveTurn()
            return
        }

        await output.stop()
        resetSpeechTiming()
        switch state {
        case .speaking, .buffering:
            state = .interrupted
        default:
            break
        }
    }

    func interruptAndBeginCapture() async {
        guard responseTask != nil else { return }

        guard await interruptActiveTurn() else { return }
        await beginCapture()
    }

    @discardableResult
    func interruptActiveTurn() async -> Bool {
        guard let activeResponseTask = responseTask else { return false }

        state = .interrupted
        await output.stop()
        resetSpeechTiming()
        // The relay may already have sent turn_end while local audio is still
        // draining. In that small window there is no active server turn to
        // interrupt; stopping the local output is sufficient and must not
        // trigger the legacy reconnect fallback.
        let didReconnect = store.isSending
            ? await store.interruptActiveTurn()
            : true
        // Let the active response consume the server's interruption
        // confirmation (and close its stream) before invalidating its
        // generation. Cancelling first would make the confirmation look like
        // a late frame and leave the store waiting for a turn that is already
        // dead.
        responseGeneration &+= 1
        activeResponseTask.cancel()
        await activeResponseTask.value
        responseTask = nil
        audioStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        streamedAudioBytes = 0
        playbackFailed = false

        guard didReconnect else {
            state = .failed(store.transientError ?? "The Hermes relay could not be restored after interruption.")
            return false
        }

        return true
    }

    func sendDraft() async {
        guard captureTask == nil, responseTask == nil else { return }
        guard !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        playbackFailed = false
        resetSpeechTiming()
        responseGeneration &+= 1
        let generation = responseGeneration
        responseTask = Task { [weak self] in
            await self?.submitDraft(generation: generation)
        }
        await responseTask?.value
        responseTask = nil
    }

    /// Resend a turn the relay never confirmed. It goes through the same
    /// submission path as any other turn, because the event handler is what
    /// produces the spoken answer and the visible state — sending straight to
    /// the store would deliver a silent, invisible turn.
    func resendUnconfirmedTurn() async {
        guard captureTask == nil, responseTask == nil else { return }
        guard let text = store.unconfirmedTurnText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }

        playbackFailed = false
        resetSpeechTiming()
        responseGeneration &+= 1
        let generation = responseGeneration
        responseTask = Task { [weak self] in
            await self?.submitVoiceTurn(text, generation: generation)
        }
        await responseTask?.value
        responseTask = nil
    }

    private nonisolated func consumeRecognition(
        _ stream: AsyncThrowingStream<SpeechRecognitionUpdate, Error>
    ) async {
        do {
            for try await update in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.provisionalText = update.text
                    if update.isFinal {
                        self.finalText = update.text
                    }
                    if self.state == .listening {
                        self.state = .transcribing
                    }
                }
            }
        } catch let error as SpeechInputError {
            if error != .cancelled {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.captureTask = nil
                    self?.captureFailureMessage = message
                    self?.state = .failed(message)
                }
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { [weak self] in
                self?.captureTask = nil
                self?.captureFailureMessage = message
                self?.state = .failed(message)
            }
        }
    }

    private func submitVoiceTurn(_ text: String, generation: UInt64) async {
        guard generation == responseGeneration, !Task.isCancelled else { return }
        turnDidComplete = false
        audioSegmentIndex = 0
        state = .thinking
        let completed = await store.sendTurn(text: text) { [weak self] event in
            await self?.handle(event, generation: generation)
        }
        guard generation == responseGeneration, !Task.isCancelled else { return }
        if !completed, !isFailed, state != .interrupted {
            state = .failed(store.transientError ?? "The voice turn could not be completed.")
        } else if completed, !isFailed, state != .interrupted {
            await finishPlaybackAndEndResponse()
        }
    }

    private func handle(_ event: HermesEvent, generation: UInt64) async {
        guard generation == responseGeneration, !Task.isCancelled else { return }
        switch event {
        case .thinkingDelta, .status:
            if !playbackFailed {
                state = .thinking
            }
        case .audioStart(let format):
            guard !playbackFailed else { return }
            await diagnostics.record(
                .segmentBoundary(
                    index: audioSegmentIndex,
                    phase: .started,
                    playbackPositionMilliseconds: Self.milliseconds(playbackPosition)
                )
            )
            audioFileBuffer.removeAll(keepingCapacity: false)
            audioStreamActive = true
            audioFormat = format
            streamedAudioBytes = 0
            playbackDuration = nil
            isPlaybackDurationFinal = false
            startPlaybackPositionObservation(generation: generation)
            await diagnostics.record(.streamStarted(format: format))
            state = .buffering
            do {
                try await output.start(format: format)
            } catch {
                await handlePlaybackFailure()
            }
        case .audioChunk(let pcm):
            guard !playbackFailed else { return }
            streamedAudioBytes += pcm.count
            await diagnostics.record(.chunkReceived(bytes: pcm.count))
            do {
                let readiness = try await output.append(pcm)
                if readiness == .ready {
                    state = .speaking
                }
            } catch {
                await handlePlaybackFailure()
            }
        case .audioEnd:
            guard !playbackFailed else { return }
            await diagnostics.record(.streamEnded(bytes: streamedAudioBytes))
            await diagnostics.record(
                .segmentBoundary(
                    index: audioSegmentIndex,
                    phase: .ended,
                    playbackPositionMilliseconds: Self.milliseconds(playbackPosition)
                )
            )
            audioSegmentIndex += 1
            do {
                try await output.finish()
                audioStreamActive = false
                finalizePlaybackDuration()
                if turnDidComplete {
                    endResponse()
                }
            } catch {
                await handlePlaybackFailure()
            }
        case .audioFileStart:
            guard !playbackFailed else { return }
            audioFileBuffer.removeAll(keepingCapacity: true)
            state = .buffering
        case .audioFileChunk(let fileData):
            guard !playbackFailed else { return }
            audioFileBuffer.append(fileData)
        case .audioFileEnd:
            guard !playbackFailed else { return }
            do {
                let decoded = try WAVAudioDecoder().decode(audioFileBuffer)
                audioFileBuffer.removeAll(keepingCapacity: false)
                playbackDuration = Self.audioDuration(
                    byteCount: decoded.pcm.count,
                    format: decoded.format
                )
                isPlaybackDurationFinal = playbackDuration != nil
                try await output.start(format: decoded.format)
                let readiness = try await output.append(decoded.pcm)
                if readiness == .ready {
                    startPlaybackPositionObservation(generation: generation)
                    state = .speaking
                }
                try await output.finish()
                if turnDidComplete {
                    endResponse()
                }
            } catch {
                await handlePlaybackFailure()
            }
        case .turnComplete:
            turnDidComplete = true
            if !isFailed, !audioStreamActive {
                endResponse()
            }
        case .error(let message):
            state = .failed(message)
        case .audioAbort:
            await stopInterruptedPlayback()
        case .turnInterrupted:
            await stopInterruptedPlayback()
            state = .interrupted
        case .speechTiming(let timing):
            await diagnostics.record(
                .speechTimingReceived(
                    segmentIndex: audioSegmentIndex,
                    audioOffsetMilliseconds: Self.milliseconds(timing.audioOffset) ?? 0,
                    durationMilliseconds: Self.milliseconds(timing.duration) ?? 0,
                    wordCount: timing.words.count,
                    source: String(describing: timing.timingSource),
                    fallbackReason: timing.fallbackReason.map { String(describing: $0) }
                )
            )
            if let index = speechTimings.firstIndex(where: { $0.segmentID == timing.segmentID }) {
                speechTimings[index] = timing
            } else {
                speechTimings.append(timing)
            }
            speechTimings.sort { lhs, rhs in
                if lhs.audioOffset == rhs.audioOffset {
                    return lhs.segmentID < rhs.segmentID
                }
                return lhs.audioOffset < rhs.audioOffset
            }
        case .messageStart, .textDelta, .textReplace, .messageComplete, .unknown:
            break
        }
    }

    private func stopInterruptedPlayback() async {
        await output.stop()
        audioStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        streamedAudioBytes = 0
        playbackFailed = false
        resetSpeechTiming()
        state = .interrupted
    }

    private func submitDraft(generation: UInt64) async {
        guard generation == responseGeneration, !Task.isCancelled else { return }
        turnDidComplete = false
        audioSegmentIndex = 0
        state = .thinking
        let completed = await store.sendDraft { [weak self] event in
            await self?.handle(event, generation: generation)
        }
        guard generation == responseGeneration, !Task.isCancelled else { return }
        if !completed, !isFailed, state != .interrupted {
            state = .failed(store.transientError ?? "The text turn could not be completed.")
        } else if completed, !isFailed, state != .interrupted {
            await finishPlaybackAndEndResponse()
        }
    }

    /// The relay delivers audio far faster than it plays: a minute of speech
    /// can arrive in seconds. A closed event stream therefore means no more
    /// audio is *coming*, not that the answer has been *heard*. Drain what is
    /// already scheduled before going quiet — `finish()` returns once the
    /// buffers have actually played out.
    private func finishPlaybackAndEndResponse() async {
        if audioStreamActive {
            audioStreamActive = false
            do {
                try await output.finish()
                finalizePlaybackDuration()
            } catch {
                await handlePlaybackFailure()
                return
            }
        }
        endResponse()
    }

    private func handlePlaybackFailure() async {
        playbackFailed = true
        audioStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        stopPlaybackPositionObservation()
        await diagnostics.record(.playbackFailed)
        await output.stop()
        state = .failed("Audio playback failed. The response text is still available.")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func startPlaybackPositionObservation(generation: UInt64) {
        stopPlaybackPositionObservation()
        playbackPositionTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard self.responseGeneration == generation else { return }
                self.playbackPosition = await self.output.playbackPosition()

                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// The answer is finished: audio has drained and the relay has confirmed
    /// the turn. Only then does the clock stop and the HUD go quiet.
    private func endResponse() {
        guard !isFailed, state != .interrupted else { return }
        stopPlaybackPositionObservation()
        state = .idle
    }

    private func stopPlaybackPositionObservation() {
        playbackPositionTask?.cancel()
        playbackPositionTask = nil
        playbackPosition = nil
    }

    private static func milliseconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private func resetSpeechTiming() {
        speechTimings.removeAll(keepingCapacity: false)
        audioFormat = nil
        playbackDuration = nil
        isPlaybackDurationFinal = false
        stopPlaybackPositionObservation()
    }

    private func finalizePlaybackDuration() {
        playbackDuration = Self.audioDuration(
            byteCount: streamedAudioBytes,
            format: audioFormat
        )
        isPlaybackDurationFinal = playbackDuration != nil
    }

    private static func audioDuration(byteCount: Int, format: AudioFormat?) -> TimeInterval? {
        guard let format,
              format.sampleRate > 0,
              format.channels > 0,
              format.sampleWidth > 0 else {
            return nil
        }
        let bytesPerFrame = format.channels * format.sampleWidth
        guard bytesPerFrame > 0 else { return nil }
        return Double(byteCount / bytesPerFrame) / Double(format.sampleRate)
    }

    private func permissionMessage(for authorization: SpeechAuthorization) -> String {
        switch authorization {
        case .microphoneDenied:
            return "Microphone access is denied. Allow microphone and speech recognition access in Settings."
        case .speechDenied:
            return "Speech recognition access is denied. Allow speech recognition access in Settings."
        case .restricted:
            return "Speech recognition is restricted on this device. Check Screen Time or device management settings."
        case .notDetermined:
            return "Microphone and speech recognition access is required for voice turns."
        case .authorized:
            return ""
        }
    }
}

private enum CaptureStartFailure: Sendable {
    case permission(SpeechAuthorization)
    case input(SpeechInputError)
}

private enum CaptureStartResult: Sendable {
    case started(AsyncThrowingStream<SpeechRecognitionUpdate, Error>)
    case failed(CaptureStartFailure)
}

private struct CaptureStartRequest: Sendable {
    let id: UInt64
    let task: Task<CaptureStartResult, Never>
}

private actor CaptureStartGate {
    private var nextID: UInt64 = 0
    private var activeRequest: CaptureStartRequest?

    func begin(input: any SpeechInput) -> CaptureStartRequest? {
        guard activeRequest == nil else { return nil }
        nextID &+= 1
        let task = Task.detached(priority: .userInitiated) {
            await VoiceSessionCoordinator.startInput(input)
        }
        let request = CaptureStartRequest(id: nextID, task: task)
        activeRequest = request
        return request
    }

    func result() async -> (id: UInt64, result: CaptureStartResult)? {
        guard let activeRequest else { return nil }
        return (activeRequest.id, await activeRequest.task.value)
    }

    func isCurrent(_ id: UInt64) -> Bool {
        activeRequest?.id == id
    }

    func clear(id: UInt64) {
        guard activeRequest?.id == id else { return }
        activeRequest = nil
    }

    func cancel() -> Bool {
        guard let activeRequest else { return false }
        activeRequest.task.cancel()
        self.activeRequest = nil
        return true
    }
}

private actor CompletionGate {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}
