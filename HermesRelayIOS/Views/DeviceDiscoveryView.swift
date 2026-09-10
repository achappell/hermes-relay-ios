#if os(iOS)
import Observation
import SwiftUI

@MainActor
struct DeviceDiscoveryView: View {
    let client: any DeviceDiscoveryClient
    let administrationClient: any DeviceAdministrationClient
    let draftStore: any DeviceSetupDraftStore

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceDiscoveryModel
    @State private var isManualPairingPresented = false
    @State private var setupDevice: HouseholdDevice?

    init(
        client: any DeviceDiscoveryClient,
        administrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient(),
        draftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore()
    ) {
        self.client = client
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        _model = State(
            initialValue: DeviceDiscoveryModel(
                client: client,
                administrationClient: administrationClient,
                draftStore: draftStore
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    Text(
                        "Found Devices are not approved. An unconfigured Device "
                            + "stays inert and cannot wake, capture, or access Hermes."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if model.isDiscovering {
                    Section {
                        ProgressView("Searching for Devices…")
                    }
                }

                Section("Approved Devices") {
                    if model.approvedDevices.isEmpty {
                        Text("No approved Devices yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.approvedDevices) { device in
                            let setupStatus = model.setupStatus(for: device)
                            let hasSetupDraft = model.hasSetupDraft(for: device)
                            if setupStatus == .pending {
                                Button {
                                    setupDevice = device
                                } label: {
                                    DeviceDiscoveryRow(
                                        device: device,
                                        connectionState: nil,
                                        isInteractive: true,
                                        setupStatus: setupStatus,
                                        hasSetupDraft: hasSetupDraft
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("approved-device-\(device.id)")
                                .accessibilityHint(
                                    "Continue Room and Wake Mapping setup. The Device remains inactive until Ready."
                                )
                            } else {
                                DeviceDiscoveryRow(
                                    device: device,
                                    connectionState: nil,
                                    isInteractive: false,
                                    setupStatus: setupStatus,
                                    hasSetupDraft: hasSetupDraft
                                )
                            }
                        }
                    }
                }

                Section {
                    if model.discoveredDevices.isEmpty {
                        Text("No unconfigured Devices found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discoveredDevices) { device in
                            let rowAccessibilityIdentifier = "device-\(device.id)"
                            let connectionState = model.connectionState(for: device)
                            let isConnecting = connectionState == .connecting
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    Task { await model.connect(to: device) }
                                } label: {
                                    DeviceDiscoveryRow(
                                        device: device,
                                        connectionState: connectionState,
                                        isInteractive: true,
                                        setupStatus: nil,
                                        hasSetupDraft: false
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isConnecting || model.isApproving)
                                .accessibilityIdentifier(rowAccessibilityIdentifier)
                                .accessibilityHint(
                                    "Connects only to identify this Device. It remains unconfigured."
                                )

                                if connectionState == .connected {
                                    Button {
                                        Task {
                                            if await model.approve(device),
                                               let approvedDevice = model.approvedDevice(for: device) {
                                                setupDevice = approvedDevice
                                            }
                                        }
                                    } label: {
                                        Label(
                                            "Approve and configure",
                                            systemImage: "checkmark.shield"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                    }
                                    .disabled(model.isApproving)
                                    .accessibilityIdentifier("approve-device-\(device.id)")
                                    .accessibilityHint(
                                        "Approves this Device, then opens Room and Wake Mapping setup."
                                    )
                                }
                            }
                        }
                    }
                } header: {
                    Text("Discovered Devices")
                } footer: {
                    Text(
                        "Selecting a Device confirms its identity only. Approval and setup "
                            + "happen in a later step."
                    )
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if model.isManualFallbackAvailable {
                    Section {
                        Button {
                            model.beginManualPairing()
                            isManualPairingPresented = true
                        } label: {
                            Label("Use manual pairing", systemImage: "rectangle.and.pencil.and.ellipsis")
                        }
                    } footer: {
                        Text(
                            "Use the identifier printed on the Device when local discovery "
                                + "is unavailable. This does not approve the Device."
                        )
                    }
                }

                if let statusMessage = model.statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.discover() }
                    } label: {
                        Label("Discover", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isDiscovering)
                }
            }
            .refreshable {
                await model.discover()
            }
            .task {
                await model.discover()
            }
        }
        .sheet(isPresented: $isManualPairingPresented) {
            ManualDevicePairingView(model: model)
        }
        .sheet(item: $setupDevice, onDismiss: {
            Task { await model.refreshSetupDrafts() }
        }) { device in
            DeviceSetupView(
                device: device,
                administrationClient: administrationClient,
                draftStore: draftStore
            ) {
                model.markReady(device)
            }
        }
    }
}

@MainActor
private struct DeviceDiscoveryRow: View {
    let device: HouseholdDevice
    let connectionState: DeviceConnectionState?
    let isInteractive: Bool
    let setupStatus: DeviceSetupStatus?
    let hasSetupDraft: Bool

    private var deviceIcon: String {
        switch device.kind {
        case .puck:
            "circle.fill"
        case .display:
            "rectangle.fill"
        }
    }

    private var trustLabel: String {
        switch device.trustState {
        case .approved:
            "Approved"
        case .unconfigured:
            "Unconfigured and inert"
        }
    }

    private var actionLabel: String {
        if let setupStatus, !setupStatus.isActive {
            return hasSetupDraft ? "Resume setup" : "Set up"
        }
        guard let connectionState else { return "" }
        switch connectionState {
        case .idle:
            return "Identify"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Identify again"
        case .failed:
            return "Retry"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: deviceIcon)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.headline)
                Text("\(device.kind.label) · \(trustLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let connectionState {
                    Label(connectionState.label, systemImage: connectionState.systemImage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let setupStatus {
                    Label(setupStatus.label, systemImage: setupStatus.isActive ? "checkmark.circle.fill" : "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(setupStatus.isActive ? .green : .secondary)
                }
            }

            Spacer(minLength: 8)

            if isInteractive {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(actionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct DeviceSetupView: View {
    let device: HouseholdDevice
    let administrationClient: any DeviceAdministrationClient
    let draftStore: any DeviceSetupDraftStore
    let onReady: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceSetupModel
    @State private var isDiscardConfirmationPresented = false
    @State private var shouldPreserveDraftOnDisappear = true

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        draftStore: any DeviceSetupDraftStore,
        onReady: @escaping @MainActor () -> Void
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.onReady = onReady
        _model = State(
            initialValue: DeviceSetupModel(
                device: device,
                administrationClient: administrationClient,
                draftStore: draftStore
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Label(
                        "Approved, but inactive until setup is complete.",
                        systemImage: "lock.shield"
                    )
                    Text(
                        model.hasDraft
                            ? "Resume this saved setup draft. It remains inactive until Ready."
                            : "Set up \(device.displayName) in this order: Room, Wake Mappings, then Ready."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Setup pending")
                }

                switch model.step {
                case .room:
                    DeviceSetupRoomStep(model: model)
                case .wakeMappings:
                    DeviceSetupWakeMappingsStep(model: model)
                case .ready:
                    DeviceSetupReadyStep(model: model) {
                        onReady()
                        dismiss()
                    }
                case .complete:
                    DeviceSetupCompleteStep(device: device)
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Set Up Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    if model.hasDraft {
                        Button("Discard setup", role: .destructive) {
                            isDiscardConfirmationPresented = true
                        }
                        .disabled(model.isLoadingDraft || model.isSavingDraft || model.isPublishing)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            if await model.preserveDraft() {
                                shouldPreserveDraftOnDisappear = false
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.isLoadingDraft || model.isSavingDraft || model.isPublishing)
                }
            }
            .confirmationDialog(
                "Discard saved setup?",
                isPresented: $isDiscardConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Discard Setup", role: .destructive) {
                    Task {
                        if await model.discardDraft() {
                            shouldPreserveDraftOnDisappear = false
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The saved Room and Wake Mappings will be removed. "
                        + "The Device remains inactive."
                )
            }
            .task {
                await model.loadDraft()
            }
            .onDisappear {
                guard shouldPreserveDraftOnDisappear else { return }
                Task { await model.preserveDraft() }
            }
        }
    }
}

@MainActor
private struct DeviceSetupRoomStep: View {
    @Bindable var model: DeviceSetupModel

    var body: some View {
        Section {
            TextField("Room name", text: $model.room)
                .textInputAutocapitalization(.words)

            Button("Continue to Wake Mappings") {
                model.continueFromRoom()
            }
        } header: {
            Text("1. Room")
        } footer: {
            Text("A Device remains inactive until the complete setup is confirmed.")
        }
    }
}

@MainActor
private struct DeviceSetupWakeMappingsStep: View {
    @Bindable var model: DeviceSetupModel

    var body: some View {
        Section {
            if model.wakeMappings.isEmpty {
                Text("Add at least one Wake Mapping.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($model.wakeMappings) { $mapping in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Wake phrase", text: $mapping.wakePhrase)
                            .textInputAutocapitalization(.sentences)
                        TextField(
                            "Hermes Profile identifier",
                            text: $mapping.profileIdentifier
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)

                        Button("Remove mapping", role: .destructive) {
                            model.removeWakeMapping(id: mapping.id)
                        }
                        .font(.footnote)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Wake Mapping")
                }
            }

            Button {
                model.addWakeMapping()
            } label: {
                Label("Add Wake Mapping", systemImage: "plus")
            }

            Button("Review setup") {
                model.continueFromMappings()
            }

            Button("Back to Room") {
                model.returnToRoom()
            }
        } header: {
            Text("2. Wake Mappings")
        } footer: {
            Text("Each wake phrase must be unique and point to one Hermes Profile identifier.")
        }
    }
}

@MainActor
private struct DeviceSetupReadyStep: View {
    let model: DeviceSetupModel
    let onReady: @MainActor () -> Void

    init(
        model: DeviceSetupModel,
        onReady: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.onReady = onReady
    }

    var body: some View {
        Section {
            LabeledContent("Room", value: model.room)

            ForEach(model.wakeMappings) { mapping in
                VStack(alignment: .leading, spacing: 2) {
                    Text(mapping.wakePhrase)
                        .font(.headline)
                    Text("Profile: \(mapping.profileIdentifier)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Button("Edit Wake Mappings") {
                model.editWakeMappings()
            }
        } header: {
            Text("3. Ready")
        } footer: {
            Text("Confirm only when this Device should become an active household doorway.")
        }

        Section {
            Button {
                Task {
                    if await model.confirmReady() {
                        onReady()
                    }
                }
            } label: {
                if model.isPublishing {
                    ProgressView("Making Device ready…")
                } else {
                    Text("Mark Device Ready")
                }
            }
            .disabled(model.isPublishing)
            .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
private struct DeviceSetupCompleteStep: View {
    let device: HouseholdDevice

    var body: some View {
        Section {
            Label(
                "\(device.displayName) is ready and active.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        }
    }
}

@MainActor
private struct ManualDevicePairingView: View {
    let model: DeviceDiscoveryModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    TextField("Device identifier", text: $model.manualIdentifier)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                } header: {
                    Text("Identify a Device")
                } footer: {
                    Text(
                        "Enter the identifier printed on the Device. Identification keeps "
                            + "the Device unconfigured until you explicitly approve it."
                    )
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await model.submitManualPairing() {
                                dismiss()
                            }
                        }
                    } label: {
                        if model.isPairingManually {
                            ProgressView("Identifying Device…")
                        } else {
                            Text("Identify Device")
                        }
                    }
                    .disabled(
                        model.isPairingManually
                            || model.manualIdentifier.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
            .navigationTitle("Manual Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
