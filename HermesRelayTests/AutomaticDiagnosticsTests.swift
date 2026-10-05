import Foundation
import XCTest
@testable import HermesRelayIOS

final class AutomaticDiagnosticsTests: XCTestCase {
    func testOptInQueueSurvivesRelaunchAndRetriesWithoutChangingReportID() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.reporter()
        await first.record(.transportLost, profileID: fixture.profileID)
        var settings = try await first.settings()
        XCTAssertEqual(settings.first?.pending, 0)
        XCTAssertEqual(settings.first?.enabled, false)
        try await first.setEnabled(true, pairingID: fixture.pairing.id)
        await first.record(.transportLost, profileID: fixture.profileID)
        await first.flush() // Offline: retain the report.
        settings = try await first.settings()
        XCTAssertEqual(settings.first?.pending, 1)
        let before = await fixture.sink.reports

        let restarted = fixture.reporter()
        await restarted.lifecycle(.active)
        await fixture.sink.setOffline(false)
        await restarted.flush()
        let after = await fixture.sink.reports
        XCTAssertEqual(before.first?.id, after.last?.id)
        XCTAssertEqual(after.last?.events.last?.name, .connectionLost)
        settings = try await restarted.settings()
        XCTAssertEqual(settings.first?.pending, 0)
        XCTAssertNotNil(settings.first?.lastSent)
        let third = fixture.reporter()
        settings = try await third.settings()
        XCTAssertEqual(settings.first?.pending, 0)
    }

    func testQuickRestartRetainsRecoveryForTheNextThrottledReport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.reporter()
        try await first.setEnabled(true, pairingID: fixture.pairing.id)
        await first.record(.transportLost, profileID: fixture.profileID)
        let restarted = fixture.reporter(date: fixture.date.addingTimeInterval(5))
        await restarted.lifecycle(.active)
        await restarted.connectionResult(ready: true, code: nil, phase: .open, profileID: fixture.profileID)
        let later = fixture.reporter(date: fixture.date.addingTimeInterval(61))
        await fixture.sink.setOffline(false)
        await later.flush()
        await later.flush()
        let reports = await fixture.sink.reports
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(try XCTUnwrap(reports.last).events.contains { $0.name == .connectionReady })
        XCTAssertGreaterThan(Set(try XCTUnwrap(reports.last).events.map(\.launchID)).count, 1)
    }

    func testDisablePurgesDurableQueueAndStopsCollecting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        try await reporter.setEnabled(false, pairingID: fixture.pairing.id)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        let restarted = fixture.reporter()
        await restarted.flush()
        let calls = await fixture.sink.reports
        XCTAssertTrue(calls.isEmpty)
        let settings = try await restarted.settings()
        XCTAssertEqual(settings.first?.enabled, false)
        XCTAssertEqual(settings.first?.pending, 0)
    }

    func testReportsNeverFollowARepairedDeviceOrAnotherHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        var replacement = fixture.pairing
        replacement.deviceID = "replacement-device"
        let restarted = fixture.reporter(pairing: replacement)
        await restarted.flush()
        let calls = await fixture.sink.reports
        XCTAssertTrue(calls.isEmpty)
        let settings = try await restarted.settings()
        XCTAssertEqual(settings.first?.enabled, false)
    }

    func testExpiredReportsAreRemovedAcrossLaunches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        let later = fixture.reporter(date: fixture.date.addingTimeInterval(8 * 86400))
        await later.flush()
        let settings = try await later.settings()
        XCTAssertEqual(settings.first?.pending, 0)
        let calls = await fixture.sink.reports
        XCTAssertTrue(calls.isEmpty)
    }

    func testDisablingCancelsInFlightUploadAndConcurrentFlushDoesNotDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = expectation(description: "Upload started")
        let pairing = fixture.pairing
        let date = fixture.date
        let reporter = AutomaticDiagnosticsReporter(
            fileURL: fixture.directory.appendingPathComponent("reports.json"),
            pairings: { [pairing] in [pairing] },
            upload: { _, _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
            }, now: { date }
        )
        try await reporter.setEnabled(true, pairingID: pairing.id)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        let first = Task { await reporter.flush() }
        await fulfillment(of: [started], timeout: 2)
        await reporter.flush()
        try await reporter.setEnabled(false, pairingID: pairing.id)
        await first.value
        let settings = try await reporter.settings()
        XCTAssertEqual(settings.first?.enabled, false)
        XCTAssertEqual(settings.first?.lastSent, nil)
    }

    func testQueueAndContextRemainBoundedAcrossManyLaunches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        for minute in 0..<15 {
            let next = fixture.reporter(date: fixture.date.addingTimeInterval(Double(minute * 61)))
            for _ in 0..<12 { await next.record(.requestStarted(method: .promptSubmit), profileID: fixture.profileID) }
            await next.record(.transportLost, profileID: fixture.profileID)
        }
        let latest = fixture.reporter(date: fixture.date.addingTimeInterval(15 * 61))
        let settings = try await latest.settings()
        XCTAssertEqual(settings.first?.pending, 10)
        await latest.flush()
        let reports = await fixture.sink.reports
        XCTAssertLessThanOrEqual(try XCTUnwrap(reports.first).events.count, 100)
        XCTAssertGreaterThan(Set(try XCTUnwrap(reports.first).events.map(\.launchID)).count, 1)
    }

    func testUploaderUsesPairedOriginAndRequiresExactAcknowledgment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = ClientDiagnosticReport.make(events: [.init(time: fixture.date.timeIntervalSince1970, name: .connectionLost, launchID: UUID())], now: fixture.date)
        let transport = ReportUploadTransport(receiptID: report.id)
        let uploader = ClientDiagnosticUploader(transport: transport, credentials: ReportTestCredentials())
        try await uploader.send(pairing: fixture.pairing, report: report)
        let sent = await transport.request
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.url?.absoluteString, "https://home.example/api/v1/client-diagnostics")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Device fixture-device-secret")
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("fixture-device-secret"))
        let wrong = ClientDiagnosticUploader(transport: ReportUploadTransport(receiptID: UUID()), credentials: ReportTestCredentials())
        do {
            try await wrong.send(pairing: fixture.pairing, report: report)
            XCTFail("A receipt for another report must not remove this report")
        } catch { }
    }

    func testReportHasOnlyAllowlistedFieldsAndRepeatedFailuresAreCoalesced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        for _ in 0..<110 {
            await reporter.record(.requestFailed(method: .promptSubmit, code: .hermesUnavailable, uncertain: false, durationMilliseconds: 15), profileID: fixture.profileID)
        }
        await reporter.flush()
        let reports = await fixture.sink.reports
        XCTAssertEqual(reports.count, 1)
        let data = try JSONEncoder().encode(XCTUnwrap(reports.first))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "report_id", "created_at", "app_version", "build", "platform", "os_version", "model", "events"])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertTrue(events.allSatisfy { Set($0.keys).isSubset(of: ["time", "name", "launch_id", "code", "duration_ms", "phase", "uncertain"]) })
        XCTAssertEqual(reports.first?.events.last?.code, "hermes_unavailable")
    }

    func testSchemaTwoReportCarriesCorrelationIdentityAndReferencedOrigins() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        await reporter.record(.reportSchemasAdvertised([1, 2]), profileID: fixture.profileID)
        let correlation = HomeRequestCorrelation(homeConnectionID: "conn-" + String(repeating: "a", count: 32),
                                                 requestID: "req-" + String(repeating: "b", count: 32))
        var linked = correlation
        linked.correlationID = "corr-" + String(repeating: "c", count: 32)
        await reporter.record(.requestStarted(method: .promptSubmit, correlation: correlation), profileID: fixture.profileID)
        await reporter.record(.responseReceived(method: .promptSubmit, correlation: linked, kind: .rejection), profileID: fixture.profileID)
        await reporter.record(.requestFailed(method: .promptSubmit, code: .requestRejected, uncertain: false,
                                             durationMilliseconds: 5, correlation: linked), profileID: fixture.profileID)
        await reporter.flush()
        let sent = await fixture.sink.reports
        let report = try XCTUnwrap(sent.first)
        XCTAssertEqual(report.schema, 2)
        let body = try report.body()
        XCTAssertLessThanOrEqual(body.count, ClientDiagnosticReport.maxBodyBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "report_id", "created_at", "app_version", "build", "platform", "os_version", "model", "events", "origins"])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let allowed: Set<String> = ["time", "name", "launch_id", "code", "duration_ms", "phase", "uncertain", "event_id", "sequence",
                                    "connection_id", "home_connection_id", "request_id", "correlation_id", "correlation_state",
                                    "leg", "pending_state", "response_kind", "sent_close_code", "received_close_code", "observed_status_code"]
        XCTAssertTrue(events.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        XCTAssertTrue(events.allSatisfy { HomeDiagnosticIdentifier.isValid($0["event_id"], prefix: "evt") })
        let sequences = events.compactMap { $0["sequence"] as? Int }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
        let started = try XCTUnwrap(events.first { $0["name"] as? String == "request_started" })
        XCTAssertEqual(started["home_connection_id"] as? String, correlation.homeConnectionID)
        XCTAssertEqual(started["request_id"] as? String, correlation.requestID)
        XCTAssertEqual(started["leg"] as? String, "client_home")
        XCTAssertEqual(started["phase"] as? String, "submission")
        XCTAssertEqual(started["correlation_state"] as? String, "local_only")
        XCTAssertNil(started["response_kind"])
        let received = try XCTUnwrap(events.first { $0["name"] as? String == "client_response_received" })
        XCTAssertEqual(received["correlation_id"] as? String, linked.correlationID)
        XCTAssertEqual(received["response_kind"] as? String, "rejection")
        let origins = try XCTUnwrap(json["origins"] as? [[String: Any]])
        XCTAssertEqual(Set(origins.compactMap { $0["launch_id"] as? String }), Set(events.compactMap { $0["launch_id"] as? String }))
        XCTAssertTrue(origins.allSatisfy {
            Set($0.keys) == ["launch_id", "app_version", "build_number", "os_version", "source_revision", "artifact_sha256", "provenance_status"]
        })
    }

    func testLegacyHomeReportStaysSchemaOneWithoutSchemaTwoEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reporter = fixture.reporter()
        try await reporter.setEnabled(true, pairingID: fixture.pairing.id)
        await reporter.record(.reportSchemasAdvertised([]), profileID: fixture.profileID)
        let correlation = HomeRequestCorrelation(homeConnectionID: "conn-" + String(repeating: "a", count: 32),
                                                 requestID: "req-" + String(repeating: "b", count: 32),
                                                 correlationID: "corr-" + String(repeating: "c", count: 32))
        await reporter.record(.responseReceived(method: .promptSubmit, correlation: correlation, kind: .accepted), profileID: fixture.profileID)
        await reporter.record(.transportLost, profileID: fixture.profileID)
        await reporter.flush()
        let sent = await fixture.sink.reports
        let report = try XCTUnwrap(sent.first)
        XCTAssertEqual(report.schema, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try report.body()) as? [String: Any])
        XCTAssertNil(json["origins"])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertTrue(events.allSatisfy { Set($0.keys).isSubset(of: ["time", "name", "launch_id", "code", "duration_ms", "phase", "uncertain"]) })
        XCTAssertFalse(events.contains { $0["name"] as? String == "client_response_received" })
    }

    func testPackingIsBoundedDeterministicAndCarriesOnlyReferencedOrigins() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = UUID(), second = UUID()
        let events = (0..<250).map { index in
            ClientDiagnosticEvent(time: date.timeIntervalSince1970 + Double(index), name: .requestStarted,
                                  launchID: index < 120 ? first : second, phase: "submission",
                                  eventID: "evt-" + String(format: "%032lx", index), sequence: index)
        }
        let origins = [first: ClientDiagnosticOrigin(launchID: first, appVersion: "1.2", buildNumber: "7", osVersion: "26.5"),
                       second: ClientDiagnosticOrigin.unavailable(launchID: second)]
        func ids() -> () -> UUID {
            var counter: UInt8 = 0
            return { counter += 1; return UUID(uuid: (counter, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        }
        let packed = ClientDiagnosticReport.pack(events: events, schema: 2, origins: origins, now: date, makeID: ids())
        XCTAssertEqual(packed.reports.map(\.events.count), [100, 100, 50])
        XCTAssertEqual(packed.dropped, 0)
        XCTAssertEqual(packed.reports.flatMap(\.events), events)
        XCTAssertEqual(packed.reports.map { $0.origins?.map(\.launchID) ?? [] }, [[first], [first, second], [second]])
        let again = ClientDiagnosticReport.pack(events: events, schema: 2, origins: origins, now: date, makeID: ids())
        XCTAssertEqual(try packed.reports.map { try $0.body() }, try again.reports.map { try $0.body() })

        let tight = ClientDiagnosticReport.pack(events: events, schema: 2, origins: origins, now: date, maxBytes: 4_000, makeID: ids())
        XCTAssertGreaterThan(tight.reports.count, 3)
        XCTAssertTrue(try tight.reports.allSatisfy { try $0.body().count <= 4_000 })
        XCTAssertEqual(tight.reports.flatMap(\.events), events)

        let tooSmall = ClientDiagnosticReport.pack(events: Array(events.prefix(3)), schema: 2, origins: origins, now: date, maxBytes: 200, makeID: ids())
        XCTAssertEqual(tooSmall.reports.count, 0)
        XCTAssertEqual(tooSmall.dropped, 3)
    }

    func testOriginNullsVersionsOnlyWhenUnavailable() throws {
        let known = ClientDiagnosticOrigin(launchID: UUID(), appVersion: "1.0", buildNumber: "3", osVersion: "26.5.1")
        XCTAssertEqual(known.provenanceStatus, "unverified")
        let partial = ClientDiagnosticOrigin(launchID: UUID(), appVersion: "1.0-beta", buildNumber: "3", osVersion: "26.5")
        XCTAssertEqual(partial.provenanceStatus, "unavailable")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(partial)) as? [String: Any])
        XCTAssertTrue(json["app_version"] is NSNull)
        XCTAssertTrue(json["source_revision"] is NSNull)
        XCTAssertTrue(json["artifact_sha256"] is NSNull)
    }
}

