import SwiftUI

struct RecentTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: String
    let role: TranscriptRole
    let text: String
    let isLive: Bool

    init(id: String, role: TranscriptRole, text: String, isLive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isLive = isLive
    }
}

struct RecentTranscriptProjection: Equatable, Sendable {
    private static let maximumEntryCount = 6

    let entries: [RecentTranscriptEntry]

    init(
        messages: [TranscriptMessage],
        provisionalText: String,
        isResponseActive: Bool = false
    ) {
        var entries = messages.compactMap { message -> RecentTranscriptEntry? in
            guard message.role == .user || message.role == .assistant else { return nil }
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return RecentTranscriptEntry(
                id: message.id.uuidString,
                role: message.role,
                text: message.text
            )
        }

        let liveText = provisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveText.isEmpty {
            entries.append(
                RecentTranscriptEntry(
                    id: "live-user",
                    role: .user,
                    text: liveText,
                    isLive: true
                )
            )
        }

        if isResponseActive,
           let latestAssistantID = entries.last(where: { $0.role == .assistant })?.id {
            entries = entries.map { entry in
                guard entry.id == latestAssistantID else { return entry }
                return RecentTranscriptEntry(
                    id: entry.id,
                    role: entry.role,
                    text: entry.text,
                    isLive: true
                )
            }
        }

        self.entries = Array(entries.suffix(Self.maximumEntryCount))
    }

    var latestEntryID: String? {
        entries.last?.id
    }
}

struct RecentTranscriptFollowState: Equatable, Sendable {
    private(set) var isFollowingLatest = true

    mutating func pauseFollowing() {
        isFollowingLatest = false
    }

    mutating func resumeFollowing() {
        isFollowingLatest = true
    }
}

enum RecentTranscriptReveal {
    static func nextText(
        current: String,
        target: String,
        characterBudget: Int
    ) -> String {
        guard !target.isEmpty, current != target else { return target }
        guard target.hasPrefix(current) else { return target }

        let remaining = target.dropFirst(current.count)
        let minimumCount = min(max(1, characterBudget), remaining.count)
        let minimumEnd = remaining.index(remaining.startIndex, offsetBy: minimumCount)

        guard let whitespace = remaining[minimumEnd...].firstIndex(where: \.isWhitespace) else {
            // The first fragment must give the user visible feedback; later
            // fragments wait rather than jumping through an unfinished word.
            return current.isEmpty ? target : current
        }

        let end = remaining.index(after: whitespace)
        return current + remaining[..<end]
    }
}

enum SpeechTimingReveal {
    static func visibleText(
        target: String,
        timing: SpeechTiming,
        playbackPosition: TimeInterval
    ) -> String {
        visibleText(
            target: target,
            timings: [timing],
            playbackPosition: playbackPosition
        )
    }

    static func visibleText(
        target: String,
        timings: [SpeechTiming],
        playbackPosition: TimeInterval
    ) -> String {
        guard !target.isEmpty,
              playbackPosition.isFinite,
              !timings.isEmpty else {
            return ""
        }

        let targetWords = targetWords(in: target)
        guard !targetWords.isEmpty else { return "" }

        var targetCursor = 0
        var visibleEnd: String.Index?

        for timing in deduplicatedTimings(timings) {
            guard let mapping = map(timing, to: targetWords, from: targetCursor) else {
                break
            }

            guard playbackPosition >= timing.audioOffset else {
                break
            }

            let visibleWordCount = visibleWordCount(
                for: timing,
                mapping: mapping,
                playbackPosition: playbackPosition
            )
            if visibleWordCount > 0 {
                let lastVisibleWord = targetWords[mapping.targetRange.lowerBound + visibleWordCount - 1]
                var end = lastVisibleWord.range.upperBound
                while end < target.endIndex, target[end].isWhitespace {
                    end = target.index(after: end)
                }
                visibleEnd = end
            }

            targetCursor = mapping.targetRange.upperBound
            if playbackPosition < timing.endTime {
                break
            }
        }

        guard let visibleEnd else { return "" }
        return String(target[..<visibleEnd])
    }

    private struct TargetWord {
        let range: Range<String.Index>
        let normalized: String
    }

