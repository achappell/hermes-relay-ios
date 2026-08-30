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
