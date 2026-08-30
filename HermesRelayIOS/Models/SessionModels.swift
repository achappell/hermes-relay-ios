import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .failed:
            return "Unavailable"
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

struct SessionMetadata: Equatable, Sendable {
    let sessionID: String
    let model: String?
}

struct AudioFormat: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let sampleWidth: Int
}

enum TranscriptRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
    case error
}

struct TranscriptMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: TranscriptRole
    var text: String

    init(id: UUID = UUID(), role: TranscriptRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum HermesEvent: Equatable, Sendable {
    case messageStart
    case textDelta(String)
    case textReplace(String)
    case thinkingDelta(String)
    case status(text: String, kind: String?)
    case audioStart(AudioFormat)
    case audioChunk(Data)
    case audioEnd
    case messageComplete(text: String, reasoning: String, failureReason: String)
    case turnComplete(turnID: String)
    case error(String)
    case unknown(type: String)
}