    private struct SegmentMapping {
        let targetRange: Range<Int>
        let usesWordTiming: Bool
    }

    private static func targetWords(in text: String) -> [TargetWord] {
        var words: [TargetWord] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            words.append(
                TargetWord(
                    range: start..<index,
                    normalized: normalizedWord(String(text[start..<index]))
                )
            )
        }

        return words
    }

    private static func deduplicatedTimings(_ timings: [SpeechTiming]) -> [SpeechTiming] {
        var latestByID: [String: SpeechTiming] = [:]
        for timing in timings {
            latestByID[timing.segmentID] = timing
        }
        return latestByID.values.sorted { lhs, rhs in
            if lhs.audioOffset == rhs.audioOffset {
                return lhs.segmentID < rhs.segmentID
            }
            return lhs.audioOffset < rhs.audioOffset
        }
    }

    private static func map(
        _ timing: SpeechTiming,
        to targetWords: [TargetWord],
        from targetCursor: Int
    ) -> SegmentMapping? {
        guard timing.audioOffset.isFinite,
              timing.duration.isFinite,
              timing.audioOffset >= 0,
              timing.duration > 0,
              timing.endTime.isFinite else {
            return nil
        }

        let spokenWords = normalizedTokens(in: timing.text)
        guard !spokenWords.isEmpty else { return nil }

        let timingWords = timing.words.map { normalizedWord($0.text) }
        let usesWordTiming = timing.timingSource == .alignment
            && timingWords == spokenWords
            && validWordSpans(timing.words, for: timing)
        let expectedWords = usesWordTiming ? timingWords : spokenWords

        guard targetCursor < targetWords.count,
              expectedWords.allSatisfy({ !$0.isEmpty }),
              expectedWords.count <= targetWords.count - targetCursor else {
            return nil
        }

        let lastStart = targetWords.count - expectedWords.count
        guard targetCursor <= lastStart else { return nil }

        for start in targetCursor...lastStart {
            let candidate = targetWords[start..<(start + expectedWords.count)]
            guard zip(candidate, expectedWords).allSatisfy({ targetWord, spokenWord in
                targetWord.normalized == spokenWord
            }) else {
                continue
            }
            return SegmentMapping(
                targetRange: start..<(start + expectedWords.count),
                usesWordTiming: usesWordTiming
            )
        }

        return nil
    }

    private static func visibleWordCount(
        for timing: SpeechTiming,
        mapping: SegmentMapping,
        playbackPosition: TimeInterval
    ) -> Int {
        let mappedCount = mapping.targetRange.count
        guard mappedCount > 0, playbackPosition >= timing.audioOffset else { return 0 }

        if mapping.usesWordTiming {
            return min(
                mappedCount,
                timing.words.prefix { $0.startTime <= max(0, playbackPosition) }.count
            )
        }

        let elapsed = playbackPosition - timing.audioOffset
        guard elapsed > 0 else { return 0 }
        let progress = min(1, max(0, elapsed / timing.duration))
        return progress >= 1
            ? mappedCount
            : max(1, Int(ceil(progress * Double(mappedCount))))
    }

    private static func validWordSpans(
        _ words: [SpeechTimingWord],
        for timing: SpeechTiming
    ) -> Bool {
        guard !words.isEmpty else { return false }

        var previousStart = timing.audioOffset
        var previousEnd = timing.audioOffset
        for (index, word) in words.enumerated() {
            guard !normalizedWord(word.text).isEmpty,
                  word.startTime.isFinite,
                  word.endTime.isFinite,
                  word.startTime >= timing.audioOffset,
                  word.endTime > word.startTime,
                  word.endTime <= timing.endTime,
                  index == 0
                    ? true
                    : word.startTime >= previousStart && word.startTime >= previousEnd else {
                return false
            }
            previousStart = word.startTime
            previousEnd = word.endTime
        }
        return true
    }

    private static func normalizedTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalizedWord(String($0)) }
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum AudioDurationReveal {
    static func visibleText(
        target: String,
        playbackPosition: TimeInterval,
        audioDuration: TimeInterval
    ) -> String {
        guard !target.isEmpty,
              playbackPosition.isFinite,
              audioDuration.isFinite,
              audioDuration > 0,
              playbackPosition > 0 else {
            return ""
        }

        let ranges = wordRanges(in: target)
        guard !ranges.isEmpty else { return "" }

        let progress = min(1, max(0, playbackPosition / audioDuration))
        let visibleWordCount = progress >= 1
            ? ranges.count
            : max(1, Int(ceil(progress * Double(ranges.count))))
        let lastVisibleRange = ranges[min(visibleWordCount, ranges.count) - 1]
        var end = lastVisibleRange.upperBound
        while end < target.endIndex, target[end].isWhitespace {
            end = target.index(after: end)
        }
        return String(target[..<end])
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }

        return ranges
    }
}

