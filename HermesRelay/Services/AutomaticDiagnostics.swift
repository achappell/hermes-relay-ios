import Foundation

/// Only typed, content-free fields cross the upload boundary. Raw journal strings never do.
struct ClientDiagnosticEvent: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable {
        case launch, active, inactive, background
        case connectionLost = "connection_lost"
        case connectionReady = "connection_ready"
        case connectionFailed = "connection_failed"
        case requestStarted = "request_started"
        case requestCompleted = "request_completed"
        case requestFailed = "request_failed"
    }
    let time: Double
    let name: Name
    let launchID: UUID
    var code: String?
    var durationMS: Int?
    var phase: String?
    var uncertain: Bool?
    enum CodingKeys: String, CodingKey {
        case time, name, code, phase, uncertain
        case launchID = "launch_id", durationMS = "duration_ms"
    }
    static let allowedCodes: Set<String> = ["unknown", "transport_unavailable", "transport_timeout", "hermes_unavailable", "protocol_error", "conversation_mismatch", "stale_conversation", "request_rejected", "reconnect_required", "unauthorized", "forbidden", "capability_unavailable", "invalid_request"]
}

struct ClientDiagnosticReport: Codable, Equatable, Sendable, Identifiable {
    let schema: Int
    let id: UUID
    let createdAt: Double
    let appVersion: String
    let build: String
    let platform: String
    let osVersion: String
    let model: String
    let events: [ClientDiagnosticEvent]
    enum CodingKeys: String, CodingKey {
        case schema, build, platform, model, events
        case id = "report_id", createdAt = "created_at", appVersion = "app_version", osVersion = "os_version"
    }

