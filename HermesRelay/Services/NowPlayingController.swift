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

/// iOS-only Now Playing adapter. On macOS every call is a no-op because the
/// macOS lifecycle never retains background voice work.
@MainActor
final class NowPlayingController: NowPlayingPresenting {
    private var title: String?
    #if os(iOS)
    private var targets: [(MPRemoteCommand, Any)] = []
    #endif

    func show(
        title: String,
        isPlaying: Bool,
        onCommand: @escaping @MainActor @Sendable (NowPlayingCommand) -> Void
    ) {
        #if os(iOS)
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
                // MediaPlayer does not promise the main thread; hop explicitly.
                Task { @MainActor in onCommand(action) }
                return .success
            }
            targets.append((command, target))
        }
        #endif
        self.title = title
        update(isPlaying: isPlaying)
    }

    func update(isPlaying: Bool) {
        guard let title else { return }
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Hermes",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        #endif
    }

    func clear() {
        title = nil
        #if os(iOS)
        removeTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    #if os(iOS)
    private func removeTargets() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
    }
    #endif
}
