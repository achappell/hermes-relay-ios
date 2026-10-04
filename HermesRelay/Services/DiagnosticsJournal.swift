import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A small on-device record of how Home connections went, kept in every
/// build so a Release phone can share it from Settings. Entries are fixed
/// event names, codes, phases, check-site names, and durations only — never
/// conversation handles, prompts, replies, tokens, or audio.
///
/// Appends are synchronous under a lock so entries keep the order they were
/// recorded in, whichever actor records them.
final class DiagnosticsJournal: @unchecked Sendable {
    static let shared = DiagnosticsJournal(fileURL: defaultFileURL())
    static let defaultMaxEntries = 2_000

    struct Entry: Codable, Equatable, Sendable {
        let time: Date
        let event: String

        enum CodingKeys: String, CodingKey {
            case time = "t"
            case event = "e"
        }
    }

    private let fileURL: URL?
    private let maxEntries: Int
    /// Lines past `maxEntries` tolerated before the file is rewritten, so a
    /// full journal is not rewritten on every append.
    private let trimSlack: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [Entry]?

    init(
        fileURL: URL?,
        maxEntries: Int = DiagnosticsJournal.defaultMaxEntries,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        self.trimSlack = max(1, maxEntries / 8)
        self.now = now
    }

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadedEntries()
        let entry = Entry(time: now(), event: event)
        current.append(entry)
        if current.count > maxEntries + trimSlack {
            current.removeFirst(current.count - maxEntries)
            entries = current
            rewrite(current)
        } else {
            entries = current
            appendLine(entry)
        }
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadedEntries().suffix(maxEntries))
    }

    /// The shared text: one JSON header line, then one JSON line per entry.
    func exportText(header: DiagnosticsHeader) -> String {
        let encoder = Self.encoder()
        var lines: [String] = []
        if let data = try? encoder.encode(header) {
            lines.append(String(decoding: data, as: UTF8.self))
        }
        for entry in snapshot() {
            if let data = try? encoder.encode(entry) {
                lines.append(String(decoding: data, as: UTF8.self))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func exportFile(header: DiagnosticsHeader) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Hermes Relay diagnostics.txt")
        try Data(exportText(header: header).utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Storage

    private func loadedEntries() -> [Entry] {
        if let entries { return entries }
        var loaded: [Entry] = []
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = Self.decoder()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                // A line torn by a crash mid-append is skipped, not fatal.
                if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                    loaded.append(entry)
                }
            }
        }
        entries = loaded
        return loaded
    }

    private func appendLine(_ entry: Entry) {
        guard let fileURL, let data = try? Self.encoder().encode(entry) else { return }
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            prepareDirectory(for: fileURL)
            try? line.write(to: fileURL, options: .atomic)
            excludeFromBackup(fileURL)
        }
    }

    private func rewrite(_ entries: [Entry]) {
        guard let fileURL else { return }
        let encoder = Self.encoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        prepareDirectory(for: fileURL)
        try? data.write(to: fileURL, options: .atomic)
        excludeFromBackup(fileURL)
    }

    private func prepareDirectory(for fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func excludeFromBackup(_ fileURL: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(timestampStyle))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            return try timestampStyle.parse(text)
        }
        return decoder
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("HermesRelayIOS/Diagnostics/connection-journal.jsonl")
    }
}

/// Identifies the build and device a shared journal came from. No user,
/// profile, or network identity.
struct DiagnosticsHeader: Codable, Equatable, Sendable {
    let kind: String
    let appVersion: String
    let build: String
    let system: String
    let model: String
    let exportedAt: Date

    enum CodingKeys: String, CodingKey {
        case kind
        case appVersion = "app_version"
        case build
        case system
        case model
        case exportedAt = "t"
    }

    static func current(now: Date = Date()) -> DiagnosticsHeader {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticsHeader(
            kind: "hermes-relay-diagnostics/1",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            system: "\(platformName) \(ProcessInfo.processInfo.operatingSystemVersionString)",
            model: machineIdentifier(),
            exportedAt: now
        )
    }

    private static var platformName: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// What the Settings share sheet sends: the journal written to a text file
/// at the moment of sharing.
struct DiagnosticsExport: Transferable {
    let journal: DiagnosticsJournal

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try export.journal.exportFile(header: .current()))
        }
    }
}

extension HomeBridgeDiagnostic {
    /// The journal line for this event, or nil for per-event notices that
    /// would flood the journal during audio.
    var journalLine: String? {
        switch self {
        case .requestStarted(let method, _):
            "home bridge request started method=\(method.rawValue)"
        case .requestCompleted(let method, let durationMilliseconds, let correlationPresent, _):
            "home bridge request completed method=\(method.rawValue) duration_ms=\(durationMilliseconds) correlation_present=\(correlationPresent)"
        case .requestFailed(let method, let code, let uncertain, let durationMilliseconds, _):
            "home bridge request failed method=\(method.rawValue) code=\(code.rawValue) uncertain=\(uncertain) duration_ms=\(durationMilliseconds)"
        case .eventReceived, .responseReceived, .requestResolved, .reportSchemasAdvertised:
            nil
        case .transportLost:
            "home bridge transport lost"
        }
    }
}

/// Journals bridge diagnostics in every build and forwards them to `next`
/// (the unified log in Debug builds).
struct JournalingHomeBridgeDiagnostics: HomeBridgeDiagnostics {
    let journal: DiagnosticsJournal
    let next: (any HomeBridgeDiagnostics)?

    func record(_ event: HomeBridgeDiagnostic) async {
        if let line = event.journalLine { journal.record(line) }
        await next?.record(event)
    }
}
