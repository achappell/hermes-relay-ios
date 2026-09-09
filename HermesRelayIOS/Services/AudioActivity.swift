import Foundation
import AVFAudio

enum MicrophoneActivity: Equatable, Sendable {
    case silence
    case backgroundNoise
    case speech
    case unavailable
}

struct AudioActivityClassifier: Sendable {
    let noiseThreshold: Float
    let speechThreshold: Float

    init(noiseThreshold: Float, speechThreshold: Float) {
        precondition(noiseThreshold >= 0)
        precondition(speechThreshold > noiseThreshold)
        self.noiseThreshold = noiseThreshold
        self.speechThreshold = speechThreshold
    }

    func classify(level: Float) -> MicrophoneActivity {
        let normalizedLevel = Self.normalize(level)
        if normalizedLevel < noiseThreshold {
            return .silence
        }
        if normalizedLevel < speechThreshold {
            return .backgroundNoise
        }
        return .speech
    }

    private static func normalize(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }
}

struct AudioActivitySnapshot: Equatable, Sendable {
    let microphoneLevel: Float
    let microphoneActivity: MicrophoneActivity
    let playbackLevel: Float
    let playbackActive: Bool

    static let safe = AudioActivitySnapshot(
        microphoneLevel: 0,
        microphoneActivity: .silence,
        playbackLevel: 0,
        playbackActive: false
    )
}

enum HandsFreeAudioRouteSafety: Equatable, Sendable {
    case echoSafe
    case notEchoSafe
    case unknown
}

/// Keeps the microphone alive while hands-free mode listens during playback.
/// The two platform adapters share this lease so one of them cannot deactivate
/// the audio session out from under the other.
actor AppleAudioSessionCoordinator {
    private var inputActive = false
    private var outputActive = false

    func activateInput() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        inputActive = true
    }

    func activateOutput() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true)
        #endif
        outputActive = true
    }

    func deactivateInput() {
        inputActive = false
        deactivateIfUnused()
    }

    func deactivateOutput() {
        outputActive = false
        deactivateIfUnused()
    }

    private func deactivateIfUnused() {
        guard !inputActive, !outputActive else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

protocol HandsFreeAudioRouteSafetyProvider: Sendable {
    func currentSafety() async -> HandsFreeAudioRouteSafety
}

struct SystemHandsFreeAudioRouteSafetyProvider: HandsFreeAudioRouteSafetyProvider {
    func currentSafety() async -> HandsFreeAudioRouteSafety {
        #if os(iOS)
        let outputPorts = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputPorts.isEmpty else { return .unknown }

        // The built-in speaker and remote speakers are not safe for automatic
        // barge-in: the microphone can hear Hermes and wake the next turn.
        let isEchoSafe = outputPorts.allSatisfy { port in
            switch port.portType {
            case .headphones, .bluetoothHFP, .bluetoothLE:
                return true
            default:
                return false
            }
        }
        return isEchoSafe ? .echoSafe : .notEchoSafe
        #else
        return .unknown
        #endif
    }
}

enum AudioActivityEvent: Equatable, Sendable {
    case microphone(level: Float)
    case microphoneUnavailable
    case microphoneEnded
    case playback(level: Float)
    case playbackEnded
}

protocol AudioActivityReporter: Sendable {
    func reportMicrophone(level: Float) async
    func reportMicrophoneUnavailable() async
    func reportMicrophoneEnded() async
    func reportPlayback(level: Float) async
    func reportPlaybackEnded() async
}

actor AudioActivityStore: AudioActivityReporter {
    private let classifier: AudioActivityClassifier
    private let minimumEmissionIntervalNanoseconds: UInt64
    private var snapshotContinuations: [UUID: AsyncStream<AudioActivitySnapshot>.Continuation] = [:]

    private var snapshot = AudioActivitySnapshot.safe
    private var lastEmissionAt: UInt64?

    init(
        classifier: AudioActivityClassifier = AudioActivityClassifier(
            noiseThreshold: 0.02,
            speechThreshold: 0.08
        ),
        minimumEmissionIntervalNanoseconds: UInt64 = 50_000_000
    ) {
        self.classifier = classifier
        self.minimumEmissionIntervalNanoseconds = minimumEmissionIntervalNanoseconds
    }

    func snapshots() -> AsyncStream<AudioActivitySnapshot> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<AudioActivitySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshotContinuations[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSnapshotSubscriber(subscriberID)
            }
        }
        continuation.yield(snapshot)
        return stream
    }

    private func removeSnapshotSubscriber(_ subscriberID: UUID) {
        snapshotContinuations.removeValue(forKey: subscriberID)
    }

    func currentSnapshot() -> AudioActivitySnapshot {
        snapshot
    }

    @discardableResult
    func ingest(
        _ event: AudioActivityEvent,
        at timestampNanoseconds: UInt64
    ) -> AudioActivitySnapshot? {
        let previous = snapshot
        switch event {
        case .microphone(let level):
            let normalizedLevel = Self.normalize(level)
            snapshot = AudioActivitySnapshot(
                microphoneLevel: normalizedLevel,
                microphoneActivity: classifier.classify(level: normalizedLevel),
                playbackLevel: previous.playbackLevel,
                playbackActive: previous.playbackActive
            )
        case .microphoneUnavailable:
            snapshot = AudioActivitySnapshot(
                microphoneLevel: 0,
                microphoneActivity: .unavailable,
                playbackLevel: previous.playbackLevel,
                playbackActive: previous.playbackActive
            )
        case .microphoneEnded:
            snapshot = AudioActivitySnapshot(
                microphoneLevel: 0,
                microphoneActivity: .silence,
                playbackLevel: previous.playbackLevel,
                playbackActive: previous.playbackActive
            )
        case .playback(let level):
            snapshot = AudioActivitySnapshot(
                microphoneLevel: previous.microphoneLevel,
                microphoneActivity: previous.microphoneActivity,
                playbackLevel: Self.normalize(level),
                playbackActive: true
            )
        case .playbackEnded:
            snapshot = AudioActivitySnapshot(
                microphoneLevel: previous.microphoneLevel,
                microphoneActivity: previous.microphoneActivity,
                playbackLevel: 0,
                playbackActive: false
            )
        }

        let stateChanged = previous.microphoneActivity != snapshot.microphoneActivity
            || previous.playbackActive != snapshot.playbackActive
        let intervalElapsed = if let lastEmissionAt {
            timestampNanoseconds >= lastEmissionAt
                && timestampNanoseconds - lastEmissionAt >= minimumEmissionIntervalNanoseconds
        } else {
            true
        }
        guard stateChanged || intervalElapsed else { return nil }

        lastEmissionAt = timestampNanoseconds
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    func reportMicrophone(level: Float) async {
        _ = ingest(.microphone(level: level), at: Self.now)
    }

    func reportMicrophoneUnavailable() async {
        _ = ingest(.microphoneUnavailable, at: Self.now)
    }

    func reportMicrophoneEnded() async {
        _ = ingest(.microphoneEnded, at: Self.now)
    }

    func reportPlayback(level: Float) async {
        _ = ingest(.playback(level: level), at: Self.now)
    }

    func reportPlaybackEnded() async {
        _ = ingest(.playbackEnded, at: Self.now)
    }

    private static var now: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func normalize(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }
}

