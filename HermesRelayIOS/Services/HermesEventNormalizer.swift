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

    func normalizeBinary(_ data: Data, audioFileActive: Bool) -> HermesEvent {
        _ = audioFileActive
        return .audioChunk(data)
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
}
