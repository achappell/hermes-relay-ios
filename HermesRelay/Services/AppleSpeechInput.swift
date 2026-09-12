import AVFAudio
import Foundation
import Speech

actor AppleSpeechInput: SpeechInput {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionSession: SpeechRecognitionSession?
    private let activityReporter: any AudioActivityReporter
    private let audioSessionCoordinator: AppleAudioSessionCoordinator
    private let finalResultGraceNanoseconds: UInt64
    private var configurationObserver: AudioEngineConfigurationObserver?
    private var interruptionObserver: AudioInterruptionObserver?

    init(
        locale: Locale = Locale(identifier: "en-US"),
        finalResultGraceNanoseconds: UInt64 = 1_000_000_000,
        activityReporter: any AudioActivityReporter = NoopAudioActivityReporter(),
        audioSessionCoordinator: AppleAudioSessionCoordinator = AppleAudioSessionCoordinator()
    ) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.activityReporter = activityReporter
        self.audioSessionCoordinator = audioSessionCoordinator
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

        let session = SpeechRecognitionSession(activityReporter: activityReporter)
        let stream = await session.makeStream()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        do {
            try await audioSessionCoordinator.activateInput()

            let inputNode = audioEngine.inputNode
            // The input scope reports the hardware format. During a route
            // change the output scope can briefly retain a stale client format
            // (for example, 48 kHz while the hardware is 16 kHz). Input nodes
            // do not convert between those formats, so using the stale output
            // format makes installTap throw an uncaught Core Audio exception.
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw SpeechInputError.captureFailed
            }
            let activityReporter = self.activityReporter
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
                let level = PCMActivityAnalyzer.normalizedRMS(buffer)
                Task {
                    await activityReporter.reportMicrophone(level: level)
                }
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            recognitionRequest = request
            recognitionSession = session
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self, session] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let recognitionError = error.map { Self.mapRecognitionError($0) }
                Task {
                    await self?.handleRecognition(
                        session: session,
                        text: text,
                        isFinal: isFinal,
                        error: recognitionError
                    )
                }
            }
            installConfigurationObserver()
            #if os(iOS)
            installAudioInterruptionObserver()
            #endif
            return stream
        } catch {
            await stopResources()
            await activityReporter.reportMicrophoneUnavailable()
            _ = await session.finish(throwing: SpeechInputError.captureFailed)
            recognitionSession = nil
            throw SpeechInputError.captureFailed
        }
    }

    func cancel() async {
        let wasActive = await recognitionSession?.isActive() ?? false
        _ = await recognitionSession?.finish(throwing: SpeechInputError.cancelled)
        recognitionSession = nil
        await stopResources()
        if wasActive {
            await activityReporter.reportMicrophoneEnded()
        }
    }

    func finish() async {
        guard let session = recognitionSession,
              await session.isActive() else { return }
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
        if await session.finish() {
            recognitionSession = nil
            await stopResources()
            await activityReporter.reportMicrophoneEnded()
        }
    }

    private func handleRecognition(
        session: SpeechRecognitionSession,
        text: String?,
        isFinal: Bool,
        error: SpeechInputError?
    ) async {
        guard recognitionSession === session else { return }
        if await session.handle(text: text, isFinal: isFinal, error: error) {
            recognitionSession = nil
            await stopResources()
        }
    }

    static func mapRecognitionError(_ error: Error) -> SpeechInputError {
        let error = error as NSError
        // Speech reports a stopped empty capture as this assistant error rather
        // than as a successful empty result.
        if error.domain == "kAFAssistantErrorDomain", error.code == 1110 {
            return .noSpeech
        }
        return .captureFailed
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
        guard let session = recognitionSession,
              await session.isActive() else { return }
        await activityReporter.reportMicrophoneUnavailable()
        guard await session.isActive() else { return }
        if audioEngine.inputNode.inputFormat(forBus: 0).channelCount == 0 {
            _ = await session.finish(throwing: SpeechInputError.captureFailed)
            recognitionSession = nil
            await stopResources()
        }
    }

    private func stopResources() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver.token)
            self.interruptionObserver = nil
        }
        await audioSessionCoordinator.deactivateInput()
    }

    #if os(iOS)
    private func installAudioInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  type == .began else { return }
            Task {
                await self?.handleAudioInterruption()
            }
        }
        interruptionObserver = AudioInterruptionObserver(token)
    }

    private func handleAudioInterruption() async {
        guard let session = recognitionSession,
              await session.isActive() else { return }
        _ = await session.finish(throwing: SpeechInputError.captureFailed)
        recognitionSession = nil
        await stopResources()
        await activityReporter.reportMicrophoneUnavailable()
    }
    #endif

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
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver.token)
        }
    }
}

private final class AudioEngineConfigurationObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}

private final class AudioInterruptionObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}
