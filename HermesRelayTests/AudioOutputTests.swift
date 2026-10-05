import Foundation
import AVFAudio
import XCTest
@testable import HermesRelayIOS

final class AudioOutputTests: XCTestCase {
    func testSigned16PCMFormatIsAccepted() throws {
        XCTAssertNoThrow(
            try PCMFormatValidator.validate(
                AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
            )
        )
    }

    func testPCMFrameAccumulatorReleasesCompleteFramesBeforeStreamEnds() throws {
        var accumulator = PCMFrameAccumulator(bytesPerFrame: 4)

        XCTAssertNil(try accumulator.append(Data([0, 1])))
        XCTAssertEqual(
            try accumulator.append(Data([2, 3, 4])),
            Data([0, 1, 2, 3])
        )
        XCTAssertEqual(
            try accumulator.append(Data([5, 6, 7])),
            Data([4, 5, 6, 7])
        )
        XCTAssertNoThrow(try accumulator.finish())
    }

    func testPCMFrameAccumulatorRejectsPartialFinalFrame() throws {
        var accumulator = PCMFrameAccumulator(bytesPerFrame: 4)

        XCTAssertNil(try accumulator.append(Data([0, 1])))
        XCTAssertThrowsError(try accumulator.finish()) { error in
            XCTAssertEqual(error as? AudioOutputError, .outputFailed)
        }
    }

    func testPlaybackDrainWaitsForScheduledBuffers() async {
        let drain = AudioPlaybackDrain()
        let flag = PlaybackCompletionFlag()
        await drain.scheduleBuffer()
        await drain.scheduleBuffer()

        let waitTask = Task {
            await drain.waitForCompletion()
            await flag.markCompleted()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        let completedBeforeBufferConsumed = await flag.isCompleted()
        XCTAssertFalse(completedBeforeBufferConsumed)

        await drain.bufferDidComplete()
        let completedBeforeFinalBufferConsumed = await flag.isCompleted()
        XCTAssertFalse(completedBeforeFinalBufferConsumed)

        await drain.bufferDidComplete()
        await waitTask.value

        let completedAfterBufferConsumed = await flag.isCompleted()
        XCTAssertTrue(completedAfterBufferConsumed)
    }

    func testFakeOutputPreservesChunkOrder() async throws {
        let output = RecordingAudioOutput()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)

        try await output.start(format: format)
        _ = try await output.append(Data([0, 1]))
        _ = try await output.append(Data([2, 3]))
        await output.finish()

        let chunks = await output.recordedChunks()
        let operations = await output.operations()
        XCTAssertEqual(chunks, [Data([0, 1]), Data([2, 3])])
        XCTAssertEqual(operations, [.start(format), .append, .append, .finish])
    }

    func testFinishAndStopCleanUpTheOutput() async throws {
        let output = RecordingAudioOutput()
        let format = AudioFormat(sampleRate: 16_000, channels: 2, sampleWidth: 2)

        try await output.start(format: format)
        await output.finish()
        await output.stop()

        let operations = await output.operations()
        let isActive = await output.isActive()
        XCTAssertEqual(operations, [.start(format), .finish, .stop])
        XCTAssertFalse(isActive)
    }

    func testOutputFailureReachesTheCaller() async throws {
        let output = RecordingAudioOutput(appendError: .outputFailed)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)

