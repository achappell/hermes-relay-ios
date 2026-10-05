import Foundation

/// Only typed, content-free fields cross the upload boundary. Raw journal strings never do.
/// `eventID` and `sequence` are assigned once at observation and never change, because Home
/// rejects an `event_id` whose content differs across schema-2 reports.
struct ClientDiagnosticEvent: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable {
        case launch, active, inactive, background
        case connectionLost = "connection_lost"
        case connectionReady = "connection_ready"
        case connectionFailed = "connection_failed"
        case requestStarted = "request_started"
        case requestCompleted = "request_completed"
        case requestFailed = "request_failed"
        /// Schema 2 only.
        case clientResponseReceived = "client_response_received"
        case clientRequestResolved = "client_request_resolved"

        var isSchema1: Bool { self != .clientResponseReceived && self != .clientRequestResolved }
    }
    let time: Double
    let name: Name
    let launchID: UUID
    var code: String?
    var durationMS: Int?
    var phase: String?
    var uncertain: Bool?
    var eventID: String
    var sequence: Int
    var homeConnectionID: String?
    var requestID: String?
    var correlationID: String?
    var correlationState: String?
    var leg: String?
    var pendingState: String?
    var responseKind: String?

    enum CodingKeys: String, CodingKey {
        case time, name, code, phase, uncertain, sequence, leg
        case launchID = "launch_id", durationMS = "duration_ms", eventID = "event_id"
        case homeConnectionID = "home_connection_id", requestID = "request_id"
        case correlationID = "correlation_id", correlationState = "correlation_state"
        case pendingState = "pending_state", responseKind = "response_kind"
    }

    init(time: Double, name: Name, launchID: UUID, code: String? = nil, durationMS: Int? = nil,
         phase: String? = nil, uncertain: Bool? = nil, eventID: String = HomeDiagnosticIdentifier.make("evt"),
         sequence: Int = 0) {
        self.time = time
        self.name = name
        self.launchID = launchID
        self.code = code
        self.durationMS = durationMS
        self.phase = phase
        self.uncertain = uncertain
        self.eventID = eventID
        self.sequence = sequence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        name = try c.decode(Name.self, forKey: .name)
        launchID = try c.decode(UUID.self, forKey: .launchID)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        durationMS = try c.decodeIfPresent(Int.self, forKey: .durationMS)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        uncertain = try c.decodeIfPresent(Bool.self, forKey: .uncertain)
        // Context persisted before schema 2 has no identity; it gets one once, here, and keeps it.
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID) ?? HomeDiagnosticIdentifier.make("evt")
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        homeConnectionID = try c.decodeIfPresent(String.self, forKey: .homeConnectionID)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        correlationID = try c.decodeIfPresent(String.self, forKey: .correlationID)
        correlationState = try c.decodeIfPresent(String.self, forKey: .correlationState)
        leg = try c.decodeIfPresent(String.self, forKey: .leg)
        pendingState = try c.decodeIfPresent(String.self, forKey: .pendingState)
        responseKind = try c.decodeIfPresent(String.self, forKey: .responseKind)
    }

    func encode(to encoder: Encoder) throws {
        try encode(to: encoder, schema: 2)
    }

    /// Schema 1 emits only the schema-1 keys Home accepts there.
    func encode(to encoder: Encoder, schema: Int) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(name, forKey: .name)
        try c.encode(launchID, forKey: .launchID)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(durationMS, forKey: .durationMS)
        try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(uncertain, forKey: .uncertain)
        guard schema == 2 else { return }
        try c.encode(eventID, forKey: .eventID)
        try c.encode(sequence, forKey: .sequence)
        try c.encodeIfPresent(homeConnectionID, forKey: .homeConnectionID)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encodeIfPresent(correlationID, forKey: .correlationID)
        try c.encodeIfPresent(correlationState, forKey: .correlationState)
        try c.encodeIfPresent(leg, forKey: .leg)
        try c.encodeIfPresent(pendingState, forKey: .pendingState)
        try c.encodeIfPresent(responseKind, forKey: .responseKind)
    }

    static let allowedCodes: Set<String> = ["unknown", "transport_unavailable", "transport_timeout", "hermes_unavailable", "protocol_error", "conversation_mismatch", "stale_conversation", "request_rejected", "reconnect_required", "unauthorized", "forbidden", "capability_unavailable", "invalid_request"]
}

