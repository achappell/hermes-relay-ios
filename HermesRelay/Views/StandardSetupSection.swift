import SwiftUI
import Observation

struct StandardSetupDraft: Equatable {
    var endpoint = ""
    var token = ""
    var targetProfile = ""

    init(profile: RelayProfile? = nil) {
        endpoint = profile?.endpoint.absoluteString ?? ""
        targetProfile = profile?.standardProfile ?? ""
    }

    /// A changed connection is a new local identity. Its predecessor remains
    /// selectable, with its credential and transcript untouched.
    func connection(original: RelayProfile?, storedToken: String?) throws -> (profile: RelayProfile, token: String) {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandardSetupError.endpointRequired
        }
        let candidate = try RelayProfile.standard(endpoint: url, targetProfile: targetProfile)
        let endpointChanged = original.map { $0.endpoint != candidate.endpoint } ?? true
        let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointChanged || !enteredToken.isEmpty else {
            throw StandardSetupError.newEndpointNeedsToken
        }
        let resolvedToken = enteredToken.isEmpty ? (storedToken ?? "") : enteredToken
        guard !resolvedToken.isEmpty else { throw StandardSetupError.tokenRequired }
        let identityChanged = endpointChanged
            || original?.standardProfile != candidate.standardProfile
            || (!enteredToken.isEmpty && enteredToken != storedToken)
        let profile = try RelayProfile.standard(
            endpoint: candidate.endpoint,
            targetProfile: candidate.standardProfile ?? "default",
            id: identityChanged ? UUID() : (original?.id ?? UUID()),
            displayName: original?.displayName ?? "Standard Hermes"
        )
        return (profile, resolvedToken)
    }
}

enum StandardSetupError: LocalizedError, Equatable {
    case endpointRequired
    case newEndpointNeedsToken
    case tokenRequired

    var errorDescription: String? {
        switch self {
        case .endpointRequired: "Enter the Standard Hermes WSS endpoint."
        case .newEndpointNeedsToken: "Enter a Standard token for this endpoint. Tokens are never reused at a different endpoint."
        case .tokenRequired: "Add a Standard token."
        }
    }
}

@MainActor
@Observable
final class StandardSetupModel {
    var draft: StandardSetupDraft
    private(set) var hasStoredToken = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private let original: RelayProfile?
    private let store: RelayConfigurationStore
    private let blockedReason: @MainActor () -> String?
    private let beginReconfiguration: @MainActor () async -> Bool
    private let endReconfiguration: @MainActor () -> Void
    private let checkConnection: @Sendable (RelayProfile, String) async throws -> Void

    init(
        profile: RelayProfile? = nil,
        store: RelayConfigurationStore,
        blockedReason: @escaping @MainActor () -> String? = { nil },
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        checkConnection: @escaping @Sendable (RelayProfile, String) async throws -> Void = { profile, token in
            try await StandardSessionClient(profile: profile, token: token).checkConnection()
        }
    ) {
        self.original = profile
        self.store = store
        self.blockedReason = blockedReason
        self.beginReconfiguration = beginReconfiguration
        self.endReconfiguration = endReconfiguration
        self.checkConnection = checkConnection
        draft = StandardSetupDraft(profile: profile)
    }

    func load() async {
        guard let original else { return }
        do {
            hasStoredToken = try await store.loadStandardToken(for: original.id) != nil
        } catch {
            errorMessage = "The Standard token could not be read from Keychain. Enter a replacement."
        }
    }

