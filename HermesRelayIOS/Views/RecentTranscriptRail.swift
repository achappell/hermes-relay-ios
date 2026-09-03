import SwiftUI

struct RecentTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: String
    let role: TranscriptRole
    let text: String
    let isLive: Bool

    init(id: String, role: TranscriptRole, text: String, isLive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isLive = isLive
    }
}

struct RecentTranscriptProjection: Equatable, Sendable {
    private static let maximumEntryCount = 6

    let entries: [RecentTranscriptEntry]

    init(messages: [TranscriptMessage], provisionalText: String) {
        var entries = messages.compactMap { message -> RecentTranscriptEntry? in
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return RecentTranscriptEntry(
                id: message.id.uuidString,
                role: message.role,
                text: message.text
            )
        }

        let liveText = provisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveText.isEmpty {
            entries.append(
                RecentTranscriptEntry(
                    id: "live-user",
                    role: .user,
                    text: liveText,
                    isLive: true
                )
            )
        }

        self.entries = Array(entries.suffix(Self.maximumEntryCount))
    }

    var latestEntryID: String? {
        entries.last?.id
    }
}

struct RecentTranscriptFollowState: Equatable, Sendable {
    private(set) var isFollowingLatest = true

    mutating func pauseFollowing() {
        isFollowingLatest = false
    }

    mutating func resumeFollowing() {
        isFollowingLatest = true
    }
}

struct RecentTranscriptRail: View {
    let messages: [TranscriptMessage]
    let provisionalText: String
    let hasPersistedHistory: Bool
    let onShowHistory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followState = RecentTranscriptFollowState()

    private static let bottomAnchorID = "recent-transcript-bottom"

    private var projection: RecentTranscriptProjection {
        RecentTranscriptProjection(messages: messages, provisionalText: provisionalText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Recent transcript", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if followState.isFollowingLatest {
                    Text("Live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Resume live") {
                        followState.resumeFollowing()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityHint("Returns the transcript to the newest text")
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(projection.entries) { entry in
                            RecentTranscriptEntryView(entry: entry)
                                .id(entry.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 152)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            followState.pauseFollowing()
                        }
                )
                .onTapGesture {
                    followState.pauseFollowing()
                }
                .onAppear {
                    scrollToLatest(using: proxy, animated: false)
                }
                .onChange(of: projection.entries) { _, _ in
                    guard followState.isFollowingLatest else { return }
                    scrollToLatest(using: proxy, animated: false)
                }
                .onChange(of: followState.isFollowingLatest) { _, isFollowing in
                    guard isFollowing else { return }
                    scrollToLatest(using: proxy, animated: !reduceMotion)
                }
                .accessibilityLabel(
                    followState.isFollowingLatest
                        ? "Recent transcript, following live text"
                        : "Recent transcript, reading paused"
                )
            }

            HStack(spacing: 12) {
                if hasPersistedHistory {
                    Button(action: onShowHistory) {
                        Label("All history", systemImage: "clock.arrow.circlepath")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }

                Spacer(minLength: 8)

                Text(followState.isFollowingLatest ? "Following newest" : "Reading paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 680)
        .accessibilityElement(children: .contain)
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct RecentTranscriptEntryView: View {
    let entry: RecentTranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.role.railLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(entry.role.railTint)
                .frame(width: 48, alignment: .leading)

            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if entry.isLive {
                Circle()
                    .fill(entry.role.railTint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            entry.isLive
                ? "(entry.role.railLabel), live, (entry.text)"
                : "(entry.role.railLabel), (entry.text)"
        )
    }
}

private extension TranscriptRole {
    var railLabel: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Hermes"
        case .system:
            return "System"
        case .error:
            return "Error"
        }
    }

    var railTint: Color {
        switch self {
        case .user:
            return .accentColor
        case .assistant:
            return .secondary
        case .system:
            return .yellow
        case .error:
            return .red
        }
    }
}

#Preview("Recent Transcript Rail") {
    RecentTranscriptRail(
        messages: [
            TranscriptMessage(role: .user, text: "Can you walk me through the longer answer?"),
            TranscriptMessage(
                role: .assistant,
                text: "The recent rail keeps the current exchange visible as Hermes continues speaking. Scroll up to read older lines, then resume live when you are ready to follow the newest text."
            )
        ],
        provisionalText: "",
        hasPersistedHistory: true,
        onShowHistory: {}
    )
    .padding()
}
