import Foundation

struct WAVFallbackWriter: Sendable {
    func write(pcm: Data, format: AudioFormat) throws -> URL {
        try PCMFormatValidator.validate(format)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesAudioFallback", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var wav = Data(capacity: 44 + pcm.count)
        wav.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16, to: &wav)
        appendUInt16(1, to: &wav)
        appendUInt16(UInt16(format.channels), to: &wav)
        appendUInt32(UInt32(format.sampleRate), to: &wav)
        appendUInt32(UInt32(format.sampleRate * format.channels * format.sampleWidth), to: &wav)
        appendUInt16(UInt16(format.channels * format.sampleWidth), to: &wav)
        appendUInt16(UInt16(format.sampleWidth * 8), to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(pcm.count), to: &wav)
        wav.append(pcm)

        try wav.write(to: url, options: .atomic)
        return url
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}

enum WAVAudioDecodingError: LocalizedError, Equatable, Sendable {
    case invalidFile
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Hermes returned an invalid WAV audio file."
        case .unsupportedFormat:
            return "Hermes returned an unsupported WAV audio format."
        }
    }
}

struct DecodedWAVAudio: Equatable, Sendable {
    let pcm: Data
    let format: AudioFormat
}

struct WAVAudioDecoder: Sendable {
    func decode(_ wav: Data) throws -> DecodedWAVAudio {
        guard wav.count >= 12,
              chunkID(in: wav, offset: 0) == "RIFF",
              chunkID(in: wav, offset: 8) == "WAVE" else {
            throw WAVAudioDecodingError.invalidFile
        }

        var cursor = 12
        var format: AudioFormat?
        var pcm: Data?

        while cursor <= wav.count - 8 {
            let chunkSize = Int(readUInt32(from: wav, offset: cursor + 4))
            let payloadStart = cursor + 8
            guard chunkSize <= wav.count - payloadStart else {
                throw WAVAudioDecodingError.invalidFile
            }
            let payloadEnd = payloadStart + chunkSize

            switch chunkID(in: wav, offset: cursor) {
            case "fmt ":
                guard chunkSize >= 16 else {
                    throw WAVAudioDecodingError.invalidFile
                }
                guard readUInt16(from: wav, offset: payloadStart) == 1 else {
                    throw WAVAudioDecodingError.unsupportedFormat
                }
                let channels = Int(readUInt16(from: wav, offset: payloadStart + 2))
                let sampleRate = Int(readUInt32(from: wav, offset: payloadStart + 4))
                let blockAlign = Int(readUInt16(from: wav, offset: payloadStart + 12))
                let bitsPerSample = Int(readUInt16(from: wav, offset: payloadStart + 14))
                let sampleWidth = bitsPerSample / 8
                guard channels > 0,
                      sampleRate > 0,
                      bitsPerSample == 16,
                      sampleWidth == 2,
                      blockAlign == channels * sampleWidth else {
                    throw WAVAudioDecodingError.unsupportedFormat
                }
                format = AudioFormat(
                    sampleRate: sampleRate,
                    channels: channels,
                    sampleWidth: sampleWidth
                )
            case "data":
                pcm = Data(wav[payloadStart..<payloadEnd])
            default:
                break
            }

            let paddedEnd = payloadEnd + chunkSize % 2
            guard paddedEnd <= wav.count else {
                throw WAVAudioDecodingError.invalidFile
            }
            cursor = paddedEnd
        }

        guard let format, let pcm else {
            throw WAVAudioDecodingError.invalidFile
        }
        guard pcm.count % (format.channels * format.sampleWidth) == 0 else {
            throw WAVAudioDecodingError.invalidFile
        }
        return DecodedWAVAudio(pcm: pcm, format: format)
    }

    private func chunkID(in data: Data, offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private func readUInt16(from data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(from data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
