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

    private var finalText: String?
    private var captureTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var playbackFailed = false
    private var audioFileBuffer = Data()
    private var streamedAudioBytes = 0
    private var captureFailureMessage: String?

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
        responseTask = Task { [weak self] in
            await self?.submitVoiceTurn(text)
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
        await output.stop()
        switch state {
        case .speaking, .buffering:
            state = .interrupted
        default:
            break
        }
    }

    func sendDraft() async {
        guard captureTask == nil, responseTask == nil else { return }
        guard !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        playbackFailed = false
        responseTask = Task { [weak self] in
            await self?.submitDraft()
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

    private func submitVoiceTurn(_ text: String) async {
        state = .thinking
        let completed = await store.sendTurn(text: text) { [weak self] event in
            await self?.handle(event)
        }
        if !completed, !isFailed {
            state = .failed(store.transientError ?? "The voice turn could not be completed.")
        } else if completed, !isFailed, state != .interrupted {
            state = .idle
        }
    }

    private func handle(_ event: HermesEvent) async {
        switch event {
        case .thinkingDelta, .status:
            if !playbackFailed {
                state = .thinking
            }
        case .audioStart(let format):
            guard !playbackFailed else { return }
            audioFileBuffer.removeAll(keepingCapacity: false)
            streamedAudioBytes = 0
            await diagnostics.record(.streamStarted(format: format))
            state = .buffering
            do {
                try await output.start(format: format)
            } catch {
                await handlePlaybackFailure()
            }
            if !playbackFailed {
                state = .speaking
            }
        case .audioChunk(let pcm):
            guard !playbackFailed else { return }
            streamedAudioBytes += pcm.count
            await diagnostics.record(.chunkReceived(bytes: pcm.count))
            do {
                try await output.append(pcm)
                state = .speaking
            } catch {
                await handlePlaybackFailure()
            }
        case .audioEnd:
            guard !playbackFailed else { return }
            await diagnostics.record(.streamEnded(bytes: streamedAudioBytes))
            do {
                try await output.finish()
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
                try await output.start(format: decoded.format)
                try await output.append(decoded.pcm)
                try await output.finish()
                state = .speaking
            } catch {
                await handlePlaybackFailure()
            }
        case .turnComplete:
            state = isFailed ? state : .idle
        case .error(let message):
            state = .failed(message)
        case .messageStart, .textDelta, .textReplace, .messageComplete, .unknown:
            break
        }
    }

    private func submitDraft() async {
        state = .thinking
        let completed = await store.sendDraft { [weak self] event in
            await self?.handle(event)
        }
        if !completed, !isFailed {
            state = .failed(store.transientError ?? "The text turn could not be completed.")
        } else if completed, !isFailed, state != .interrupted {
            state = .idle
        }
    }

    private func handlePlaybackFailure() async {
        playbackFailed = true
        audioFileBuffer.removeAll(keepingCapacity: false)
        await diagnostics.record(.playbackFailed)
        await output.stop()
        state = .failed("Audio playback failed. The response text is still available.")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
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
