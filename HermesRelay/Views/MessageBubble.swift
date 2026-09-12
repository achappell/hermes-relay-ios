import SwiftUI

struct MessageBubble: View {
    let message: TranscriptMessage
    private let exportFormatter = TranscriptExportFormatter()

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            bubbleContent
                .frame(
                    maxWidth: message.role == .user || message.role == .assistant ? 320 : .infinity,
                    alignment: .leading
                )

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HermesVisualTokens.secondaryInk)
            Text(message.text)
                .foregroundStyle(HermesVisualTokens.primaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .relayPanel(cornerRadius: 16, fill: message.role.backgroundColor)
        .contextMenu {
            Button {
                TranscriptClipboard.copy(exportFormatter.plainText(for: [message]))
            } label: {
                Label("Copy message", systemImage: "doc.on.doc")
            }

            ShareLink(
                item: exportFormatter.markdown(for: [message]),
                preview: SharePreview("Hermes conversation message")
            ) {
                Label("Share message", systemImage: "square.and.arrow.up")
            }
        }
    }
}

private extension TranscriptRole {
    var label: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Hermes"
        case .system:
            return "System"
        case .error:
            return "Unavailable"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .user:
            return HermesVisualTokens.identityWash
        case .assistant:
            return HermesVisualTokens.raisedPanel
        case .system:
            return HermesVisualTokens.attentionWash
        case .error:
            return HermesVisualTokens.unavailableWash
        }
    }
}
