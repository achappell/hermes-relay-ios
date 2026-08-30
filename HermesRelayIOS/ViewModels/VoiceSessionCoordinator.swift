import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionCoordinator {
    private let store: ConversationStore
    private let input: any SpeechInput
    private let output: any AudioOutput

    private(set) var state: VoiceState = .idle
    private(set) var provisionalText = ""

    private var finalText: String?
    private var captureTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var playbackFailed = false

    init(
        store: ConversationStore,
        input: any SpeechInput,
        output: any AudioOutput
    ) {
        self.store = store
        self.input = input
        self.output = output
    }

    func beginCapture() async {
        guard captureTask == nil, responseTask == nil else { return }
        if case .failed = state {
            state = .idle
        }

        var authorization = await input.authorization()
        if authorization == .notDetermined {
            authorization = await input.requestAuthorization()
        }
        guard authorization == .authorized else {
            state = .failed(permissionMessage(for: authorization))
            return
        }

        do {
            let stream = try await input.start()
            provisionalText = ""
            finalText = nil
            state = .listening
            captureTask = Task { [weak self] in
                await self?.consumeRecognition(stream)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func endCaptureAndSend() async {
        guard let captureTask else { return }
        state = .transcribing
        await input.finish()
        await captureTask.value
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

    private func consumeRecognition(
        _ stream: AsyncThrowingStream<SpeechRecognitionUpdate, Error>
    ) async {
        do {
            for try await update in stream {
                guard !Task.isCancelled else { return }
                provisionalText = update.text
                if update.isFinal {
                    finalText = update.text
                }
                if state == .listening {
                    state = .transcribing
                }
            }
        } catch let error as SpeechInputError {
            if error != .cancelled {
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
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
        case .turnComplete:
            state = isFailed ? state : .idle
        case .error(let message):
            state = .failed(message)
        case .messageStart, .textDelta, .textReplace, .messageComplete, .unknown:
            break
        }
    }

    private func handlePlaybackFailure() async {
        playbackFailed = true
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
