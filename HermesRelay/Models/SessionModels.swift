import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, of: Int)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .reconnecting(let attempt, let total):
            return "Reconnecting… (\(attempt) of \(total))"
        case .failed:
            return "Unavailable"
        }
    }

    var isConnected: Bool {
        self == .connected
    }

    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

enum VoiceFailureAction: Equatable, Sendable {
    case openSettings
}

enum VoiceFailure: Equatable, Sendable {
    case message(String)
    case permission(SpeechAuthorization)

    var message: String {
        switch self {
        case .message(let message):
            return message
        case .permission(let authorization):
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

    var action: VoiceFailureAction? {
        switch self {
        case .message:
            return nil
        case .permission:
            return .openSettings
        }
    }
}

enum VoiceState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
    case buffering
    case complete
    case interrupted
    case failed(VoiceFailure)

    static func failed(_ message: String) -> VoiceState {
        .failed(.message(message))
    }

    var failure: VoiceFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }

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
        case .complete:
            return "Complete"
        case .interrupted:
            return "Interrupted"
        case .failed(let failure):
            return failure.message
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
        case .complete:
            return "checkmark.circle"
        case .interrupted:
            return "pause.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var isCaptureActive: Bool {
        switch self {
        case .listening, .transcribing:
            return true
        default:
            return false
        }
    }

    var isResponseActive: Bool {
        switch self {
        case .thinking, .buffering, .speaking:
            return true
        default:
            return false
        }
    }

    var isOutputActive: Bool {
        switch self {
        case .buffering, .speaking:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .complete, .interrupted, .failed:
            return true
        default:
            return false
        }
    }
}

enum HermesSessionBindingIdentity: Equatable, Sendable {
    case legacy(sessionID: String)
    case home(conversation: HomeConversationBinding, turn: HomeTurnBinding?)
}

struct SessionMetadata: Equatable, Sendable {
    /// Legacy clients expose their fork session ID here. Home metadata keeps
    /// this nil: its conversation and turn handles belong to the typed
    /// binding identity below and are never smuggled through this field.
    let sessionID: String?
    let model: String?
    let capabilities: [String]
    let binding: HermesSessionBindingIdentity

    init(sessionID: String, model: String?, capabilities: [String] = []) {
        self.sessionID = sessionID
        self.model = model
        self.capabilities = capabilities
        self.binding = .legacy(sessionID: sessionID)
    }

    init(
        homeConversation: HomeConversationBinding,
        model: String? = nil,
        capabilities: [String] = []
    ) {
        self.sessionID = nil
        self.model = model
        self.capabilities = capabilities
        self.binding = .home(conversation: homeConversation, turn: nil)
    }

    var supportsInterrupt: Bool {
        capabilities.contains("interrupt")
    }
}

/// The verified connection identity that owns a user-initiated turn.
///
/// A session ID is always required. The profile ID is optional so injected
/// clients used by previews and deterministic tests can still participate in
/// the same binding rule without inventing configuration state.
struct HermesTurnBinding: Equatable, Sendable {
    let profileID: UUID?
    /// Non-nil only for the legacy fork binding. Home uses `identity`.
    let sessionID: String?
    let identity: HermesSessionBindingIdentity

    init(profileID: UUID?, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.identity = .legacy(sessionID: sessionID)
    }

    init(
        profileID: UUID?,
        homeConversation: HomeConversationBinding,
        turn: HomeTurnBinding? = nil
    ) {
        self.profileID = profileID
        self.sessionID = nil
        self.identity = .home(conversation: homeConversation, turn: turn)
    }

    var homeConversation: HomeConversationBinding? {
        guard case .home(let conversation, _) = identity else { return nil }
        return conversation
    }

    var homeTurn: HomeTurnBinding? {
        guard case .home(_, let turn) = identity else { return nil }
        return turn
    }
}

struct AudioFormat: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let sampleWidth: Int
    let byteOrder: HomeByteOrder

    init(
        sampleRate: Int,
        channels: Int,
        sampleWidth: Int,
        byteOrder: HomeByteOrder = .little
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleWidth = sampleWidth
        self.byteOrder = byteOrder
    }
}

/// A word boundary measured from the beginning of the active inbound audio stream.
struct SpeechTimingWord: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeechTimingSource: String, Equatable, Sendable {
    case alignment
    case durationFallback = "duration_fallback"
}

enum SpeechTimingFallbackReason: String, Equatable, Sendable {
    case disabled
    case unsupported
    case missing
    case error
    case timeout
    case invalid
}

/// Timing for one audio segment. Segment revisions use the same segment ID.
struct SpeechTiming: Equatable, Sendable {
    let segmentID: String
    let text: String
    let timingSource: SpeechTimingSource
    let audioOffset: TimeInterval
    let duration: TimeInterval
    let fallbackReason: SpeechTimingFallbackReason?
    let words: [SpeechTimingWord]

    var endTime: TimeInterval {
        audioOffset + duration
    }

    var usesWordTiming: Bool {
        timingSource == .alignment && !words.isEmpty
    }
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
    let createdAt: Date?

    init(
        id: UUID = UUID(),
        role: TranscriptRole,
        text: String,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(TranscriptRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
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
    case audioAbort(turnID: String, reason: String)
    case turnInterrupted(turnID: String, reason: String)
    case speechTiming(SpeechTiming)
    case messageComplete(text: String, reasoning: String, failureReason: String)
    case turnComplete(turnID: String)
    case error(String)
    case unknown(type: String)
}