enum RecentTranscriptDisplay {
    static func liveEntry(from entries: [RecentTranscriptEntry]) -> RecentTranscriptEntry? {
        entries.last(where: \.isLive)
    }

    static func historyEntries(from entries: [RecentTranscriptEntry]) -> [RecentTranscriptEntry] {
        entries.filter { !$0.isLive }
    }

    static func entries(
        projection: RecentTranscriptProjection,
        isResponseActive: Bool,
        revealedTexts: [String: String],
        speechTimings: [SpeechTiming] = [],
        playbackDuration: TimeInterval? = nil,
        playbackPosition: TimeInterval? = nil
    ) -> [RecentTranscriptEntry] {
        guard isResponseActive,
              let latestAssistantID = projection.entries.last(where: { $0.role == .assistant })?.id else {
            return projection.entries
        }

        return projection.entries.map { entry in
            guard entry.id == latestAssistantID else { return entry }
            let pacedText: String? = revealedTexts[entry.id].flatMap { revealedText -> String? in
                guard !revealedText.isEmpty else { return nil }
                return entry.text.hasPrefix(revealedText) ? revealedText : nil
            }
            let playbackText = playbackText(
                target: entry.text,
                speechTimings: speechTimings,
                playbackDuration: playbackDuration,
                playbackPosition: playbackPosition
            )
            let visibleText = longestValidPrefix(
                in: entry.text,
                candidates: [pacedText, playbackText]
            ) ?? RecentTranscriptReveal.nextText(
                current: "",
                target: entry.text,
                characterBudget: 1
            )
            return RecentTranscriptEntry(
                id: entry.id,
                role: entry.role,
                text: visibleText,
                isLive: entry.isLive
            )
        }
    }

    static func playbackText(
        target: String,
        speechTimings: [SpeechTiming],
        playbackDuration: TimeInterval?,
        playbackPosition: TimeInterval?
    ) -> String? {
        guard let playbackPosition else { return nil }

        if !speechTimings.isEmpty {
            let timedText = SpeechTimingReveal.visibleText(
                target: target,
                timings: speechTimings,
                playbackPosition: playbackPosition
            )
            if !timedText.isEmpty {
                return timedText
            }
        }

        guard let playbackDuration else { return nil }
        let durationText = AudioDurationReveal.visibleText(
            target: target,
            playbackPosition: playbackPosition,
            audioDuration: playbackDuration
        )
        return durationText.isEmpty ? nil : durationText
    }

    static func longestValidPrefix(
        in target: String,
        candidates: [String?]
    ) -> String? {
        candidates
            .compactMap { $0 }
            .filter { !$0.isEmpty && target.hasPrefix($0) }
            .max { lhs, rhs in lhs.count < rhs.count }
    }
}

private struct RecentTranscriptRevealTarget: Equatable, Sendable {
    let id: String
    let text: String
    let usesPlaybackClock: Bool
}

struct DisplayFrameUpdateGate: Equatable, Sendable {
    private(set) var hasPendingUpdate = false

    mutating func request() -> Bool {
        guard !hasPendingUpdate else { return false }
        hasPendingUpdate = true
        return true
    }

    mutating func complete() {
        hasPendingUpdate = false
    }
}

@MainActor
final class DisplayFrameUpdateScheduler {
    private let frameNanoseconds: UInt64
    private var gate = DisplayFrameUpdateGate()
    private var pendingTask: Task<Void, Never>?

