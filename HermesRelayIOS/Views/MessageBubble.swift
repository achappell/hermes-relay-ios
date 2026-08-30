import SwiftUI

struct MessageBubble: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(message.role.backgroundColor, in: RoundedRectangle(cornerRadius: 14))
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
}
