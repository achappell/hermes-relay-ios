import Foundation

enum SpeechAuthorization: Equatable, Sendable {
    case authorized
    case denied
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
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone and speech recognition permission are required for voice turns."
        case .captureFailed:
            return "The voice capture could not be started."
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
