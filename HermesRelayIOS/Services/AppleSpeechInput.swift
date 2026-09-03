import AVFAudio
import Foundation
import Speech

actor AppleSpeechInput: SpeechInput {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeContinuation: AsyncThrowingStream<SpeechRecognitionUpdate, Error>.Continuation?
    private let activityReporter: any AudioActivityReporter
    private let finalResultGraceNanoseconds: UInt64
    private var configurationObserver: AudioEngineConfigurationObserver?

    init(
        locale: Locale = Locale(identifier: "en-US"),
        finalResultGraceNanoseconds: UInt64 = 1_000_000_000,
        activityReporter: any AudioActivityReporter = NoopAudioActivityReporter()
    ) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.activityReporter = activityReporter
        self.finalResultGraceNanoseconds = finalResultGraceNanoseconds
    }

    func authorization() async -> SpeechAuthorization {
        combinedAuthorization(
            speech: SFSpeechRecognizer.authorizationStatus(),
            microphone: microphoneAuthorization()
        )
    }

    func requestAuthorization() async -> SpeechAuthorization {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return combinedAuthorization(
            speech: speechStatus,
            microphone: microphoneGranted ? .authorized : .microphoneDenied
        )
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionUpdate, Error> {
        guard await authorization() == .authorized else {
            await activityReporter.reportMicrophoneUnavailable()
            throw SpeechInputError.notAuthorized
        }
        guard let recognizer else {
            await activityReporter.reportMicrophoneUnavailable()
            throw SpeechInputError.captureFailed
        }

        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionUpdate, Error>.makeStream()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.channelCount > 0 else {
                throw SpeechInputError.captureFailed
            }
            let activityReporter = self.activityReporter
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                let level = PCMActivityAnalyzer.normalizedRMS(buffer)
                Task {
                    await activityReporter.reportMicrophone(level: level)
                }
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            recognitionRequest = request
            activeContinuation = continuation
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let didFail = error != nil
                Task {
                    await self?.handleRecognition(text: text, isFinal: isFinal, didFail: didFail)
                }
            }
            installConfigurationObserver()
            return stream
        } catch {
            stopResources()
            await activityReporter.reportMicrophoneUnavailable()
            continuation.finish(throwing: SpeechInputError.captureFailed)
            throw SpeechInputError.captureFailed
        }
    }

    func cancel() async {
        let wasActive = activeContinuation != nil
        activeContinuation?.finish(throwing: SpeechInputError.cancelled)
        activeContinuation = nil
        stopResources()
        if wasActive {
            await activityReporter.reportMicrophoneEnded()
        }
    }

    func finish() async {
        guard activeContinuation != nil else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()

        // Give the recognizer a brief window to deliver its final, most accurate
        // result. If it doesn't, terminate the stream so the coordinator isn't
        // left waiting out its full recognition timeout.
        try? await Task.sleep(nanoseconds: finalResultGraceNanoseconds)
        if activeContinuation != nil {
            activeContinuation?.finish()
            activeContinuation = nil
            stopResources()
            await activityReporter.reportMicrophoneEnded()
        }
    }

    private func handleRecognition(text: String?, isFinal: Bool, didFail: Bool) async {
        guard let continuation = activeContinuation else { return }
        if didFail {
            continuation.finish(throwing: SpeechInputError.captureFailed)
            activeContinuation = nil
            stopResources()
            await activityReporter.reportMicrophoneUnavailable()
            return
        }
        if let text, !text.isEmpty {
            continuation.yield(SpeechRecognitionUpdate(text: text, isFinal: isFinal))
        }
        if isFinal {
            continuation.finish()
            activeContinuation = nil
            stopResources()
            await activityReporter.reportMicrophoneEnded()
        }
    }

    private func installConfigurationObserver() {
        guard configurationObserver == nil else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVAudioEngineConfigurationChangeNotification"),
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleConfigurationChange()
            }
        }
        configurationObserver = AudioEngineConfigurationObserver(observer)
    }

    private func handleConfigurationChange() async {
        guard activeContinuation != nil else { return }
        await activityReporter.reportMicrophoneUnavailable()
        guard activeContinuation != nil else { return }
        if audioEngine.inputNode.inputFormat(forBus: 0).channelCount == 0 {
            activeContinuation?.finish(throwing: SpeechInputError.captureFailed)
            activeContinuation = nil
            stopResources()
        }
    }

    private func stopResources() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    static func resolveAuthorization(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: SpeechAuthorization
    ) -> SpeechAuthorization {
        switch speech {
        case .restricted:
            return .restricted
        case .denied:
            return .speechDenied
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return microphone
        @unknown default:
            return .speechDenied
        }
    }

    private func combinedAuthorization(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: SpeechAuthorization
    ) -> SpeechAuthorization {
        Self.resolveAuthorization(speech: speech, microphone: microphone)
    }

    private func microphoneAuthorization() -> SpeechAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .authorized
        case .undetermined:
            return .notDetermined
        case .denied:
            return .microphoneDenied
        @unknown default:
            return .microphoneDenied
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver.token)
        }
    }
}

private final class AudioEngineConfigurationObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}
