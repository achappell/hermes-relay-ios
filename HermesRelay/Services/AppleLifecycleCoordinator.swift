import Foundation

enum AppleLifecycleOutcome: Equatable, Sendable {
    case completed
    case persistenceFailed
}

enum AppleLifecycleInput: Sendable {
    case active
    case inactive
    case background
    case suspended
    case windowDisappeared
    case relaunch
    /// Background voice work kept alive by IOS-HOME-07 has ended; tear down
    /// if the scene is still not active.
    case backgroundWorkEnded
}

/// The one owner of lifecycle teardown on both Apple surfaces. SwiftUI only
/// reports a phase; this object decides when local state is safe to stop and
/// when a new Home transport may be created.
@MainActor
final class AppleLifecycleCoordinator {
    private let store: ConversationStore
    private let voice: VoiceSessionCoordinator
    private let homeClientFactory: any HomeBridgeSessionClientFactory
    private let clock: any HomeMonotonicClock
    /// IOS-HOME-07: iOS keeps in-flight voice work alive in the background.
    /// macOS never suspends, so its lifecycle stays exactly as before.
    private let backgroundRetentionEnabled: Bool

    private(set) var activeHomeClient: (any HomeBridgeSessionClient)?
    private var generation: UInt64 = 0
    private var isActive = true
    private var deactivationPending = false
    /// True while the scene is backgrounded but voice work keeps the audio
    /// session, voice engine and Home transport alive.
    private(set) var isRetainingBackgroundWork = false
    // Scene phases arrive as separate Tasks. Each request waits for the one
    // before it, and only the newest request runs, so a teardown that is
    // still finishing can never drop or undo a newer activation.
    private var latestRequest: UInt64 = 0
    private var pendingWork: Task<Void, Never>?

    init(
        store: ConversationStore,
        voice: VoiceSessionCoordinator,
        homeClientFactory: HomeBridgeSessionClientFactory,
        clock: any HomeMonotonicClock,
        backgroundRetentionEnabled: Bool = AppleLifecycleCoordinator.platformSupportsBackgroundRetention
    ) {
        self.store = store
        self.voice = voice
        self.homeClientFactory = homeClientFactory
        self.clock = clock
        self.backgroundRetentionEnabled = backgroundRetentionEnabled
        store.configureHomeClientFactory(homeClientFactory)
    }

    nonisolated static var platformSupportsBackgroundRetention: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    func handle(_ input: AppleLifecycleInput) async -> AppleLifecycleOutcome {
        latestRequest &+= 1
        let request = latestRequest
        let previous = pendingWork
        let work = Task { @MainActor [weak self] () -> AppleLifecycleOutcome in
            await previous?.value
            guard let self, request == self.latestRequest else { return .completed }
            return await self.process(input)
        }
        pendingWork = Task { _ = await work.value }
        return await work.value
    }

    private func process(_ input: AppleLifecycleInput) async -> AppleLifecycleOutcome {
        switch input {
        case .active:
            if isRetainingBackgroundWork {
                return await returnFromRetainedBackground()
            }
            if isActive, !deactivationPending, store.hasLiveTransport {
                return .completed
            }
            return await activate()
        case .relaunch:
            return await activate()
        case .inactive where backgroundRetentionEnabled:
            // Control Center, the notification shade or an app-switcher peek
            // must never cut off playback or capture: snapshot only.
            return await snapshotOrFinishRetainedWork()
        case .background where backgroundRetentionEnabled:
            return await deactivateRetainingVoiceWork()
        case .inactive, .background, .suspended, .windowDisappeared:
            return await deactivate()
        case .backgroundWorkEnded:
            guard isRetainingBackgroundWork else { return .completed }
            return await deactivate()
        }
    }

    private func snapshotOnly() async -> AppleLifecycleOutcome {
        guard await store.lifecycleSnapshot() else {
            deactivationPending = true
            return .persistenceFailed
        }
        return .completed
    }

    /// A newer phase can supersede the queued `.backgroundWorkEnded`; when
    /// the retained work has already ended, tear down here instead.
    private func snapshotOrFinishRetainedWork() async -> AppleLifecycleOutcome {
        if isRetainingBackgroundWork, voice.backgroundRetention == .none {
            return await deactivate()
        }
        return await snapshotOnly()
    }

    private func deactivateRetainingVoiceWork() async -> AppleLifecycleOutcome {
        guard !isRetainingBackgroundWork else { return await snapshotOrFinishRetainedWork() }
        guard isActive, voice.backgroundRetention != .none else {
            return await deactivate()
        }
        guard await store.lifecycleSnapshot() else {
            deactivationPending = true
            return .persistenceFailed
        }
        deactivationPending = false
        isActive = false
        isRetainingBackgroundWork = true
        let retained = await voice.enterBackground { [weak self] in
            Task { @MainActor [weak self] in
                _ = await self?.handle(.backgroundWorkEnded)
            }
        }
        guard retained else { return await deactivate() }
        return .completed
    }

    /// A transport kept alive in the background makes `.active` a no-op.
    /// Otherwise the retained work is torn down and activation runs as today.
    private func returnFromRetainedBackground() async -> AppleLifecycleOutcome {
        if !deactivationPending, store.hasLiveTransport {
            isRetainingBackgroundWork = false
            isActive = true
            await voice.exitBackground()
            return .completed
        }
        let teardown = await deactivate()
        guard teardown == .completed else { return teardown }
        return await activate()
    }

    private func activate() async -> AppleLifecycleOutcome {
        if deactivationPending {
            let result = await deactivate()
            guard result == .completed else { return result }
        }

        generation &+= 1
        isActive = true
        store.setLifecycleActive(true)
        // The clock is injected even though activation itself has no timeout;
        // keeping the boundary clock-owned prevents wall-clock dates from
        // becoming a hidden lifecycle authority.
        _ = clock.now()

        let configured = await store.loadConfiguredClient()
        await store.loadPersistedConversation()
        guard isActive else { return .completed }
        guard configured else {
            activeHomeClient = nil
            return .completed
        }

        await store.connect()
        guard isActive else { return .completed }
        activeHomeClient = store.currentHomeClientForLifecycle()
        return .completed
    }

    private func deactivate() async -> AppleLifecycleOutcome {
        let snapshotSucceeded = await store.lifecycleWillDeactivate()
        guard snapshotSucceeded else {
            deactivationPending = true
            return .persistenceFailed
        }

        isRetainingBackgroundWork = false
        deactivationPending = false
        generation &+= 1
        isActive = false
        await voice.stopForLifecycle()

        // Clear the store's ownership before awaiting the actor. Repeated
        // inactive notifications now observe an empty slot and cannot close
        // the same client twice.
        let client = store.takeHomeClientForLifecycle()
        activeHomeClient = nil
        await client?.close()
        return .completed
    }
}
