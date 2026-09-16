#if os(iOS)
import Observation
import SwiftUI

@MainActor
struct DeviceDiscoveryView: View {
    private enum PresentedSheet: Identifiable {
        case manualPairing
        case setup(HouseholdDevice)
        case reenrollment(HouseholdDevice)
        case configuration(HouseholdDevice)

        var id: String {
            switch self {
            case .manualPairing:
                "manual-pairing"
            case let .setup(device):
                "setup-\(device.id)"
            case let .reenrollment(device):
                "reenrollment-\(device.id)"
            case let .configuration(device):
                "configuration-\(device.id)"
            }
        }
    }

    let client: any DeviceDiscoveryClient
    let administrationClient: any DeviceAdministrationClient
    let draftStore: any DeviceSetupDraftStore
    let configurationStore: any DeviceConfigurationStore
    let homeServiceClient: (any HomeServiceClient)?

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceDiscoveryModel
    @State private var presentedSheet: PresentedSheet?

    init(
        client: any DeviceDiscoveryClient,
        administrationClient: any DeviceAdministrationClient = UnavailableDeviceAdministrationClient(),
        draftStore: any DeviceSetupDraftStore = NoopDeviceSetupDraftStore(),
        configurationStore: any DeviceConfigurationStore = NoopDeviceConfigurationStore(),
        homeServiceClient: (any HomeServiceClient)? = nil
    ) {
        self.client = client
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.configurationStore = configurationStore
        self.homeServiceClient = homeServiceClient
        _model = State(
            initialValue: DeviceDiscoveryModel(
                client: client,
                administrationClient: administrationClient,
                draftStore: draftStore,
                configurationStore: configurationStore
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    Label(
                        "Discovery confirms identity only. Approval and setup are separate; an unconfigured Device remains inert.",
                        systemImage: "info.circle"
                    )
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                }

                if model.isDiscovering {
                    Section {
                        ProgressView("Searching for Devices…")
                    }
                }

                if model.isVerifying {
                    Section {
                        ProgressView("Verifying approved Devices…")
                    }
                }

                Section("Approved Devices") {
                    if model.approvedDevices.isEmpty {
                        ContentUnavailableView {
                            Label("No approved Devices yet", systemImage: "checkmark.shield")
                        } description: {
                            Text("Discover a Device below, identify it, then approve and configure it.")
                        }
                    } else {
                        ForEach(model.approvedDevices) { device in
                            let setupStatus = model.setupStatus(for: device)
                            let hasSetupDraft = model.hasSetupDraft(for: device)
                            if setupStatus == .pending {
                                Button {
                                    presentedSheet = .setup(device)
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
                            } else if setupStatus == .revocationPending,
                                      model.configurationState(for: device) != nil {
                                Button {
                                    presentedSheet = .configuration(device)
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
                                .accessibilityIdentifier("pending-revocation-device-\(device.id)")
                                .accessibilityHint(
                                    "Retries Device access revocation. The Device remains unavailable until revocation is confirmed."
                                )
                            } else if setupStatus == .revoked {
                                Button {
                                    Task {
                                        if await model.reEnroll(device) {
                                            presentedSheet = .reenrollment(device)
                                        }
                                    }
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
                                .disabled(model.isReenrolling)
                                .accessibilityIdentifier("reenroll-device-\(device.id)")
                                .accessibilityHint(
                                    "Requests a new Device credential. Room, Wake Mapping, and Ready setup are still required."
                                )
                            } else if let setupStatus,
                                      setupStatus.isActive,
                                      model.configurationState(for: device) != nil {
                                Button {
                                    presentedSheet = .configuration(device)
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
                                .accessibilityIdentifier("configured-device-\(device.id)")
                                .accessibilityHint(
                                    "Edit Wake Mappings. The current verified mapping remains active until an update is published."
                                )
                            } else if let setupStatus,
                                      setupStatus.canVerify,
                                      model.configurationState(for: device) != nil {
                                Button {
                                    Task { await model.verify(device) }
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
                                .disabled(model.isVerifying)
                                .accessibilityIdentifier("verify-device-\(device.id)")
                                .accessibilityHint(
                                    "Verifies the Device identity and mapped Profiles before restoring Ready state."
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
                    if !model.isDiscovering,
                       model.discoveredDevices.isEmpty,
                       model.discoveryErrorMessage == nil {
                        ContentUnavailableView {
                            Label(
                                "No unconfigured Devices found",
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                        } description: {
                            Text("Tap Discover to scan the local network for a Device to identify.")
                        }
                    } else if !model.discoveredDevices.isEmpty {
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
                                                presentedSheet = .setup(approvedDevice)
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
                        "Identify confirms the Device only. Approval opens the ordered Room and Wake Mapping setup."
                    )
                }

                if let discoveryErrorMessage = model.discoveryErrorMessage {
                    Section {
                        Label(discoveryErrorMessage, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                        Button {
                            Task { await model.discover() }
                        } label: {
                            Label("Retry discovery", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isDiscovering)
                        .accessibilityIdentifier("retry-device-discovery")
                    } header: {
                        Text("Discovery unavailable")
                    }
                } else if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                    }
                }

                if model.isManualFallbackAvailable {
                    Section {
                        Button {
                            model.beginManualPairing()
                            presentedSheet = .manualPairing
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
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
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
                    .accessibilityIdentifier("discover-devices")
                }
            }
            .refreshable {
                await model.discover()
            }
            .task {
                await model.discover()
            }
        }
        .sheet(item: $presentedSheet, onDismiss: {
            Task { await model.refreshSetupDrafts() }
        }) { sheet in
            switch sheet {
            case .manualPairing:
                ManualDevicePairingView(model: model)
            case let .setup(device):
                DeviceSetupView(
                    device: device,
                    administrationClient: administrationClient,
                    draftStore: draftStore,
                    configurationStore: configurationStore,
                    homeServiceClient: homeServiceClient
                ) {
                    model.markReady(device)
                }
            case let .reenrollment(device):
                DeviceSetupView(
                    device: device,
                    administrationClient: administrationClient,
                    draftStore: draftStore,
                    configurationStore: configurationStore,
                    homeServiceClient: homeServiceClient,
                    isReenrollment: true
                ) {
                    model.markReady(device)
                }
            case let .configuration(device):
                DeviceConfigurationView(
                    device: device,
                    administrationClient: administrationClient,
                    configurationStore: configurationStore,
                    homeServiceClient: homeServiceClient
                )
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
        if let setupStatus {
            if setupStatus.canVerify {
                return setupStatus == .verificationRequired ? "Verify" : "Retry"
            }
            if setupStatus == .revocationPending {
                return "Retry Disconnect"
            }
            if setupStatus == .revoked {
                return "Re-enroll required"
            }
            if !setupStatus.isActive {
                return hasSetupDraft ? "Resume setup" : "Set up"
            }
            return setupStatus == .updatePending ? "Review update" : "Edit"
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
                .foregroundStyle(HermesVisualTokens.secondaryInk)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.headline)
                Text("\(device.kind.label) · \(trustLabel)")
                    .font(.subheadline)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)

                if let connectionState {
                    Label(connectionState.label, systemImage: connectionState.systemImage)
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                }

                if let setupStatus {
                    Label(setupStatus.label, systemImage: setupStatus.isActive ? "checkmark.circle.fill" : "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(setupStatus.isActive ? HermesVisualTokens.live : HermesVisualTokens.secondaryInk)
                }
            }

            Spacer(minLength: 8)

            if isInteractive {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(actionLabel)
                        .font(.caption)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HermesVisualTokens.secondaryInk.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

@MainActor
private struct DeviceSetupView: View {
    let device: HouseholdDevice
    let administrationClient: any DeviceAdministrationClient
    let draftStore: any DeviceSetupDraftStore
    let configurationStore: any DeviceConfigurationStore
    let homeServiceClient: (any HomeServiceClient)?
    let isReenrollment: Bool
    let onReady: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceSetupModel
    @State private var isDiscardConfirmationPresented = false
    @State private var shouldPreserveDraftOnDisappear = true

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        draftStore: any DeviceSetupDraftStore,
        configurationStore: any DeviceConfigurationStore,
        homeServiceClient: (any HomeServiceClient)? = nil,
        isReenrollment: Bool = false,
        onReady: @escaping @MainActor () -> Void
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.draftStore = draftStore
        self.configurationStore = configurationStore
        self.homeServiceClient = homeServiceClient
        self.isReenrollment = isReenrollment
        self.onReady = onReady
        _model = State(
            initialValue: DeviceSetupModel(
                device: device,
                administrationClient: administrationClient,
                draftStore: draftStore,
                configurationStore: configurationStore,
                homeServiceClient: homeServiceClient
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Label(
                        isReenrollment
                            ? "New access is approved, but this Device remains inactive until setup is complete."
                            : "Approved, but inactive until setup is complete.",
                        systemImage: "lock.shield"
                    )
                    Text(
                        model.hasDraft
                            ? "Resume this saved setup draft. It remains inactive until Ready."
                            : isReenrollment
                                ? "Re-enroll \(device.displayName) in this order: Room, Wake Mappings, then Ready."
                                : "Set up \(device.displayName) in this order: Room, Wake Mappings, then Ready."
                    )
                        .font(.footnote)
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                } header: {
                    Text(isReenrollment ? "Re-enrollment pending" : "Setup pending")
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
                            .foregroundStyle(HermesVisualTokens.unavailable)
                    }
                }

                if let homeStatusMessage = model.homeStatusMessage {
                    Section("Home configuration") {
                        Label(homeStatusMessage, systemImage: "house")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    }
                }
            }
            .navigationTitle(isReenrollment ? "Re-enroll Device" : "Set Up Device")
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
            if model.isHomeBacked, !model.homeRooms.isEmpty {
                Picker("Room", selection: $model.room) {
                    ForEach(model.homeRooms, id: \.id) { room in
                        Text(room.name).tag(room.id)
                    }
                }
            } else {
                TextField("Room name", text: $model.room)
                    .textInputAutocapitalization(.words)
            }

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
            if model.isHomeBacked {
                if model.wakeMappings.isEmpty {
                    Text("Home has no canonical Wake Mappings for this Device.")
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                } else {
                    ForEach(model.wakeMappings) { mapping in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.wakePhrase)
                                .font(.headline)
                            Text("Home mapping: \(mapping.canonicalID?.rawValue ?? "unknown")")
                                .font(.subheadline)
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                            Text("Profile: \(mapping.profileIdentifier)")
                                .font(.subheadline)
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Home owns these household mappings. Their names, IDs, and Profile assignment are read-only here.")
                    .font(.footnote)
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
            } else if model.wakeMappings.isEmpty {
                Text("Add at least one Wake Mapping.")
                    .foregroundStyle(HermesVisualTokens.secondaryInk)
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

            if !model.isHomeBacked {
                Button {
                    model.addWakeMapping()
                } label: {
                    Label("Add Wake Mapping", systemImage: "plus")
                }
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
                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                }
                .accessibilityElement(children: .combine)
            }

            if !model.isHomeBacked {
                Button("Edit Wake Mappings") {
                    model.editWakeMappings()
                }
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
            .foregroundStyle(HermesVisualTokens.live)
        }
    }
}

@MainActor
private struct DeviceConfigurationView: View {
    let device: HouseholdDevice
    let administrationClient: any DeviceAdministrationClient
    let configurationStore: any DeviceConfigurationStore
    let homeServiceClient: (any HomeServiceClient)?

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceConfigurationModel
    @State private var isDisconnectConfirmationPresented = false

    init(
        device: HouseholdDevice,
        administrationClient: any DeviceAdministrationClient,
        configurationStore: any DeviceConfigurationStore,
        homeServiceClient: (any HomeServiceClient)? = nil
    ) {
        self.device = device
        self.administrationClient = administrationClient
        self.configurationStore = configurationStore
        self.homeServiceClient = homeServiceClient
        _model = State(
            initialValue: DeviceConfigurationModel(
                device: device,
                administrationClient: administrationClient,
                configurationStore: configurationStore,
                homeServiceClient: homeServiceClient
            )
        )
    }

    private var accessStatusText: String {
        switch model.identityStatus {
        case .verified:
            model.publicationStatus == .verified
                ? "Verified configuration is active."
                : "Update pending. The current verified mapping remains active."
        case .verificationRequired:
            "Device verification is required. It remains inactive."
        case .unavailable:
            "Device access is unavailable. It remains inactive."
        case .revocationPending:
            "Disconnect is pending. The Device remains inactive until revocation is confirmed."
        case .revoked:
            "Device access is revoked. Explicit re-enrollment is required."
        }
    }

    private var accessStatusIcon: String {
        switch model.identityStatus {
        case .verified:
            model.publicationStatus == .verified ? "checkmark.shield" : "clock.arrow.circlepath"
        case .verificationRequired, .unavailable:
            "exclamationmark.shield"
        case .revocationPending:
            "clock.badge.xmark"
        case .revoked:
            "lock.slash"
        }
    }

    private var canEditConfiguration: Bool {
        model.identityStatus.isOperational && !model.isRevoking
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Label(
                        accessStatusText,
                        systemImage: accessStatusIcon
                    )
                    LabeledContent("Access", value: model.identityStatus.label)
                    if model.isHomeBacked, !model.homeRooms.isEmpty {
                        Picker("Room", selection: $model.room) {
                            ForEach(model.homeRooms, id: \.id) { room in
                                Text(room.name).tag(room.id)
                            }
                        }
                    } else {
                        LabeledContent("Room", value: model.room)
                    }
                } header: {
                    Text(device.displayName)
                } footer: {
                    Text(
                        "A Wake Mapping is not applied until the Device accepts the exact Profile-specific configuration."
                    )
                }

                if homeServiceClient != nil {
                    Section {
                        if let revision = model.homeConfigurationRevision {
                            LabeledContent("Revision", value: "\(revision)")
                        }
                        if let homeStatusMessage = model.homeStatusMessage {
                            Label(homeStatusMessage, systemImage: "house")
                                .font(.footnote)
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                        }
                        Button("Reload Home configuration") {
                            Task { _ = await model.reloadHomeConfiguration() }
                        }
                    } header: {
                        Text("Home configuration")
                    } footer: {
                        Text("Home owns the household snapshot and wake arbitration. Reload before retrying a stale publish.")
                    }
                }

                Section {
                    if model.identityStatus == .revoked {
                        Label(
                            "Re-enrollment is required before this Device can be configured again.",
                            systemImage: "lock.slash"
                        )
                    } else {
                        Button(role: .destructive) {
                            isDisconnectConfirmationPresented = true
                        } label: {
                            if model.isRevoking {
                                ProgressView("Disconnecting Device…")
                            } else {
                                Label(
                                    model.identityStatus == .revocationPending
                                        ? "Retry Disconnect"
                                        : "Disconnect Device",
                                    systemImage: "minus.circle"
                                )
                            }
                        }
                        .disabled(model.isRevoking)
                    }
                } header: {
                    Text("Device access")
                } footer: {
                    Text(
                        "Disconnect revokes the Device Credential and Hermes access. "
                            + "The Device stays inactive until explicit re-enrollment and setup are complete."
                    )
                }

                Section {
                    if model.isHomeBacked {
                        if model.homeMappingCatalog.isEmpty {
                            Text("Home has no canonical Wake Mappings for this Device.")
                                .foregroundStyle(HermesVisualTokens.secondaryInk)
                        } else {
                            ForEach(model.homeMappingCatalog) { mapping in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mapping.wakePhrase)
                                        .font(.headline)
                                    Text("Home mapping: \(mapping.id.rawValue)")
                                        .font(.subheadline)
                                        .foregroundStyle(HermesVisualTokens.secondaryInk)
                                    if let profile = model.verifiedConfiguration.profileIdentifier {
                                        Text("Profile: \(profile)")
                                            .font(.subheadline)
                                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Text("Home owns these household mappings. Their names, IDs, and Profile assignment are read-only here.")
                            .font(.footnote)
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
                    } else if model.wakeMappings.isEmpty {
                        Text("Add at least one Wake Mapping.")
                            .foregroundStyle(HermesVisualTokens.secondaryInk)
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
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Wake Mapping")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.removeWakeMapping(id: mapping.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }

                    if !model.isHomeBacked {
                        Button {
                            model.wakeMappings.append(DeviceWakeMapping())
                        } label: {
                            Label("Add Wake Mapping", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("Wake Mappings")
                } footer: {
                    Text(
                        model.isHomeBacked
                            ? "Home's global catalog is read-only on the Device editor."
                            : "Each wake phrase must be unique and point to one Hermes Profile identifier."
                    )
                }
                .disabled(!canEditConfiguration)

                Section {
                    Button {
                        Task { _ = await model.publish() }
                    } label: {
                        if model.isPublishing {
                            ProgressView("Publishing mapping…")
                        } else {
                            Text("Publish mapping update")
                        }
                    }
                    .disabled(!canEditConfiguration || model.isPublishing)
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HermesVisualTokens.unavailable)
                    }
                }
            }
            .navigationTitle("Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Disconnect \(device.displayName)?",
                isPresented: $isDisconnectConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Disconnect Device", role: .destructive) {
                    Task {
                        if await model.revoke() {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This revokes the Device Credential and Hermes access. "
                        + "The Device will remain inactive until you explicitly re-enroll and complete setup."
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await model.load()
            }
            .onDisappear {
                Task { _ = await model.preservePending() }
            }
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
                            .foregroundStyle(HermesVisualTokens.unavailable)
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
