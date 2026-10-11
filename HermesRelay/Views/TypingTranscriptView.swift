import SwiftUI

/// The typing view's transcript (IOS-UX-F7): every message in order, newest at
/// the bottom, at compact density with no panel chrome. It lives inside the
/// conversation's single scroll view; `bottomAnchorID` marks the newest end.
struct TypingTranscriptView: View {
    static let bottomAnchorID = "typing-transcript-bottom"

    let messages: [TranscriptMessage]
    var thinkingTurns: [ThinkingTurn] = []
    var onOpenThinking: (UUID) -> Void = { _ in }
    private let exportFormatter = TranscriptExportFormatter()

    /// Hermes's reply is created empty when it starts; an empty row is noise.
    nonisolated static func visibleMessages(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(
                ThinkingTranscriptOrdering.items(
                    messages: Self.visibleMessages(messages),
                    turns: thinkingTurns
                )
            ) { item in
                switch item {
                case .message(let message):
                    row(for: message)
                case .thinking(let turn):
                    ThinkingRow(turn: turn) { onOpenThinking(turn.id) }
                }
            }
            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchorID)
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("typing-transcript")
    }

    private func row(for message: TranscriptMessage) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(message.role.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    message.role == .user ? HermesVisualTokens.identity : HermesVisualTokens.secondaryInk
                )
            Text(message.text)
                .font(.callout)
                .foregroundStyle(HermesVisualTokens.primaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
