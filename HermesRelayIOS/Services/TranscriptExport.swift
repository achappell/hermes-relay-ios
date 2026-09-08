import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TranscriptExportFormatter: Sendable {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func plainText(for messages: [TranscriptMessage]) -> String {
        let sections = messages.compactMap { message -> String? in
            guard !message.text.isEmpty else { return nil }
            let timestamp = formattedTimestamp(for: message.createdAt)
            let heading = timestamp.map { "[\($0)] " } ?? ""
            return "\(heading)\(message.role.exportLabel)\n\(message.text)"
        }
        return sections.isEmpty ? "No conversation yet." : sections.joined(separator: "\n\n")
    }

    func markdown(for messages: [TranscriptMessage]) -> String {
        let sections = messages.compactMap { message -> String? in
            guard !message.text.isEmpty else { return nil }
            let timestamp = formattedTimestamp(for: message.createdAt)
            let heading = timestamp.map { "### \(message.role.exportLabel) — \($0)" }
                ?? "### \(message.role.exportLabel)"
            return "\(heading)\n\n\(message.text)"
        }
        if sections.isEmpty {
            return "## Conversation\n\n_No conversation yet._"
        }
        return "## Conversation\n\n" + sections.joined(separator: "\n\n")
    }

    private func formattedTimestamp(for date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

private extension TranscriptRole {
    var exportLabel: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Hermes"
        case .system:
            return "System"
        case .error:
            return "Unavailable"
        }
    }
}

enum TranscriptClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