    func save(onSaved: @MainActor () async -> Void = {}) async -> Bool {
        guard !isSaving else { return false }
        if let reason = blockedReason() { errorMessage = reason; return false }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }
        guard await beginReconfiguration() else {
            errorMessage = blockedReason() ?? "Another connection change is already in progress."
            return false
        }
        defer { endReconfiguration() }
        do {
            let storedToken: String?
            if let original {
                do {
                    storedToken = try await store.loadStandardToken(for: original.id)
                } catch {
                    guard !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
                    storedToken = nil
                }
            } else {
                storedToken = nil
            }
            let connection = try draft.connection(original: original, storedToken: storedToken)
            // Authenticated ping checks readiness without creating a session.
            do {
                try await checkConnection(connection.profile, connection.token)
            } catch {
                errorMessage = "Standard connection check failed. Check the endpoint, token, and network. No conversation was created or prompt sent."
                return false
            }
            if let reason = blockedReason() { errorMessage = reason; return false }
            try await store.saveStandardConnection(connection.profile, token: connection.token)
            draft.token = ""
            hasStoredToken = true
            statusMessage = original.map { $0.id != connection.profile.id } == true
                ? "Saved as a new Standard connection. The earlier connection and its history remain on this device; select it to view that transcript. Nothing was copied."
                : "Standard connection checked and saved. Start a new conversation to begin."
            // The lease must cover the live session switch, not just persistence.
            await onSaved()
            return true
        } catch let error as StandardSetupError {
            errorMessage = error.localizedDescription
        } catch let error as RelayProfileError {
            errorMessage = error.localizedDescription
        } catch let error as RelayConfigurationError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The Standard configuration could not be saved. Check Keychain access and try again."
        }
        return false
    }
}

@MainActor
struct StandardSetupSection: View {
    @State private var model: StandardSetupModel
    let connectionChangeBlockedReason: String?
    let onSaved: @MainActor () async -> Void

    init(
        profile: RelayProfile? = nil,
        configurationStore: RelayConfigurationStore,
        connectionChangeBlockedReason: String? = nil,
        reconfigurationBlockedReason: @escaping @MainActor () -> String? = { nil },
        beginReconfiguration: @escaping @MainActor () async -> Bool = { true },
        endReconfiguration: @escaping @MainActor () -> Void = {},
        onSaved: @escaping @MainActor () async -> Void
    ) {
        _model = State(initialValue: StandardSetupModel(
            profile: profile, store: configurationStore, blockedReason: reconfigurationBlockedReason,
            beginReconfiguration: beginReconfiguration, endReconfiguration: endReconfiguration
        ))
        self.connectionChangeBlockedReason = connectionChangeBlockedReason
        self.onSaved = onSaved
    }

    var body: some View {
        Section {
            LabeledContent("Connection mode", value: "Standard Hermes")
            TextField("wss://hermes-host/api/ws", text: $model.draft.endpoint)
                .autocorrectionDisabled()
                .accessibilityLabel("Standard endpoint")
                .accessibilityIdentifier("standard-endpoint")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            SecureField("Standard token", text: $model.draft.token)
                .autocorrectionDisabled()
                .accessibilityLabel("Standard token")
                .accessibilityIdentifier("standard-token")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
            if model.hasStoredToken {
                Text("Leave the token blank to keep it only at the same endpoint. An endpoint change requires a new token.")
                    .font(.footnote)
            }
            TextField("Hermes target profile (optional; default)", text: $model.draft.targetProfile)
                .autocorrectionDisabled()
                .accessibilityLabel("Hermes target profile, optional")
                .accessibilityIdentifier("standard-target-profile")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HermesVisualTokens.unavailable)
            }
            if let message = model.statusMessage {
                Text(message).font(.footnote)
            }
            Button(model.isSaving ? "Checking Standard connection…" : "Check and save Standard connection") {
                Task {
                    _ = await model.save(onSaved: onSaved)
                }
            }
            .accessibilityIdentifier("save-standard-connection")
            .disabled(model.isSaving || connectionChangeBlockedReason != nil)
        } header: {
            Text("Direct Standard setup")
        } footer: {
            Text("Connect directly to unmodified Hermes over WSS at /api/ws. The authenticated readiness check creates no conversation. Typed text only: Home features and voice are unavailable. Tokens stay in the separate Standard Keychain record. Changing endpoint, target profile, or token creates a new connection and keeps the earlier history with its original connection.")
        }
        .disabled(connectionChangeBlockedReason != nil || model.isSaving)
        .task { await model.load() }
    }
}
