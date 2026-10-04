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

    private(set) var activeHomeClient: (any HomeBridgeSessionClient)?
    private var generation: UInt64 = 0
    private var isActive = true
    private var deactivationPending = false
    // Scene phases arrive as separate Tasks. Each request waits for the one
    // before it, and only the newest request runs, so a teardown that is
    // still finishing can never drop or undo a newer activation.
    private var latestRequest: UInt64 = 0
    private var pendingWork: Task<Void, Never>?

    init(
        store: ConversationStore,
        voice: VoiceSessionCoordinator,
        homeClientFactory: HomeBridgeSessionClientFactory,
        clock: any HomeMonotonicClock
    ) {
        self.store = store
        self.voice = voice
        self.homeClientFactory = homeClientFactory
        self.clock = clock
        store.configureHomeClientFactory(homeClientFactory)
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
            if isActive, !deactivationPending, store.hasLiveTransport {
                return .completed
            }
            return await activate()
        case .relaunch:
            return await activate()
        case .inactive, .background, .suspended, .windowDisappeared:
            return await deactivate()
        }
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
