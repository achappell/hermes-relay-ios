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
    case textDelta(String)
    case status(String)
    case messageComplete
    case error(String)
    case turnComplete
}