    init(frameNanoseconds: UInt64 = 16_000_000) {
        self.frameNanoseconds = frameNanoseconds
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        guard gate.request() else { return }

        let frameNanoseconds = self.frameNanoseconds
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: frameNanoseconds)
            } catch {
                self?.pendingTask = nil
                self?.gate.complete()
                return
            }

            guard let self, !Task.isCancelled else { return }
            pendingTask = nil
            gate.complete()
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        gate.complete()
    }
}

struct RecentTranscriptRail: View {
    let messages: [TranscriptMessage]
    let provisionalText: String
    let hasPersistedHistory: Bool
    let isResponseActive: Bool
    let speechTimings: [SpeechTiming]
    let playbackDuration: TimeInterval?
    let playbackPosition: TimeInterval?
    let onShowHistory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followState = RecentTranscriptFollowState()
    @State private var revealedTexts: [String: String] = [:]
    @State private var revealFloorScheduler = DisplayFrameUpdateScheduler()

    private static let bottomAnchorID = "recent-transcript-bottom"
    private static let liveTranscriptViewportHeight: CGFloat = 192
    // Text-only turns still need a restrained reveal so a complete response
    // does not appear as one abrupt block.
    private static let revealStepNanoseconds: UInt64 = 320_000_000

    private var projection: RecentTranscriptProjection {
        RecentTranscriptProjection(
            messages: messages,
            provisionalText: provisionalText,
            isResponseActive: isResponseActive
        )
    }

    private var displayedEntries: [RecentTranscriptEntry] {
        RecentTranscriptDisplay.entries(
            projection: projection,
            isResponseActive: isResponseActive,
            revealedTexts: revealedTexts,
            speechTimings: speechTimings,
            playbackDuration: playbackDuration,
            playbackPosition: playbackPosition
        )
    }

    private var liveEntry: RecentTranscriptEntry? {
        RecentTranscriptDisplay.liveEntry(from: displayedEntries)
    }

    private var historyEntries: [RecentTranscriptEntry] {
        RecentTranscriptDisplay.historyEntries(from: displayedEntries)
    }

