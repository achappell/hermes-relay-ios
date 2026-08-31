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

enum VoiceState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
    case buffering
    case interrupted
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .buffering:
            return "Buffering"
        case .interrupted:
            return "Interrupted"
        case .failed(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "mic"
        case .listening:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .thinking:
            return "ellipsis"
        case .speaking:
            return "speaker.wave.2.fill"
        case .buffering:
            return "arrow.down.circle"
        case .interrupted:
            return "pause.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
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

enum TranscriptRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case error
}

struct TranscriptMessage: Codable, Identifiable, Equatable, Sendable {
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
    case audioFileStart(contentType: String)
    case audioFileChunk(Data)
    case audioFileEnd
    case messageComplete(text: String, reasoning: String, failureReason: String)
    case turnComplete(turnID: String)
    case error(String)
    case unknown(type: String)
}