        do {
            _ = try await output.append(Data([0, 1]))
            XCTFail("A playback failure must reach the caller")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }
    }

    func testPlaybackWrappersForwardPauseAndResumeToTheLiveOutput() async throws {
        // IOS-HOME-07: a route loss or interruption pauses the real player
        // through every production wrapper.
        let liveOutput = RecordingAudioOutput()
        let recovering = RecoveringAudioOutput(liveOutput: liveOutput)
        let output = HomeAwareAudioOutput(wrapped: recovering, isHomeMode: { true })
        let reporting = AudioActivityReportingOutput(wrapped: output, reporter: NoopAudioActivityReporter())
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await reporting.start(format: format)

        await reporting.pause()
        await reporting.resume()

        let operations = await liveOutput.operations()
        XCTAssertEqual(Array(operations.suffix(3)), [.start(format), .pause, .resume])
    }

    func testBackgroundVoiceIsNonMixableAndForegroundDucksOthers() {
        XCTAssertEqual(AudioSessionMixing.forBackgroundVoice(true), .nonMixable)
        XCTAssertEqual(AudioSessionMixing.forBackgroundVoice(false), .duckOthers)
    }

    func testEngineConfigurationChangeRestartsStoppedPlayback() async throws {
        let control = SimulatedEngineControl(reportsStoppedOnce: true)
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = AppleAudioOutput(engineControl: control.control, journal: journal)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        _ = try await output.append(Data(count: 2_400)) // 50 ms of silence

        await output.handleEngineConfigurationChange()
        try await output.finish()

        XCTAssertEqual(control.startCount, 1, "The stopped engine is restarted once")
        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output engine stopped restart=ok"])
    }

    func testFailedEngineRestartFailsThePendingFinishInsteadOfHanging() async throws {
        let control = SimulatedEngineControl(reportsStoppedOnce: true, startFails: true)
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = AppleAudioOutput(engineControl: control.control, journal: journal)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        _ = try await output.append(Data(count: 480_000)) // 10 s, still draining
        let finish = Task { try await output.finish() }
        try await Task.sleep(for: .milliseconds(100))

        await output.handleEngineConfigurationChange()

        do {
            try await finish.value
            XCTFail("finish() must report the failed restart")
        } catch {
            XCTAssertEqual(error as? AudioOutputError, .outputFailed)
        }
        XCTAssertEqual(
            journal.snapshot().map(\.event).filter { $0.hasPrefix("audio output engine stopped") },
            ["audio output engine stopped restart=failed"]
        )
    }

    // MARK: Live session is never reconfigured (2026-10-05 device evidence)

    func testBackgroundNeverReconfiguresALiveSession() async throws {
        let driver = RecordingAudioSessionDriver()
        let journal = DiagnosticsJournal(fileURL: nil)
        let session = AppleAudioSessionCoordinator(driver: driver, journal: journal)
        try await session.activateOutput()
        let beforeBackground = driver.calls
        XCTAssertEqual(
            beforeBackground,
            [.setCategory(AudioSessionConfiguration(mode: .spokenAudio, mixing: .duckOthers)), .setActive(true)]
        )

        await session.setBackgroundVoiceActive(true)

        XCTAssertEqual(driver.calls, beforeBackground, "Backgrounding must not touch the session behind running I/O")
        XCTAssertEqual(
            journal.snapshot().map(\.event),
            [
                "audio session category applied mode=spokenAudio mixing=duckOthers live=false",
                "audio session mixing wanted=nonMixable deferred live=true",
            ]
        )
    }

    func testDeferredNonMixableRuleAppliesWhenTheSessionNextActivates() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))
        try await session.activateOutput()
        await session.setBackgroundVoiceActive(true)
        await session.deactivateOutput()

        try await session.activateOutput()

        XCTAssertEqual(
            driver.calls.last(where: \.isCategory),
            .setCategory(AudioSessionConfiguration(mode: .spokenAudio, mixing: .nonMixable))
        )
    }

    func testAnIdleSessionTakesTheBackgroundRuleAtActivation() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))

        await session.setBackgroundVoiceActive(true)
        try await session.activateInput()

        XCTAssertEqual(
            driver.calls,
            [.setCategory(AudioSessionConfiguration(mode: .measurement, mixing: .nonMixable)), .setActive(true)]
        )
    }

    func testALiveSessionKeepsItsMixingWhenTheModeSwitches() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))
        try await session.activateOutput()
        await session.setBackgroundVoiceActive(true)

        try await session.activateInput()

        XCTAssertEqual(
            driver.calls.last(where: \.isCategory),
            .setCategory(AudioSessionConfiguration(mode: .measurement, mixing: .duckOthers)),
            "A mode switch must not also flip the live session to non-mixable"
        )
    }

    func testReactivatingALiveOutputSessionOnlyActivatesIt() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))
        try await session.activateOutput()
        let beforeRestart = driver.calls.count

        try await session.reactivateOutput()
        try await session.activateOutput()

        XCTAssertEqual(Array(driver.calls.dropFirst(beforeRestart)), [.setActive(true), .setActive(true)])
        XCTAssertEqual(driver.calls.filter(\.isCategory).count, 1)
    }

    func testEngineRestartReactivatesTheSessionWithoutReapplyingItsCategory() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))
        let control = SimulatedEngineControl(reportsStoppedOnce: true)
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = AppleAudioOutput(
            audioSessionCoordinator: session,
            engineControl: control.control,
            journal: journal
        )
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        _ = try await output.append(Data(count: 2_400))
        let beforeRestart = driver.calls.count

        await output.handleEngineConfigurationChange()
        try await output.finish()

        XCTAssertEqual(control.startCount, 1)
        XCTAssertEqual(Array(driver.calls.dropFirst(beforeRestart)), [.setActive(true)])
        XCTAssertEqual(driver.calls.filter(\.isCategory).count, 1, "The restart never sets the category again")
        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output engine stopped restart=ok"])
    }

    func testBurstOfConfigurationChangesRestartsTheEngineOnce() async throws {
        let driver = RecordingAudioSessionDriver()
        let session = AppleAudioSessionCoordinator(driver: driver, journal: DiagnosticsJournal(fileURL: nil))
        let control = StoppedUntilStartedEngineControl()
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = AppleAudioOutput(
            audioSessionCoordinator: session,
            engineControl: control.control,
            journal: journal
        )
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        _ = try await output.append(Data(count: 2_400))
        let beforeRestart = driver.calls.count

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await output.handleEngineConfigurationChange() }
            }
        }
        try await output.finish()

        XCTAssertEqual(control.startCount, 1, "Four notifications coalesce into one restart")
        XCTAssertEqual(Array(driver.calls.dropFirst(beforeRestart)), [.setActive(true)])
        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output engine stopped restart=ok"])
    }

    // MARK: Start-of-stream cushion (2026-10-05 background-entry stutter)

    private func cushionedOutput(
        lead: TimeInterval = 0.3,
        hold: Duration = .seconds(30),
        journal: DiagnosticsJournal
    ) -> AppleAudioOutput {
        AppleAudioOutput(
            audioSessionCoordinator: AppleAudioSessionCoordinator(
                driver: RecordingAudioSessionDriver(),
                journal: DiagnosticsJournal(fileURL: nil)
            ),
            journal: journal,
            cushion: AudioPlaybackCushion(lead: lead, maximumHold: hold)
        )
    }

    /// 24 kHz mono 16-bit: 4 800 bytes is 100 ms.
    private let hundredMilliseconds = Data(count: 4_800)
    private let cushionFormat = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)

    func testCushionHoldsPlaybackUntilTheLeadThresholdThenStarts() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(journal: journal)
        try await output.start(format: cushionFormat)

        let first = try await output.append(hundredMilliseconds)
        let second = try await output.append(hundredMilliseconds)
        let heldLead = await output.playbackLead()
        let heldStarted = await output.hasStartedPlayback

        XCTAssertEqual(first, .buffering, "Held audio is not audibly playing yet")
        XCTAssertEqual(second, .buffering)
        XCTAssertFalse(heldStarted)
        XCTAssertEqual(try XCTUnwrap(heldLead), 0.2, accuracy: 0.001)
        XCTAssertTrue(journal.snapshot().isEmpty)

        let third = try await output.append(hundredMilliseconds)
        let started = await output.hasStartedPlayback

        XCTAssertEqual(third, .ready)
        XCTAssertTrue(started, "Playback starts once 300 ms are scheduled")
        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output cushion started lead_ms=300 reason=threshold"])
        await output.stop()
    }

    func testStreamShorterThanTheCushionStartsWhenItEnds() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(journal: journal)
        try await output.start(format: cushionFormat)
        _ = try await output.append(Data(count: 2_400)) // 50 ms

        try await output.finish()

        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output cushion started lead_ms=50 reason=finish"])
        await output.stop()
    }

    func testCushionHoldIsCappedSoAStalledStreamStillStarts() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(hold: .milliseconds(60), journal: journal)
        try await output.start(format: cushionFormat)
        _ = try await output.append(hundredMilliseconds)
        let beforeCap = await output.hasStartedPlayback
        XCTAssertFalse(beforeCap)

        try await Task.sleep(for: .milliseconds(400))

        let afterCap = await output.hasStartedPlayback
        XCTAssertTrue(afterCap, "The hard cap releases a stalled stream")
        XCTAssertEqual(journal.snapshot().map(\.event), ["audio output cushion started lead_ms=100 reason=cap"])
        await output.stop()
    }

    func testPauseHoldsTheCushionAndResumeStartsPlayback() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(hold: .milliseconds(60), journal: journal)
        try await output.start(format: cushionFormat)
        await output.pause()
        _ = try await output.append(hundredMilliseconds)
        _ = try await output.append(hundredMilliseconds)
        _ = try await output.append(hundredMilliseconds)
        try await Task.sleep(for: .milliseconds(300))
        let whilePaused = await output.hasStartedPlayback
        XCTAssertFalse(whilePaused, "A paused stream never starts, whatever the threshold or cap")

        await output.resume()

        let afterResume = await output.hasStartedPlayback
        XCTAssertTrue(afterResume)
        await output.stop()
    }

    func testStopCancelsAHeldCushion() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(hold: .milliseconds(80), journal: journal)
        try await output.start(format: cushionFormat)
        _ = try await output.append(hundredMilliseconds)

        await output.stop()
        try await Task.sleep(for: .milliseconds(300))

        let started = await output.hasStartedPlayback
        XCTAssertFalse(started)
        XCTAssertTrue(journal.snapshot().isEmpty, "A stopped stream is never started by a stale timer")
        let lead = await output.playbackLead()
        XCTAssertNil(lead)
    }

    func testNoCushionStartsOnTheFirstBufferAsBefore() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = AppleAudioOutput(
            audioSessionCoordinator: AppleAudioSessionCoordinator(
                driver: RecordingAudioSessionDriver(),
                journal: DiagnosticsJournal(fileURL: nil)
            ),
            journal: journal,
            cushion: .none
        )
        try await output.start(format: cushionFormat)

        let readiness = try await output.append(Data(count: 2_400))
        let started = await output.hasStartedPlayback

        XCTAssertEqual(readiness, .ready)
        XCTAssertTrue(started)
        XCTAssertTrue(journal.snapshot().isEmpty)
        await output.stop()
    }

    func testEveryStreamStartsWithinTheCushionCapSoNothingWaitsForeverOnTheDrain() async throws {
        let journal = DiagnosticsJournal(fileURL: nil)
        let output = cushionedOutput(hold: .seconds(30), journal: journal)
        try await output.start(format: cushionFormat)
        _ = try await output.append(Data(count: 480)) // 10 ms, far below the cushion

        // finish() must start the held audio itself; it would otherwise wait
        // for a drain that can never begin.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await output.finish() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw AudioOutputError.outputFailed
            }
            try await group.next()
            group.cancelAll()
        }
        await output.stop()
    }

    func testRecoveringOutputWritesBufferedPCMWhenLiveOutputFails() async throws {
        let liveOutput = RecordingAudioOutput(appendError: .outputFailed)
        let output = RecoveringAudioOutput(liveOutput: liveOutput)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)

        do {
            _ = try await output.append(Data([0x01, 0x02]))
            XCTFail("The configured live output must fail")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }

        let fallbackURL = await output.fallbackURL()
        XCTAssertNotNil(fallbackURL)
        if let fallbackURL {
            defer { try? FileManager.default.removeItem(at: fallbackURL) }
            let wav = try Data(contentsOf: fallbackURL)
            XCTAssertEqual(Data(wav[44...]), Data([0x01, 0x02]))
        }
    }

    func testRecoveringOutputWritesBufferedPCMWhenLiveOutputFailsOnFinish() async throws {
        let liveOutput = FinishFailingAudioOutput()
        let output = RecoveringAudioOutput(liveOutput: liveOutput)
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        try await output.start(format: format)
        _ = try await output.append(Data([0x01, 0x02]))

        do {
            try await output.finish()
            XCTFail("A finish-time playback failure must reach the caller")
        } catch let error as AudioOutputError {
            XCTAssertEqual(error, .outputFailed)
        }

        let fallbackURL = await output.fallbackURL()
        XCTAssertNotNil(fallbackURL)
        if let fallbackURL {
            defer { try? FileManager.default.removeItem(at: fallbackURL) }
            let wav = try Data(contentsOf: fallbackURL)
            XCTAssertEqual(Data(wav[44...]), Data([0x01, 0x02]))
        }
    }

    func testWAVFallbackContainsDeclaredFrameValues() throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 2, sampleWidth: 2)
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let url = try writer.write(pcm: pcm, format: format)
        defer { try? FileManager.default.removeItem(at: url) }

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(littleEndianUInt16(wav, offset: 20), 1)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 22), 2)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 24), 24_000)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 28), 96_000)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 32), 4)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 34), 16)
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(littleEndianUInt32(wav, offset: 40), UInt32(pcm.count))
        XCTAssertEqual(Data(wav[44...]), pcm)
    }

    func testWAVDecoderExtractsDeclaredFormatAndPCM() throws {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let url = try writer.write(pcm: pcm, format: format)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try WAVAudioDecoder().decode(Data(contentsOf: url))

        XCTAssertEqual(decoded.format, format)
        XCTAssertEqual(decoded.pcm, pcm)
    }

    func testWAVFallbackRejectsUnsupportedSampleWidth() {
        let writer = WAVFallbackWriter()
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 4)

        XCTAssertThrowsError(try writer.write(pcm: Data([0, 1]), format: format)) { error in
            XCTAssertEqual(error as? AudioOutputError, .unsupportedFormat)
        }
    }

    func testPCMActivityClassifiesSilenceBackgroundNoiseAndSpeech() {
        let classifier = AudioActivityClassifier(
            noiseThreshold: 0.02,
            speechThreshold: 0.08
        )

        XCTAssertEqual(classifier.classify(level: 0), .silence)
        XCTAssertEqual(classifier.classify(level: 0.05), .backgroundNoise)
        XCTAssertEqual(classifier.classify(level: 0.12), .speech)
        XCTAssertEqual(classifier.classify(level: .nan), .silence)
    }

    func testSigned16PCMActivityMeasuresNormalizedRMS() {
        let pcm = Data([0x00, 0x40, 0x00, 0xC0])

        XCTAssertEqual(
            PCMActivityAnalyzer.normalizedRMS(pcm),
            0.5000153,
            accuracy: 0.0001
        )
        XCTAssertEqual(PCMActivityAnalyzer.normalizedRMS(Data([0x01])), 0)
    }

    func testAVAudioBufferActivityMeasuresNormalizedRMS() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let samples = buffer.floatChannelData![0]
        samples[0] = 0.5
        samples[1] = -0.5
        samples[2] = 0.5
        samples[3] = -0.5

        XCTAssertEqual(PCMActivityAnalyzer.normalizedRMS(buffer), 0.5, accuracy: 0.0001)
    }

    func testAudioActivityStoreCombinesAndThrottlesSignals() async {
        let store = AudioActivityStore(
            classifier: AudioActivityClassifier(
                noiseThreshold: 0.02,
                speechThreshold: 0.08
            ),
            minimumEmissionIntervalNanoseconds: 100
        )

        let first = await store.ingest(.microphone(level: 0.03), at: 0)
        XCTAssertEqual(
            first,
            AudioActivitySnapshot(
                microphoneLevel: 0.03,
                microphoneActivity: .backgroundNoise,
                playbackLevel: 0,
                playbackActive: false
            )
        )

        let throttled = await store.ingest(.microphone(level: 0.04), at: 50)
        XCTAssertNil(throttled)

        let playback = await store.ingest(.playback(level: 0.5), at: 100)
        XCTAssertEqual(
            playback,
            AudioActivitySnapshot(
                microphoneLevel: 0.04,
                microphoneActivity: .backgroundNoise,
                playbackLevel: 0.5,
                playbackActive: true
            )
        )

        let speech = await store.ingest(.microphone(level: 0.12), at: 101)
        XCTAssertEqual(
            speech,
            AudioActivitySnapshot(
                microphoneLevel: 0.12,
                microphoneActivity: .speech,
                playbackLevel: 0.5,
                playbackActive: true
            )
        )

        let unavailable = await store.ingest(.microphoneUnavailable, at: 102)
        XCTAssertEqual(
            unavailable,
            AudioActivitySnapshot(
                microphoneLevel: 0,
                microphoneActivity: .unavailable,
                playbackLevel: 0.5,
                playbackActive: true
            )
        )
    }

    func testAudioActivityStorePublishesSafeInitialSnapshotAndLatestState() async {
        let store = AudioActivityStore(minimumEmissionIntervalNanoseconds: 100)
        let stream = await store.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, .safe)

        let emitted = await store.ingest(.playback(level: 0.25), at: 0)
        let next = await iterator.next()
        XCTAssertEqual(next, emitted)
        let current = await store.currentSnapshot()
        XCTAssertEqual(current, emitted)
    }

    func testAudioActivityStoreBroadcastsSnapshotsToEachSubscriber() async {
        let store = AudioActivityStore(minimumEmissionIntervalNanoseconds: 0)
        let first = AudioActivitySnapshotReader(await store.snapshots())
        let second = AudioActivitySnapshotReader(await store.snapshots())

        let firstInitial = await nextSnapshot(from: first)
        let secondInitial = await nextSnapshot(from: second)
        XCTAssertEqual(firstInitial, .safe)
        XCTAssertEqual(secondInitial, .safe)

        let emitted = await store.ingest(.microphone(level: 0.12), at: 0)
        let firstUpdate = await nextSnapshot(from: first)
        let secondUpdate = await nextSnapshot(from: second)
        XCTAssertEqual(firstUpdate, emitted)
        XCTAssertEqual(secondUpdate, emitted)
    }

    func testActivityReportingOutputPublishesPlaybackLevelsAndSafeEnd() async throws {
        let reporter = RecordingAudioActivityReporter()
        let output = AudioActivityReportingOutput(
            wrapped: RecordingAudioOutput(),
            reporter: reporter
        )
        let format = AudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2)

        try await output.start(format: format)
        _ = try await output.append(Data([0x00, 0x40, 0x00, 0xC0]))
        try await output.finish()

        let events = await reporter.events()
        XCTAssertEqual(events.count, 2)
        if case .playback(let level) = events[0] {
            XCTAssertEqual(level, 0.5000153, accuracy: 0.0001)
        } else {
            XCTFail("The first activity event must describe playback")
        }
        XCTAssertEqual(events[1], .playbackEnded)
    }

    private func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func nextSnapshot(
        from reader: AudioActivitySnapshotReader,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async -> AudioActivitySnapshot? {
        await withTaskGroup(of: AudioActivitySnapshot?.self) { group in
            group.addTask {
                await reader.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private final class AudioActivitySnapshotReader: @unchecked Sendable {
    private var iterator: AsyncStream<AudioActivitySnapshot>.Iterator

    init(_ stream: AsyncStream<AudioActivitySnapshot>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> AudioActivitySnapshot? {
        await iterator.next()
    }
}

private actor RecordingAudioOutput: AudioOutput {
    enum Operation: Equatable {
        case start(AudioFormat)
        case append
        case finish
        case stop
        case pause
        case resume
    }

    private let appendError: AudioOutputError?
    private var active = false
    private var chunks: [Data] = []
    private var recordedOperations: [Operation] = []

    init(appendError: AudioOutputError? = nil) {
        self.appendError = appendError
    }

    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
        active = true
        recordedOperations.append(.start(format))
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness {
        if let appendError { throw appendError }
        guard active else { throw AudioOutputError.notStarted }
        chunks.append(pcm)
        recordedOperations.append(.append)
        return .ready
    }

    func finish() async {
        active = false
        recordedOperations.append(.finish)
    }

    func stop() async {
        active = false
        recordedOperations.append(.stop)
    }

    func playbackPosition() async -> TimeInterval? { nil }
    func pause() async { recordedOperations.append(.pause) }
    func resume() async { recordedOperations.append(.resume) }

    func recordedChunks() -> [Data] { chunks }
    func operations() -> [Operation] { recordedOperations }
    func isActive() -> Bool { active }
}

private actor FinishFailingAudioOutput: AudioOutput {
    func start(format: AudioFormat) async throws {
        try PCMFormatValidator.validate(format)
    }

    func append(_ pcm: Data) async throws -> AudioPlaybackReadiness { .ready }

    func finish() async throws {
        throw AudioOutputError.outputFailed
    }

    func stop() async {}

    func playbackPosition() async -> TimeInterval? { nil }
}

private actor PlaybackCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor RecordingAudioActivityReporter: AudioActivityReporter {
    private var recordedEvents: [AudioActivityEvent] = []

    func reportMicrophone(level: Float) async {
        recordedEvents.append(.microphone(level: level))
    }

    func reportMicrophoneUnavailable() async {
        recordedEvents.append(.microphoneUnavailable)
    }

    func reportMicrophoneEnded() async {
        recordedEvents.append(.microphoneEnded)
    }

    func reportPlayback(level: Float) async {
        recordedEvents.append(.playback(level: level))
    }

    func reportPlaybackEnded() async {
        recordedEvents.append(.playbackEnded)
    }

    func events() -> [AudioActivityEvent] {
        recordedEvents
    }
}

extension FinishFailingAudioOutput {
    func pause() async {}
    func resume() async {}
}

/// Reports the engine as stopped (as after a system configuration change) and
/// counts restarts. A successful restart starts the real engine.
private final class SimulatedEngineControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reportsStopped: Bool
    private let startFails: Bool
    private var starts = 0

    init(reportsStoppedOnce: Bool, startFails: Bool = false) {
        reportsStopped = reportsStoppedOnce
        self.startFails = startFails
    }

    var startCount: Int { lock.withLock { starts } }

    var control: AudioOutputEngineControl {
        AudioOutputEngineControl(
            isRunning: { [self] engine in
                lock.withLock {
                    if reportsStopped {
                        reportsStopped = false
                        return false
                    }
                    return engine.isRunning
                }
            },
            start: { [self] engine in
                lock.withLock { starts += 1 }
                if startFails { throw AudioOutputError.outputFailed }
                try engine.start()
            }
        )
    }
}

/// Reports the engine stopped until a restart was requested, so a burst of
/// notifications can be told apart from one restart.
private final class StoppedUntilStartedEngineControl: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }

    var control: AudioOutputEngineControl {
        AudioOutputEngineControl(
            isRunning: { [self] _ in lock.withLock { started } },
            start: { [self] _ in
                lock.withLock {
                    starts += 1
                    started = true
                }
            }
        )
    }
}

private enum RecordedAudioSessionCall: Equatable {
    case setCategory(AudioSessionConfiguration)
    case setActive(Bool)

    var isCategory: Bool {
        if case .setCategory = self { return true }
        return false
    }
}

private final class RecordingAudioSessionDriver: AudioSessionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedAudioSessionCall] = []

    var calls: [RecordedAudioSessionCall] { lock.withLock { recorded } }

    func setCategory(_ configuration: AudioSessionConfiguration) throws {
        lock.withLock { recorded.append(.setCategory(configuration)) }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        lock.withLock { recorded.append(.setActive(active)) }
    }
}
