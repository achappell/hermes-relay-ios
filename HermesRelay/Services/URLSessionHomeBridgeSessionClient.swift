import Foundation

/// The endpoint-facing implementation is kept in the Home bridge service
/// file so the public factory, unavailable adapter, and transport actor share
/// one allowlist and one lifecycle boundary. This file names the concrete
/// production client explicitly in the source map for the Apple migration.
///
/// The actor itself is `URLSessionHomeBridgeSessionClient` in
/// `HomeBridgeSessionClient.swift`; it owns the single URLSession WebSocket,
/// reader loop, request waiters, event stream, and binary PCM join.