    private var revealTarget: RecentTranscriptRevealTarget? {
        guard isResponseActive,
              let entry = projection.entries.last(where: { $0.role == .assistant }) else {
            return nil
        }
        return RecentTranscriptRevealTarget(
            id: entry.id,
            text: entry.text,
            usesPlaybackClock: playbackPosition != nil
                && (!speechTimings.isEmpty || playbackDuration != nil)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let liveEntry {
                LiveTranscriptEntryView(
                    entry: liveEntry,
                    viewportHeight: Self.liveTranscriptViewportHeight,
                    reduceMotion: reduceMotion
                )
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if liveEntry == nil {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(historyEntries) { entry in
                                RecentTranscriptEntryView(entry: entry)
                                    .id(entry.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 152)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in
                                followState.pauseFollowing()
                            }
                    )
                    .onTapGesture {
                        followState.pauseFollowing()
                    }
                    .onAppear {
                        scrollToLatest(using: proxy, animated: false)
                    }
                    .onChange(of: displayedEntries) { _, _ in
                        guard followState.isFollowingLatest else { return }
                        scrollToLatest(using: proxy, animated: !reduceMotion)
                    }
                    .onChange(of: followState.isFollowingLatest) { _, isFollowing in
                        guard isFollowing else { return }
                        scrollToLatest(using: proxy, animated: !reduceMotion)
                    }
                    .accessibilityLabel(
                        followState.isFollowingLatest
                            ? "Recent transcript, following newest text"
                            : "Recent transcript, reading paused"
                    )
                }
            }

            HStack(spacing: 12) {
                if !followState.isFollowingLatest {
                    Button("Resume live") {
                        followState.resumeFollowing()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityHint("Returns the transcript to the newest text")
                }

                Spacer(minLength: 8)

                if hasPersistedHistory {
                    Button(action: onShowHistory) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }

            .task(id: revealTarget) {
                await revealText(for: revealTarget)
            }
            .onAppear {
                updateRevealFloor()
            }
            .onChange(of: playbackPosition) { _, _ in
                scheduleRevealFloorUpdate()
            }
            .onChange(of: playbackDuration) { _, _ in
                scheduleRevealFloorUpdate()
            }
            .onDisappear {
                revealFloorScheduler.cancel()
            }
        }
        .frame(maxWidth: 680)
        .accessibilityElement(children: .contain)
    }

    @MainActor
    private func revealText(for target: RecentTranscriptRevealTarget?) async {
        guard let target else {
            return
        }
        guard !target.usesPlaybackClock else { return }

        var visibleText = revealedTexts[target.id] ?? ""
        if !target.text.hasPrefix(visibleText) {
            visibleText = ""
            revealedTexts[target.id] = visibleText
        }

        while !Task.isCancelled, visibleText != target.text {
            let nextText = RecentTranscriptReveal.nextText(
                current: visibleText,
                target: target.text,
                characterBudget: 1
            )
            guard nextText != visibleText else { return }
            visibleText = nextText
            revealedTexts[target.id] = visibleText

            guard visibleText != target.text else { return }
            do {
                try await Task.sleep(nanoseconds: Self.revealStepNanoseconds)
            } catch {
                return
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    @MainActor
    private func updateRevealFloor() {
        guard isResponseActive,
              let position = playbackPosition,
              let entry = projection.entries.last(where: { $0.role == .assistant }) else {
            return
        }

        let current = revealedTexts[entry.id] ?? ""
        let candidate = RecentTranscriptDisplay.playbackText(
            target: entry.text,
            speechTimings: speechTimings,
            playbackDuration: playbackDuration,
            playbackPosition: position
        )
        guard let visibleText = RecentTranscriptDisplay.longestValidPrefix(
            in: entry.text,
            candidates: [current, candidate]
        ), visibleText.count > current.count else { return }
        revealedTexts[entry.id] = visibleText
    }

    @MainActor
    private func scheduleRevealFloorUpdate() {
        revealFloorScheduler.schedule { [self] in
            updateRevealFloor()
        }
    }
}

private struct RecentTranscriptEntryView: View {
    let entry: RecentTranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecentTranscriptEntryHeader(entry: entry)

            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            entry.isLive
                ? "(entry.role.railLabel), live, (entry.text)"
                : "(entry.role.railLabel), (entry.text)"
        )
    }
}

private struct LiveTranscriptEntryView: View {
    let entry: RecentTranscriptEntry
    let viewportHeight: CGFloat
    let reduceMotion: Bool

    private let bottomAnchorID = "live-transcript-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecentTranscriptEntryHeader(entry: entry)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.text)
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: viewportHeight)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onAppear {
                    scrollToLatest(using: proxy, animated: false)
                }
                .onChange(of: entry.text) { _, _ in
                    scrollToLatest(using: proxy, animated: !reduceMotion)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            entry.isLive
                ? "(entry.role.railLabel), live, (entry.text)"
                : "(entry.role.railLabel), (entry.text)"
        )
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct RecentTranscriptEntryHeader: View {
    let entry: RecentTranscriptEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.role.railLabel.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(entry.role.railTint)

            if entry.isLive {
                Text("LIVE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension TranscriptRole {
    var railLabel: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Hermes"
        case .system:
            return "System"
        case .error:
            return "Error"
        }
    }

    var railTint: Color {
        switch self {
        case .user:
            return .accentColor
        case .assistant:
            return .secondary
        case .system:
            return .yellow
        case .error:
            return .red
        }
    }
}

#Preview("Recent Transcript Rail") {
    RecentTranscriptRail(
        messages: [
            TranscriptMessage(role: .user, text: "Can you walk me through the longer answer?"),
            TranscriptMessage(
                role: .assistant,
                text: "The recent rail keeps the current exchange visible as Hermes continues speaking. Scroll up to read older lines, then resume live when you are ready to follow the newest text."
            )
        ],
        provisionalText: "",
        hasPersistedHistory: true,
        isResponseActive: false,
        speechTimings: [],
        playbackDuration: nil,
        playbackPosition: nil,
        onShowHistory: {}
    )
    .padding()
}
