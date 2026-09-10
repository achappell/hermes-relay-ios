import Foundation

enum SpeechAuthorization: Equatable, Sendable {
    case authorized
    case microphoneDenied
    case speechDenied
    case restricted
    case notDetermined
}

struct SpeechRecognitionUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

enum SpeechInputError: LocalizedError, Equatable, Sendable {
    case notAuthorized
    case captureFailed
    case noSpeech
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone and speech recognition permission are required for voice turns."
        case .captureFailed:
            return "The voice capture could not be started."
        case .noSpeech:
            return "No speech was detected."
        case .cancelled:
            return "The voice capture was cancelled."
        }
    }
}

protocol SpeechInput: Sendable {
    func authorization() async -> SpeechAuthorization
    func requestAuthorization() async -> SpeechAuthorization
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error>
    func finish() async
    func cancel() async
}

enum HandsFreeInputEvent: Equatable, Sendable {
    case activity(AudioActivitySnapshot)
    case recognition(SpeechRecognitionUpdate)
}

protocol HandsFreeInput: Sendable {
    func authorization() async -> SpeechAuthorization
    func requestAuthorization() async -> SpeechAuthorization
    func start() async throws -> AsyncThrowingStream<HandsFreeInputEvent, Error>
    func finish() async
    func cancel() async
}

/// Adapts the existing speech recognizer into the single event stream used by
/// hands-free mode. The speech adapter owns the microphone; the activity store
/// supplies deterministic speech/noise/silence boundaries and keeps the HUD
/// on the same level data.
actor SpeechBackedHandsFreeInput: HandsFreeInput {
    private let speechInput: any SpeechInput
    private let activityStore: AudioActivityStore

    private var continuation: AsyncThrowingStream<HandsFreeInputEvent, Error>.Continuation?
    private var activityTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?

    init(
        speechInput: any SpeechInput,
        activityStore: AudioActivityStore
    ) {
        self.speechInput = speechInput
        self.activityStore = activityStore
    }

    func authorization() async -> SpeechAuthorization {
        await speechInput.authorization()
    }

    func requestAuthorization() async -> SpeechAuthorization {
        await speechInput.requestAuthorization()
    }

    func start() async throws -> AsyncThrowingStream<HandsFreeInputEvent, Error> {
        guard continuation == nil else {
            throw SpeechInputError.captureFailed
        }

        let recognitionStream = try await speechInput.start()
        let (stream, continuation) = AsyncThrowingStream<HandsFreeInputEvent, Error>.makeStream()
        self.continuation = continuation

        let activityStore = self.activityStore
        activityTask = Task { [weak self] in
            let snapshots = await activityStore.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await self?.yield(.activity(snapshot))
            }
        }

        recognitionTask = Task { [weak self] in
            do {
                for try await update in recognitionStream {
                    guard !Task.isCancelled else { return }
                    await self?.yield(.recognition(update))
                }
                await self?.finishStream()
            } catch {
                await self?.finishStream(throwing: error)
            }
        }

        return stream
    }

    func finish() async {
        await speechInput.finish()
        closeStream()
    }

    func cancel() async {
        await speechInput.cancel()
        closeStream(throwing: SpeechInputError.cancelled)
    }

    private func yield(_ event: HandsFreeInputEvent) {
        continuation?.yield(event)
    }

    private func finishStream(throwing error: Error? = nil) {
        guard continuation != nil else { return }
        closeStream(throwing: error)
    }

    private func closeStream(throwing error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        activityTask?.cancel()
        activityTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
