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
        case waiting(confirmationCode: String)
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

    private let coordinator: HomeClientPairingCoordinator
    private let onPaired: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    init(
        coordinator: HomeClientPairingCoordinator,
        onPaired: @escaping @MainActor () async -> Void = {}
    ) {
        self.coordinator = coordinator
        self.onPaired = onPaired
    }

    func loadPairings() async {
        pairings = (try? await coordinator.allPairings()) ?? []
    }

    func begin(link: URL) {
        do {
            begin(try HomePairingInvitation(link: link))
        } catch {
            fail(entry: error)
        }
    }

    func beginFromLinkText() {
        do {
            begin(try HomePairingInvitation(linkText: linkText))
        } catch {
            fail(entry: error)
        }
    }

    func beginFromCode() {
        do {
            begin(try HomePairingInvitation(code: code, homeAddress: homeAddress))
        } catch {
            fail(entry: error)
        }
    }

    /// Nothing is submitted for malformed input; the message names the
    /// problem.
    func fail(entry error: Error) {
        entryError = error.localizedDescription
        phase = .entry
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .entry
    }

    func startAgain() {
        task?.cancel()
        task = nil
        entryError = nil
        phase = .entry
    }

    func refresh(pairingID: UUID) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await coordinator.refresh(pairingID: pairingID)
            phase = .finished(summary)
            await loadPairings()
            if summary.activationFailure == nil,
               summary.grants.contains(where: { $0.profileName != nil }) {
                await onPaired()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func begin(_ invitation: HomePairingInvitation) {
        entryError = nil
        code = ""
        linkText = ""
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(invitation)
        }
    }

    private func run(_ invitation: HomePairingInvitation) async {
        phase = .submitting
        do {
            let request = try await coordinator.submit(invitation)
            phase = .waiting(confirmationCode: request.displayConfirmationCode)
            let summary = try await coordinator.finishPairing(invitation, request: request)
            guard !Task.isCancelled else { return }
            phase = .finished(summary)
            await loadPairings()
            if summary.activationFailure == nil,
               summary.grants.contains(where: { $0.profileName != nil }) {
                await onPaired()
            }
        } catch is CancellationError {
            phase = .entry
        } catch {
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
        onPaired: @escaping @MainActor () async -> Void = {}
    ) {
        _model = State(initialValue: HomePairingModel(coordinator: coordinator, onPaired: onPaired))
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
                case .waiting(let confirmationCode):
                    waitingSection(confirmationCode: confirmationCode)
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
                        .disabled(model.isRefreshing || !pairing.credentialUsable)
                    }
                }
            } header: {
                Text("Paired Homes")
            } footer: {
                Text("Refresh after a Profile owner approves this device.")
            }
        }
    }

    private func waitingSection(confirmationCode: String) -> some View {
        Section {
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
            .disabled(model.isRefreshing)
            .accessibilityIdentifier("home-pairing-refresh")
        } footer: {
            Text("Refresh after a Profile owner approves a waiting grant.")
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
