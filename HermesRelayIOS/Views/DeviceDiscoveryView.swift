#if os(iOS)
import Observation
import SwiftUI

@MainActor
struct DeviceDiscoveryView: View {
    let client: any DeviceDiscoveryClient

    @Environment(\.dismiss) private var dismiss
    @State private var model: DeviceDiscoveryModel
    @State private var isManualPairingPresented = false

    init(client: any DeviceDiscoveryClient) {
        self.client = client
        _model = State(initialValue: DeviceDiscoveryModel(client: client))
    }

    var body: some View {
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
                            DeviceDiscoveryRow(
                                device: device,
                                connectionState: nil,
                                isInteractive: false
                            )
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
                            Button {
                                Task { await model.connect(to: device) }
                            } label: {
                                DeviceDiscoveryRow(
                                    device: device,
                                    connectionState: connectionState,
                                    isInteractive: true
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isConnecting)
                            .accessibilityIdentifier(rowAccessibilityIdentifier)
                            .accessibilityHint(
                                "Connects only to identify this Device. It remains unconfigured."
                            )
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
    }
}

@MainActor
private struct DeviceDiscoveryRow: View {
    let device: HouseholdDevice
    let connectionState: DeviceConnectionState?
    let isInteractive: Bool

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