private struct WireEvent: Encodable {
    let event: ClientDiagnosticEvent
    let schema: Int
    func encode(to encoder: Encoder) throws { try event.encode(to: encoder, schema: schema) }
}

/// The build that observed a launch's events. Stable forever per `launch_id`: Home rejects an
/// origin whose content changes across stored reports.
struct ClientDiagnosticOrigin: Codable, Equatable, Sendable {
    let launchID: UUID
    let appVersion: String?
    let buildNumber: String?
    let osVersion: String?
    let provenanceStatus: String

    private enum CodingKeys: String, CodingKey {
        case launchID = "launch_id", appVersion = "app_version", buildNumber = "build_number"
        case osVersion = "os_version", sourceRevision = "source_revision"
        case artifactSHA256 = "artifact_sha256", provenanceStatus = "provenance_status"
    }

    init(launchID: UUID, appVersion: String?, buildNumber: String?, osVersion: String?) {
        func valid(_ value: String?) -> String? {
            value.flatMap { $0.range(of: ClientDiagnosticReport.versionPattern, options: .regularExpression) != nil ? $0 : nil }
        }
        self.launchID = launchID
        self.appVersion = valid(appVersion)
        self.buildNumber = valid(buildNumber)
        self.osVersion = valid(osVersion)
        // Self-reported versions without a source revision or digest are never "verified".
        provenanceStatus = self.appVersion != nil && self.buildNumber != nil && self.osVersion != nil
            ? "unverified" : "unavailable"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchID = try c.decode(UUID.self, forKey: .launchID)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        buildNumber = try c.decodeIfPresent(String.self, forKey: .buildNumber)
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        provenanceStatus = try c.decode(String.self, forKey: .provenanceStatus)
    }

    /// All seven keys, with explicit nulls.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchID, forKey: .launchID)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(buildNumber, forKey: .buildNumber)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encodeNil(forKey: .sourceRevision)
        try c.encodeNil(forKey: .artifactSHA256)
        try c.encode(provenanceStatus, forKey: .provenanceStatus)
    }

    static func current(launchID: UUID, now: Date) -> Self {
        let header = DiagnosticsHeader.current(now: now)
        return Self(launchID: launchID, appVersion: header.appVersion, buildNumber: header.build,
                    osVersion: ClientDiagnosticReport.currentOSVersion)
    }

    /// For launches recorded before origins were kept: nothing about them is known.
    static func unavailable(launchID: UUID) -> Self {
        Self(launchID: launchID, appVersion: nil, buildNumber: nil, osVersion: nil)
    }
}

struct ClientDiagnosticReport: Codable, Equatable, Sendable, Identifiable {
    static let maxBodyBytes = 65_536
    static let maxEvents = 100
    static let versionPattern = #"^[0-9]{1,8}(\.[0-9]{1,8}){0,3}$"#
    static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    let schema: Int
    let id: UUID
    let createdAt: Double
    let appVersion: String
    let build: String
    let platform: String
    let osVersion: String
    let model: String
    let events: [ClientDiagnosticEvent]
    /// Schema 2 only: exactly the origins of the launches its events reference.
    let origins: [ClientDiagnosticOrigin]?
    enum CodingKeys: String, CodingKey {
        case schema, build, platform, model, events, origins
        case id = "report_id", createdAt = "created_at", appVersion = "app_version", osVersion = "os_version"
    }

    init(schema: Int, id: UUID, createdAt: Double, appVersion: String, build: String, platform: String,
         osVersion: String, model: String, events: [ClientDiagnosticEvent], origins: [ClientDiagnosticOrigin]?) {
        self.schema = schema
        self.id = id
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.build = build
        self.platform = platform
        self.osVersion = osVersion
        self.model = model
        self.events = events
        self.origins = schema == 2 ? origins ?? [] : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        build = try c.decode(String.self, forKey: .build)
        platform = try c.decode(String.self, forKey: .platform)
        osVersion = try c.decode(String.self, forKey: .osVersion)
        model = try c.decode(String.self, forKey: .model)
        events = try c.decode([ClientDiagnosticEvent].self, forKey: .events)
        origins = schema == 2 ? try c.decode([ClientDiagnosticOrigin].self, forKey: .origins) : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(build, forKey: .build)
        try c.encode(platform, forKey: .platform)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(model, forKey: .model)
        try c.encode(events.map { WireEvent(event: $0, schema: schema) }, forKey: .events)
        if schema == 2 { try c.encode(origins ?? [], forKey: .origins) }
    }

