import Foundation
import Observation
import Security

// Built with production Models/Services/ViewModels by home-tail-interrupt-smoke.py.
// Only configuration/credentials/TLS trust are fixture dependencies. The store,
// Home bridge, normalizer, WebSocket factory, and URLSession reader are real.
// No native audio device or VoiceSessionCoordinator is exercised by this seam.
private struct SmokeRouteProvider: HomeApprovedRouteProvider {
    let route: HomeApprovedRoute
    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? { route }
}

private final class SmokeSecureStore: SecureValueStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ value: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

// Trust precisely the temporary peer certificate, only on loopback. Never
// install a root or disable production transport validation globally.
private final class SmokeTLS: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }

    private func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("Smoke transport: \(message)\n".utf8))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            diagnostic("task_complete domain=\(error.domain) code=\(error.code)")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                diagnostic("underlying domain=\(underlying.domain) code=\(underlying.code)")
            }
        } else {
            diagnostic("task_complete success")
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == certificate else {
            diagnostic("trust_challenge rejected host/method/certificate pin")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let anchorStatus = SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        let exclusiveStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard anchorStatus == errSecSuccess, exclusiveStatus == errSecSuccess else {
            diagnostic("trust_anchor status=\(anchorStatus) exclusive_status=\(exclusiveStatus)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            if let trustError {
                let domain = CFErrorGetDomain(trustError).map { $0 as String } ?? "unknown"
                diagnostic("trust_evaluation domain=\(domain) code=\(CFErrorGetCode(trustError))")
            } else {
                diagnostic("trust_evaluation failed_without_error")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        diagnostic("trust_evaluation accepted_pinned_certificate")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct HomeTailInterruptSmoke {
    @MainActor
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeFailure(description: message) }
    }

    // Observation resumes on actual store transitions; the Python process
    // watchdog bounds deadlocks without sleep-based ordering or retries.
    @MainActor
    static func wait(
        _ label: String, until condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        try FileHandle.standardOutput.write(contentsOf: Data("Waiting: \(label)\n".utf8))
        await withCheckedContinuation { continuation in
            observe(condition, continuation: continuation)
        }
    }

    @MainActor
    static func observe(
        _ condition: @escaping @MainActor @Sendable () -> Bool,
        continuation: CheckedContinuation<Void, Never>
    ) {
        if condition() {
            continuation.resume()
            return
        }
        withObservationTracking {
            _ = condition()
        } onChange: {
            Task { @MainActor in observe(condition, continuation: continuation) }
        }
    }

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let port = UInt16(CommandLine.arguments[1]), port > 0 else {
            throw SmokeFailure(description: "Run through scripts/home-tail-interrupt-smoke.py")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        func mark(_ name: String) throws {
            try FileHandle.standardOutput.write(contentsOf: Data("SMOKE \(name)\n".utf8))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        try require(
            support?.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") == true,
            "Refusing to access non-isolated application support"
        )
        let profileID = UUID()
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://127.0.0.1:\(port)/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "smoke"),
            householdBinding: "smoke-household"
        )
        let claim = HomeConversationClaim(
            profileID: profileID, conversationHandle: "smoke-conversation", approvedRoute: route
        )
        // Production credential metadata requires exactly 90 days, with
        // renewal opening 14 days before expiry; all dates share one epoch.
        let issuedAt = Date()
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profileID),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(90 * 24 * 60 * 60),
            renewAfter: issuedAt.addingTimeInterval(76 * 24 * 60 * 60), overlapUntil: nil
        )
        let credentials = InMemoryHomeCredentialStore()
        await credentials.seed(credential: Data("loopback-only".utf8), reference: reference, for: profileID)
        let tls = SmokeTLS(certificate: try Data(contentsOf: directory.appendingPathComponent("cert.der")))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfiguration, delegate: tls, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let factory = DefaultHomeBridgeSessionClientFactory(dependencies: HomeBridgeClientDependencies(
            routeProvider: SmokeRouteProvider(route: route), credentialStore: credentials,
            socketFactory: URLSessionWebSocketConnectionFactory(session: session), publicAdapterEnabled: true
        ))
        let configuration = RelayConfigurationStore(
            secureStore: SmokeSecureStore(), profileURL: directory.appendingPathComponent("profile.json")
        )
        let profile = try RelayProfile(
            id: profileID, endpoint: route.endpoint, clientID: "smoke", deviceID: "smoke",
            displayName: "Loopback smoke"
        )
        let migration = HomeMigrationJournal(
            schemaVersion: 1, profileID: profileID, phase: .homeSelected, selectedMode: .home,
            credential: nil, legacyCredentialRetained: true, updatedAt: Date()
        )
        try await configuration.saveCollection(RelayProfileCollection(
            profiles: [profile], selectedID: profileID, homeMigrations: [profileID: migration]
        ))
        let store = ConversationStore(
            configurationStore: configuration, homeClientFactory: factory,
            homeClaimProvider: StaticHomeConversationClaimProvider(claim: claim)
        )
        try require(await store.loadConfiguredClient(), "Synthetic Home configuration failed")
        await store.connect()
        switch store.homeBridgeState {
        case .ready:
            break
        case .unavailable(let failure), .disconnected(let failure):
            throw SmokeFailure(description: "Production Home bridge did not connect: \(failure.diagnosticSummary)")
        case .unconfigured, .connecting:
            throw SmokeFailure(description: "Production Home bridge did not reach a terminal connection state")
        }

        // A nonnil event sink selects the production control/audio join. It does
        // not emulate playback: native drain ordering belongs to coordinator tests.
        let first = Task { await store.sendTurn(text: "synthetic tail", eventHandler: { _ in }) }
        try await wait("first acceptance") { store.verifiedTurnBinding?.homeTurn?.turnID == "turn-1" }
        try mark("accepted-turn-1")
        try await wait("text terminal with sidecar outstanding") {
            if case .completed = store.homeTurnDeliveryState { return true }
            return false
        }
        try require(store.isSending, "Sidecar tail must remain active after text terminal")
        let transcript = store.messages.filter { $0.role == .assistant }.map(\.text)
        try require(!transcript.isEmpty, "Production normalizer did not retain response text")
        let tailStop = await store.interruptActiveTurn()
        try require(tailStop, "Completed-control tail stop failed")
        try require(await first.value, "Tail stop erased successful control terminal")
        try require(!store.isSending && store.verifiedTurnBinding?.homeTurn == nil, "Tail stop did not release next prompt")
        try require(store.messages.filter { $0.role == .assistant }.map(\.text) == transcript,
                    "Tail stop altered completed response text")

        let active = Task { await store.sendTurn(text: "synthetic active") }
        try await wait("next prompt acceptance") { store.verifiedTurnBinding?.homeTurn?.turnID == "turn-2" }
        try mark("accepted-turn-2")
        var activeStop: Bool?
        let activeInterrupt = Task { activeStop = await store.interruptActiveTurn() }
        try await wait("active acknowledgement and stale event processed") { store.activityText == "smoke-ack-gate" }
        // The peer withholds the matching terminal until this assertion passes.
        // Its stale turn-1 terminal also must not settle this accepted turn.
        try require(activeStop == nil && store.isSending && store.verifiedTurnBinding?.homeTurn?.turnID == "turn-2",
                    "Acknowledgement or stale terminal incorrectly settled active control")
        try mark("release-active-terminal")
        await activeInterrupt.value
        try require(activeStop == true, "Matching interruption did not settle stop")
        try require(await active.value == false, "Interrupted active turn reported successful completion")
        try require(!store.isSending, "Interrupted turn blocked a fresh prompt")

        let next = Task { await store.sendTurn(text: "synthetic next") }
        try await wait("fresh explicit prompt") { store.verifiedTurnBinding?.homeTurn?.turnID == "turn-3" }
        try mark("accepted-turn-3")
        try require(await next.value, "Fresh prompt failed after active interruption")
        try require(!store.isSending && store.verifiedTurnBinding?.homeTurn == nil, "Fresh turn did not settle")
        try require(store.messages.filter { $0.role == .user }.count == 3, "Unexpected replay in transcript")
        await store.closeHomeClient()
        print("PASS: production Apple store/URLSession Home seam; tail terminal truth, active terminal gate, next prompt")
    }
}
