import Foundation
#if os(iOS)
import MediaPlayer
#endif

enum NowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
}

/// The lock-screen card for backgrounded voice work (IOS-HOME-07). Only
/// Pause/Play and Stop are offered; nothing here can start the microphone.
@MainActor
protocol NowPlayingPresenting: AnyObject {
    func show(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @MainActor @Sendable (NowPlayingCommand) -> Void
    )
    func update(isPlaying: Bool)
    func clear()
}

/// What talks to MediaPlayer. Every call is made on the controller's private
/// serial queue, never on the main actor.
protocol NowPlayingRegistering: AnyObject, Sendable {
    func prewarm()
    func register(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @Sendable (NowPlayingCommand) -> Void
    )
    func setPlaying(title: String, isPlaying: Bool)
    func unregister()
}

/// iOS-only Now Playing adapter. On macOS every call is a no-op because the
/// macOS lifecycle never retains background voice work.
///
/// MediaPlayer registration blocks its caller: on the 2026-10-05 device run
/// the deferred `show` stalled the main actor for about a second, which
/// starved the reply player (the lead journal's sampler, also on the main
/// actor, woke up 0.95 s late exactly when the card was registered). All
/// MediaPlayer work therefore runs on a private serial queue, started warm at
/// launch, and the callers on the main actor return immediately.
@MainActor
final class NowPlayingController: NowPlayingPresenting {
    private let registrar: any NowPlayingRegistering
    private let queue: DispatchQueue
    private let journal: DiagnosticsJournal
    private var title: String?

    init(
        registrar: any NowPlayingRegistering = MediaPlayerRegistrar(),
        queue: DispatchQueue = DispatchQueue(label: "com.achappell.HermesRelay.nowplaying", qos: .utility),
        journal: DiagnosticsJournal = .shared
    ) {
        self.registrar = registrar
        self.queue = queue
        self.journal = journal
        let registrar = registrar
        queue.async { registrar.prewarm() }
    }

    func show(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @MainActor @Sendable (NowPlayingCommand) -> Void
    ) {
        self.title = title
        let registrar = registrar
        let journal = journal
        queue.async {
            let start = ContinuousClock.now
            registrar.register(title: title, isPlaying: isPlaying) { action in
                // MediaPlayer does not promise the main thread; hop explicitly.
                Task { @MainActor in onCommand(action) }
            }
            let took = start.duration(to: .now)
            let milliseconds = Int(took.components.seconds * 1_000)
                + Int(took.components.attoseconds / 1_000_000_000_000_000)
            journal.record("nowplaying registered took_ms=\(milliseconds) thread=background")
        }
    }

    func update(isPlaying: Bool) {
        guard let title else { return }
        let registrar = registrar
        queue.async { registrar.setPlaying(title: title, isPlaying: isPlaying) }
    }

    func clear() {
        title = nil
        let registrar = registrar
        queue.async { registrar.unregister() }
    }
}

#if os(iOS)
/// The real MediaPlayer adapter. State is confined to the controller's queue.
final class MediaPlayerRegistrar: NowPlayingRegistering, @unchecked Sendable {
    private var targets: [(MPRemoteCommand, Any)] = []

    func prewarm() {
        _ = MPRemoteCommandCenter.shared()
        _ = MPNowPlayingInfoCenter.default()
    }

    func register(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @Sendable (NowPlayingCommand) -> Void
    ) {
        removeTargets()
        let center = MPRemoteCommandCenter.shared()
        let bindings: [(MPRemoteCommand, NowPlayingCommand)] = [
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.stopCommand, .stop),
        ]
        for (command, action) in bindings {
            command.isEnabled = true
            let target = command.addTarget { _ in
                onCommand(action)
                return .success
            }
            targets.append((command, target))
        }
        setPlaying(title: title, isPlaying: isPlaying)
    }

    func setPlaying(title: String, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Hermes",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    func unregister() {
        removeTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func removeTargets() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
    }
}
#else
/// macOS never retains background voice work: nothing to register.
final class MediaPlayerRegistrar: NowPlayingRegistering, @unchecked Sendable {
    func prewarm() {}
    func register(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @Sendable (NowPlayingCommand) -> Void
    ) {}
    func setPlaying(title: String, isPlaying: Bool) {}
    func unregister() {}
}
#endif
