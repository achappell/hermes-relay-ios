import SwiftUI

/// The Profile's Hermes conversations on a paired Home: continue one, start
/// a new one, or rename the current one. Switching closes the current claim
/// and makes a new one; nothing is ever resent.
struct HomeSessionsView: View {
    let store: ConversationStore
    let scrollToOpenClaims: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [HomeClientSessionSummary] = []
    @State private var isLoading = true
    @State private var isLoadingClaims = true
    @State private var loadError: String?
    @State private var isSwitching = false
    @State private var renameText = ""
    @State private var isRenaming = false

    init(store: ConversationStore, scrollToOpenClaims: Bool = false) {
        self.store = store
        self.scrollToOpenClaims = scrollToOpenClaims
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if store.supportsOpenHomeClaims {
                        openOnHomeSection
                            .id("open-on-home")
                    }
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
                .task {
                    let sessionsTask = Task { await load() }
                    await loadOpenClaims()
                    await sessionsTask.value
                    if scrollToOpenClaims, store.supportsOpenHomeClaims {
                        withAnimation(.easeInOut) {
                            proxy.scrollTo("open-on-home", anchor: .top)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
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
    private var openOnHomeSection: some View {
        Section {
            if isLoadingClaims {
                ProgressView("Loading open conversations")
            } else if let error = store.openHomeClaimsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout)
                    Button("Retry") { Task { await loadOpenClaims() } }
                }
            } else if let list = store.openHomeClaimList {
                if list.claims.isEmpty {
                    Text("No open conversations on Home.")
                        .font(.callout)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                } else {
                    ForEach(list.claims) { claim in
                        openClaimRow(claim)
                    }
                    if list.claims.contains(where: { $0.claimRef != store.currentHomeClaimRef }) {
                        Button {
                            Task { await store.closeAllOtherOpenHomeClaims() }
                        } label: {
                            Label("Close all others", systemImage: "xmark.circle")
                        }
                        .disabled(store.isClosingOpenHomeClaims)
                        .accessibilityIdentifier("home-open-claims-close-all")
                    }
                }
            } else {
                Text("Open conversations are unavailable.")
                    .font(.callout)
            }
        } header: {
            if let list = store.openHomeClaimList {
                Text("Open on Home (\(list.claims.count) open · max \(list.maxClaims))")
            } else {
                Text("Open on Home")
            }
        }
    }

    private func openClaimRow(_ claim: HomeClientActiveClaim) -> some View {
        let profileLabel = claim.profileLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let openedAt = claim.openedAt ?? claim.createdAt
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profileLabel.isEmpty ? "Home conversation" : profileLabel)
                    .font(.body.weight(.semibold))
                Text(store.openHomeClaimTitles[claim.claimRef] ?? "Untitled conversation")
                    .foregroundStyle(HermesVisualTokens.primaryInk)
                    .lineLimit(2)
                Text("Opened \(openedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
                Text(claim.state.displayName)
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            }
            Spacer(minLength: 4)
            if claim.claimRef == store.currentHomeClaimRef {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Current conversation")
            } else {
                Button("Close") {
                    Task { await store.closeOpenHomeClaim(claim.claimRef) }
                }
                .disabled(store.isClosingOpenHomeClaims)
                .accessibilityLabel("Close conversation for \(claim.profileLabel ?? "Home")")
                .accessibilityIdentifier("home-open-claim-close")
            }
        }
        .padding(.vertical, 3)
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


    private func loadOpenClaims() async {
        isLoadingClaims = true
        await store.loadOpenHomeClaims()
        isLoadingClaims = false
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