    static func make(events: [ClientDiagnosticEvent], now: Date) -> Self {
        let header = DiagnosticsHeader.current(now: now)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        func safeVersion(_ value: String) -> String {
            value.range(of: #"^[0-9]{1,8}(\.[0-9]{1,8}){0,3}$"#, options: .regularExpression) != nil ? value : "0"
        }
        let model = header.model.range(of: #"^(?:(?:iPhone|iPad|Mac)[0-9]{1,3},[0-9]{1,3}|arm64|x86_64)$"#, options: .regularExpression) != nil ? header.model : "unknown"
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return Self(schema: 1, id: UUID(), createdAt: now.timeIntervalSince1970,
                    appVersion: safeVersion(header.appVersion), build: safeVersion(header.build),
                    platform: platform, osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    model: model, events: events)
    }
}

struct HomeDiagnosticSetting: Identifiable, Sendable {
    let id: UUID
    let name: String
    let enabled: Bool
    let pending: Int
    let lastSent: Date?
}

actor AutomaticDiagnosticsReporter {
    typealias Pairings = @Sendable () async throws -> [HomeClientPairing]
    typealias Upload = @Sendable (HomeClientPairing, ClientDiagnosticReport) async throws -> Void
    private struct HomeState: Codable {
        let origin: HomeClientBaseURL
        let deviceID: String
        var context: [ClientDiagnosticEvent] = []
        var reports: [ClientDiagnosticReport] = []
        var lastQueuedAt: Date?
        var lastSent: Date?
        var pendingSnapshot: Bool?
    }
    private let fileURL: URL
    private let pairings: Pairings
    private let upload: Upload
    private let now: @Sendable () -> Date
    private let launchID: UUID
    private var homes: [UUID: HomeState]
    private var uploadTask: Task<Void, Error>?
    private var uploadingHome: UUID?
    private var flushing = false
    private(set) var storageFailed = false
    static let retention: TimeInterval = 7 * 86400

    init(fileURL: URL, pairings: @escaping Pairings, upload: @escaping Upload,
         now: @escaping @Sendable () -> Date = Date.init, launchID: UUID = UUID()) {
        self.fileURL = fileURL
        self.pairings = pairings
        self.upload = upload
        self.now = now
        self.launchID = launchID
        if let data = try? Data(contentsOf: fileURL), data.count <= 4_000_000,
           let saved = try? JSONDecoder().decode([UUID: HomeState].self, from: data) {
            homes = saved
        } else {
            homes = [:]
        }
    }

    func settings() async throws -> [HomeDiagnosticSetting] {
        let paired = try await pairings()
        try reconcile(paired)
        return paired.map { pairing in
            let state = homes[pairing.id]
            return HomeDiagnosticSetting(id: pairing.id, name: pairing.home.displayName,
                                         enabled: state != nil, pending: state?.reports.count ?? 0,
                                         lastSent: state?.lastSent)
        }
    }

    func setEnabled(_ enabled: Bool, pairingID: UUID) async throws {
        let paired = try await pairings()
        guard let pairing = paired.first(where: { $0.id == pairingID }) else { return }
        if enabled {
            guard homes[pairingID] == nil, homes.count < 16 else { return }
            homes[pairingID] = HomeState(origin: pairing.home, deviceID: pairing.deviceID)
            append(.init(time: now().timeIntervalSince1970, name: .launch, launchID: launchID), to: pairingID)
        } else {
            homes.removeValue(forKey: pairingID)
            if uploadingHome == pairingID { uploadTask?.cancel() }
        }
        do { try persist() } catch {
            if enabled { homes.removeValue(forKey: pairingID) }
            throw error
        }
    }

    func connectionResult(ready: Bool, code: HomeFailureCode?, phase: HomeFailurePhase, profileID: UUID) async {
        guard let pairing = try? await pairings().first(where: { $0.profiles.contains(where: { $0.profileID == profileID }) }),
              let state = homes[pairing.id], state.origin == pairing.home, state.deviceID == pairing.deviceID else { return }
        let safeCode = code.map { ClientDiagnosticEvent.allowedCodes.contains($0.rawValue) ? $0.rawValue : "unknown" }
        append(.init(time: now().timeIntervalSince1970, name: ready ? .connectionReady : .connectionFailed,
                     launchID: launchID, code: ready ? nil : safeCode ?? "unknown", phase: phase.rawValue), to: pairing.id)
        try? persist()
    }

    func record(_ diagnostic: HomeBridgeDiagnostic, profileID: UUID) async {
        let name: ClientDiagnosticEvent.Name
        var code: String?
        var duration: Int?
        var uncertain: Bool?
        switch diagnostic {
        case .eventReceived: return
        case .transportLost: name = .connectionLost
        case .requestStarted: name = .requestStarted
        case .requestCompleted(_, let milliseconds, _):
            name = .requestCompleted; duration = milliseconds
        case .requestFailed(_, let failure, let isUncertain, let milliseconds):
            uncertain = isUncertain
            name = .requestFailed; duration = milliseconds
            code = ClientDiagnosticEvent.allowedCodes.contains(failure.rawValue) ? failure.rawValue : "unknown"
        }
        guard let pairing = try? await pairings().first(where: { $0.profiles.contains(where: { $0.profileID == profileID }) }),
              let state = homes[pairing.id], state.origin == pairing.home, state.deviceID == pairing.deviceID else { return }
        append(.init(time: now().timeIntervalSince1970, name: name, launchID: launchID,
                     code: code, durationMS: duration.map { min(86400000, max(0, $0)) },
                     phase: name == .connectionLost ? nil : "submission", uncertain: uncertain), to: pairing.id)
        try? persist()
    }

    func lifecycle(_ name: ClientDiagnosticEvent.Name) async {
        guard [.active, .inactive, .background].contains(name), let paired = try? await pairings() else { return }
        try? reconcile(paired)
        for id in Array(homes.keys) {
            if homes[id]?.context.last?.launchID != launchID {
                append(.init(time: now().timeIntervalSince1970, name: .launch, launchID: launchID), to: id)
            }
            append(.init(time: now().timeIntervalSince1970, name: name, launchID: launchID), to: id)
        }
        try? persist()
    }

    private func append(_ event: ClientDiagnosticEvent, to id: UUID) {
        guard var state = homes[id] else { return }
        let cutoff = now().timeIntervalSince1970 - Self.retention
        if event.name != .launch, state.context.last?.launchID != event.launchID {
            state.context.append(.init(time: event.time, name: .launch, launchID: event.launchID))
        }
        state.context = Array(state.context.filter { $0.time >= cutoff }.suffix(99)) + [event]
        state.reports = state.reports.filter { $0.createdAt >= cutoff }
        let isFailure = event.name == .connectionLost || event.name == .requestFailed || event.name == .connectionFailed
        let restartsAfterFailure = event.name == .launch && state.context.contains { $0.name == .connectionLost || $0.name == .requestFailed || $0.name == .connectionFailed }
        let recoveredAfterFailure = event.name == .connectionReady && state.context.contains {
            $0.name == .connectionLost || $0.name == .requestFailed || $0.name == .connectionFailed
        }
        if isFailure || restartsAfterFailure || recoveredAfterFailure { state.pendingSnapshot = true }
        queuePendingSnapshot(&state)
        homes[id] = state
    }

    private func queuePendingSnapshot(_ state: inout HomeState) {
        guard state.pendingSnapshot == true, !state.context.isEmpty,
              now().timeIntervalSince(state.lastQueuedAt ?? .distantPast) >= 60 else { return }
        state.reports = Array(state.reports.suffix(9)) + [.make(events: state.context, now: now())]
        state.lastQueuedAt = now()
        state.pendingSnapshot = false
    }

    /// Foreground retries only. Cancelling or quitting leaves the persisted report for the next launch.
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false; uploadTask = nil; uploadingHome = nil }
        guard let paired = try? await pairings() else { return }
        do { try reconcile(paired) } catch { return }
        for pairing in paired {
            guard !Task.isCancelled, pairing.credentialUsable,
                  pairing.credentialExpiresAt > now(),
                  let report = homes[pairing.id]?.reports.first else { continue }
            uploadingHome = pairing.id
            let task = Task { try await upload(pairing, report) }
            uploadTask = task
            do {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled, !task.isCancelled, homes[pairing.id] != nil else { continue }
                homes[pairing.id]?.reports.removeAll { $0.id == report.id }
                homes[pairing.id]?.lastSent = now()
                try persist()
            } catch {
                // No recursive diagnostics about the diagnostics transport. Keep the report.
            }
        }
    }

