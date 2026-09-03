import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private var client: any HermesSessionClient
    private let configurationStore: RelayConfigurationStore?
    private let socketFactory: any WebSocketConnectionFactory
    private let persistence: (any ConversationPersistence)?
    private let now: @Sendable () -> Date

    var connectionState: ConnectionState = .disconnected
    var sessionMetadata: SessionMetadata?
    var sessionStartedAt: Date?
    var messages: [TranscriptMessage] = []
    var draft = ""
    var transientError: String?
    var activityText: String?
    var isSending = false
    var unconfirmedTurnText: String?

    private var activeAssistantID: UUID?
    private var turnCompleted = false
    private var didAttemptAutomaticConnection = false
    // A closed stream can still deliver already-buffered events. Generation
    // invalidation keeps an interrupted turn from contaminating the next one.
    private var nextTurnGeneration: UInt64 = 0
    private var activeTurnGeneration: UInt64?
    private var interruptedTurnGeneration: UInt64?

    init(
        client: any HermesSessionClient = UnavailableHermesSessionClient(),
        configurationStore: RelayConfigurationStore? = nil,
        socketFactory: any WebSocketConnectionFactory = URLSessionWebSocketConnectionFactory(),
        persistence: (any ConversationPersistence)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.socketFactory = socketFactory
        self.persistence = persistence
        self.now = now
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

    @discardableResult
    func loadConfiguredClient() async -> Bool {
        guard let configurationStore else { return false }

        do {
            guard let profile = try await configurationStore.loadProfile() else {
                transientError = "Configure a Hermes relay profile before connecting."
                return false
            }
            guard let token = try await configurationStore.loadToken() else {
                transientError = "Add a Hermes relay token before connecting."
                return false
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
            return true
        } catch {
            transientError = error.localizedDescription
            return false
        }
    }

    func autoConnectIfNeeded() async {
        guard !didAttemptAutomaticConnection else { return }
        didAttemptAutomaticConnection = true
        guard await loadConfiguredClient() else { return }
        await connect()
    }

    func connect() async {
        guard connectionState != .connecting else { return }

        connectionState = .connecting
        do {
            let metadata = try await client.connect()
            sessionMetadata = metadata
            sessionStartedAt = now()
            connectionState = .connected
            transientError = nil
        } catch {
            let message = error.localizedDescription
            sessionMetadata = nil
            sessionStartedAt = nil
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
        nextTurnGeneration &+= 1
        let turnGeneration = nextTurnGeneration
        activeTurnGeneration = turnGeneration
        messages.append(TranscriptMessage(role: .user, text: text))
        var didComplete = false

        do {
            let events = await client.sendTurn(text: text)
            for try await event in events {
                guard activeTurnGeneration == turnGeneration else { break }
                apply(event)
                if let eventHandler {
                    await eventHandler(event)
                }
            }
        } catch {
            if interruptedTurnGeneration != turnGeneration {
                activeTurnGeneration = nil
                interruptedTurnGeneration = nil
                let message = error.localizedDescription
                if case RelaySessionError.disconnected = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                } else if case RelaySessionError.connectionTimedOut = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                } else if case RelaySessionError.notConnected = error {
                    connectionState = .disconnected
                    sessionMetadata = nil
                    sessionStartedAt = nil
                }
                transientError = message
                messages.append(TranscriptMessage(role: .error, text: message))
                unconfirmedTurnText = text
                if draft.isEmpty {
                    draft = text
                }
            }
        }
        let wasInterrupted = interruptedTurnGeneration == turnGeneration
        interruptedTurnGeneration = nil
        activeTurnGeneration = nil
        if wasInterrupted {
            isSending = false
            activeAssistantID = nil
            await persistConversation()
            return false
        }
        didComplete = turnCompleted
        if !didComplete {
            unconfirmedTurnText = text
        }
        isSending = false
        activeAssistantID = nil
        await persistConversation()
        return didComplete
    }

    @discardableResult
    func interruptActiveTurn() async -> Bool {
        guard isSending, let turnGeneration = activeTurnGeneration else { return false }

        interruptedTurnGeneration = turnGeneration
        activeTurnGeneration = nil
        await client.disconnect()
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
        activityText = nil
        await connect()
        return connectionState.isConnected
    }

    func clearTransientError() {
        transientError = nil
    }

    private func transportDidDisconnect() {
        connectionState = .disconnected
        sessionMetadata = nil
        sessionStartedAt = nil
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
