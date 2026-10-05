import Foundation
import Observation

/// Local voice preferences. Stored on this device only; content-free.
enum VoicePreferences {
    static let interruptByTalkingKey = "voice.interruptByTalking"

    /// "Interrupt Hermes by talking (headphones only)". Off by default: with
    /// it off, interrupting a reply is tap-only on every route (IOS-UX-F5).
    @MainActor
    static var interruptByTalking: Bool {
        get { UserDefaults.standard.bool(forKey: interruptByTalkingKey) }
        set { UserDefaults.standard.set(newValue, forKey: interruptByTalkingKey) }
    }
}

enum HandsFreeBargeInPolicy {
    static func shouldInterrupt(
        state: VoiceState,
        route: HandsFreeAudioRouteSafety,
        interruptByTalking: Bool
    ) -> Bool {
        guard state.isResponseActive else { return false }
        // Voice interruption is opt-in; without it only a tap interrupts.
        guard interruptByTalking else { return false }
        guard state.isOutputActive else { return true }
        return route == .echoSafe
    }
}

enum HandsFreeStatus: Equatable, Sendable {
    case disarmed
    case armed
    case listening
    case transcribing
    case blockedByAudioRoute
    case failed(VoiceFailure)

    var label: String {
        switch self {
        case .disarmed:
            return "Hands-free off"
        case .armed:
            return "Hands-free on"
        case .listening:
            return "Hands-free listening"
        case .transcribing:
            return "Hands-free transcribing"
        case .blockedByAudioRoute:
            return "Hands-free: headphones needed to interrupt"
        case .failed(let failure):
            return "Hands-free unavailable: \(failure.message)"
        }
    }

    var systemImage: String {
        switch self {
        case .disarmed:
            return "waveform"
        case .armed, .listening, .transcribing:
            return "waveform.and.mic"
        case .blockedByAudioRoute:
            return "headphones"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}

/// What in-flight voice work keeps the app alive in the background
/// (IOS-HOME-07). `.none` means the lifecycle tears down as before.
enum VoiceBackgroundRetention: Equatable, Sendable {
    case none
    /// A turn is submitted, streaming, or its audio is pending or playing.
    case reply
    /// Hands-free is armed or capture is live, started in the foreground.
    case voiceSession
}

extension VoiceBackgroundRetention {
    var journalName: String {
        switch self {
        case .none: "none"
        case .reply: "reply"
        case .voiceSession: "voiceSession"
        }
    }
}

extension AudioSessionEvent {
    var journalName: String {
        switch self {
        case .interruptionBegan: "interruptionBegan"
        case .interruptionEnded(let shouldResume): "interruptionEnded(shouldResume=\(shouldResume))"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .newDeviceAvailable: "newDeviceAvailable"
        }
    }
}

/// What paused reply output (IOS-HOME-07).
enum ReplyPauseReason: Equatable, Sendable {
    /// A phone call, Siri or another app took the audio session.
    case interruption
    /// The output route disappeared (headphones or AirPods removed).
    case routeLoss
    /// Lock-screen Pause.
    case user
}

@MainActor
@Observable
final class VoiceSessionCoordinator {
    private let store: ConversationStore
    nonisolated private let input: any SpeechInput
    nonisolated private let handsFreeInput: (any HandsFreeInput)?
    private let output: any AudioOutput
    nonisolated private let diagnostics: any AudioPlaybackDiagnostics
    nonisolated private let routeSafetyProvider: any HandsFreeAudioRouteSafetyProvider
    private let recognitionFinishTimeoutNanoseconds: UInt64
    private let handsFreeSilenceDurationNanoseconds: UInt64
    nonisolated private let captureStartGate = CaptureStartGate()

    private(set) var state: VoiceState = .idle
    private(set) var provisionalText = ""
    private(set) var isHandsFreeArmed = false
    private(set) var handsFreeStatus: HandsFreeStatus = .disarmed
    private(set) var isHandsFreeCaptureActive = false
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
    private var captureFinishTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var playbackFailed = false
    private var audioStreamActive = false
    private var audioFileStreamActive = false
    private var audioDeliveryStarted = false
    private var audioFormat: AudioFormat?
    private var audioFileBuffer = Data()
    private var streamedAudioBytes = 0
    private var captureFailureMessage: String?
    private var captureBinding: HermesTurnBinding?
    private var playbackPositionTask: Task<Void, Never>?
    private var handsFreeTask: Task<Void, Never>?
    private var handsFreeSilenceTask: Task<Void, Never>?
    /// A tapped recording sends itself after a pause in recognised speech
    /// (IOS-UX-F5), using the same endpoint as hands-free.
    private let interruptByTalking: @MainActor () -> Bool
    private var tappedPauseTask: Task<Void, Never>?
    private var tappedPauseGeneration = 0
    /// True while a tapped recording is being ended and sent. A tap and the
    /// pause timer can both ask to end the same recording; only the first
    /// may, or the second resets state in the middle of the reply.
    private var isEndingTappedCapture = false
    private var handsFreeCaptureGeneration: UInt64 = 0
    private var handsFreeFinalText: String?
    private var isFinishingHandsFreeInput = false
    // A response can remain in Speech.framework's recognition stream after
    // playback ends. A fresh activity event may establish the next turn on
    // any route; recognition-only wake after a response requires headphones.
    private var handsFreeWakeSuppressed = false
    // Event handlers may outlive a cancelled response task, so every response
    // is allowed to mutate state only while its generation is current.
    private var responseGeneration: UInt64 = 0

    // IOS-HOME-07 background voice work. Only the lifecycle coordinator moves
    // the coordinator in or out of the background.
    private let clock: any HomeMonotonicClock
    private let backgroundIdleTimeout: Duration
    private let audioSessionPolicy: any BackgroundAudioSessionPolicy
    private let nowPlaying: (any NowPlayingPresenting)?
    private let journal: DiagnosticsJournal
    private(set) var isBackgrounded = false
    /// Set when background work must end now (idle timeout, lock-screen Stop,
    /// an interruption that cannot resume). Retention then reports `.none`.
    private var backgroundWorkEnded = false
    /// Why `backgroundWorkEnded` was set; journaled when retention ends.
    @ObservationIgnored private var backgroundEndReason: String?
    private(set) var backgroundIdleTimeoutFired = false
    /// Why reply output is held. Each source resumes only its own pause.
    private(set) var replyPauseReason: ReplyPauseReason?
    var isReplyOutputPaused: Bool { replyPauseReason != nil }
    @ObservationIgnored private var backgroundIdleTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundIdleDeadlineArmed = false
    @ObservationIgnored private var onBackgroundRetentionEnded: (@MainActor () -> Void)?
    @ObservationIgnored private var audioSessionEventTask: Task<Void, Never>?
    /// One live retention observation at a time; re-armed only by its onChange.
    @ObservationIgnored private var retentionObservationArmed = false

    init(
        store: ConversationStore,
        input: any SpeechInput,
        output: any AudioOutput,
        diagnostics: any AudioPlaybackDiagnostics = NoopAudioPlaybackDiagnostics(),
        recognitionFinishTimeoutNanoseconds: UInt64 = 2_000_000_000,
        handsFreeInput: (any HandsFreeInput)? = nil,
        routeSafetyProvider: any HandsFreeAudioRouteSafetyProvider = SystemHandsFreeAudioRouteSafetyProvider(),
        handsFreeSilenceDurationNanoseconds: UInt64 = 1_500_000_000,
        interruptByTalking: @escaping @MainActor () -> Bool = { VoicePreferences.interruptByTalking },
        clock: any HomeMonotonicClock = ContinuousHomeMonotonicClock(),
        backgroundIdleTimeout: Duration = .seconds(60),
        audioSessionPolicy: any BackgroundAudioSessionPolicy = NoopBackgroundAudioSessionPolicy(),
        audioSessionEvents: any AudioSessionEventSource = SystemAudioSessionEventSource(),
        nowPlaying: (any NowPlayingPresenting)? = nil,
        journal: DiagnosticsJournal = .shared
    ) {
        self.interruptByTalking = interruptByTalking
        self.store = store
        self.input = input
        self.handsFreeInput = handsFreeInput
        self.output = output
        self.diagnostics = diagnostics
        self.routeSafetyProvider = routeSafetyProvider
        self.recognitionFinishTimeoutNanoseconds = recognitionFinishTimeoutNanoseconds
        self.handsFreeSilenceDurationNanoseconds = handsFreeSilenceDurationNanoseconds
        self.clock = clock
        self.backgroundIdleTimeout = backgroundIdleTimeout
        self.audioSessionPolicy = audioSessionPolicy
        self.nowPlaying = nowPlaying
        self.journal = journal
        let events = audioSessionEvents.events()
        audioSessionEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleAudioSessionEvent(event)
            }
        }
    }

