import SwiftUI
import Observation

/// Receives `hermes-home://pair` links opened from outside the app.
@MainActor
@Observable
final class HomePairingLinkInbox {
    var pendingLink: URL?

    init() {}

    /// Accepts only pairing links; any other URL is ignored.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard HomePairingInvitation.isPairingLink(url) else { return false }
        pendingLink = url
        return true
    }

    /// Only an explicit Home setup action consumes a received link. A busy
    /// connection keeps it available for that action to be retried.
    func takePendingLink(blockedReason: String? = nil) -> URL? {
        guard blockedReason == nil else { return nil }
        defer { pendingLink = nil }
        return pendingLink
    }
}

/// One presentation of the pairing sheet for an opened link.
struct HomePairingLinkRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
@Observable
final class HomePairingModel {
    enum Phase: Equatable {
        case entry
        case submitting
        case waiting(confirmationCode: String, home: String)
        case finished(HomeClientPairingSummary)
        case failed(String)
    }

    private(set) var phase: Phase = .entry
    var linkText = ""
    var code = ""
    var homeAddress = ""
    private(set) var entryError: String?
    private(set) var pairings: [HomeClientPairing] = []
    private(set) var isRefreshing = false
    private(set) var isOperating = false

    private let coordinator: HomeClientPairingCoordinator
    private let beginReconfiguration: @MainActor () async -> Bool
    private let endReconfiguration: @MainActor () -> Void
    private let blockedReason: @MainActor () -> String?
    private let onReconfigurationFailure: @MainActor () async -> Void
    private let onPaired: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    init(
        coordinator: HomeClientPairingCoordinator,
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        blockedReason: @escaping @MainActor () -> String? = { nil },
        onReconfigurationFailure: @escaping @MainActor () async -> Void = {},
        onPaired: @escaping @MainActor () async -> Void = {}
    ) {
        self.coordinator = coordinator
        self.beginReconfiguration = beginReconfiguration
        self.endReconfiguration = endReconfiguration
        self.blockedReason = blockedReason
        self.onReconfigurationFailure = onReconfigurationFailure
        self.onPaired = onPaired
    }

    func loadPairings() async {
        pairings = (try? await coordinator.allPairings()) ?? []
    }

    func begin(link: URL) {
        guard !isOperating else { return }
        // A deliberately opened link must remain retryable if the
        // connection becomes busy before its operation acquires the lease.
        linkText = link.absoluteString
        do {
            begin(try HomePairingInvitation(link: link))
        } catch {
            fail(entry: error)
        }
    }

    func beginFromLinkText() {
        guard !isOperating else { return }
        do {
            begin(try HomePairingInvitation(linkText: linkText))
        } catch {
            fail(entry: error)
        }
    }

    func beginFromCode() {
        guard !isOperating else { return }
        do {
            begin(try HomePairingInvitation(code: code, homeAddress: homeAddress))
        } catch {
            fail(entry: error)
        }
    }

    /// Nothing is submitted for malformed input; the message names the
    /// problem.
    func fail(entry error: Error) {
        guard !isOperating else { return }
        entryError = error.localizedDescription
        phase = .entry
    }

    func cancel() {
        task?.cancel()
        phase = .entry
    }

    func startAgain() {
        cancel()
        entryError = nil
        phase = .entry
    }

