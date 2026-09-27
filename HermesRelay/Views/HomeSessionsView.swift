import SwiftUI

/// The Profile's Hermes conversations on a paired Home: continue one, start
/// a new one, or rename the current one. Switching closes the current claim
/// and makes a new one; nothing is ever resent.
struct HomeSessionsView: View {
    let store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [HomeClientSessionSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSwitching = false
    @State private var renameText = ""
    @State private var isRenaming = false

    var body: some View {
        NavigationStack {
            List {
                currentSection
                if let blockedReason = store.homeSessionSwitchBlockedReason {
                    Section {
                        Label(blockedReason, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                }
                earlierSection
            }
            .navigationTitle("Conversations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await switchSession { await store.startNewHomeSession() } }
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                    }
                    .disabled(isSwitching || store.homeSessionSwitchBlockedReason != nil)
                    .accessibilityIdentifier("home-sessions-new")
                }
            }
            .overlay {
                if isSwitching {
                    ProgressView("Switching…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Rename conversation", isPresented: $isRenaming) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let title = renameText
                    Task {
                        if await store.renameHomeSession(to: title) { await load() }
                    }
                }
            }
            .task { await load() }
        }
    }

    private var currentSection: some View {
        Section("Current") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.homeSession?.title ?? "Untitled conversation")
                        .font(.body.weight(.semibold))
                    if let current = currentSummary {
                        Text(Self.detail(for: current))
                            .font(.caption)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                }
                Spacer()
                if store.canRenameHomeSession {
                    Button("Rename") {
                        renameText = store.homeSession?.title ?? ""
                        isRenaming = true
                    }
                    .accessibilityIdentifier("home-sessions-rename")
                }
            }
        }
    }

    @ViewBuilder
    private var earlierSection: some View {
        Section("Earlier") {
            if isLoading {
                ProgressView()
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError)
                        .font(.callout)
                    Button("Retry") { Task { await load() } }
                }
            } else if otherSessions.isEmpty {
                Text("No other conversations for this Profile yet.")
                    .font(.callout)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            } else {
                ForEach(otherSessions) { session in
                    Button {
                        Task { await switchSession { await store.resumeHomeSession(session) } }
                    } label: {
                        sessionRow(session)
                    }
                    .disabled(isSwitching || session.active || store.homeSessionSwitchBlockedReason != nil)
                }
            }
        }
    }

    private func sessionRow(_ session: HomeClientSessionSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled conversation" : session.title)
                    .foregroundStyle(HermesVisualTokens.primaryInk)
                    .lineLimit(2)
                Text(Self.detail(for: session))
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }
            Spacer()
            if session.active {
                Text("In use")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("In use on another device")
            }
        }
        .contentShape(Rectangle())
    }

    private var currentSummary: HomeClientSessionSummary? {
        guard let sessionRef = store.homeSession?.sessionRef else { return nil }
        return sessions.first { $0.sessionRef == sessionRef }
    }

    private var otherSessions: [HomeClientSessionSummary] {
        let current = store.homeSession?.sessionRef
        return sessions.filter { $0.sessionRef != current }
    }

    static func detail(for session: HomeClientSessionSummary) -> String {
        let messages = session.messageCount == 1 ? "1 message" : "\(session.messageCount) messages"
        guard let startedAt = session.startedAt else { return messages }
        let started = startedAt.formatted(.relative(presentation: .named))
        return "Started \(started) · \(messages)"
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            sessions = try await store.loadHomeSessions()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? "Home could not list conversations. Try again."
        }
        isLoading = false
    }

    private func switchSession(_ action: () async -> Bool) async {
        isSwitching = true
        let switched = await action()
        isSwitching = false
        if switched {
            dismiss()
        } else {
            await load()
        }
    }
}
