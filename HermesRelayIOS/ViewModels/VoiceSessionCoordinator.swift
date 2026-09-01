import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionCoordinator {
    private let store: ConversationStore
    nonisolated private let input: any SpeechInput
    private let output: any AudioOutput
    private let recognitionFinishTimeoutNanoseconds: UInt64
    nonisolated private let captureStartGate = CaptureStartGate()

    private(set) var state: VoiceState = .idle
    private(set) var provisionalText = ""

    private var finalText: String?
    private var captureTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var playbackFailed = false
    private var audioFileBuffer = Data()

    init(
        store: ConversationStore,
        input: any SpeechInput,
        output: any AudioOutput,
        recognitionFinishTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.store = store
        self.input = input
        self.output = output
        self.recognitionFinishTimeoutNanoseconds = recognitionFinishTimeoutNanoseconds
    }

    nonisolated func beginCapture() async {
        let canStart = await MainActor.run { [weak self] in
            guard let self else { return false }
            return self.captureTask == nil && self.responseTask == nil
        }
        guard canStart, let startTask = await captureStartGate.begin(input: input) else { return }

        let result = await startTask.value
        await MainActor.run { [weak self] in
            self?.applyCaptureStart(result)
        }
        await captureStartGate.clear()
    }

    func endCaptureAndSend() async {
        if let result = await captureStartGate.result() {
            applyCaptureStart(result)
        }
        guard let captureTask else { return }
        state = .transcribing
        requestInputFinish()
        await waitForRecognitionCompletion(captureTask)
        self.captureTask = nil

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
        var authorization = await input.authorization()
        if authorization == .notDetermined {
            authorization = await input.requestAuthorization()
        }
        guard authorization == .authorized else {
            return .failed(.permission(authorization))
        }

        do {
            return .started(try await input.start())
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
            Task {
                await input.cancel()
            }
        }
    }

    func cancelCapture() async {
        guard let captureTask else { return }
        await input.cancel()
        captureTask.cancel()
        await captureTask.value
        self.captureTask = nil
        provisionalText = ""
        finalText = nil
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
                    self?.state = .failed(message)
                }
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { [weak self] in
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
            do {
                try await output.append(pcm)
                state = .speaking
            } catch {
                await handlePlaybackFailure()
            }
        case .audioEnd:
            guard !playbackFailed else { return }
            await output.finish()
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
                await output.finish()
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
        await output.stop()
        state = .failed("Audio playback failed. The response text is still available.")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func permissionMessage(for authorization: SpeechAuthorization) -> String {
        switch authorization {
        case .denied:
            return "Microphone access is denied. Allow microphone and speech recognition access in Settings."
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

private actor CaptureStartGate {
    private var startTask: Task<CaptureStartResult, Never>?

    func begin(input: any SpeechInput) -> Task<CaptureStartResult, Never>? {
        guard startTask == nil else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            await VoiceSessionCoordinator.startInput(input)
        }
        startTask = task
        return task
    }

    func result() async -> CaptureStartResult? {
        guard let startTask else { return nil }
        return await startTask.value
    }

    func clear() {
        startTask = nil
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