    func refresh(pairingID: UUID) async {
        guard !isOperating else { return }
        if let reason = blockedReason() {
            entryError = reason
            return
        }
        isOperating = true
        isRefreshing = true
        defer {
            isRefreshing = false
            isOperating = false
        }
        guard await beginReconfiguration() else {
            entryError = blockedReason() ?? "Another connection change is already in progress."
            return
        }
        defer { endReconfiguration() }
        guard !Task.isCancelled else { return }
        if let reason = blockedReason() {
            entryError = reason
            return
        }
        do {
            let summary = try await coordinator.refresh(pairingID: pairingID)
            await finish(summary)
        } catch {
            await loadPairings()
            await onReconfigurationFailure()
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish(_ summary: HomeClientPairingSummary) async {
        await loadPairings()
        if summary.activationFailure == nil,
           summary.grants.contains(where: { $0.profileName != nil }) {
            await onPaired()
        } else if summary.activationFailure != nil {
            await onReconfigurationFailure()
        }
        // Published last, so anything observing `.finished` sees the pairing
        // list and the activation announcement already settled.
        phase = .finished(summary)
    }

    private func begin(_ invitation: HomePairingInvitation) {
        guard !isOperating else { return }
        if let reason = blockedReason() {
            entryError = reason
            return
        }
        isOperating = true
        entryError = nil
        task = Task { [weak self] in
            await self?.run(invitation)
        }
    }

    private func run(_ invitation: HomePairingInvitation) async {
        defer {
            task = nil
            isOperating = false
        }
        guard await beginReconfiguration() else {
            entryError = blockedReason() ?? "Another connection change is already in progress."
            phase = .entry
            return
        }
        defer { endReconfiguration() }
        guard !Task.isCancelled else { return }
        if let reason = blockedReason() {
            entryError = reason
            phase = .entry
            return
        }
        code = ""
        linkText = ""
        phase = .submitting
        do {
            let request = try await coordinator.submit(invitation)
            try Task.checkCancellation()
            if let reason = blockedReason() {
                entryError = reason
                phase = .entry
                return
            }
            phase = .waiting(
                confirmationCode: request.displayConfirmationCode,
                home: invitation.home.displayName
            )
            let summary = try await coordinator.finishPairing(invitation, request: request)
            // A pairing that completed is shown and announced even if the
            // sheet was cancelled meanwhile; the credential is already stored.
            await finish(summary)
        } catch is CancellationError {
            await loadPairings()
            await onReconfigurationFailure()
            phase = .entry
        } catch {
            await loadPairings()
            await onReconfigurationFailure()
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

@MainActor
struct HomePairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: HomePairingModel
    @State private var showingScanner = false
    private let initialLink: URL?

    init(
        coordinator: HomeClientPairingCoordinator,
        initialLink: URL? = nil,
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        blockedReason: @escaping @MainActor () -> String? = { nil },
        onReconfigurationFailure: @escaping @MainActor () async -> Void = {},
        onPaired: @escaping @MainActor () async -> Void = {}
    ) {
        _model = State(initialValue: HomePairingModel(
            coordinator: coordinator,
            beginReconfiguration: beginReconfiguration,
            endReconfiguration: endReconfiguration,
            blockedReason: blockedReason,
            onReconfigurationFailure: onReconfigurationFailure,
            onPaired: onPaired
        ))
        self.initialLink = initialLink
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .entry:
                    entrySections
                case .submitting:
                    Section {
                        ProgressView("Sending the pairing request…")
                    }
                case .waiting(let confirmationCode, let home):
                    waitingSection(confirmationCode: confirmationCode, home: home)
                case .finished(let summary):
                    summarySections(summary)
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                        Button("Start again") { model.startAgain() }
                            .accessibilityIdentifier("home-pairing-start-again")
                    }
                }
            }
            .navigationTitle("Pair with Home")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingScanner) {
                HomePairingScannerView(
                    onLink: { url in
                        showingScanner = false
                        model.begin(link: url)
                    },
                    onUnavailable: { message in
                        showingScanner = false
                        model.fail(entry: HomePairingScannerUnavailable(message: message))
                    }
                )
                .ignoresSafeArea()
            }
            #endif
            .onDisappear {
                // Swiping the sheet away must not leave polling running.
                model.cancel()
            }
            .task {
                await model.loadPairings()
                if let initialLink, model.phase == .entry {
                    model.begin(link: initialLink)
                }
            }
        }
    }

    @ViewBuilder
    private var entrySections: some View {
        if let entryError = model.entryError {
            Section {
                Label(entryError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HermesVisualTokens.unavailable)
                    .accessibilityIdentifier("home-pairing-entry-error")
            }
        }

        #if os(iOS)
        Section {
            Button {
                showingScanner = true
            } label: {
                Label("Scan the QR code", systemImage: "qrcode.viewfinder")
            }
        } footer: {
            Text("Scan the code on the Home pairing page. If the camera is unavailable, enter the code below.")
        }
        #endif

        Section {
            TextField("hermes-home://pair?…", text: $model.linkText)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Pair from link") { model.beginFromLinkText() }
                .disabled(model.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .disabled(model.isOperating)
        } header: {
            Text("Pairing link")
        } footer: {
            Text("Paste the link copied from the Home pairing page.")
        }

        Section {
            TextField("Home address (https://…)", text: $model.homeAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            TextField("Pairing code", text: $model.code)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                #endif
            Button("Pair with code") { model.beginFromCode() }
                .disabled(
                    model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .disabled(model.isOperating)
        } header: {
            Text("Short code")
        } footer: {
            Text("Codes are accepted in any case, with or without the dash.")
        }

        if !model.pairings.isEmpty {
            Section {
                ForEach(model.pairings) { pairing in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pairing.home.displayName)
                            Text(pairing.credentialUsable ? "Paired" : "Pair again to use this Home")
                                .font(.caption)
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                        }
                        Spacer()
                        Button("Refresh") {
                            Task { await model.refresh(pairingID: pairing.id) }
                        }
                        .disabled(model.isOperating || !pairing.credentialUsable)
                    }
                }
            } header: {
                Text("Paired Homes")
            } footer: {
                Text("Refresh after a Profile owner approves this device.")
            }
        }
    }

    private func waitingSection(confirmationCode: String, home: String) -> some View {
        Section {
            Text("Pairing with \(home)")
                .font(.headline)
                .accessibilityIdentifier("home-pairing-home")
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirmation code")
                    .font(.caption)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
                Text(confirmationCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .accessibilityIdentifier("home-pairing-confirmation-code")
            }
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for approval on the Home page")
            }
            Button("Cancel", role: .cancel) { model.cancel() }
        } footer: {
            Text("Check that the Home page shows the same confirmation code before approving.")
        }
    }

    @ViewBuilder
    private func summarySections(_ summary: HomeClientPairingSummary) -> some View {
        Section {
            ForEach(summary.grants) { grant in
                VStack(alignment: .leading, spacing: 2) {
                    Text(grant.profileName ?? grant.label)
                    Text(grantStatusText(grant))
                        .font(.caption)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                }
            }
            if summary.grants.isEmpty {
                Text("Home has not granted any Profiles to this device yet.")
            }
        } header: {
            Text("Paired with \(summary.homeName)")
        }

        if let failure = summary.activationFailure {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HermesVisualTokens.unavailable)
            } footer: {
                Text("Home mode is selected only after the first connection succeeds.")
            }
        }

        Section {
            Button("Refresh") {
                Task { await model.refresh(pairingID: summary.pairingID) }
            }
            .disabled(model.isOperating)
            .accessibilityIdentifier("home-pairing-refresh")
        } footer: {
            Text("A waiting Profile is approved from a device already using it, in Settings → Home pairing. Refresh afterwards.")
        }
    }

    private func grantStatusText(_ grant: HomeClientPairingSummary.Grant) -> String {
        if grant.isWaitingForOwner {
            return "Waiting for the Profile owner to approve"
        }
        if grant.status == .active {
            return grant.available ? "Ready" : "Unavailable on Home right now"
        }
        return "Not available to this device"
    }
}

struct HomePairingScannerUnavailable: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
