import Foundation

enum HermesEventNormalizationError: LocalizedError, Equatable, Sendable {
    case invalidJSON
    case nonObjectJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The Hermes relay sent invalid JSON."
        case .nonObjectJSON:
            return "The Hermes relay sent a non-object JSON event."
        }
    }
}

struct HermesEventNormalizer: Sendable {
    private var renderedPreview = ""
    private var streamedText = false

    mutating func normalizeJSON(_ data: Data, turnID: String) throws -> [HermesEvent] {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HermesEventNormalizationError.nonObjectJSON
            }
            object = decoded
        } catch let error as HermesEventNormalizationError {
            throw error
        } catch {
            throw HermesEventNormalizationError.invalidJSON
        }

        let type = stringValue(for: "type", in: object) ?? "missing"
        let payload = object["payload"] as? [String: Any] ?? object

        switch type {
        case "message.start":
            return [.messageStart]
        case "text_delta", "message.delta":
            if type == "message.delta", payload["rendered"] == nil {
                let delta = stringValue(for: "text", in: payload) ?? ""
                guard !delta.isEmpty else { return [] }
                renderedPreview += delta
                streamedText = true
                return [.textDelta(delta)]
            }
            let preview = stringValue(for: "rendered", in: payload)
                ?? stringValue(for: "text", in: payload)
                ?? ""
            return normalizePreview(
                preview,
                replace: boolValue(for: "replace", in: payload)
                    || boolValue(for: "replace", in: object)
            )
        case "text", "text_final":
            let finalText = stringValue(for: "text", in: payload)
                ?? stringValue(for: "rendered", in: payload)
                ?? ""
            return normalizeFinalText(finalText)
        case "message.complete":
            let finalText = stringValue(for: "text", in: payload)
                ?? stringValue(for: "rendered", in: payload)
                ?? ""
            let update = normalizeFinalText(finalText)
            let completion = HermesEvent.messageComplete(
                text: finalText,
                reasoning: stringValue(for: "reasoning", in: payload) ?? "",
                failureReason: stringValue(for: "failure_reason", in: payload)
                    ?? stringValue(for: "failureReason", in: payload)
                    ?? ""
            )
            return update + [completion]
        case "thinking.delta", "reasoning.delta", "reasoning.available":
            guard let text = stringValue(for: "text", in: payload), !text.isEmpty else {
                return []
            }
            return [.thinkingDelta(text)]
        case "status", "status.update":
            let text = stringValue(for: "text", in: payload)
                ?? stringValue(for: "status", in: payload)
                ?? stringValue(for: "text", in: object)
                ?? stringValue(for: "status", in: object)
                ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            let kind = stringValue(for: "kind", in: payload)
                ?? stringValue(for: "kind", in: object)
            return [.status(text: text, kind: kind)]
        case "audio_start":
            return [
                .audioStart(
                    AudioFormat(
                        sampleRate: intValue(for: "sample_rate", in: payload, default: 24000),
                        channels: intValue(for: "channels", in: payload, default: 1),
                        sampleWidth: intValue(for: "sample_width", in: payload, default: 2)
                    )
                )
            ]
        case "audio_end":
            return [.audioEnd]
        case "audio_file_start":
            return [
                .audioFileStart(
                    contentType: stringValue(for: "content_type", in: payload)
                        ?? stringValue(for: "content_type", in: object)
                        ?? "audio/wav"
                )
            ]
        case "audio_file_end":
            return [.audioFileEnd]
        case "audio_abort":
            return [
                .audioAbort(
                    turnID: stringValue(for: "turn_id", in: payload)
                        ?? stringValue(for: "turn_id", in: object)
                        ?? turnID,
                    reason: stringValue(for: "error", in: payload)
                        ?? stringValue(for: "reason", in: payload)
                        ?? stringValue(for: "message", in: payload)
                        ?? stringValue(for: "error", in: object)
                        ?? stringValue(for: "reason", in: object)
                        ?? "audio stream aborted"
                )
            ]
        case "turn_interrupted":
            return [
                .turnInterrupted(
                    turnID: stringValue(for: "turn_id", in: payload)
                        ?? stringValue(for: "turn_id", in: object)
                        ?? turnID,
                    reason: stringValue(for: "reason", in: payload)
                        ?? stringValue(for: "error", in: payload)
                        ?? stringValue(for: "message", in: payload)
                        ?? stringValue(for: "reason", in: object)
                        ?? stringValue(for: "error", in: object)
                        ?? stringValue(for: "message", in: object)
                        ?? "turn interrupted"
                )
            ]
        case "speech_timing":
            guard let timing = normalizeSpeechTiming(payload, turnID: turnID) else {
                return [.unknown(type: type)]
            }
            return [.speechTiming(timing)]
        case "error":
            let message = stringValue(for: "error", in: payload)
                ?? stringValue(for: "message", in: payload)
                ?? stringValue(for: "error", in: object)
                ?? stringValue(for: "message", in: object)
                ?? "voice-session error"
            return [.error(message)]
        case "turn_end", "turn_complete":
            return [
                .turnComplete(
                    turnID: stringValue(for: "turn_id", in: payload)
                        ?? stringValue(for: "turn_id", in: object)
                        ?? turnID
                )
            ]
        default:
            return [.unknown(type: type)]
        }
    }

    /// Home has already passed its strict schema and redaction boundary. This
    /// method is the only bridge from that typed event into the existing
    /// normalized seam; Home never gets a second Standard parser.
    /// Standard has no separate turn-complete event: a turn-owned
    /// `message.complete` with a terminal (or absent) status ends the turn, the
    /// same rule Home applies before releasing the turn.
    private static func homeTurnTerminal(status: String?, turnID: String?) -> [HermesEvent] {
        guard let turnID else { return [] }
        switch status?.lowercased() {
        case nil, "completed", "complete", "failed", "error", "timeout", "timed_out", "timed-out":
            return [.turnComplete(turnID: turnID)]
        case "cancelled", "canceled", "interrupted", "aborted", "stopped":
            return [.turnInterrupted(turnID: turnID, reason: "turn interrupted")]
        default:
            return []
        }
    }

    mutating func normalizeHome(_ event: HomeStandardEvent) -> [HermesEvent] {
        switch event.type {
        case .messageStart:
            return [.messageStart]
        case .messageDelta, .textDelta:
            guard case .delta(let rendered, let text, let replace, _) = event.payload else { return [] }
            return normalizePreview(rendered ?? text ?? "", replace: replace)
        case .text, .textFinal:
            guard case .final(let rendered, let text, _, _, _) = event.payload else { return [] }
            return normalizeFinalText(text ?? rendered ?? "")
        case .messageComplete:
            guard case .final(let rendered, let text, let status, let reasoning, let failureReason) = event.payload else { return [] }
            let finalText = text ?? rendered ?? ""
            let update = normalizeFinalText(finalText)
            return update + [
                .messageComplete(
                    text: finalText,
                    reasoning: reasoning ?? "",
                    failureReason: failureReason?.rawValue ?? ""
                )
            ] + Self.homeTurnTerminal(status: status, turnID: event.scope.turnID)
        case .thinking, .reasoning:
            guard case .activity(let text, _, let reasoning, _) = event.payload else { return [] }
            let activity = text ?? reasoning ?? ""
            return activity.isEmpty ? [] : [.thinkingDelta(activity)]
        case .status:
            guard case .activity(let text, let status, _, let kind) = event.payload else { return [] }
            let activity = text ?? status ?? ""
            return activity.isEmpty ? [] : [.status(text: activity, kind: kind?.rawValue)]
        case .turnComplete:
            guard event.scope.turnID != nil else { return [] }
            return [.turnComplete(turnID: event.scope.turnID!)]
        case .turnInterrupted:
            guard event.scope.turnID != nil else { return [] }
            return [.turnInterrupted(turnID: event.scope.turnID!, reason: "turn interrupted")]
        case .audioAbort:
            guard event.scope.turnID != nil else { return [] }
            return [.audioAbort(turnID: event.scope.turnID!, reason: "audio aborted")]
        case .error:
            guard case .error(let safeError) = event.payload else { return [] }
            return [.error(safeError.code.rawValue)]
        }
    }

    mutating func normalizeHomeAudio(
        _ event: HomeBridgeEvent
    ) -> [HermesEvent] {
        switch event {
        case .audioStart(_, let format):
            return [
                .audioStart(
                    AudioFormat(
                        sampleRate: format.sampleRate,
                        channels: format.channels,
                        sampleWidth: format.sampleWidth,
                        byteOrder: format.byteOrder
                    )
                )
            ]
        case .binaryPCM(_, let data):
            return [.audioChunk(data)]
        case .audioTerminal(_, let terminal):
            switch terminal {
            case .end: return [.audioEnd]
            case .fallback, .unavailable, .invalid:
                return [.audioAbort(turnID: "home", reason: terminal.rawValue)]
            }
        default:
            return []
        }
    }

    func normalizeBinary(_ data: Data, audioFileActive: Bool) -> HermesEvent {
        audioFileActive ? .audioFileChunk(data) : .audioChunk(data)
    }

    private mutating func normalizePreview(_ preview: String, replace: Bool) -> [HermesEvent] {
        guard !preview.isEmpty else { return [] }

        if replace {
            renderedPreview = preview
            streamedText = true
            return [.textReplace(preview)]
        }
        if !streamedText {
            renderedPreview = preview
            streamedText = true
            return [.textDelta(preview)]
        }
        if preview == renderedPreview {
            return []
        }
        if preview.hasPrefix(renderedPreview) {
            let suffix = String(preview.dropFirst(renderedPreview.count))
            renderedPreview = preview
            return suffix.isEmpty ? [] : [.textDelta(suffix)]
        }

        renderedPreview = preview
        return [.textReplace(preview)]
    }

    private mutating func normalizeFinalText(_ finalText: String) -> [HermesEvent] {
        guard !finalText.isEmpty else { return [] }
        guard streamedText else {
            renderedPreview = finalText
            streamedText = true
            return [.textDelta(finalText)]
        }
        if finalText == renderedPreview {
            return []
        }
        if finalText.hasPrefix(renderedPreview) {
            let suffix = String(finalText.dropFirst(renderedPreview.count))
            renderedPreview = finalText
            return suffix.isEmpty ? [] : [.textDelta(suffix)]
        }

        renderedPreview = finalText
        return [.textReplace(finalText)]
    }

    private func normalizeSpeechTiming(
        _ payload: [String: Any],
        turnID: String
    ) -> SpeechTiming? {
        guard let segmentID = stringValue(for: "segment_id", in: payload),
              !segmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let text = stringValue(for: "text", in: payload)
                ?? stringValue(for: "rendered", in: payload),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let audioOffsetMilliseconds = doubleValue(for: "audio_offset_ms", in: payload),
              let durationMilliseconds = doubleValue(for: "duration_ms", in: payload),
              audioOffsetMilliseconds.isFinite,
              durationMilliseconds.isFinite,
              audioOffsetMilliseconds >= 0,
              durationMilliseconds > 0,
              (audioOffsetMilliseconds + durationMilliseconds).isFinite else {
            return nil
        }

        let audioOffset = audioOffsetMilliseconds / 1_000
        let duration = durationMilliseconds / 1_000
        let fallback = { (reason: SpeechTimingFallbackReason) in
            SpeechTiming(
                segmentID: segmentID,
                text: text,
                timingSource: .durationFallback,
                audioOffset: audioOffset,
                duration: duration,
                fallbackReason: reason,
                words: []
            )
        }

        let source = stringValue(for: "timing_source", in: payload)
            .flatMap { SpeechTimingSource(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let source else {
            return fallback(.invalid)
        }

        guard source == .alignment else {
            return SpeechTiming(
                segmentID: segmentID,
                text: text,
                timingSource: .durationFallback,
                audioOffset: audioOffset,
                duration: duration,
                fallbackReason: fallbackReason(in: payload),
                words: []
            )
        }

        guard let rawWords = payload["words"] as? [[String: Any]],
              let words = validatedSpeechTimingWords(
                  rawWords,
                  audioOffsetMilliseconds: audioOffsetMilliseconds,
                  durationMilliseconds: durationMilliseconds
              ),
              normalizedTokens(in: text) == words.map({ normalizedToken($0.text) }) else {
            return fallback(.invalid)
        }

        return SpeechTiming(
            segmentID: segmentID,
            text: text,
            timingSource: .alignment,
            audioOffset: audioOffset,
            duration: duration,
            fallbackReason: nil,
            words: words
        )
    }

    private func validatedSpeechTimingWords(
        _ rawWords: [[String: Any]],
        audioOffsetMilliseconds: Double,
        durationMilliseconds: Double
    ) -> [SpeechTimingWord]? {
        guard !rawWords.isEmpty else { return nil }

        let segmentEndMilliseconds = audioOffsetMilliseconds + durationMilliseconds
        var previousStartMilliseconds = audioOffsetMilliseconds
        var previousEndMilliseconds = audioOffsetMilliseconds
        var words: [SpeechTimingWord] = []

        for (index, rawWord) in rawWords.enumerated() {
            guard let text = stringValue(for: "text", in: rawWord),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let startMilliseconds = doubleValue(for: "start_ms", in: rawWord),
                  let endMilliseconds = doubleValue(for: "end_ms", in: rawWord),
                  startMilliseconds.isFinite,
                  endMilliseconds.isFinite,
                  startMilliseconds >= audioOffsetMilliseconds,
                  endMilliseconds > startMilliseconds,
                  endMilliseconds <= segmentEndMilliseconds,
                  index == 0
                    ? true
                    : startMilliseconds >= previousStartMilliseconds
                        && startMilliseconds >= previousEndMilliseconds else {
                return nil
            }

            words.append(
                SpeechTimingWord(
                    text: text,
                    startTime: startMilliseconds / 1_000,
                    endTime: endMilliseconds / 1_000
                )
            )
            previousStartMilliseconds = startMilliseconds
            previousEndMilliseconds = endMilliseconds
        }

        return words
    }

    private func fallbackReason(in payload: [String: Any]) -> SpeechTimingFallbackReason {
        guard let rawReason = stringValue(for: "fallback_reason", in: payload) else {
            return .missing
        }
        return SpeechTimingFallbackReason(rawValue: rawReason) ?? .invalid
    }

    private func normalizedTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalizedToken(String($0)) }
    }

    private func normalizedToken(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func stringValue(for key: String, in object: [String: Any]) -> String? {
        object[key] as? String
    }

    private func boolValue(for key: String, in object: [String: Any]) -> Bool {
        object[key] as? Bool ?? false
    }

    private func intValue(for key: String, in object: [String: Any], default defaultValue: Int) -> Int {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? String, let integer = Int(value) { return integer }
        return defaultValue
    }

    private func doubleValue(for key: String, in object: [String: Any]) -> Double? {
        if let value = object[key] as? Double { return value }
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? String { return Double(value) }
        return nil
    }
}
