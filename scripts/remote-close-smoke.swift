import Foundation

@main
struct SessionSmoke {
    @MainActor
    static func main() async throws {
        let port = CommandLine.arguments.dropFirst().first ?? "18735"
        let profile = try RelayProfile(
            endpoint: URL(string: "ws://127.0.0.1:\(port)")!,
            clientID: "smoke", deviceID: "shared-test-device", displayName: "Smoke"
        )
        let first = URLSessionHermesSessionClient(profile: profile, token: "local-test", socketFactory: URLSessionWebSocketConnectionFactory())
        let second = URLSessionHermesSessionClient(profile: profile, token: "local-test", socketFactory: URLSessionWebSocketConnectionFactory())
        _ = try await first.connect()
        let stream = await first.sendTurn(text: "test")
        var partialReceived = false
        var closeReported = false
        do {
            for try await event in stream {
                if case .textDelta = event {
                    partialReceived = true
                    _ = try await second.connect()
                }
            }
        } catch RelaySessionError.disconnected {
            closeReported = true
        }
        precondition(partialReceived && closeReported)
        let rejected = await first.sendTurn(text: "must not send")
        do {
            for try await _ in rejected {}
            preconditionFailure("Closed session accepted a turn")
        } catch RelaySessionError.notConnected {}
        _ = try await first.connect()
        await first.disconnect()
        await second.disconnect()
        print("PASS: partial response, duplicate-identity eviction, visible disconnect error, rejected stale send, fresh handshake")
    }
}
