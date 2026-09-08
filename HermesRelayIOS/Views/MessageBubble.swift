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
                .foregroundStyle(.secondary)
            Text(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .relayGlass(
            cornerRadius: 16,
            tint: message.role.glassTint,
            fallbackColor: message.role.backgroundColor
        )
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
            return Color.accentColor.opacity(0.15)
        case .assistant:
            return Color.secondary.opacity(0.12)
        case .system:
            return Color.yellow.opacity(0.16)
        case .error:
            return Color.red.opacity(0.12)
        }
    }

    var glassTint: Color? {
        switch self {
        case .user:
            return Color.accentColor.opacity(0.18)
        case .assistant:
            return nil
        case .system:
            return Color.yellow.opacity(0.18)
        case .error:
            return Color.red.opacity(0.18)
        }
    }
}
