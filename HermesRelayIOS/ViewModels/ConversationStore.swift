import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private let client: any HermesSessionClient

    var connectionState: ConnectionState = .disconnected
    var messages: [TranscriptMessage] = []
    var draft = ""
    var transientError: String?

    init(client: any HermesSessionClient = UnavailableHermesSessionClient()) {
        self.client = client
    }

    func connect() async {
        guard connectionState != .connecting else { return }

        connectionState = .connecting
        do {
            _ = try await client.connect()
            connectionState = .connected
            transientError = nil
        } catch {
            let message = error.localizedDescription
            connectionState = .failed(message)
            transientError = message
        }
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard connectionState.isConnected else {
            transientError = "Connect to the Hermes relay before sending."
            return
        }

        draft = ""
        messages.append(TranscriptMessage(role: .user, text: text))

        do {
            for try await event in client.sendTurn(text: text) {
                apply(event)
            }
        } catch {
            let message = error.localizedDescription
            transientError = message
            messages.append(TranscriptMessage(role: .error, text: message))
        }
    }

    func clearTransientError() {
        transientError = nil
    }

    private func apply(_ event: HermesEvent) {
        switch event {
        case .textDelta(let text):
            if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[index].text += text
            } else {
                messages.append(TranscriptMessage(role: .assistant, text: text))
            }
        case .status(let text):
            transientError = text
        case .messageComplete, .turnComplete:
            break
        case .error(let text):
            transientError = text
            messages.append(TranscriptMessage(role: .error, text: text))
        }
    }
}