    private func reconcile(_ paired: [HomeClientPairing]) throws {
        homes = homes.filter { id, state in
            paired.contains { $0.id == id && $0.home == state.origin && $0.deviceID == state.deviceID }
        }
        for id in Array(homes.keys) {
            let cutoff = now().timeIntervalSince1970 - Self.retention
            homes[id]?.context.removeAll { $0.time < cutoff }
            homes[id]?.reports.removeAll { $0.createdAt < cutoff || $0.events.contains(where: { $0.time < cutoff }) }
            if var state = homes[id] {
                if state.context.isEmpty { state.pendingSnapshot = false }
                queuePendingSnapshot(&state)
                homes[id] = state
            }
        }
        try persist()
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(homes)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
            var url = fileURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            storageFailed = false
        } catch {
            storageFailed = true
            throw error
        }
    }
}

struct ClientDiagnosticUploader: Sendable {
    let transport: any HomeHTTPTransport
    let credentials: any HomeCredentialProvisioningStore
    func send(pairing: HomeClientPairing, report: ClientDiagnosticReport) async throws {
        try await credentials.withPrivateDeviceCredential(for: pairing.id) { credential in
            try Task.checkCancellation()
            var request = URLRequest(url: pairing.home.apiURL("/api/v1/client-diagnostics"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Device \(String(decoding: credential, as: UTF8.self))", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(report)
            let (data, response) = try await transport.data(for: request)
            struct Receipt: Decodable { let schema: Int; let report_id: UUID }
            guard response.statusCode == 200, let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  receipt.schema == 1, receipt.report_id == report.id else { throw HomeServiceError.invalidResponse }
        }
    }
}

struct ReportingHomeBridgeDiagnostics: HomeBridgeDiagnostics {
    let profileID: UUID
    let reporter: AutomaticDiagnosticsReporter
    let next: any HomeBridgeDiagnostics
    func connectionResult(ready: Bool, code: HomeFailureCode?, phase: HomeFailurePhase) async {
        await reporter.connectionResult(ready: ready, code: code, phase: phase, profileID: profileID)
    }
    func record(_ event: HomeBridgeDiagnostic) async {
        await next.record(event)
        await reporter.record(event, profileID: profileID)
    }
}