struct NoopAudioActivityReporter: AudioActivityReporter {
    func reportMicrophone(level: Float) async {}
    func reportMicrophoneUnavailable() async {}
    func reportMicrophoneEnded() async {}
    func reportPlayback(level: Float) async {}
    func reportPlaybackEnded() async {}
}

enum PCMActivityAnalyzer {
    static func normalizedRMS(_ pcm: Data) -> Float {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        for sampleIndex in 0..<sampleCount {
            let byteOffset = sampleIndex * MemoryLayout<Int16>.size
            let bits = UInt16(pcm[byteOffset])
                | UInt16(pcm[byteOffset + 1]) << 8
            let sample = Double(Int16(bitPattern: bits)) / Double(Int16.max)
            sumOfSquares += sample * sample
        }

        return min(
            max(Float((sumOfSquares / Double(sampleCount)).squareRoot()), 0),
            1
        )
    }

    static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        if let channels = buffer.floatChannelData {
            var sumOfSquares = 0.0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    let sample = Double(channels[channel][frame])
                    sumOfSquares += sample * sample
                }
            }
            return min(
                max(Float((sumOfSquares / Double(frameCount * channelCount)).squareRoot()), 0),
                1
            )
        }

        if let channels = buffer.int16ChannelData {
            var sumOfSquares = 0.0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    let sample = Double(channels[channel][frame]) / Double(Int16.max)
                    sumOfSquares += sample * sample
                }
            }
            return min(
                max(Float((sumOfSquares / Double(frameCount * channelCount)).squareRoot()), 0),
                1
            )
        }

        return 0
    }
}
