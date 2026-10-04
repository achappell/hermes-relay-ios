import SwiftUI

extension EnvironmentValues {
    @Entry var automaticDiagnostics: AutomaticDiagnosticsReporter? = nil
}

struct AutomaticDiagnosticsSettings: View {
    let reporter: AutomaticDiagnosticsReporter
    @State private var homes: [HomeDiagnosticSetting] = []
    @State private var error: String?
    @State private var updating = false

    var body: some View {
        Section {
            if homes.isEmpty {
                Text("Pair with Home to send connection reports automatically.")
                    .foregroundStyle(.secondary)
            }
            ForEach(homes) { home in
                Toggle(isOn: Binding(get: { home.enabled }, set: { enabled in
                    updating = true
                    Task {
                        do {
                            try await reporter.setEnabled(enabled, pairingID: home.id)
                            try await reload()
                        } catch { self.error = "The reporting setting could not be saved. Try again." }
                        updating = false
                    }
                })) {
                    Text("Send connection reports to \(home.name)")
                }
                .disabled(updating)
                if home.enabled {
                    Text(home.pending > 0 ? "\(home.pending) report(s) waiting to send." : "No reports waiting to send.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let sent = home.lastSent {
                        Text("Last sent: \(sent.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Automatic connection reports")
        } footer: {
            Text("Sends connection errors, timing, app version, and device model to your Home, with random connection and request identifiers so Home can match them to its own records. No messages, audio, or passwords. Reports survive quitting and retry while the app is open. Unsent reports and Home copies expire after seven days. Turning this off deletes unsent reports; copies already sent expire on Home.")
        }
        .task {
            while !Task.isCancelled {
                if !updating {
                    do { try await reload() }
                    catch { self.error = "Home reporting settings could not be loaded." }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func reload() async throws {
        homes = try await reporter.settings()
        error = await reporter.storageFailed ? "Reports could not be saved on this device." : nil
    }
}
