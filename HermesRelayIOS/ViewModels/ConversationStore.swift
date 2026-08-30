import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private var client: any HermesSessionClient
    private let configurationStore: RelayConfigurationStore?
    private let socketFactory: any WebSocketConnectionFactory

    var connectionState: ConnectionState = .disconnected
    var sessionMetadata: SessionMetadata?
    var messages: [TranscriptMessage] = []
    var draft = ""
    var transientError: String?
    var activityText: String?
    var isSending = false

    private var activeAssistantID: UUID?

    init(
        client: any HermesSessionClient = UnavailableHermesSessionClient(),
        configurationStore: RelayConfigurationStore? = nil,
        socketFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory()
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.socketFactory = socketFactory
    }

    func loadConfiguredClient() async {
        guard let configurationStore else { return }

        do {
            guard let profile = try await configurationStore.loadProfile() else {
                transientError = "Configure a Hermes relay profile before connecting."
                return
            }
            guard let token = try await configurationStore.loadToken() else {
                transientError = "Add a Hermes relay token before connecting."
                return
            }
            client = URLSessionHermesSessionClient(
                profile: profile,
                token: token,
                socketFactory: socketFactory
            )
            transientError = nil
        } catch {
            transientError = error.localizedDescription
        }
    }

    func connect() async {
        guard connectionState != .connecting else { return }

        connectionState = .connecting
        do {
            let metadata = try await client.connect()
            sessionMetadata = metadata
            connectionState = .connected
            transientError = nil
        } catch {
            let message = error.localizedDescription
            sessionMetadata = nil
            connectionState = .failed(message)
            transientError = message
        }
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await sendTurn(text: text)
    }

    func sendTurn(text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard connectionState.isConnected else {
            transientError = "Connect to the Hermes relay before sending."
            return
        }
        guard !isSending else {
            transientError = "A Hermes turn is already in progress."
            return
        }

        isSending = true
        activeAssistantID = nil
        activityText = nil
        messages.append(TranscriptMessage(role: .user, text: text))

        do {
            let events = await client.sendTurn(text: text)
            for try await event in events {
                apply(event)
            }
        } catch {
            let message = error.localizedDescription
            transientError = message
            messages.append(TranscriptMessage(role: .error, text: message))
        }
        isSending = false
        activeAssistantID = nil
    }

    func clearTransientError() {
        transientError = nil
    }

    private func apply(_ event: HermesEvent) {
        switch event {
        case .messageStart:
            let message = TranscriptMessage(role: .assistant, text: "")
            activeAssistantID = message.id
            messages.append(message)
        case .textDelta(let text):
            if let index = activeAssistantIndex {
                messages[index].text += text
            } else {
                let message = TranscriptMessage(role: .assistant, text: text)
                activeAssistantID = message.id
                messages.append(message)
            }
        case .textReplace(let text):
            if let index = activeAssistantIndex {
                messages[index].text = text
            } else {
                let message = TranscriptMessage(role: .assistant, text: text)
                activeAssistantID = message.id
                messages.append(message)
            }
        case .thinkingDelta(let text):
            activityText = text
        case .status(let text, _):
            activityText = text
        case .audioStart, .audioChunk, .audioEnd, .unknown:
            break
        case .messageComplete(_, _, let failureReason):
            if !failureReason.isEmpty {
                transientError = failureReason
            }
        case .turnComplete:
            activeAssistantID = nil
        case .error(let text):
            transientError = text
            messages.append(TranscriptMessage(role: .error, text: text))
        }
    }

    private var activeAssistantIndex: Int? {
        guard let activeAssistantID else { return nil }
        return messages.firstIndex { $0.id == activeAssistantID }
    }
}