    isolated deinit {
        audioSessionEventTask?.cancel()
        backgroundIdleTask?.cancel()
    }

    func toggleHandsFree() async {
        if isHandsFreeArmed {
            await disableHandsFree()
        } else {
            await armHandsFree()
        }
    }

    func disableHandsFree() async {
        let wasCapturing = isHandsFreeCaptureActive
        isHandsFreeArmed = false
        isHandsFreeCaptureActive = false
        handsFreeStatus = .disarmed
        handsFreeCaptureGeneration &+= 1
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        handsFreeFinalText = nil
        handsFreeWakeSuppressed = false
        isFinishingHandsFreeInput = true

        if let handsFreeInput {
            await handsFreeInput.cancel()
        }
        handsFreeTask?.cancel()
        if let handsFreeTask {
            await handsFreeTask.value
        }
        self.handsFreeTask = nil
        isFinishingHandsFreeInput = false

        if wasCapturing || state == .listening || state == .transcribing {
            provisionalText = ""
            finalText = nil
            if responseTask == nil {
                state = .idle
            }
        }
    }

    private func armHandsFree() async {
        // Decision 1: the microphone is never started from the background.
        guard !isHandsFreeArmed, !isBackgrounded else { return }
        guard let handsFreeInput else {
            setHandsFreeFailure(.message("Hands-free audio input is unavailable."))
            return
        }
        guard captureTask == nil else {
            setHandsFreeFailure(.message("Finish the current recording before enabling hands-free mode."))
            return
        }
        guard store.verifiedTurnBinding != nil else {
            setHandsFreeFailure(.message(store.turnUnavailableMessage))
            return
        }

        var authorization = await handsFreeInput.authorization()
        if authorization == .notDetermined {
            authorization = await handsFreeInput.requestAuthorization()
        }
        guard authorization == .authorized else {
            setHandsFreeFailure(.permission(authorization))
            return
        }

        do {
            let stream = try await handsFreeInput.start()
            isHandsFreeArmed = true
            handsFreeStatus = .armed
            isHandsFreeCaptureActive = false
            handsFreeFinalText = nil
            handsFreeWakeSuppressed = false
            startHandsFreeStream(stream)
        } catch let error as SpeechInputError {
            if error == .notAuthorized {
                let currentAuthorization = await handsFreeInput.authorization()
                if currentAuthorization != .authorized {
                    setHandsFreeFailure(.permission(currentAuthorization))
                    return
                }
            }
            setHandsFreeFailure(.message(error.localizedDescription))
        } catch {
            setHandsFreeFailure(.message(error.localizedDescription))
        }
    }

    private func setHandsFreeFailure(_ failure: VoiceFailure) {
        let wasCapturing = isHandsFreeCaptureActive
        isHandsFreeArmed = false
        isHandsFreeCaptureActive = false
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        handsFreeFinalText = nil
        provisionalText = ""
        handsFreeStatus = .failed(failure)
        if wasCapturing || (!state.isResponseActive && !state.isCaptureActive) {
            state = .failed(failure)
        }
    }

