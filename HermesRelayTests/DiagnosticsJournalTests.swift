import Foundation
import XCTest
@testable import HermesRelayIOS

final class DiagnosticsJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsJournalTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("journal.jsonl") }

    private func makeJournal(maxEntries: Int = 100) -> DiagnosticsJournal {
        let clock = TestClock()
        return DiagnosticsJournal(fileURL: fileURL, maxEntries: maxEntries, now: { clock.tick() })
    }

    func testEntriesSurviveANewJournalInOrder() {
        let journal = makeJournal()
        journal.record("home connect open result=ready")
        journal.record("app phase=background")

        let reopened = makeJournal()

        XCTAssertEqual(
            reopened.snapshot().map(\.event),
            ["home connect open result=ready", "app phase=background"]
        )
    }

    func testJournalKeepsOnlyTheNewestEntries() {
        let journal = makeJournal(maxEntries: 4)
        for index in 0..<11 { journal.record("event \(index)") }

        let expected = ["event 7", "event 8", "event 9", "event 10"]
        XCTAssertEqual(journal.snapshot().map(\.event), expected)
        XCTAssertEqual(makeJournal(maxEntries: 4).snapshot().map(\.event), expected)
    }

    func testATornLineIsSkipped() throws {
        let journal = makeJournal()
        journal.record("before")
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"t\":\"2026-09-2".utf8))
        try handle.close()

        let reopened = makeJournal()
        XCTAssertEqual(reopened.snapshot().map(\.event), ["before"])
    }

    func testExportStartsWithTheHeaderThenOneLinePerEntry() throws {
        let journal = makeJournal()
        journal.record("home connect local mismatch site=open_ready_vs_claim fields=handle")
        let header = DiagnosticsHeader(
            kind: "hermes-relay-diagnostics/1",
            appVersion: "0.4.1",
            build: "42",
            system: "iOS 26.0",
            model: "iPhone18,1",
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        let lines = journal.exportText(header: header)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(lines.count, 2)
        let decodedHeader = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(decodedHeader?["kind"] as? String, "hermes-relay-diagnostics/1")
        XCTAssertEqual(decodedHeader?["app_version"] as? String, "0.4.1")
        let decodedEntry = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        XCTAssertEqual(
            decodedEntry?["e"] as? String,
            "home connect local mismatch site=open_ready_vs_claim fields=handle"
        )
        XCTAssertNotNil(decodedEntry?["t"] as? String)
    }

    func testExportFileIsWrittenForTheShareSheet() throws {
        let journal = makeJournal()
        journal.record("app phase=active")

        let url = try journal.exportFile(header: .current())

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"e\":\"app phase=active\""))
        XCTAssertEqual(url.lastPathComponent, "Hermes Relay diagnostics.txt")
    }

    func testBridgeDiagnosticsAreJournaledExceptPerEventNotices() async {
        let journal = makeJournal()
        let diagnostics = JournalingHomeBridgeDiagnostics(journal: journal, next: nil)

        await diagnostics.record(.eventReceived(kind: .audioFrame))
        await diagnostics.record(.requestFailed(
            method: .promptSubmit,
            code: .conversationMismatch,
            uncertain: false,
            durationMilliseconds: 12
        ))
        await diagnostics.record(.transportLost)

        XCTAssertEqual(journal.snapshot().map(\.event), [
            "home bridge request failed method=prompt.submit code=conversation_mismatch uncertain=false duration_ms=12",
            "home bridge transport lost",
        ])
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_790_000_000

    func tick() -> Date {
        lock.lock()
        defer { lock.unlock() }
        seconds += 1
        return Date(timeIntervalSince1970: seconds)
    }
}
