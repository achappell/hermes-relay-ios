import SwiftUI
import Observation

/// One paired Home's owner tasks: decide other devices' requests for the
/// Profiles this device holds, see and revoke holders, and forget the Home.
@MainActor
@Observable
final class HomeOwnerAdministrationModel {
    enum LoadState: Equatable {
        case loading
        case loaded(HomeProfileOwnerOverview)
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    /// The grant whose decision or revoke is in flight.
    private(set) var busyGrantID: String?
    /// The outcome of the last action, shown until the next one.
    private(set) var actionMessage: String?
    private(set) var actionFailed = false
    private(set) var isUnpairing = false
    private(set) var unpairError: String?

    let homeName: String
    private let pairingID: UUID
    private let coordinator: HomeClientPairingCoordinator
    private let performUnpair: @MainActor () async throws -> Void
    /// Counts loads so an older one that answers late cannot replace a newer
    /// answer, such as the list refreshed after a decision.
    private var loadGeneration = 0

    init(
        pairingID: UUID,
        homeName: String,
        coordinator: HomeClientPairingCoordinator,
        performUnpair: @escaping @MainActor () async throws -> Void
    ) {
        self.pairingID = pairingID
        self.homeName = homeName
        self.coordinator = coordinator
        self.performUnpair = performUnpair
    }

    var isBusy: Bool { busyGrantID != nil || isUnpairing }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if case .failed = state { state = .loading }
        do {
            let overview = try await coordinator.ownerOverview(pairingID: pairingID)
            guard generation == loadGeneration else { return }
            state = .loaded(overview)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func decide(_ grant: HomeProfileGrantHolder, _ action: HomeProfileGrantAction) async {
        guard !isBusy else { return }
        busyGrantID = grant.grantID
        defer { busyGrantID = nil }
        do {
            _ = try await coordinator.decideProfileGrant(
                pairingID: pairingID,
                grantID: grant.grantID,
                action: action
            )
            actionFailed = false
            actionMessage = Self.successMessage(for: grant, action)
        } catch is CancellationError {
            return
        } catch {
            actionFailed = true
            actionMessage = error.localizedDescription
        }
        await load()
    }

    /// True when the Home was forgotten and the screen should close.
    func unpair() async -> Bool {
        guard !isBusy else { return false }
        isUnpairing = true
        defer { isUnpairing = false }
        do {
            try await performUnpair()
            unpairError = nil
            return true
        } catch {
            unpairError = error.localizedDescription
            return false
        }
    }

    static func successMessage(for grant: HomeProfileGrantHolder, _ action: HomeProfileGrantAction) -> String {
        switch action {
        case .approve:
            return "\(grant.deviceLabel) can now use \(grant.profileLabel)."
        case .reject:
            return "\(grant.deviceLabel)'s request for \(grant.profileLabel) was rejected."
        case .revoke:
            return "\(grant.deviceLabel) no longer has access to \(grant.profileLabel)."
        }
    }

    static func deviceTypeName(_ type: String) -> String {
        switch type {
        case "ios": return "iPhone or iPad"
        case "macos": return "Mac"
        case "android": return "Android"
        case "tui": return "Terminal"
        default: return type.isEmpty ? "Device" : type.capitalized
        }
    }
}

@MainActor
struct HomeOwnerAdministrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: HomeOwnerAdministrationModel
    @State private var revokeCandidate: HomeProfileGrantHolder?
    @State private var confirmingUnpair = false

    init(model: HomeOwnerAdministrationModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            if let message = model.actionMessage {
                Section {
                    Label(message, systemImage: model.actionFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(model.actionFailed ? HermesVisualTokens.unavailable : HermesVisualTokens.secondaryInk)
                        .accessibilityIdentifier("home-owner-action-message")
                }
            }
            switch model.state {
            case .loading:
                Section { ProgressView("Checking Home…") }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HermesVisualTokens.unavailable)
                    Button("Retry") { Task { await model.load() } }
                        .accessibilityIdentifier("home-owner-retry")
                }
            case .loaded(let overview):
                if overview.holders.isEmpty && overview.pending.isEmpty {
                    Section {
                        Text("This device doesn't hold a Profile on this Home yet, so there is nothing to approve. Once Home grants this device a Profile, requests from other devices for it appear here.")
                            .font(.callout)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                } else {
                    pendingSection(overview.pending)
                    ForEach(overview.holderGroups) { group in
                        holderSection(profileLabel: group.profileLabel, holders: group.holders)
                    }
                }
            }
            unpairSection
        }
        .navigationTitle(model.homeName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("home-owner-refresh")
            }
        }
        .confirmationDialog(
            "Remove access?",
            isPresented: Binding(
                get: { revokeCandidate != nil },
                set: { if !$0 { revokeCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: revokeCandidate
        ) { holder in
            Button("Revoke \(holder.deviceLabel)", role: .destructive) {
                Task { await model.decide(holder, .revoke) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { holder in
            Text("\(holder.deviceLabel) will stop using \(holder.profileLabel) immediately and must be approved again to return.")
        }
        .confirmationDialog(
            "Unpair \(model.homeName)?",
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                Task {
                    if await model.unpair() { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Home's saved profiles, their conversations on this device, and its credential. Home keeps listing this device until it is removed on the Home page.")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func pendingSection(_ pending: [HomeProfileGrantHolder]) -> some View {
        Section {
            if pending.isEmpty {
                Text("No devices are waiting for your approval.")
                    .font(.callout)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            } else {
                ForEach(pending) { grant in
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(grant.deviceLabel)
                                .font(.headline)
                            Text("\(HomeOwnerAdministrationModel.deviceTypeName(grant.deviceType)) · wants \(grant.profileLabel)")
                                .font(.subheadline)
                            if let createdAt = grant.createdAt {
                                Text("Requested \(createdAt, format: .relative(presentation: .named))")
                                    .font(.caption)
                                    .foregroundStyle(HermesVisualTokens.secondaryInk)
                            }
                        }
                        HStack {
                            Button("Approve") { Task { await model.decide(grant, .approve) } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("home-owner-approve")
                            Button("Reject", role: .destructive) { Task { await model.decide(grant, .reject) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("home-owner-reject")
                            if model.busyGrantID == grant.grantID {
                                ProgressView()
                            }
                        }
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Waiting for your approval")
        } footer: {
            Text("Check that you recognise the device before approving. Requests expire after 24 hours.")
        }
    }

    private func holderSection(profileLabel: String, holders: [HomeProfileGrantHolder]) -> some View {
        Section {
            ForEach(holders) { holder in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holder.isThisDevice ? "\(holder.deviceLabel) (this device)" : holder.deviceLabel)
                        Text(holderDetail(holder))
                            .font(.caption)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                    Spacer()
                    if model.busyGrantID == holder.grantID {
                        ProgressView()
                    } else if !holder.isThisDevice && !holder.isPending {
                        Button("Revoke", role: .destructive) { revokeCandidate = holder }
                            .buttonStyle(.borderless)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("home-owner-revoke")
                    }
                }
            }
        } header: {
            Text("Devices using \(profileLabel)")
        }
    }

    private func holderDetail(_ holder: HomeProfileGrantHolder) -> String {
        var parts = [HomeOwnerAdministrationModel.deviceTypeName(holder.deviceType)]
        if holder.isPending { parts.append("Waiting for approval") }
        if holder.bootstrap { parts.append("First device, approved on the Home page") }
        return parts.joined(separator: " · ")
    }

    private var unpairSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingUnpair = true
            } label: {
                if model.isUnpairing {
                    ProgressView()
                } else {
                    Label("Unpair this Home", systemImage: "house.slash")
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("home-owner-unpair")
            if let unpairError = model.unpairError {
                Label(unpairError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HermesVisualTokens.unavailable)
            }
        } footer: {
            Text("Unpairing forgets this Home on this device. To remove the device from Home as well, use the Home page.")
        }
    }
}
