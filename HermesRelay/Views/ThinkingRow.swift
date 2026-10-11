import SwiftUI

/// Where each turn's thinking row sits in a transcript (IOS-UX-F6): right
/// after the user message that began the turn, so before that turn's reply.
enum TranscriptDisplayItem: Identifiable, Equatable {
    case message(TranscriptMessage)
    case thinking(ThinkingTurn)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id.uuidString)"
        case .thinking(let turn): "thinking-\(turn.id.uuidString)"
        }
    }
}

enum ThinkingTranscriptOrdering {
    static func items(messages: [TranscriptMessage], turns: [ThinkingTurn]) -> [TranscriptDisplayItem] {
        var items: [TranscriptDisplayItem] = []
        var placed = Set<UUID>()
        for message in messages {
            items.append(.message(message))
            for turn in turns where turn.anchorMessageID == message.id && !placed.contains(turn.id) {
                items.append(.thinking(turn))
                placed.insert(turn.id)
            }
        }
        // A turn with no user message (thinking before any prompt exists)
        // goes at the end rather than being lost.
        for turn in turns where turn.anchorMessageID == nil && !placed.contains(turn.id) {
            items.append(.thinking(turn))
        }
        return items
    }

    /// The row for the exchange the voice view is showing: the newest turn,
    /// when it belongs to the newest user message.
    static func latestExchangeTurn(messages: [TranscriptMessage], turns: [ThinkingTurn]) -> ThinkingTurn? {
        guard let turn = turns.last else { return nil }
        let lastUserID = messages.last(where: { $0.role == .user })?.id
        return turn.anchorMessageID == lastUserID ? turn : nil
    }
}

/// Decides whether the opened thinking view should follow new text: only
/// while the reader is at the bottom (IOS-UX-F6 criterion 4).
enum ThinkingFollow {
    static let bottomTolerance: CGFloat = 24

    static func isAtBottom(offset: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        offset + viewportHeight >= contentHeight - bottomTolerance
    }
}

/// One collapsed row for a turn's thinking text. Its height is fixed, so it
/// never grows, shrinks or jumps as text arrives. It announces once, when it
/// appears, and never per delta: its accessibility label does not carry the text.
struct ThinkingRow: View {
    static let height: CGFloat = 40

    let turn: ThinkingTurn
    let onOpen: () -> Void

    static func title(isActive: Bool) -> String {
        isActive ? "Hermes is thinking" : "Hermes thought"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                if turn.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.bubble")
                        .imageScale(.small)
                }
                Text(Self.title(isActive: turn.isActive))
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .imageScale(.small)
            }
            .foregroundStyle(HermesVisualTokens.secondaryInk)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .relayPanel(cornerRadius: 12, fill: HermesVisualTokens.panel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title(isActive: turn.isActive))
        .accessibilityHint("Opens the thinking text")
        .accessibilityIdentifier("thinking-row")
    }
}

/// The full thinking text for one turn. It grows live while the turn is still
/// thinking, follows new text only while the reader is at the bottom, and does
/// not animate under Reduce Motion. Each paragraph is its own element so
/// VoiceOver moves through it line by line.
struct ThinkingSheet: View {
    let turn: ThinkingTurn
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAtBottom = true

    private static let bottomID = "thinking-bottom"

    private var paragraphs: [String] {
        turn.text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.callout)
                                .foregroundStyle(HermesVisualTokens.primaryInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(16)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    ThinkingFollow.isAtBottom(
                        offset: geometry.contentOffset.y,
                        viewportHeight: geometry.containerSize.height,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onChange(of: turn.text) {
                    guard isAtBottom else { return }
                    if reduceMotion {
                        reader.scrollTo(Self.bottomID, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            reader.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle(ThinkingRow.title(isActive: turn.isActive))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("thinking-sheet")
    }
}
