import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private var client: any HermesSessionClient
    private let configurationStore: RelayConfigurationStore?
    private let socketFactory: any WebSocketConnectionFactory
    private let persistence: (any ConversationPersistence)?

    var connectionState: ConnectionState = .disconnected
    var sessionMetadata: SessionMetadata?
    var messages: [TranscriptMessage] = []
    var draft = ""
    var transientError: String?
    var activityText: String?
    var isSending = false
    var unconfirmedTurnText: String?

    private var activeAssistantID: UUID?
    private var turnCompleted = false

    init(
        client: any HermesSessionClient = UnavailableHermesSessionClient(),
        configurationStore: RelayConfigurationStore? = nil,
        socketFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory(),
        persistence: (any ConversationPersistence)? = nil
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.socketFactory = socketFactory
        self.persistence = persistence
    }

    func loadPersistedConversation() async {
        guard let persistence else { return }

        do {
            let conversation = try await persistence.load()
            messages = conversation.messages
            draft = conversation.draft
            unconfirmedTurnText = conversation.unconfirmedTurnText
            activeAssistantID = nil
        } catch {
            transientError = "The saved conversation could not be restored."
        }
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
                socketFactory: socketFactory,
                onTransportDisconnected: { @MainActor [weak self] in
                    self?.transportDidDisconnect()
                }
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

    @discardableResult
    func sendDraft(
        eventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)? = nil
    ) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let completed = await sendTurn(text: text, eventHandler: eventHandler)
        if completed, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draft = ""
            await persistConversation()
        }
        return completed
    }

    @discardableResult
    func sendTurn(
        text: String,
        eventHandler: (@MainActor @Sendable (HermesEvent) async -> Void)? = nil
    ) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard connectionState.isConnected else {
            if draft.isEmpty {
                draft = text
            }
            transientError = "Connect to the Hermes relay before sending."
            await persistConversation()
            return false
        }
        guard !isSending else {
            transientError = "A Hermes turn is already in progress."
            return false
        }

        isSending = true
        activeAssistantID = nil
        activityText = nil
        transientError = nil
        turnCompleted = false
        unconfirmedTurnText = nil
        messages.append(TranscriptMessage(role: .user, text: text))
        var didComplete = false

        do {
            let events = await client.sendTurn(text: text)
            for try await event in events {
                apply(event)
                if let eventHandler {
                    await eventHandler(event)
                }
            }
            didComplete = turnCompleted
            if !didComplete {
                unconfirmedTurnText = text
            }
        } catch {
            let message = error.localizedDescription
            if case RelaySessionError.disconnected = error {
                connectionState = .disconnected
                sessionMetadata = nil
            } else if case RelaySessionError.connectionTimedOut = error {
                connectionState = .disconnected
                sessionMetadata = nil
            } else if case RelaySessionError.notConnected = error {
                connectionState = .disconnected
                sessionMetadata = nil
            }
            transientError = message
            messages.append(TranscriptMessage(role: .error, text: message))
            unconfirmedTurnText = text
            if draft.isEmpty {
                draft = text
            }
        }
        isSending = false
        activeAssistantID = nil
        await persistConversation()
        return didComplete
    }

    func clearTransientError() {
        transientError = nil
    }

    private func transportDidDisconnect() {
        connectionState = .disconnected
        sessionMetadata = nil
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
        case .audioStart, .audioChunk, .audioEnd,
             .audioFileStart, .audioFileChunk, .audioFileEnd, .unknown:
            break
        case .messageComplete(_, _, let failureReason):
            if !failureReason.isEmpty {
                transientError = failureReason
            }
        case .turnComplete:
            turnCompleted = true
            unconfirmedTurnText = nil
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

    private func persistConversation() async {
        guard let persistence else { return }
        do {
            try await persistence.save(
                PersistedConversation(
                    messages: messages,
                    draft: draft,
                    unconfirmedTurnText: unconfirmedTurnText
                )
            )
        } catch {
            if transientError == nil {
                transientError = "The local conversation could not be saved."
            }
        }
    }
}