    /// The exact upload bytes: sorted keys, no whitespace, so a retry resends identical bytes.
    func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func make(events: [ClientDiagnosticEvent], now: Date, schema: Int = 1,
                     origins: [ClientDiagnosticOrigin] = [], id: UUID = UUID()) -> Self {
        let header = DiagnosticsHeader.current(now: now)
        func safeVersion(_ value: String) -> String {
            value.range(of: versionPattern, options: .regularExpression) != nil ? value : "0"
        }
        let model = header.model.range(of: #"^(?:(?:iPhone|iPad|Mac)[0-9]{1,3},[0-9]{1,3}|arm64|x86_64)$"#, options: .regularExpression) != nil ? header.model : "unknown"
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return Self(schema: schema, id: id, createdAt: now.timeIntervalSince1970,
                    appVersion: safeVersion(header.appVersion), build: safeVersion(header.build),
                    platform: platform, osVersion: currentOSVersion,
                    model: model, events: events, origins: origins)
    }

    /// Deterministic greedy packing in observation order: whole events (plus the origins they
    /// newly need) join the open report while it stays within `maxEvents` and `maxBytes`; then it
    /// is sealed and the next one opens. An event that cannot fit even alone is dropped and
    /// counted. Schema 1 carries only schema-1 event names.
    static func pack(events: [ClientDiagnosticEvent], schema: Int, origins: [UUID: ClientDiagnosticOrigin],
                     now: Date, maxBytes: Int = maxBodyBytes,
                     makeID: () -> UUID = UUID.init) -> (reports: [Self], dropped: Int) {
        let candidates = schema == 2 ? events : events.filter { $0.name.isSchema1 }
        func build(_ events: [ClientDiagnosticEvent], id: UUID) -> Self {
            var seen = Set<UUID>()
            let referenced = events.compactMap { event -> ClientDiagnosticOrigin? in
                guard seen.insert(event.launchID).inserted else { return nil }
                return origins[event.launchID] ?? .unavailable(launchID: event.launchID)
            }
            return make(events: events, now: now, schema: schema, origins: referenced, id: id)
        }
        // Report IDs are fixed-width, so a placeholder measures the sealed size exactly.
        let probeID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func fits(_ events: [ClientDiagnosticEvent]) -> Bool {
            events.count <= maxEvents && ((try? build(events, id: probeID).body().count) ?? Int.max) <= maxBytes
        }
        var sealed: [Self] = []
        var open: [ClientDiagnosticEvent] = []
        var dropped = 0
        for event in candidates {
            if fits(open + [event]) {
                open.append(event)
                continue
            }
            if !open.isEmpty { sealed.append(build(open, id: makeID())) }
            if fits([event]) {
                open = [event]
            } else {
                open = []
                dropped += 1
            }
        }
        if !open.isEmpty { sealed.append(build(open, id: makeID())) }
        return (sealed, dropped)
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
        /// 2 once this Home advertised schema-2 reports on its latest ready; otherwise schema 1.
        var reportSchema: Int?
        /// Origins of the launches in `context`, fixed when first observed.
        var origins: [String: ClientDiagnosticOrigin]?
        /// Events that could not fit any report body alone.
        var packingLosses: Int?
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
    private let currentOrigin: ClientDiagnosticOrigin
    private var nextSequence: Int
    static let retention: TimeInterval = 7 * 86400

    init(fileURL: URL, pairings: @escaping Pairings, upload: @escaping Upload,
         now: @escaping @Sendable () -> Date = Date.init, launchID: UUID = UUID()) {
        self.fileURL = fileURL
        self.pairings = pairings
        self.upload = upload
        self.now = now
        self.launchID = launchID
        var loaded: [UUID: HomeState] = [:]
        if let data = try? Data(contentsOf: fileURL), data.count <= 4_000_000,
           let saved = try? JSONDecoder().decode([UUID: HomeState].self, from: data) {
            loaded = saved
        }
        homes = loaded
        currentOrigin = .current(launchID: launchID, now: now())
        // Monotonic per launch, including across a reporter rebuilt within the same launch.
        nextSequence = (loaded.values.flatMap(\.context).filter { $0.launchID == launchID }.map(\.sequence).max() ?? -1) + 1
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
        var phase: String? = "submission"
        var correlation: HomeRequestCorrelation?
        var pendingState: String?
        var responseKind: HomeResponseKind?
        switch diagnostic {
        case .eventReceived: return
        case .reportSchemasAdvertised(let schemas):
            guard let pairing = try? await pairings().first(where: { $0.profiles.contains(where: { $0.profileID == profileID }) }),
                  let state = homes[pairing.id], state.origin == pairing.home, state.deviceID == pairing.deviceID else { return }
            let schema = schemas.contains(2) ? 2 : 1
            guard state.reportSchema ?? 1 != schema else { return }
            homes[pairing.id]?.reportSchema = schema
            try? persist()
            return
        case .transportLost: name = .connectionLost; phase = nil
        case .requestStarted(_, let value):
            name = .requestStarted; correlation = value; pendingState = "awaiting_write"
        case .requestCompleted(_, let milliseconds, _, let value):
            name = .requestCompleted; duration = milliseconds; correlation = value; pendingState = "response_resolved"
        case .requestFailed(_, let failure, let isUncertain, let milliseconds, let value):
            uncertain = isUncertain
            name = .requestFailed; duration = milliseconds; correlation = value
            pendingState = isUncertain ? "unknown" : "response_resolved"
            code = ClientDiagnosticEvent.allowedCodes.contains(failure.rawValue) ? failure.rawValue : "unknown"
        case .responseReceived(_, let value, let kind):
            name = .clientResponseReceived; correlation = value; responseKind = kind
            phase = "response"; pendingState = "response_resolved"
        case .requestResolved(_, let value, let kind):
            name = .clientRequestResolved; correlation = value; responseKind = kind
            phase = "response"; pendingState = "response_resolved"
        }
        guard let pairing = try? await pairings().first(where: { $0.profiles.contains(where: { $0.profileID == profileID }) }),
              let state = homes[pairing.id], state.origin == pairing.home, state.deviceID == pairing.deviceID else { return }
        var event = ClientDiagnosticEvent(time: now().timeIntervalSince1970, name: name, launchID: launchID,
                                          code: code, durationMS: duration.map { min(86400000, max(0, $0)) },
                                          phase: phase, uncertain: uncertain)
        if let correlation, HomeDiagnosticIdentifier.isValid(correlation.homeConnectionID, prefix: "conn"),
           HomeDiagnosticIdentifier.isValid(correlation.requestID, prefix: "req") {
            event.homeConnectionID = correlation.homeConnectionID
            event.requestID = correlation.requestID
            event.correlationID = correlation.correlationID.flatMap {
                HomeDiagnosticIdentifier.isValid($0, prefix: "corr") ? $0 : nil
            }
            // Only Home can say whether a join is linked; the client's view is always local.
            event.correlationState = "local_only"
            event.leg = "client_home"
            event.pendingState = pendingState
            event.responseKind = responseKind?.rawValue
        } else if responseKind != nil {
            return
        }
        append(event, to: pairing.id)
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
            state.context.append(stamp(.init(time: event.time, name: .launch, launchID: event.launchID)))
        }
        state.context = Array(state.context.filter { $0.time >= cutoff }.suffix(99)) + [stamp(event)]
        var origins = state.origins ?? [:]
        let launches = Set(state.context.map(\.launchID.uuidString))
        origins = origins.filter { launches.contains($0.key) }
        for launch in state.context.map(\.launchID) where origins[launch.uuidString] == nil {
            origins[launch.uuidString] = launch == launchID ? currentOrigin : .unavailable(launchID: launch)
        }
        state.origins = origins
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

    /// Observation: the one place an event's identity and sequence are fixed.
    private func stamp(_ event: ClientDiagnosticEvent) -> ClientDiagnosticEvent {
        var event = event
        event.eventID = HomeDiagnosticIdentifier.make("evt")
        event.sequence = nextSequence
        nextSequence += 1
        return event
    }

    private func queuePendingSnapshot(_ state: inout HomeState) {
        guard state.pendingSnapshot == true, !state.context.isEmpty,
              now().timeIntervalSince(state.lastQueuedAt ?? .distantPast) >= 60 else { return }
        var origins: [UUID: ClientDiagnosticOrigin] = [:]
        for origin in (state.origins ?? [:]).values { origins[origin.launchID] = origin }
        let packed = ClientDiagnosticReport.pack(events: state.context, schema: state.reportSchema ?? 1,
                                                 origins: origins, now: now())
        state.reports = Array((state.reports + packed.reports).suffix(10))
        if packed.dropped > 0 { state.packingLosses = (state.packingLosses ?? 0) + packed.dropped }
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
            request.httpBody = try report.body()
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