private actor ReportSink {
    var reports: [ClientDiagnosticReport] = []
    private var offline = true
    func setOffline(_ value: Bool) { offline = value }
    func send(_ report: ClientDiagnosticReport) throws {
        reports.append(report)
        if offline { throw URLError(.notConnectedToInternet) }
    }
}

private struct Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let profileID = UUID()
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let pairing: HomeClientPairing
    let sink = ReportSink()
    init() throws {
        pairing = HomeClientPairing(id: UUID(), home: try HomeClientBaseURL("https://home.example"), endpointID: UUID(), deviceID: "test-device", generation: 1, credentialExpiresAt: date.addingTimeInterval(30 * 86400), profiles: [.init(profileID: profileID, grantID: "grant")])
    }
    func reporter(pairing override: HomeClientPairing? = nil, date overrideDate: Date? = nil) -> AutomaticDiagnosticsReporter {
        let pairing = override ?? pairing
        let date = overrideDate ?? date
        return AutomaticDiagnosticsReporter(fileURL: directory.appendingPathComponent("reports.json"), pairings: { [pairing] in [pairing] }, upload: { [sink] _, report in try await sink.send(report) }, now: { date })
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ReportUploadTransport: HomeHTTPTransport {
    let receiptID: UUID
    var request: URLRequest?
    init(receiptID: UUID) { self.receiptID = receiptID }
    func data(for request: URLRequest) async throws -> (Data, HomeHTTPResponse) {
        self.request = request
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "report_id": receiptID.uuidString])
        return (data, HomeHTTPResponse(statusCode: 200))
    }
}

private struct ReportTestCredentials: HomeCredentialProvisioningStore {
    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws {}
    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord { throw HomeServiceError.invalidResponse }
    func withPrivateDeviceCredential(for profileID: UUID, _ body: @Sendable (Data) async throws -> Void) async throws {
        try await body(Data("fixture-device-secret".utf8))
    }
    func commitHomeSelection(for profileID: UUID) async throws {}
    func rollbackToLegacyAtIdle(for profileID: UUID) async throws {}
    func provision(preIssuedCredential: Data, reference: HomeCredentialReference, for profileID: UUID) async throws {}
    func removeCredential(for ownerID: UUID) async throws {}
}
