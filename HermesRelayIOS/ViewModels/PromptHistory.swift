import Foundation

struct PromptHistory: Equatable, Sendable {
    private(set) var entries: [String] = []
    private let limit: Int
    private var cursor: Int?
    private var draftBeforeNavigation: String?

    init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func record(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if entries.last == text {
            resetNavigation()
            return
        }
        entries.append(text)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        resetNavigation()
    }

    mutating func previous(currentDraft: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor == nil {
            cursor = entries.count
            draftBeforeNavigation = currentDraft
        }
        cursor = max(0, cursor! - 1)
        return entries[cursor!]
    }

    mutating func next() -> String? {
        guard let cursor else { return nil }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        self.cursor = entries.count
        return draftBeforeNavigation ?? ""
    }

    mutating func resetNavigation() {
        cursor = nil
        draftBeforeNavigation = nil
    }
}
