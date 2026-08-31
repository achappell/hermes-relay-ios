import AVFAudio
import Foundation

actor AppleAudioOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var pcmResponseBuffer = Data()
    private var isAcceptingAudio = false
    private var playbackStarted = false

    init() {
        engine.attach(playerNode)
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        stopResources()

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw AudioOutputError.unsupportedFormat
        }

        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try audioSession.setActive(true)
            #endif

            engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
            engine.prepare()
            try engine.start()
            audioFormat = avFormat
            pcmResponseBuffer.removeAll(keepingCapacity: true)
            isAcceptingAudio = true
        } catch {
            stopResources()
            throw AudioOutputError.outputFailed
        }
    }

    func append(_ pcm: Data) async throws {
        guard isAcceptingAudio, let audioFormat else {
            throw AudioOutputError.notStarted
        }

        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, pcm.count % bytesPerFrame == 0 else {
            throw AudioOutputError.outputFailed
        }
        guard !pcm.isEmpty else { return }

        pcmResponseBuffer.append(pcm)
    }

    func finish() async {
        if let audioFormat,
           let bytesPerFrame = Int(exactly: audioFormat.streamDescription.pointee.mBytesPerFrame),
           !pcmResponseBuffer.isEmpty {
            let pcmToSchedule = pcmResponseBuffer
            pcmResponseBuffer.removeAll(keepingCapacity: true)
            try? schedule(pcmToSchedule, format: audioFormat, bytesPerFrame: bytesPerFrame)
        }
        isAcceptingAudio = false
    }

    func stop() async {
        stopResources()
    }

    private func schedule(
        _ pcm: Data,
        format: AVAudioFormat?,
        bytesPerFrame: Int
    ) throws {
        guard let format else { throw AudioOutputError.notStarted }
        guard !pcm.isEmpty, pcm.count % bytesPerFrame == 0 else {
            throw AudioOutputError.outputFailed
        }

        let frameCapacity = AVAudioFrameCount(pcm.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw AudioOutputError.outputFailed
        }
        buffer.frameLength = frameCapacity

        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw AudioOutputError.outputFailed
        }
        pcm.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(destination, source, pcm.count)
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        startPlaybackIfNeeded()
    }

    private func startPlaybackIfNeeded() {
        guard !playbackStarted else { return }
        playerNode.play()
        playbackStarted = true
    }

    private func stopResources() {
        isAcceptingAudio = false
        pcmResponseBuffer.removeAll(keepingCapacity: false)
        playbackStarted = false
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        audioFormat = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}