    private func startHandsFreeStream(
        _ stream: AsyncThrowingStream<HandsFreeInputEvent, Error>
    ) {
        guard isHandsFreeArmed else { return }
        handsFreeTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handleHandsFreeEvent(event)
                }
                await self?.handleHandsFreeStreamEnded()
            } catch {
                await self?.handleHandsFreeStreamError(error)
            }
        }
    }

    private func handleHandsFreeEvent(_ event: HandsFreeInputEvent) async {
        guard isHandsFreeArmed else { return }

        switch event {
        case .activity(let snapshot):
            guard !isFinishingHandsFreeInput else { return }
            guard snapshot.microphoneActivity != .unavailable else {
                setHandsFreeFailure(.message("The hands-free microphone is unavailable. Check the input route and microphone permission."))
                isFinishingHandsFreeInput = true
                if let handsFreeInput {
                    await handsFreeInput.cancel()
                }
                handsFreeTask?.cancel()
                handsFreeTask = nil
                isFinishingHandsFreeInput = false
                return
            }

            if snapshot.microphoneActivity == .speech {
                handsFreeSilenceTask?.cancel()
                handsFreeSilenceTask = nil
                // Activity is a fresh wake signal, including after a
                // response. The route check inside the helper protects
                // automatic barge-in while output is still active.
                _ = await startHandsFreeCaptureIfNeeded()
            } else {
                if snapshot.microphoneActivity == .silence,
                   isHandsFreeCaptureActive {
                    scheduleHandsFreeSilence()
                } else if snapshot.microphoneActivity == .backgroundNoise {
                    // Noise is evidence that the user may still be speaking;
                    // it must not begin or preserve a false endpoint clock.
                    handsFreeSilenceTask?.cancel()
                    handsFreeSilenceTask = nil
                }
                if handsFreeStatus == .blockedByAudioRoute,
                   !snapshot.playbackActive {
                    handsFreeStatus = .armed
                }
            }

        case .recognition(let update):
            guard !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Recognition is also evidence that the user is still speaking.
            // This matters when a queued or synthetic silence snapshot arrives
            // after capture has started; it must not be allowed to end the
            // phrase while Speech.framework is still producing text.
            handsFreeSilenceTask?.cancel()
            handsFreeSilenceTask = nil
            if !isHandsFreeCaptureActive {
                if !state.isResponseActive, handsFreeWakeSuppressed {
                    let route = await routeSafetyProvider.currentSafety()
                    guard route == .echoSafe else { return }
                }
            }
            guard await startHandsFreeCaptureIfNeeded() else { return }
            guard !state.isResponseActive else { return }
            provisionalText = update.text
            if update.isFinal {
                handsFreeFinalText = update.text
            }
        }
    }

    private func startHandsFreeCaptureIfNeeded() async -> Bool {
        guard isHandsFreeArmed else { return false }
        if state.isResponseActive {
            // With voice interruption off, speech during a reply is ignored
            // quietly: only a tap on the orb interrupts.
            guard interruptByTalking() else { return false }
            let route = state.isOutputActive
                ? await routeSafetyProvider.currentSafety()
                : .echoSafe
            guard isHandsFreeArmed else { return false }
            guard HandsFreeBargeInPolicy.shouldInterrupt(
                state: state,
                route: route,
                interruptByTalking: interruptByTalking()
            ) else {
                handsFreeStatus = .blockedByAudioRoute
                return false
            }
            guard await interruptActiveTurn() else { return false }
        }

        if !isHandsFreeCaptureActive {
            beginHandsFreeCapture()
        }
        if isHandsFreeCaptureActive {
            handsFreeWakeSuppressed = false
        }
        return isHandsFreeCaptureActive
    }

    private func beginHandsFreeCapture() {
        guard isHandsFreeArmed,
              !isHandsFreeCaptureActive,
              captureTask == nil,
              responseTask == nil,
              store.verifiedTurnBinding != nil else { return }

        handsFreeCaptureGeneration &+= 1
        handsFreeFinalText = nil
        provisionalText = ""
        isHandsFreeCaptureActive = true
        handsFreeStatus = .listening
        state = .listening
    }

    /// Restarts the pause clock on every recognised word. When no new words
    /// arrive for the endpoint duration, the recording ends and sends, as if
    /// the orb had been tapped. Nothing starts before the first word.
    private func scheduleTappedPause() {
        guard captureTask != nil, !isHandsFreeCaptureActive, !isEndingTappedCapture else { return }
        tappedPauseTask?.cancel()
        tappedPauseGeneration &+= 1
        let generation = tappedPauseGeneration
        let duration = handsFreeSilenceDurationNanoseconds
        tappedPauseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }
            guard let self,
                  self.tappedPauseGeneration == generation,
                  self.captureTask != nil,
                  self.state.isCaptureActive else { return }
            self.tappedPauseTask = nil
            await self.endCaptureAndSend()
        }
    }

    private func cancelTappedPause() {
        tappedPauseTask?.cancel()
        tappedPauseTask = nil
        tappedPauseGeneration &+= 1
    }

    private func scheduleHandsFreeSilence() {
        // Activity snapshots continue at the store's throttled cadence while
        // the microphone remains quiet. Keep one endpoint clock for that
        // quiet stretch; repeated non-speech snapshots must not postpone it.
        guard isHandsFreeCaptureActive, handsFreeSilenceTask == nil else { return }
        let generation = handsFreeCaptureGeneration
        let duration = handsFreeSilenceDurationNanoseconds
        handsFreeSilenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }
            guard let self,
                  self.isHandsFreeCaptureActive,
                  self.handsFreeCaptureGeneration == generation else { return }
            await self.finishHandsFreeCapture()
        }
    }

    private func finishHandsFreeCapture() async {
        guard isHandsFreeArmed, isHandsFreeCaptureActive else { return }
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        handsFreeStatus = .transcribing
        state = .transcribing

        await finishHandsFreeInputAndWait()
        isHandsFreeCaptureActive = false

        let text = (handsFreeFinalText ?? provisionalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        handsFreeFinalText = nil
        provisionalText = ""

        guard isHandsFreeArmed else {
            if case .failed(let failure) = handsFreeStatus {
                state = .failed(failure)
            } else {
                state = .idle
            }
            return
        }

        await restartHandsFreeStream()
        handsFreeStatus = .armed

        guard !text.isEmpty else {
            state = .idle
            return
        }
        guard let binding = store.verifiedTurnBinding else {
            setHandsFreeFailure(.message(store.turnUnavailableMessage))
            return
        }

        await startVoiceResponse(text: text, binding: binding)
    }

    private func finishHandsFreeInputAndWait() async {
        isFinishingHandsFreeInput = true
        if let handsFreeInput {
            await handsFreeInput.finish()
        }
        if let handsFreeTask {
            await handsFreeTask.value
        }
        self.handsFreeTask = nil
        isFinishingHandsFreeInput = false
    }

    private func restartHandsFreeStream() async {
        guard isHandsFreeArmed, let handsFreeInput else { return }
        do {
            let stream = try await handsFreeInput.start()
            startHandsFreeStream(stream)
        } catch let error as SpeechInputError {
            setHandsFreeFailure(.message(error.localizedDescription))
        } catch {
            setHandsFreeFailure(.message(error.localizedDescription))
        }
    }

    private func handleHandsFreeStreamEnded() async {
        guard isHandsFreeArmed, !isFinishingHandsFreeInput else { return }
        handsFreeTask = nil
        // Speech.framework can finalize a recognition window before the user
        // has stopped speaking. Recognition lifetime is not the hands-free
        // turn boundary; preserve the active phrase and let microphone
        // silence end the capture.
        if isHandsFreeCaptureActive {
            handsFreeFinalText = nil
        }
        await restartHandsFreeStream()
    }

    private func handleHandsFreeStreamError(_ error: Error) async {
        guard isHandsFreeArmed, !isFinishingHandsFreeInput else { return }
        handsFreeTask = nil
        if let error = error as? SpeechInputError,
           error == .cancelled || error == .noSpeech {
            if isHandsFreeCaptureActive {
                handsFreeStatus = .listening
                // A recognizer request can fail even though the activity
                // stream still has an open phrase. Keep the partial text and
                // replace only the recognizer; silence remains the endpoint.
                handsFreeFinalText = nil
                await restartHandsFreeStream()
                return
            }
            handsFreeStatus = .armed
            await restartHandsFreeStream()
            return
        }
        setHandsFreeFailure(.message(error.localizedDescription))
    }

    nonisolated func beginCapture() async {
        // A tapped capture is never started from the background (Decision 1).
        let blocked = await MainActor.run { [weak self] in
            guard let self else { return true }
            return self.isHandsFreeArmed || self.isBackgrounded
        }
        guard !blocked else { return }
        await waitForCaptureFinish()

        let binding: HermesTurnBinding? = await MainActor.run { [weak self] in
            guard let self else { return nil }
            guard self.captureTask == nil, self.responseTask == nil else { return nil }
            guard let binding = self.store.verifiedTurnBinding else {
                let message = self.store.turnUnavailableMessage
                self.store.transientError = message
                self.state = .failed(message)
                return nil
            }
            return binding
        }
        guard let binding, let startRequest = await captureStartGate.begin(input: input) else { return }
        await MainActor.run { [weak self] in
            self?.captureBinding = binding
        }

        let result = await startRequest.task.value
        guard await captureStartGate.isCurrent(startRequest.id) else { return }
        await MainActor.run { [weak self] in
            self?.applyCaptureStart(result)
        }
        await captureStartGate.clear(id: startRequest.id)
    }

    func endCaptureAndSend() async {
        cancelTappedPause()
        if isHandsFreeCaptureActive {
            await finishHandsFreeCapture()
            return
        }
        if let pendingStart = await captureStartGate.result(),
           await captureStartGate.isCurrent(pendingStart.id) {
            let result = pendingStart.result
            applyCaptureStart(result)
            await captureStartGate.clear(id: pendingStart.id)
        }
        guard let captureTask, !isEndingTappedCapture else { return }
        isEndingTappedCapture = true
        state = .transcribing
        requestInputFinish()
        await waitForRecognitionCompletion(captureTask)
        self.captureTask = nil
        // With the recording task cleared, a late second call finds nothing
        // to end; the guard only needs to cover the wait above.
        isEndingTappedCapture = false

        if let captureFailureMessage {
            provisionalText = ""
            finalText = nil
            captureBinding = nil
            state = .failed(captureFailureMessage)
            self.captureFailureMessage = nil
            return
        }

        let text = (finalText ?? provisionalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        provisionalText = ""
        finalText = nil

        guard !text.isEmpty else {
            captureBinding = nil
            state = .idle
            return
        }

        guard let binding = captureBinding,
              store.isCurrentTurnBinding(binding) else {
            captureBinding = nil
            let message = "The selected Hermes Profile changed. Start a new turn."
            store.transientError = message
            state = .failed(message)
            return
        }
        captureBinding = nil

        await startVoiceResponse(text: text, binding: binding)
    }

    private func startVoiceResponse(
        text: String,
        binding: HermesTurnBinding
    ) async {
        guard responseTask == nil, captureTask == nil else { return }
        if isHandsFreeArmed {
            handsFreeWakeSuppressed = true
            handsFreeFinalText = nil
            provisionalText = ""
        }
        playbackFailed = false
        clearReplyPause()
        audioDeliveryStarted = false
        audioFileStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        resetSpeechTiming()
        responseGeneration &+= 1
        let generation = responseGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.submitVoiceTurn(text, binding: binding, generation: generation)
        }
        responseTask = task
        await task.value
        if responseTask != nil {
            responseTask = nil
        }
    }

    private func requestInputFinish() {
        let input = self.input

        captureFinishTask = Task.detached(priority: .userInitiated) {
            await input.finish()
        }
    }

    private func waitForCaptureFinish() async {
        guard let captureFinishTask else { return }
        await captureFinishTask.value
        self.captureFinishTask = nil
    }

    private func applyCaptureStart(_ result: CaptureStartResult) {
        guard captureTask == nil, responseTask == nil else { return }
        if case .failed = state {
            state = .idle
        }
        captureFailureMessage = nil

        switch result {
        case .started(let stream):
            guard let binding = captureBinding,
                  store.isCurrentTurnBinding(binding) else {
                captureBinding = nil
                let message = "The selected Hermes Profile changed. Start a new turn."
                store.transientError = message
                state = .failed(message)
                Task { await input.cancel() }
                return
            }
            provisionalText = ""
            finalText = nil
            state = .listening
            captureTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.consumeRecognition(stream)
            }
        case .failed(let failure):
            switch failure {
            case .permission(let authorization):
                captureBinding = nil
                state = .failed(.permission(authorization))
            case .input(let error):
                captureBinding = nil
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
            if error == .notAuthorized {
                let currentAuthorization = await input.authorization()
                if currentAuthorization != .authorized {
                    return .failed(.permission(currentAuthorization))
                }
            }
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
        cancelTappedPause()
        if isHandsFreeCaptureActive {
            isHandsFreeCaptureActive = false
            handsFreeCaptureGeneration &+= 1
            handsFreeSilenceTask?.cancel()
            handsFreeSilenceTask = nil
            handsFreeFinalText = nil
            provisionalText = ""
            finalText = nil
            state = .idle
            handsFreeStatus = isHandsFreeArmed ? .armed : .disarmed
            await finishHandsFreeInputAndWait()
            await restartHandsFreeStream()
            return
        }
        if await captureStartGate.cancel() {
            await input.cancel()
            captureBinding = nil
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
        captureBinding = nil
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

    /// Lifecycle teardown is intentionally local. It cancels recognition and
    /// response work, stops native playback, and never sends an interrupt or
    /// reconnect while the surface is inactive.
    func stopForLifecycle() async {
        journal.record(
            "voice stopForLifecycle reply=\(responseTask != nil) hands_free=\(isHandsFreeArmed) backgrounded=\(isBackgrounded)"
        )
        // This teardown is the lifecycle's own; never re-notify it.
        onBackgroundRetentionEnded = nil
        responseGeneration &+= 1
        handsFreeCaptureGeneration &+= 1
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        captureFinishTask?.cancel()
        captureFinishTask = nil

        await input.cancel()
        await handsFreeInput?.cancel()
        handsFreeTask?.cancel()
        if let handsFreeTask { await handsFreeTask.value }
        self.handsFreeTask = nil

        _ = await captureStartGate.cancel()
        captureTask?.cancel()
        if let captureTask { await captureTask.value }
        self.captureTask = nil

        responseTask?.cancel()
        // Stopping playback releases a response still waiting for its audio
        // to drain, including a reply paused by an interruption or route loss.
        await output.stop()
        if let responseTask { await responseTask.value }
        self.responseTask = nil

        stopPlaybackPositionObservation()
        isHandsFreeArmed = false
        isHandsFreeCaptureActive = false
        handsFreeStatus = .disarmed
        isFinishingHandsFreeInput = false
        provisionalText = ""
        finalText = nil
        captureBinding = nil
        captureFailureMessage = nil
        handsFreeFinalText = nil
        audioStreamActive = false
        audioFileStreamActive = false
        audioDeliveryStarted = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        playbackFailed = false
        clearReplyPause()
        turnDidComplete = false
        resetSpeechTiming()
        state = .idle
        // Only now, with capture and playback stopped, release the
        // non-mixable session and the lock-screen card.
        await leaveBackground()
    }

    func interruptAndBeginCapture() async {
        guard responseTask != nil else { return }

        guard await interruptActiveTurn() else { return }
        await beginCapture()
    }

    @discardableResult
    func interruptActiveTurn() async -> Bool {
        guard let activeResponseTask = responseTask else { return false }

        let isHomeTurn = store.isHomeMode
        if !isHomeTurn {
            state = .interrupted
        }
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
        audioFileStreamActive = false
        audioDeliveryStarted = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        streamedAudioBytes = 0
        playbackFailed = false

        guard didReconnect else {
            state = .failed(store.transientError ?? "The Hermes relay could not be restored after interruption.")
            return false
        }

        if isHomeTurn {
            // Home only becomes Interrupted after the matching terminal event;
            // the store's interrupt call does not return before that gate.
            state = .interrupted
        }

        if isHandsFreeArmed {
            handsFreeWakeSuppressed = false
        }
        return true
    }

    func sendDraft() async {
        guard captureTask == nil, responseTask == nil else { return }
        guard !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        playbackFailed = false
        clearReplyPause()
        audioDeliveryStarted = false
        audioFileStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
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
        guard let binding = store.verifiedTurnBinding else {
            let message = store.turnUnavailableMessage
            store.transientError = message
            state = .failed(message)
            return
        }

        playbackFailed = false
        clearReplyPause()
        audioDeliveryStarted = false
        audioFileStreamActive = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        resetSpeechTiming()
        responseGeneration &+= 1
        let generation = responseGeneration
        responseTask = Task { [weak self] in
            await self?.submitVoiceTurn(text, binding: binding, generation: generation)
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
                    if !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.scheduleTappedPause()
                    }
                }
            }
        } catch let error as SpeechInputError {
            switch error {
            case .cancelled:
                return
            case .noSpeech:
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.captureTask = nil
                    self.captureBinding = nil
                    self.provisionalText = ""
                    self.finalText = nil
                    self.captureFailureMessage = nil
                    self.state = .idle
                }
            default:
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

    private func submitVoiceTurn(
        _ text: String,
        binding: HermesTurnBinding,
        generation: UInt64
    ) async {
        guard generation == responseGeneration, !Task.isCancelled else { return }
        turnDidComplete = false
        audioSegmentIndex = 0
        state = .thinking
        let completed = await store.sendTurn(text: text, expectedBinding: binding) { [weak self] event in
            await self?.handle(event, generation: generation)
        }
        guard generation == responseGeneration, !Task.isCancelled else { return }
        if !completed, !isFailed, state != .interrupted {
            state = .failed(store.transientError ?? "The voice turn could not be completed.")
            updateNowPlayingPlaybackState()
        } else if completed, !isFailed, state != .interrupted {
            await finishPlaybackAndEndResponse(generation: generation)
        } else if completed, store.isHomeMode {
            // Control delivery is known even when native playback failed. Do
            // not leave an accepted Home binding permanently in-flight.
            await store.completeHomeTurnAfterAudio()
        }
    }

    private func handle(_ event: HermesEvent, generation: UInt64) async {
        guard generation == responseGeneration, !Task.isCancelled else { return }
        switch event {
        case .thinkingDelta, .status:
            guard !playbackFailed, !state.isTerminal, !state.isOutputActive else { return }
            state = .thinking
        case .audioStart(let format):
            guard !playbackFailed, !state.isTerminal else { return }
            await diagnostics.record(
                .segmentBoundary(
                    index: audioSegmentIndex,
                    phase: .started,
                    playbackPositionMilliseconds: Self.milliseconds(playbackPosition)
                )
            )
            audioFileBuffer.removeAll(keepingCapacity: false)
            audioFileStreamActive = false
            audioStreamActive = true
            audioFormat = format
            streamedAudioBytes = 0
            playbackDuration = nil
            isPlaybackDurationFinal = false
            startPlaybackPositionObservation(generation: generation)
            await diagnostics.record(.streamStarted(format: format))
            state = .buffering
            updateNowPlayingPlaybackState()
            do {
                try await output.start(format: format)
                guard isCurrentResponse(generation) else { return }
            } catch {
                await handlePlaybackFailure(generation: generation)
            }
        case .audioChunk(let pcm):
            guard !playbackFailed, !state.isTerminal, audioStreamActive else { return }
            streamedAudioBytes += pcm.count
            await diagnostics.record(.chunkReceived(bytes: pcm.count))
            do {
                let readiness = try await output.append(pcm)
                guard isCurrentResponse(generation) else { return }
                if !pcm.isEmpty {
                    audioDeliveryStarted = true
                }
                if readiness == .ready {
                    state = .speaking
                    updateNowPlayingPlaybackState()
                }
            } catch {
                await handlePlaybackFailure(generation: generation)
            }
        case .audioEnd:
            guard !playbackFailed, !state.isTerminal, audioStreamActive else { return }
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
                guard isCurrentResponse(generation) else { return }
                audioStreamActive = false
                finalizePlaybackDuration()
                if turnDidComplete {
                    if audioDeliveryStarted {
                        endResponse()
                    } else {
                        await handlePlaybackFailure(generation: generation)
                    }
                }
            } catch {
                await handlePlaybackFailure(generation: generation)
            }
        case .audioFileStart:
            guard !playbackFailed, !state.isTerminal else { return }
            audioFileBuffer.removeAll(keepingCapacity: true)
            audioFileStreamActive = true
            state = .buffering
            updateNowPlayingPlaybackState()
        case .audioFileChunk(let fileData):
            guard !playbackFailed, audioFileStreamActive else { return }
            audioFileBuffer.append(fileData)
        case .audioFileEnd:
            guard !playbackFailed, audioFileStreamActive else { return }
            do {
                let decoded = try WAVAudioDecoder().decode(audioFileBuffer)
                guard !decoded.pcm.isEmpty else {
                    await handlePlaybackFailure(generation: generation)
                    return
                }
                audioFileBuffer.removeAll(keepingCapacity: false)
                playbackDuration = Self.audioDuration(
                    byteCount: decoded.pcm.count,
                    format: decoded.format
                )
                isPlaybackDurationFinal = playbackDuration != nil
                try await output.start(format: decoded.format)
                guard isCurrentResponse(generation) else { return }
                let readiness = try await output.append(decoded.pcm)
                guard isCurrentResponse(generation) else { return }
                audioDeliveryStarted = true
                if readiness == .ready {
                    startPlaybackPositionObservation(generation: generation)
                    state = .speaking
                    updateNowPlayingPlaybackState()
                }
                try await output.finish()
                guard isCurrentResponse(generation) else { return }
                audioFileStreamActive = false
                if turnDidComplete {
                    endResponse()
                }
            } catch {
                await handlePlaybackFailure(generation: generation)
            }
        case .turnComplete:
            guard !playbackFailed, !state.isTerminal else { return }
            turnDidComplete = true
            if !isFailed, !audioStreamActive, !audioFileStreamActive {
                if audioDeliveryStarted {
                    endResponse()
                } else if !store.isHomeMode {
                    await handlePlaybackFailure(generation: generation)
                }
                // Home sends reply audio after the text turn completes; its
                // audio terminal or audio-start deadline settles playback.
            }
        case .error(let message):
            guard !playbackFailed, !state.isTerminal else { return }
            playbackFailed = true
            audioStreamActive = false
            audioFileStreamActive = false
            audioDeliveryStarted = false
            audioFileBuffer.removeAll(keepingCapacity: false)
            stopPlaybackPositionObservation()
            await output.stop()
            guard isCurrentResponse(generation, allowingPlaybackFailure: true) else { return }
            state = .failed(message)
            updateNowPlayingPlaybackState()
        case .audioAbort(_, let reason):
            guard !state.isTerminal else { return }
            if store.isHomeMode, Self.isHomeAudioFailure(reason) {
                await handlePlaybackFailure(generation: generation)
            } else {
                await stopInterruptedPlayback(generation: generation)
            }
        case .turnInterrupted:
            guard !state.isTerminal else { return }
            await stopInterruptedPlayback(generation: generation)
            guard generation == responseGeneration, !Task.isCancelled else { return }
            state = .interrupted
            updateNowPlayingPlaybackState()
        case .speechTiming(let timing):
            guard !state.isTerminal else { return }
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
            guard isCurrentResponse(generation) else { return }
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
        case .messageComplete(_, _, let failureReason):
            guard !state.isTerminal else { return }
            let reason = failureReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { return }
            playbackFailed = true
            audioStreamActive = false
            audioFileStreamActive = false
            audioDeliveryStarted = false
            audioFileBuffer.removeAll(keepingCapacity: false)
            stopPlaybackPositionObservation()
            await output.stop()
            guard isCurrentResponse(generation, allowingPlaybackFailure: true) else { return }
            state = .failed(reason)
            updateNowPlayingPlaybackState()
        case .messageStart, .textDelta, .textReplace, .unknown:
            break
        }
    }

    private func stopInterruptedPlayback(generation: UInt64) async {
        await output.stop()
        guard generation == responseGeneration, !Task.isCancelled else { return }
        audioStreamActive = false
        audioFileStreamActive = false
        audioDeliveryStarted = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        streamedAudioBytes = 0
        playbackFailed = false
        resetSpeechTiming()
        state = .interrupted
        updateNowPlayingPlaybackState()
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
            updateNowPlayingPlaybackState()
            audioFileBuffer.removeAll(keepingCapacity: false)
        } else if completed, !isFailed, state != .interrupted {
            await finishPlaybackAndEndResponse(generation: generation)
        } else if completed, store.isHomeMode {
            await store.completeHomeTurnAfterAudio()
        }
    }

    /// The relay delivers audio far faster than it plays: a minute of speech
    /// can arrive in seconds. A closed event stream therefore means no more
    /// audio is *coming*, not that the answer has been *heard*. Drain what is
    /// already scheduled before going quiet — `finish()` returns once the
    /// buffers have actually played out.
    private func finishPlaybackAndEndResponse(generation: UInt64) async {
        await playRemainingAudioAndEndResponse(generation: generation)
        // Home control delivery is already known here. Every exit, including
        // a playback failure, must release the accepted binding or the next
        // turn is refused locally.
        if store.isHomeMode, generation == responseGeneration {
            await store.completeHomeTurnAfterAudio()
        }
    }

    private func playRemainingAudioAndEndResponse(generation: UInt64) async {
        if audioStreamActive {
            audioStreamActive = false
            do {
                try await output.finish()
                guard isCurrentResponse(generation) else { return }
                finalizePlaybackDuration()
            } catch {
                await handlePlaybackFailure(generation: generation)
                return
            }
        }
        if audioFileStreamActive {
            await handlePlaybackFailure(generation: generation)
            return
        }
        guard isCurrentResponse(generation) else { return }
        guard audioDeliveryStarted else {
            await handlePlaybackFailure(generation: generation)
            return
        }
        endResponse()
    }

    private func handlePlaybackFailure(generation: UInt64) async {
        guard generation == responseGeneration,
              !Task.isCancelled,
              !state.isTerminal else { return }
        playbackFailed = true
        audioStreamActive = false
        audioFileStreamActive = false
        audioDeliveryStarted = false
        audioFileBuffer.removeAll(keepingCapacity: false)
        stopPlaybackPositionObservation()
        await diagnostics.record(.playbackFailed)
        await output.stop()
        guard isCurrentResponse(generation, allowingPlaybackFailure: true) else { return }
        state = .failed("Audio playback failed. The response text is still available.")
        updateNowPlayingPlaybackState()
        store.settleActiveAssistantPresentation()
    }

    private static func isHomeAudioFailure(_ reason: String) -> Bool {
        switch reason {
        case "fallback", "unavailable", "invalid", "invalid Home PCM audio":
            return true
        default:
            return false
        }
    }

    private func isCurrentResponse(
        _ generation: UInt64,
        allowingPlaybackFailure: Bool = false
    ) -> Bool {
        guard generation == responseGeneration,
              !Task.isCancelled,
              !state.isTerminal else { return false }
        return allowingPlaybackFailure || !playbackFailed
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
    /// the turn. Only then does the clock stop and the HUD settle on Complete.
    private func endResponse() {
        guard !isFailed, state != .interrupted else { return }
        stopPlaybackPositionObservation()
        state = .complete
        updateNowPlayingPlaybackState()
        store.settleActiveAssistantPresentation()
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

}

// MARK: - IOS-HOME-07 background voice work

extension VoiceSessionCoordinator {
    /// The single predicate the lifecycle coordinator asks before teardown.
    var backgroundRetention: VoiceBackgroundRetention {
        if isBackgrounded, backgroundWorkEnded { return .none }
        if responseTask != nil { return .reply }
        if isHandsFreeArmed || isHandsFreeCaptureActive || captureTask != nil {
            return .voiceSession
        }
        return .none
    }

    /// Keeps in-flight voice work running after the scene leaves the
    /// foreground. Returns false when nothing is in flight; the caller then
    /// tears down as before. `onRetentionEnded` fires once, when the work
    /// ends or the idle timeout fires, so the caller can run its teardown.
    func enterBackground(onRetentionEnded: @escaping @MainActor () -> Void) async -> Bool {
        let retention = backgroundRetention
        guard retention != .none else { return false }
        isBackgrounded = true
        backgroundWorkEnded = false
        backgroundIdleTimeoutFired = false
        backgroundEndReason = nil
        onBackgroundRetentionEnded = onRetentionEnded
        journal.record("voice background enter retention=\(retention.journalName)")
        await audioSessionPolicy.setBackgroundVoiceActive(true)
        // A hands-free session with no reply output is not "playing".
        nowPlaying?.show(title: nowPlayingTitle, isPlaying: isReplyOutputPlaying) { [weak self] command in
            Task { await self?.handleNowPlayingCommand(command) }
        }
        evaluateBackgroundRetention()
        return true
    }

    /// The scene is active again with the transport still live. A reply held
    /// by lock-screen Pause or an interruption has no foreground control, so
    /// it resumes; a route-loss pause waits for the route to come back.
    func exitBackground() async {
        journal.record("voice background exit")
        if replyPauseReason == .user || replyPauseReason == .interruption {
            await resumeReplyOutput()
        }
        await leaveBackground()
    }

    func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
        journal.record(
            "voice audio session event \(event.journalName) reply=\(responseTask != nil) backgrounded=\(isBackgrounded)"
        )
        switch event {
        case .interruptionBegan:
            // Decision 5: an interruption ends the mic session outright.
            if isHandsFreeArmed {
                await disableHandsFree()
            }
            if captureTask != nil || state.isCaptureActive {
                await cancelCapture()
            }
            if responseTask != nil {
                await pauseReplyOutput(.interruption)
            }
        case .interruptionEnded(let shouldResume):
            // Only an interruption pause belongs to this event.
            guard replyPauseReason == .interruption else { return }
            if shouldResume,
               responseTask != nil,
               store.hasLiveTransport,
               !backgroundIdleTimeoutFired {
                await resumeReplyOutput()
            } else if isBackgrounded {
                endBackgroundWork(reason: "interruption")
            } else {
                await stopPlayback()
            }
        case .oldDeviceUnavailable:
            // Never move a reply to the speaker mid-sentence.
            if responseTask != nil {
                await pauseReplyOutput(.routeLoss)
            }
        case .newDeviceAvailable:
            if replyPauseReason == .routeLoss {
                await resumeReplyOutput(allowingRouteLoss: true)
            }
        }
    }

    func handleNowPlayingCommand(_ command: NowPlayingCommand) async {
        switch command {
        case .pause:
            await pauseReplyOutput(.user)
        case .play:
            await resumeReplyOutput()
        case .togglePlayPause:
            if isReplyOutputPaused {
                await resumeReplyOutput()
            } else {
                await pauseReplyOutput(.user)
            }
        case .stop:
            endBackgroundWork(reason: "nowPlayingStop")
        }
    }

    private var isReplyOutputPlaying: Bool {
        state == .speaking && !isReplyOutputPaused
    }

    private func updateNowPlayingPlaybackState() {
        nowPlaying?.update(isPlaying: isReplyOutputPlaying)
    }

    private func pauseReplyOutput(_ reason: ReplyPauseReason) async {
        guard responseTask != nil, !isReplyOutputPaused else { return }
        replyPauseReason = reason
        await output.pause()
        updateNowPlayingPlaybackState()
    }

    private func resumeReplyOutput(allowingRouteLoss: Bool = false) async {
        guard responseTask != nil, isReplyOutputPaused else { return }
        guard allowingRouteLoss || replyPauseReason != .routeLoss else { return }
        replyPauseReason = nil
        await output.resume()
        updateNowPlayingPlaybackState()
    }

    /// Drops any held pause when a reply ends or a new one starts. The
    /// platform output keeps a pause across streams, so release it too.
    func clearReplyPause() {
        guard replyPauseReason != nil else { return }
        replyPauseReason = nil
        let output = self.output
        Task { await output.resume() }
    }

    private func endBackgroundWork(reason: String) {
        guard isBackgrounded else { return }
        backgroundWorkEnded = true
        backgroundEndReason = reason
        evaluateBackgroundRetention()
    }

    private func leaveBackground() async {
        isBackgrounded = false
        backgroundWorkEnded = false
        backgroundIdleTimeoutFired = false
        onBackgroundRetentionEnded = nil
        cancelBackgroundIdleTimeout()
        nowPlaying?.clear()
        await audioSessionPolicy.setBackgroundVoiceActive(false)
    }

    /// Re-reads retention whenever an input it depends on changes. Ending
    /// retention notifies the lifecycle owner; an armed hands-free session
    /// with nothing in flight runs the background idle timeout (Decision 2).
    private func evaluateBackgroundRetention() {
        guard isBackgrounded else { return }
        let retention = backgroundRetention
        guard retention != .none else {
            cancelBackgroundIdleTimeout()
            let callback = onBackgroundRetentionEnded
            onBackgroundRetentionEnded = nil
            if callback != nil {
                journal.record(
                    "voice background retention ended reason=\(backgroundEndReason ?? "workFinished")"
                )
            }
            callback?()
            return
        }

        // Decision 2: an armed hands-free session with nothing in flight, or
        // a reply held paused, ends after the background idle timeout.
        let isIdle = (retention == .voiceSession
            && captureTask == nil
            && !isHandsFreeCaptureActive)
            || (retention == .reply && isReplyOutputPaused)
        if isIdle {
            if !backgroundIdleDeadlineArmed {
                armBackgroundIdleTimeout()
            }
        } else {
            cancelBackgroundIdleTimeout()
        }

        guard !retentionObservationArmed else { return }
        retentionObservationArmed = true
        withObservationTracking {
            _ = self.isBackgrounded
            _ = self.backgroundWorkEnded
            _ = self.responseTask
            _ = self.captureTask
            _ = self.isHandsFreeArmed
            _ = self.isHandsFreeCaptureActive
            _ = self.replyPauseReason
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.retentionObservationArmed = false
                self.evaluateBackgroundRetention()
            }
        }
    }

    private func armBackgroundIdleTimeout() {
        cancelBackgroundIdleTimeout()
        backgroundIdleDeadlineArmed = true
        let clock = self.clock
        let deadline = clock.now().advanced(by: backgroundIdleTimeout)
        backgroundIdleTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.isBackgrounded,
                  self.backgroundIdleDeadlineArmed else { return }
            self.backgroundIdleDeadlineArmed = false
            self.backgroundIdleTask = nil
            self.backgroundIdleTimeoutFired = true
            self.endBackgroundWork(reason: "idleTimeout")
        }
    }

    private func cancelBackgroundIdleTimeout() {
        backgroundIdleDeadlineArmed = false
        backgroundIdleTask?.cancel()
        backgroundIdleTask = nil
    }

    private var nowPlayingTitle: String {
        let conversationTitle = store.homeSession?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationTitle, !conversationTitle.isEmpty else {
            return "Hermes conversation"
        }
        return conversationTitle.count > 60
            ? String(conversationTitle.prefix(60)) + "…"
            : conversationTitle
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
