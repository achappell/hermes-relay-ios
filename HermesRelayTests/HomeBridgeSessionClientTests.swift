import Foundation
import XCTest
@testable import HermesRelayIOS

final class HomeBridgeSessionClientTests: XCTestCase {
    func testURLSessionClientUsesOneDeviceSocketAndSharedEventReader() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()

        guard case .ready(let binding, let capabilities) = await client.open(claim: fixture.claim) else {
            return XCTFail("A valid Home bridge response must become ready")
        }
        XCTAssertEqual(binding.conversationHandle, fixture.claim.conversationHandle)
        XCTAssertEqual(capabilities.timing, .absent)

        let submission = await client.submitPrompt("hello", binding: binding)
        guard case .accepted(let turn) = submission else {
            return XCTFail("The fake JSON-RPC response must accept the prompt")
        }

        let standard = HomeStandardEvent(
            type: .messageDelta,
            scope: HomeEventScope(
                conversationHandle: binding.conversationHandle,
                turnID: turn.turnID,
                correlationID: turn.correlationID
            ),
            payload: .delta(
                rendered: "Hello from Home",
                text: nil,
                replace: false,
                kind: .assistant
            )
        )
        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: binding.conversationHandle,
            turnID: turn.turnID,
            correlationID: turn.correlationID,
            type: "message.delta",
            payload: [
                "rendered": "Hello from Home",
                "kind": "assistant",
            ]
        )))
        let standardEvent = try await events.next()
        XCTAssertEqual(standardEvent, .standard(standard))

        let recordedRequest = await fixture.requests.first()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Device device-secret"
        )
        let requestCount = await fixture.requests.count()
        XCTAssertEqual(requestCount, 1)
        let sentMethods = try await fixture.socket.sentMethods()
        XCTAssertEqual(sentMethods, ["conversation.open", "prompt.submit"])

        await client.close()
        await client.close()
        let closeCount = await fixture.socket.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testURLSessionClientJoinsBinaryPCMOnlyInsideAValidatedAudioScope() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must open before it can accept audio")
        }

        let scope = HomeEventScope(
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "correlation-1"
        )
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "start")))
        await fixture.socket.enqueue(.binary(Data([0x01, 0x02])))
        await fixture.socket.enqueue(.text(try audioFrame(scope: scope, kind: "end")))

        let audioStart = try await events.next()
        XCTAssertEqual(
            audioStart,
            .audioStart(scope, HomeAudioFormat(sampleRate: 24_000, channels: 1, sampleWidth: 2))
        )
        let audioPCM = try await events.next()
        XCTAssertEqual(audioPCM, .binaryPCM(scope, Data([0x01, 0x02])))
        let audioEnd = try await events.next()
        XCTAssertEqual(audioEnd, .audioTerminal(scope, .end))
        await client.close()
    }

    func testStructuredPromptIsCorrelatedAndResponsesUseTheFixedOperation() async throws {
        let fixture = try await makeFixture()
        let client = fixture.client
        let stream = await client.events()
        var events = stream.makeAsyncIterator()
        guard case .ready(let binding, _) = await client.open(claim: fixture.claim) else {
            return XCTFail("The bridge must be ready before prompts are accepted")
        }

        let prompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-1",
            options: ["yes", "no"],
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            sensitive: false
        )
        await fixture.socket.enqueue(.text(try eventFrame(
            conversationHandle: prompt.conversationHandle,
            turnID: prompt.turnID,
            correlationID: prompt.correlationID,
            type: prompt.eventType,
            payload: [
                "options": prompt.options,
                "expires_at": ISO8601DateFormatter().string(from: prompt.expiresAt!),
                "sensitive": false,
            ]
        )))
        let promptEvent = try await events.next()
        XCTAssertEqual(promptEvent, .structuredPrompt(prompt))

        let responseOutcome = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(responseOutcome, .accepted)
        let sentMethods = try await fixture.socket.sentMethods()
        XCTAssertEqual(sentMethods, ["conversation.open", "prompt.respond"])
        await client.close()
    }

    func testProductionFactoryStopsAtThePublicAdapterGate() async {
        let dependencies = HomeBridgeClientDependencies(
            routeProvider: StaticRouteProvider(route: nil),
            credentialStore: InMemoryHomeCredentialStore(),
            publicAdapterEnabled: false
        )
        let client = DefaultHomeBridgeSessionClientFactory(dependencies: dependencies)
            .make(profileID: UUID(), mode: .home)

        let outcome = await client.open(
            claim: HomeConversationClaim(
                profileID: UUID(),
                conversationHandle: "opaque",
                approvedRoute: HomeApprovedRoute(
                    endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
                    identity: HomeRouteIdentity(routeClass: .home, id: "home"),
                    householdBinding: "household"
                )
            )
        )

        XCTAssertEqual(outcome, .unavailable(.publicAdapterUnavailable))
    }

    func testFakeExercisesAcceptedStaleExpiredRejectedAndUncertainControls() async {
        let profileID = UUID()
        let claim = HomeDemoFixtures.claim(for: profileID)
        let client = FakeHomeBridgeSessionClient(
            claim: claim,
            capabilities: HomeBridgeCapabilities(
                commands: ["open"],
                heartbeat: true,
                interrupt: true,
                timing: .absent
            )
        )
        guard case .ready(let binding, _) = await client.open(claim: claim) else {
            return XCTFail("The deterministic fake must open")
        }

        let prompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-1",
            options: ["yes", "no"],
            expiresAt: nil,
            sensitive: false
        )
        await client.emit(.structuredPrompt(prompt))
        let accepted = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(accepted, .accepted)
        let stale = await client.respond(
            to: prompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            stale,
            .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        )

        let expiredPrompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-expired",
            options: ["yes"],
            expiresAt: Date(timeIntervalSince1970: 0),
            sensitive: false
        )
        await client.emit(.structuredPrompt(expiredPrompt))
        let expired = await client.respond(
            to: expiredPrompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            expired,
            .rejected(.home(code: .requestRejected, phase: .structuredResponse))
        )

        let uncertainPrompt = HomeStructuredPrompt(
            kind: .approval,
            conversationHandle: binding.conversationHandle,
            turnID: "turn-1",
            correlationID: "approval-uncertain",
            options: ["yes"],
            expiresAt: nil,
            sensitive: false
        )
        await client.emit(.structuredPrompt(uncertainPrompt))
        await client.setNextResponseOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        )
        let uncertain = await client.respond(
            to: uncertainPrompt,
            with: .approval(choice: "yes", all: nil)
        )
        XCTAssertEqual(
            uncertain,
            .uncertain(.home(code: .transportTimeout, phase: .structuredResponse))
        )

        let command = HomeCommandRequest(binding: binding, name: "open", argument: nil)
        await client.setNextCommandOutcome(
            .rejected(.home(code: .requestRejected, phase: .command))
        )
        let rejectedCommand = await client.dispatch(command)
        XCTAssertEqual(
            rejectedCommand,
            .rejected(.home(code: .requestRejected, phase: .command))
        )
        await client.setNextCommandOutcome(
            .uncertain(.home(code: .transportTimeout, phase: .command))
        )
        let uncertainCommand = await client.dispatch(command)
        XCTAssertEqual(
            uncertainCommand,
            .uncertain(.home(code: .transportTimeout, phase: .command))
        )
    }

    private func makeFixture() async throws -> Fixture {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "home-a"),
            householdBinding: "household-a"
        )
        let claim = HomeConversationClaim(
            profileID: profileID,
            conversationHandle: "opaque-home-conversation",
            approvedRoute: route
        )
        let reference = HomeCredentialReference(
            service: HomeCredentialKeychain.service,
            account: HomeCredentialKeychain.account(for: profileID),
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 90 * 24 * 60 * 60),
            renewAfter: Date(timeIntervalSince1970: 76 * 24 * 60 * 60),
            overlapUntil: nil
        )
        let credentialStore = InMemoryHomeCredentialStore()
        await credentialStore.seed(
            credential: Data("device-secret".utf8),
            reference: reference,
            for: profileID
        )
        let socket = TestHomeSocket(claim: claim)
        let requests = TestHomeRequestRecorder()
        let socketFactory = TestHomeSocketFactory(socket: socket, recorder: requests)
        let dependencies = HomeBridgeClientDependencies(
            routeProvider: StaticRouteProvider(route: route),
            credentialStore: credentialStore,
            socketFactory: socketFactory,
            publicAdapterEnabled: true
        )
        return Fixture(
            claim: claim,
            client: URLSessionHomeBridgeSessionClient(dependencies: dependencies),
            socket: socket,
            requests: requests
        )
    }

    private func eventFrame(
        conversationHandle: String,
        turnID: String?,
        correlationID: String?,
        type: String,
        payload: [String: Any]
    ) throws -> String {
        var params: [String: Any] = [
            "conversation_handle": conversationHandle,
            "type": type,
            "payload": payload,
        ]
        if let turnID { params["turn_id"] = turnID }
        if let correlationID { params["correlation_id"] = correlationID }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": 1,
            "method": "event",
            "params": params,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func audioFrame(scope: HomeEventScope, kind: String) throws -> String {
        var params: [String: Any] = [
            "conversation_handle": scope.conversationHandle,
            "turn_id": scope.turnID as Any,
            "correlation_id": scope.correlationID as Any,
            "kind": kind,
        ]
        if kind == "start" {
            params["sample_rate"] = 24_000
            params["channels"] = 1
            params["sample_width"] = 2
            params["byte_order"] = "little"
        }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": 1,
            "method": "audio.frame",
            "params": params,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private struct Fixture: Sendable {
    let claim: HomeConversationClaim
    let client: URLSessionHomeBridgeSessionClient
    let socket: TestHomeSocket
    let requests: TestHomeRequestRecorder
}

private struct StaticRouteProvider: HomeApprovedRouteProvider, Sendable {
    let route: HomeApprovedRoute?

    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? {
        route
    }
}

private actor TestHomeRequestRecorder {
    private var values: [URLRequest] = []

    func record(_ request: URLRequest) { values.append(request) }
    func first() -> URLRequest? { values.first }
    func count() -> Int { values.count }
}

private final class TestHomeSocketFactory: WebSocketConnectionFactory, @unchecked Sendable {
    private let socket: TestHomeSocket
    private let recorder: TestHomeRequestRecorder

    init(socket: TestHomeSocket, recorder: TestHomeRequestRecorder) {
        self.socket = socket
        self.recorder = recorder
    }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        await recorder.record(urlRequest)
        return socket
    }
}

private actor TestHomeSocket: WebSocketConnection {
    private let claim: HomeConversationClaim
    private var frames: [WebSocketFrame] = []
    private var receivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var sent: [String] = []
    private var closed = false
    private var closes = 0

    init(claim: HomeConversationClaim) {
        self.claim = claim
    }

    func send(text: String) async throws {
        sent.append(text)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(object["id"] as? String)
        let method = try XCTUnwrap(object["method"] as? String)
        let params = object["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "conversation.open", "conversation.reconnect":
            result = [
                "schema": 1,
                "status": "ready",
                "conversation_handle": claim.conversationHandle,
                "route": ["class": "home", "id": "home-a"],
                "capabilities": [
                    "commands": ["open"],
                    "heartbeat": true,
                    "timing": "absent",
                    "interrupt": true,
                ],
            ]
        case "prompt.submit":
            result = [
                "schema": 1,
                "status": "accepted",
                "conversation_handle": claim.conversationHandle,
                "turn_id": "turn-1",
                "correlation_id": "correlation-1",
            ]
        case "session.interrupt":
            result = ["status": "acknowledged"]
        case "prompt.respond":
            result = [
                "schema": 1,
                "status": "accepted",
                "conversation_handle": params["conversation_handle"] as? String ?? claim.conversationHandle,
                "turn_id": params["turn_id"] as? String ?? "turn-1",
                "correlation_id": params["correlation_id"] as? String ?? "correlation-1",
            ]
        case "command.dispatch":
            result = [
                "schema": 1,
                "conversation_handle": claim.conversationHandle,
                "correlation_id": "command-1",
                "name": params["name"] as? String ?? "open",
                "status": "completed",
            ]
        case "bridge.ping":
            result = ["status": "alive"]
        default:
            throw TestHomeSocketError.unexpectedMethod
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "schema": 1,
            "id": id,
            "result": result,
        ]
        enqueue(.text(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)))
    }

    func receive() async throws -> WebSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw TestHomeSocketError.closed }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }

    func close() async {
        closes += 1
        closed = true
        let waiters = receivers
        receivers.removeAll()
        frames.removeAll()
        for waiter in waiters { waiter.resume(throwing: TestHomeSocketError.closed) }
    }

    func enqueue(_ frame: WebSocketFrame) {
        if let receiver = receivers.first {
            receivers.removeFirst()
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func sentMethods() throws -> [String] {
        try sent.map { text in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(object["method"] as? String)
        }
    }

    func closeCount() -> Int { closes }
}

private enum TestHomeSocketError: Error {
    case closed
    case unexpectedMethod
}
