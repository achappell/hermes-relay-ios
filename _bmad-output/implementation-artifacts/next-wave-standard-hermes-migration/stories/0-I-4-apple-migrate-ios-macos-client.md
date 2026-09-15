---
title: '[Apple] Migrate the iOS/macOS client'
type: 'feature'
created: '2026-09-14'
status: 'ready-for-dev'
review_loop_iteration: 2
followup_review_recommended: false
context:
  - '{project-root}/docs/architecture.md'
  - '{project-root}/docs/workflow.md'
  - '{project-root}/_bmad-output/implementation-artifacts/next-wave-standard-hermes-migration/SPEC.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** The Apple client currently speaks the fork-only `hello`/`turn`/
`interrupt` protocol with a personal Hermes bearer and same-socket PCM. Story 4
must move the client behind Home's planned schema-1 bridge without changing
local Profiles, history, drafts, native capture/playback, or interruption
semantics. The Home public adapter is not served yet, so this story cannot claim
live route integration.

**Approach:** Add an Apple-local, typed Home bridge boundary and an injectable
fake implementation for deterministic evidence. The endpoint-facing contract
is one WebSocket at the planned
`wss://<selected-approved-route>/api/v1/bridge/ws`: JSON-RPC 2.0 requests and
responses, `event`/`audio.frame` JSON notifications, and binary PCM share one
receive owner. Home owns Device authorization, approved-route and Household
Identity proof, opaque conversation handles, reconnect, redaction, and the
endpoint envelope. Vanilla Hermes `0.21.1` owns only the backend `/api/ws`
gateway and `/api/audio/speak-stream` sidecar that Home joins internally; Apple
code must not open those sockets or send Home methods to them. Production Home
mode reports a typed `public_adapter_unavailable` state until that endpoint is
served, while the existing fork client remains an explicit rollback path.

## Boundaries & Constraints

**Always:**

- Send only `Authorization: Device <device-credential>` on a Home WebSocket
  upgrade and never put that credential in a URL, subprotocol, JSON body,
  snapshot, log, diagnostic, transcript, prompt, or audio. The Device
  credential is pre-issued by Home pairing; this story consumes it and never
  derives or issues one from a Hermes bearer.
- Send only schema-1 Home operations to the planned Home endpoint:
  `conversation.open`, `conversation.reconnect`, `prompt.submit`,
  `session.interrupt`, `prompt.respond`, `command.dispatch`, and
  `bridge.ping`. Every request has a unique client request ID. Keep the Home
  conversation handle and Home turn ID opaque; the Standard runtime Session ID
  stays private to Home and is never substituted into Apple state.
- Keep route state, Home bridge state, and turn-delivery state separate. A
  route that is reachable is not a ready bridge, and a ready bridge is not
  evidence that an earlier turn completed. Freeze the handle, approved route,
  Profile identity, and current turn binding until the turn is settled or
  explicitly marked uncertain.
- Use one Home WebSocket reader. Demultiplex control notifications, audio
  notifications, and binary PCM after the valid `audio.frame` start. A fake may
  model Home's internal Standard gateway and audio-sidecar join, but no Apple
  production or test client may open the two vanilla Hermes sockets directly.
- Preserve Standard event names, semantic payload meaning, ordering,
  correlation, and cumulative-preview replacement at the existing normalized
  session seam. Reject or safely map server-only IDs and content-bearing error
  fields before they reach diagnostics or SwiftUI. Global events without a
  `turn_id` never complete or retarget the active turn.
- Accept PCM only after a valid `audio.frame` `kind: start` with positive sample
  rate, `channels: 1`, `sample_width: 2`, and `byte_order: little`. Binary
  WebSocket frames are transport chunks, not sample boundaries: append them to
  a per-turn signed-16 little-endian accumulator, retain one trailing byte when
  a chunk splits a sample, and reject only an odd aggregate at the terminal
  boundary. Enforce the `end`, `fallback`, and `unavailable` terminal kinds;
  reject bytes before start, after terminal, duplicate starts, and stale
  generations. Text remains usable when audio is unavailable.
- Treat `timing: absent` as authoritative for the pinned Standard baseline.
  Suppress legacy `speech_timing` as a Home capability; expose timing absence
  or use only the already-verified local playback clock/final PCM duration.
  Network arrival, ping latency, and transcript timestamps are never timing
  authority.
- Keep a known non-delivery (`request_rejected`, invalid request, capability
  failure) distinct from uncertain delivery (`transport_unavailable` or
  `transport_timeout`). Persist `unconfirmedTurnText` only for the latter.
  Reconnect may restore the existing binding but never resubmits the prompt or
  clears the marker; a fresh user action creates a new Home turn ID.
- Keep ordinary transcript and draft data in the existing per-Profile local
  conversation store. “No content in artifacts” applies to logs, diagnostics,
  snapshots, and validation evidence, not to the local history required by this
  story. Credentials and raw PCM never enter either boundary.

**Never:**

- Claim that `/api/v1/bridge/ws` is live, treat a refusal or `404` as invalid
  credentials, or silently fall back from Home mode to a direct Hermes bearer.
- Send Home methods to vanilla Hermes `/api/ws`, send a server-held Hermes
  bearer to an endpoint, expose the Standard runtime Session ID, add a second
  Hermes parser, or invent public `audio.start`/`audio.end` methods.
- Switch route, Profile, Household binding, or conversation handle during an
  active or uncertain turn; replay an uncertain prompt; or treat reconnect
  readiness, an interrupt acknowledgement, an audio `start`, or network
  arrival as turn completion.
- Convert structured prompts or commands into ordinary `prompt.submit` text.
  Secret and sudo values must not enter transcript, persistence, diagnostics,
  or evidence.

## Typed Contract and State Tables

The implementation adds endpoint-safe types in
`HermesRelay/Models/HomeBridgeModels.swift` and makes the existing normalized
seam explicit about the two transport families:

| Type | Required meaning |
|---|---|
| `HomeRouteIdentity` / `HomeRouteState` | The safe class/label supplied by Home (`home`, `tailscale`, or explicitly enabled `public`) and the route attempt result. Apple does not discover unapproved routes or prove Household Identity itself; it accepts only a `HomeApprovedRoute` record and Home's same-identity proof, then rejects a missing or changed route binding. |
| `HomeConversationBinding` | Profile UUID plus opaque Home conversation handle, selected route identity, and safe capability snapshot. It contains no Profile ID on the wire and no Standard runtime Session ID. |
| `HomeBridgeState` | `unconfigured`, `connecting`, `ready`, `disconnected`, or `unavailable` with safe Home reason. Only a schema-1 `conversation.open`/`conversation.reconnect` result with `status: ready` can project to `Connected`. |
| `HomeTurnDeliveryState` | `idle`, `awaitingAcceptance`, `accepted`, `completed`, `interrupted`, `failedKnown`, or `uncertain`, carrying the opaque Home turn/correlation. It is independent from route and bridge state. |
| `HomeBridgeFailure` | Stable Home code (`invalid_request`, `authorization_unavailable`, `unauthorized`, `stale_conversation`, `conversation_mismatch`, `request_rejected`, `transport_unavailable`, `transport_timeout`, `protocol_error`, `capability_unavailable`, or `hermes_unavailable`) or a separate `HomeRouteAttemptFailure` (`route_unavailable`, `route_unauthorized`, `route_identity_mismatch`, `route_timeout`), plus safe phase and delivery classification. `public_adapter_unavailable` is Apple-local adapter state, never a Home wire error. |
| `HomeBridgeCapabilities` | Advertised commands, heartbeat support, interrupt support, and `timing: absent`; absent optional capabilities produce typed unavailable results. |
| `HomeStructuredPrompt` / `HomeCommandResult` | Correlated approval, clarify, secret, or sudo request with fixed response keys, sensitivity, options, expiry, handle, turn, and correlation; commands are dispatchable only when advertised. |
| `HomeAudioState` | `notRequested`, `waitingForStart`, `streaming`, `ended`, `fallback`, `unavailable`, or `invalid`, with one validated format/generation. Invalid or late PCM is never passed to playback. |
| `HomeCredentialRecord` / `HomeMigrationPhase` | Separate Keychain reference and lifecycle metadata for the Home Device credential and legacy Hermes credential. Values never enter Codable Profiles, snapshots, or logs. Phases are persisted so a crash cannot create a half-selected mode. |

`SessionMetadata` and `HermesTurnBinding` must use a typed binding identity:
the Home case carries the opaque conversation/turn binding, while the
legacy-only case carries the fork session ID. The existing `sessionID` field
must not be filled with a sentinel or the Home handle. The Standard runtime
Session ID, if Home uses it to resume, remains inside the Home transport actor.
The normalized `HermesSessionClient` interruption result becomes a typed
`confirmed`, `rejected`, `unavailable`, or `uncertain` outcome. The legacy
client maps its current `true` to `confirmed` and `false` to
`unavailable`/fallback; the Home client maps the stable Home codes without
collapsing rejection and uncertainty.

The shared local types used by the client, store, and coordinator are concrete
and equatable; they are not `[String: Any]` escape hatches:

```swift
enum HomeFailureCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case authorizationUnavailable = "authorization_unavailable"
    case unauthorized
    case staleConversation = "stale_conversation"
    case conversationMismatch = "conversation_mismatch"
    case requestRejected = "request_rejected"
    case transportUnavailable = "transport_unavailable"
    case transportTimeout = "transport_timeout"
    case protocolError = "protocol_error"
    case capabilityUnavailable = "capability_unavailable"
    case hermesUnavailable = "hermes_unavailable"
}

enum HomeRouteAttemptFailure: String, Sendable {
    case unavailable
    case unauthorized
    case identityMismatch
    case timeout
}

enum HomeFailurePhase: String, Sendable {
    case route, authorization, open, reconnect, submission, interrupt
    case structuredResponse, command, ping, audio, lifecycle
}

enum HomeBridgeFailure: Equatable, Sendable {
    case home(code: HomeFailureCode, phase: HomeFailurePhase)
    case route(HomeRouteAttemptFailure)
    case reconnectRequired
    case publicAdapterUnavailable
}

struct HomeConversationBinding: Equatable, Sendable {
    let profileID: UUID                 // local only; never encoded on the wire
    let conversationHandle: String     // opaque Home value
    let endpoint: URL
    let route: HomeRouteIdentity
    let householdBinding: String       // local Home receipt, not a wire field
    let capabilities: HomeBridgeCapabilities
}

struct HomeBridgeCapabilities: Equatable, Sendable {
    let commands: Set<String>
    let heartbeat: Bool
    let interrupt: Bool
    let timing: HomeTimingCapability
}

enum HomeTimingCapability: String, Sendable {
    case absent
}

struct HomeAudioFormat: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let sampleWidth: Int
    let byteOrder: HomeByteOrder
}

enum HomeByteOrder: String, Sendable {
    case little
}
```

`HomeBridgeFailure` carries only a stable code/reason and safe phase. It never
stores a raw server message, request ID, endpoint credential, Standard session
ID, or content-bearing error field. The Home client returns these types for
every operation; the store owns delivery classification and the views consume
derived state rather than inspecting wire dictionaries.

### Operation deadlines and transitions

Use an injected monotonic clock/sleeper and these Apple-local bounds so every
wait is testable and reconnect remains bounded:

```swift
protocol HomeMonotonicClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until: ContinuousClock.Instant) async throws
}
```

`URLSessionHomeBridgeSessionClient`, `FakeHomeBridgeSessionClient`,
`HomeConfigurationMigration`, `ConversationStore`, and the lifecycle
coordinator receive the same clock through their initializers. A shared
`withHomeDeadline` helper races the operation against
`clock.sleep(until:)`, cancels the losing task, and closes only that operation's
pending request. It never uses wall-clock `Date` for timeout decisions. The
10-second bound is per `conversation.open`, prompt-acceptance, and
`conversation.reconnect` attempt; `ReconnectPolicy` supplies its existing
finite attempt count/backoff and the caller's overall cancellation, so no
retry can hide an unbounded wait. Lifecycle deactivation owns cancellation of
all outstanding Home operations, and a cancelled operation cannot publish a
late readiness or delivery result.

| Operation | Bound | Success | Failure transition |
|---|---:|---|---|
| `conversation.open` | 10 s | `HomeBridgeState.ready` with matching handle and route | `unavailable` for typed result, `disconnected` for transport; adapter absence is `public_adapter_unavailable`, not `unauthorized` |
| `conversation.reconnect` | 10 s per attempt | Ready existing binding; retain any `unresolved_turn` | Preserve uncertainty; after `ReconnectPolicy` exhaustion, `unavailable`/`disconnected` and no new submission |
| `prompt.submit` acceptance | 10 s | `accepted` with new opaque Home turn ID | Known Home rejection → `failedKnown`; transport/timeout → `uncertain` and persist draft/marker |
| `session.interrupt` acknowledgement | 2 s | Keep waiting for matching interrupted/cancelled terminal event | Known rejection/unavailable stays distinct; timeout/transport uses close/reconnect fallback and `uncertain` delivery |
| `bridge.ping` | 5 s | Update liveness only | Typed unavailable/disconnected; never changes timing or turn state |
| Audio start/terminal | 5 s to start, then bounded active-turn lifetime | Audio terminal contributes to the join | `invalid`/`unavailable` releases audio and lets known control terminal settle text; it never becomes an uncertain prompt |

The turn join is `controlTerminal && audioTerminal`, where `audioTerminal` is
`notRequested`, `ended`, `fallback`, `unavailable`, or `invalid`. A known
control terminal plus an audio failure therefore settles the turn after local
playback cleanup rather than waiting forever or marking the text delivery
uncertain. Late frames are rejected by the turn/generation guard.

### Route-loss matrix

| Loss point | Required result |
|---|---|
| Idle or before capture/submission | Home may choose another approved same-identity route at a new connection boundary; Apple stays disconnected until fresh authorization and `ready`. The draft remains local. |
| During `awaitingAcceptance` | Mark delivery uncertain because the prompt may have crossed the boundary; do not resend, switch route, or clear the marker. Reconnect the same Home binding only. |
| After acceptance before control terminal | Keep the opaque turn unresolved; reconnect may resume the existing binding/cursor when Home provides it, but must not replay the old response or prompt. |
| After control terminal while audio drains | Keep the route frozen until audio settles. If audio fails, mark audio unavailable and finish text honestly; do not reopen a route or make the known turn uncertain. |
| Reconnect mismatch, revocation, expired credential, or exhausted attempts | Stop new capture/submission, preserve local uncertainty, expose the safe unavailable/disconnected reason, and require fresh authorization or a fresh user action. Never attach another Profile or Household. |

### Approved-route input and wire-reason mapping

The Apple adapter receives a Home-approved route record from pairing or the
persisted Home configuration. It never performs discovery, mDNS, Tailscale
probing, public-route guessing, or Household Identity proof. Define the input
seam explicitly:

```swift
enum HomeRouteClass: String, Codable, Sendable {
    case home, tailscale, `public`
}

struct HomeRouteIdentity: Codable, Equatable, Sendable {
    let routeClass: HomeRouteClass
    let id: String
}

struct HomeApprovedRoute: Codable, Equatable, Sendable {
    let endpoint: URL                 // production: wss://.../api/v1/bridge/ws
    let identity: HomeRouteIdentity  // class plus Home-provided safe label
    let householdBinding: String     // opaque, non-secret Home receipt
}

protocol HomeApprovedRouteProvider: Sendable {
    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute?
}
```

`HomeApprovedRoute` validates `wss`, the exact `/api/v1/bridge/ws` path, no
userinfo, query, or fragment for the native adapter, and a non-empty Home
identity/binding. The provider is backed by a pairing/configuration handoff;
Apple does not manufacture the record. `FakeHomeBridgeSessionClient` receives
the record in its initializer and returns the exact contract-v1 ready shape
with deterministic route class/id metadata. URLSession never selects a route
on its own. The contract-v1 ready result contains `route.class` and `route.id`
but does not define a `household_binding` field: `householdBinding` remains a
local, non-secret receipt associated with the approved record and is never
invented as a wire field. The adapter compares the returned route class/id to
the approved record and treats Home's successful Device authorization and
identity-valid route selection as Home-owned proof; Apple does not re-prove
Household Identity. If a later Home version adds an explicit opaque proof
field, it is an optional versioned extension and must be compared only when
present. None of these values is a Profile ID, Hermes Session ID, bearer, or
credential.

Map Home's wire results without collapsing route, authorization, adapter, and
delivery failures:

| Wire result | Apple typed result/state | Turn effect |
|---|---|---|
| `route_unavailable` | `HomeBridgeFailure.route(.unavailable)` → `HomeBridgeState.unavailable(.routeUnavailable)` | No turn uncertainty when opening idle; keep any existing marker unchanged. |
| `route_unauthorized` | `HomeBridgeFailure.route(.unauthorized)` → unavailable with a route reason, not credential replacement | Do not label the Device credential invalid or try a bearer. |
| `route_identity_mismatch` | `HomeBridgeFailure.route(.identityMismatch)` → unavailable and discard that route attempt | Never create a binding, Profile, or turn through that route; the provider may supply the next approved route at a new boundary. |
| `route_timeout` | `HomeBridgeFailure.route(.timeout)` → disconnected/unavailable after the bounded attempt | Preserve an existing uncertain turn; no replacement submission. |
| `conversation.open` result `status: unavailable`, `reason: reconnect_required` | `HomeBridgeFailure.reconnectRequired` → disconnected/unavailable, never `ready` | With a persisted binding, issue only `conversation.reconnect` on the same route while active; retain `unresolved_turn`. Without one, require fresh readiness. |
| Home `unauthorized` / `authorization_unavailable` | Credential/authorization failure in `HomeBridgeState.unavailable` | Stop new work and request fresh Home authorization; never reinterpret it as a route class or derive a credential. |
| `stale_conversation` / `conversation_mismatch` | Binding failure in unavailable state | An active accepted turn remains unresolved; do not attach another handle or Profile. |
| `request_rejected` / invalid request / absent capability | `HomeTurnDeliveryState.failedKnown` | The prompt was not accepted; do not persist `unconfirmedTurnText`. The bridge may remain ready. |
| `transport_unavailable` / `transport_timeout` | disconnected transport failure | `awaitingAcceptance` and `accepted` both become `uncertain`; persist the marker before teardown and never replay. |
| Apple-local `public_adapter_unavailable` | Adapter-unavailable state before any Home wire call | This is a planned endpoint gate, not a Home response or credential failure; no direct vanilla call is allowed. |

The mapping is implemented as distinct Swift cases and tested by asserting the
safe state/reason pair. A reconnect-ready result may restore the bridge while
`HomeTurnDeliveryState` remains `uncertain`; readiness never settles an older
turn.

### Typed prompt submission and delivery seam

The Home client must return a typed acceptance result instead of making the
store infer delivery from a thrown stream:

```swift
enum HomePromptSubmissionOutcome: Equatable, Sendable {
    case accepted(HomeTurnBinding)
    case rejected(HomeBridgeFailure)  // request_rejected/invalid/capability
    case uncertain(HomeBridgeFailure) // transport loss or timeout after send
}

protocol HomeBridgeSessionClient: Sendable {
    func open(binding: HomeConversationBinding) async -> HomeOpenOutcome
    func reconnect(binding: HomeConversationBinding) async -> HomeReconnectOutcome
    func submitPrompt(
        _ text: String,
        binding: HomeConversationBinding
    ) async -> HomePromptSubmissionOutcome
    func interrupt(
        binding: HomeConversationBinding,
        turnID: String
    ) async -> HomeInterruptOutcome
    func respond(
        to prompt: HomeStructuredPrompt,
        with response: HomePromptResponse
    ) async -> HomeStructuredResponseOutcome
    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome
    func ping(binding: HomeConversationBinding) async -> HomePingOutcome
    func events() -> AsyncThrowingStream<HomeBridgeEvent, Error>
    func close() async
}

enum HomeOpenOutcome: Equatable, Sendable {
    case ready(binding: HomeConversationBinding, capabilities: HomeBridgeCapabilities)
    case unavailable(HomeBridgeFailure)
    case disconnected(HomeBridgeFailure)
}

enum HomeReconnectOutcome: Equatable, Sendable {
    case ready(binding: HomeConversationBinding, unresolvedTurn: HomeUnresolvedTurn?)
    case unavailable(HomeBridgeFailure)
    case disconnected(HomeBridgeFailure)
}

struct HomeUnresolvedTurn: Equatable, Sendable {
    let turnID: String
    let resumeCursor: String?
}

enum HomeInterruptOutcome: Equatable, Sendable {
    case acknowledged
    case rejected(HomeBridgeFailure)
    case unavailable(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

enum HomeStructuredResponseOutcome: Equatable, Sendable {
    case accepted
    case rejected(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

struct HomeCommandRequest: Equatable, Sendable {
    let binding: HomeConversationBinding
    let name: String
    let argument: String?
}

enum HomeCommandOutcome: Equatable, Sendable {
    case completed(HomeCommandResult)
    case rejected(HomeBridgeFailure)
    case uncertain(HomeBridgeFailure)
}

struct HomeCommandResult: Equatable, Sendable {
    let name: String
    let status: String
}

enum HomePingOutcome: Equatable, Sendable {
    case alive
    case unavailable(HomeBridgeFailure)
}

struct HomeBridgeClientDependencies: Sendable {
    let routeProvider: any HomeApprovedRouteProvider
    let credentialStore: any HomeCredentialStore
    let clock: any HomeMonotonicClock
    let socketFactory: any WebSocketConnectionFactory
    let publicAdapterEnabled: Bool
}

protocol HomeBridgeSessionClientFactory: Sendable {
    func make(
        profileID: UUID,
        mode: AppleTransportMode
    ) -> any HomeBridgeSessionClient
}

enum AppleTransportMode: String, Codable, Sendable {
    case home
    case legacy
}
```

`URLSessionHomeBridgeSessionClient.open` obtains the approved route and private
credential through the injected dependencies, creates exactly one
`URLSessionWebSocketTask`, starts exactly one receive loop, and publishes one
shared `events()` stream. Every operation serializes an allowlisted JSON-RPC
request with a fresh client request ID and waits on the pending-response table;
operation methods never call `receive` themselves. The loop validates
`jsonrpc/schema`, routes a matching response to its waiter, emits matching
`event`/`audio.frame` notifications, joins binary PCM through the audio
accumulator, and rejects mismatched opaque conversation/turn/correlation
values. `close()` cancels the one reader, fails pending waiters with a typed
transport result, and finishes the shared stream. The production factory
returns `UnavailableHomeBridgeSessionClient` with
`public_adapter_unavailable` before creating a socket when the planned public
adapter is not served; the fake is the only implementation enabled for the
Debug evidence path. This is the complete operation/factory seam for open,
reconnect, prompt, interrupt, structured response, command, ping, events, and
close.

The store transition is explicit: validation or a correlated Home rejection
before acceptance is `failedKnown` with no uncertainty marker; a send with no
acceptance response is `uncertain` and persists the local draft/marker before
transport teardown; an accepted binding becomes `accepted`; a later loss keeps
that same opaque binding and becomes unresolved/`uncertain` until a terminal
event or an explicit safe failure. Reconnect restores only that binding and
cursor, never calls `submitPrompt` for the old input, and never replays an old
response. Only a fresh user action creates a new Home turn and may clear or
replace the marker after its own outcome is classified.

### Structured prompts and commands

Define the concrete transient types used by the protocol rather than passing
untyped dictionaries into SwiftUI:

```swift
enum HomeStructuredPromptKind: String, Sendable {
    case approval, clarification, secret, sudo
}

struct HomeStructuredPrompt: Equatable, Sendable {
    let kind: HomeStructuredPromptKind
    let conversationHandle: String
    let turnID: String
    let correlationID: String
    let options: [String]
    let expiresAt: Date?
    let sensitive: Bool
}

enum HomePromptResponse: Equatable, Sendable {
    case approval(choice: String, all: Bool?)
    case clarification(answer: String)
    case secret(value: String)
    case sudo(password: String)
}
```

The encoder maps those cases only to the fixed Home keys: approval
`choice`/optional `all`, clarification `answer`, secret `value`, and sudo
`password`. `HomeStructuredPrompt` owns the pending request in the bridge
actor; `respond(to:with:)` must match the opaque conversation handle, Home
turn ID, correlation ID, event kind, and unexpired state. A stale,
uncorrelated, unsupported, or capability-missing response returns a typed
known rejection and does not write a frame. Secret/password values exist only
in the transient request and the private encoder call; they are never
`Codable`, transcript text, diagnostic fields, or test snapshots. A command
uses `HomeCommandRequest`/`dispatch(_:)` only when its name is in the current
capability snapshot; it never becomes `prompt.submit` text. The fake must
exercise accepted, stale, expired, rejected, and transport-uncertain outcomes.

### Relaunch-safe Home conversation recovery

The ordinary `PersistedConversation` file remains the per-Profile local store,
but it must carry an optional Home recovery record alongside messages, draft,
and `unconfirmedTurnText`. The record contains only safe opaque binding state;
it never contains a Device credential, bearer, Standard runtime ID, raw frame,
PCM, structured secret, prompt answer, or response value:

```swift
enum PersistedHomeDeliveryState: String, Codable, Sendable {
    case accepted
    case uncertain
}

struct PersistedHomeRecovery: Codable, Equatable, Sendable {
    let schemaVersion: Int       // 1
    let profileID: UUID
    let endpoint: URL
    let route: HomeRouteIdentity
    let householdBinding: String
    let conversationHandle: String
    let turnID: String?
    let correlationID: String?
    let resumeCursor: String?
    let deliveryState: PersistedHomeDeliveryState
    let updatedAt: Date
}

struct PersistedConversation: Codable, Equatable, Sendable {
    let messages: [TranscriptMessage]
    let draft: String
    let unconfirmedTurnText: String?
    let homeRecovery: PersistedHomeRecovery?

    init(
        messages: [TranscriptMessage],
        draft: String,
        unconfirmedTurnText: String? = nil,
        homeRecovery: PersistedHomeRecovery? = nil
    ) {
        self.messages = messages
        self.draft = draft
        self.unconfirmedTurnText = unconfirmedTurnText
        self.homeRecovery = homeRecovery
    }
}
```

`homeRecovery` is optional so old files decode as legacy-local state. The
existing JSON persistence actor writes the conversation and recovery record in
one atomic replacement and applies the existing iOS file-protection policy.
The store writes the approved binding before exposing `ready`, writes the new
turn and local text before treating a prompt as accepted, writes
`deliveryState: uncertain` before closing after a send/acceptance loss, and
updates the cursor/terminal state only for a matching opaque binding. It clears
the recovery record only after the matching control terminal and audio join
have settled, or after a known pre-acceptance rejection. Reconnect readiness,
relaunch, route reachability, and a fresh `conversation.open` never clear it.

An unresolved record is restored before client auto-connect. Recovery obtains
the currently approved route for the same Profile, verifies endpoint/route and
Household-binding equality against the record, opens the existing Home
conversation, and sends `conversation.reconnect` only when the open result is
`reconnect_required` or the record is unresolved. It uses the returned cursor
when present, accepts an `unresolved_turn` as still unresolved, and never calls
`prompt.submit` for the persisted text. A route, Profile, or binding mismatch
keeps the record intact and projects a safe unavailable state. Only an explicit
fresh user action may create a new opaque turn; a known failure of that new
action leaves the old unresolved record untouched, an accepted new turn may
replace it atomically, and a new uncertain action replaces it only with its own
new unresolved record. Tests cover old-file decoding, accepted/uncertain
round-trips, crash-before-save, same-binding reconnect, mismatch preservation,
and the no-resend/fresh-action rule.

### Home event and PCM types

The bridge actor emits typed events rather than forwarding an untyped JSON
dictionary to the UI:

```swift
struct HomeEventScope: Equatable, Sendable {
    let conversationHandle: String
    let turnID: String?
    let correlationID: String?
}

struct HomeStandardEvent: Equatable, Sendable {
    let type: String
    let scope: HomeEventScope
    let rendered: String?
    let text: String?
    let replace: Bool
    let status: String?
}

enum HomeBridgeEvent: Equatable, Sendable {
    case standard(HomeStandardEvent)
    case audioStart(HomeEventScope, HomeAudioFormat)
    case audioTerminal(HomeEventScope, HomeAudioTerminal)
    case binaryPCM(HomeEventScope, Data)
    case structuredPrompt(HomeStructuredPrompt)
    case activity(HomeEventScope?, String)
}

enum HomeAudioTerminal: String, Sendable {
    case end, fallback, unavailable
}

struct HomePCMAccumulator: Sendable {
    mutating func append(transportChunk: Data) throws -> Data
    mutating func finish() throws
}
```

`HomePCMAccumulator` joins bytes across arbitrary WebSocket binary frames and
returns only complete two-byte samples to native playback. `finish()` rejects
an odd aggregate; an odd individual transport chunk is valid when the next
chunk supplies its second byte. The accumulator is created per Home turn and
generation, is discarded on fallback/unavailable/invalid, and has no
Codable/logging path. The audio-start deadline and active-turn cancellation
are owned by the same operation deadline helper as control messages. The
normalizer receives only `HomeStandardEvent` after allowlist validation; outer
JSON-RPC/request IDs and any server-only IDs never enter the normalized model.

### Standard event allowlist and redaction

`HomeStandardEvent` is the only input to the existing normalizer and contains
the opaque Home binding plus an internal, non-persisted correlation. Before
calling `HermesEventNormalizer`, the Home adapter creates a fresh object from
an allowlist:

| Standard event | Fields allowed into the local normalizer | Redaction rule |
|---|---|---|
| `message.start` | event type only | No server IDs. |
| `message.delta` / `text_delta` | `rendered`, `text`, `replace` | Text may reach local transcript/UI; never diagnostics/snapshots. |
| `text` / `text_final` / `message.complete` | final text/rendered and local reasoning if needed | No server session/request IDs; raw error fields are dropped. |
| thinking/reasoning/status | text/status/kind | Content is UI-only; diagnostics retain only a safe state/count. |
| `turn_complete` / `turn_interrupted` / `audio_abort` | terminal type and matching Home turn correlation | The incoming Standard ID is compared internally, then not exposed as `sessionID`. |
| error | stable Home failure code and safe phase | Drop `message`, `error`, `failure_reason`, stack, and server metadata. |
| `speech_timing` | none in Home mode | Suppress as `timing: absent`; never manufacture timing. |

Unknown payload keys, Standard runtime Session IDs, bearer-related fields,
and unrelated request IDs are rejected or discarded before SwiftUI and
diagnostic sinks. A notification without a matching Home turn is allowed only
as non-terminal global activity; it cannot retarget or complete the active
turn. The normalizer continues to own cumulative-preview suffix/replacement
semantics, while a redaction wrapper owns the content-safe diagnostic copy.

### Credential handoff and migration transaction

The production pairing handoff supplies a pre-issued Device credential to the
secure store and returns only a non-secret reference/receipt to this client;
Apple never issues one from the legacy bearer. Add these explicit seams:

```swift
struct HomeCredentialReference: Codable, Equatable, Sendable {
    let service: String       // com.achappell.HermesRelayIOS.home-device
    let account: String       // device-credential.<profile UUID>
    let issuedAt: Date
    let expiresAt: Date
    let renewAfter: Date
    let overlapUntil: Date?
}

enum HomeCredentialState: String, Codable, Sendable {
    case active
    case expired
    case revoked
    case replaced
}

struct HomeCredentialRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let reference: HomeCredentialReference
    let state: HomeCredentialState
}

protocol HomePairingCredentialHandoff: Sendable {
    /// Pairing writes the pre-issued value to this reference and returns no
    /// credential material to the migration/UI layer.
    func preIssuedReference(for profileID: UUID) async throws -> HomeCredentialReference
}

protocol HomeCredentialStore: Sendable {
    func stage(preIssued: HomeCredentialReference, for profileID: UUID) async throws
    func verifiedReadBack(for profileID: UUID) async throws -> HomeCredentialRecord
    /// The raw value is available only inside the secure adapter operation and
    /// is never returned to a caller that owns UI, persistence, or logging.
    func withPrivateDeviceCredential<T: Sendable>(
        for profileID: UUID,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T
    func commitHomeSelection(for profileID: UUID) async throws
    func rollbackToLegacyAtIdle(for profileID: UUID) async throws
}
```

`HomeCredentialStore` reads the pre-issued value privately through the
Keychain-backed `SecureValueStore`; it never returns credential bytes to
Codable Profiles, UI state, snapshots, logs, or diagnostics. The existing
legacy bearer remains under its existing service/account until an explicit
idle-boundary rollback policy says otherwise. Persist these idempotent phases:
`notStarted → staged → readBackVerified → fakeReadyVerified → homeSelected`,
with `rollbackPending`/`legacySelected` for recovery. Home credentials follow
the companion lifecycle exactly: expiry is 90 days after issuance, renewal is
eligible 14 days before expiry, and a replacement has at most a 10-minute
overlap. The migration transaction must stage the pairing-written reference,
verify private secure read-back, run fake-ready `conversation.open`, then
atomically select Home mode. Any write/read-back/fake-ready/crash failure leaves
legacy mode selected and the Home reference retryable; a credential that is
expired, revoked, or replaced is unavailable for new work. Rollback is refused
while capture, playback, reconnect, or an active/uncertain turn exists.

Tests seed an in-memory `SecureValueStore` at the exact Home service/account,
inject a synthetic pre-issued reference through a fake
`HomePairingCredentialHandoff`, and pass that store to
`FakeHomeBridgeSessionClient`; they do not invoke UI pairing and do not assert
or print the secret value. The fake read-back compares bytes only inside the
store and exposes metadata/state, never the bytes. A production Home pairing
adapter may later provide the same reference/receipt without changing this
migration seam.

### Migration journal and crash recovery

The migration state has one persisted source of truth: extend the Codable
`RelayProfileCollection` with `homeMigrations: [UUID: HomeMigrationJournal]`
and write it in the same atomic profile-collection replacement as the
Profile's selected `AppleTransportMode`. Do not create separate mode booleans
or infer a phase from Keychain presence.

```swift
struct HomeMigrationJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int       // 1
    let profileID: UUID
    var phase: HomeMigrationPhase
    var selectedMode: AppleTransportMode
    var credential: HomeCredentialReference?
    var legacyCredentialRetained: Bool
    var updatedAt: Date
}
```

`RelayConfigurationStore` owns `loadHomeMigration`,
`stageHomeMigration`, `recordHomeReadBack`, `recordFakeReady`,
`commitHomeMigration`, and `rollbackHomeMigrationAtIdle`; each updates the
journal and profile snapshot through its existing `.atomic` write. The exact
order is: (1) verify the legacy profile and legacy Keychain reference remain
readable, (2) ask pairing for the pre-issued reference, (3) stage the Home
reference in secure storage, (4) atomically record `staged`, (5) privately
verify read-back and record `readBackVerified`, (6) run fake-ready
`conversation.open` and record `fakeReadyVerified`, then (7) atomically write
Home mode plus `homeSelected`. The legacy credential is retained throughout.

At launch, `HomeConfigurationMigration` recovers the journal before client
construction: `staged`, `readBackVerified`, or `fakeReadyVerified` forces
legacy mode and remains retryable; `homeSelected` is accepted only if the
Home reference is still readable and its lifecycle state is active, otherwise
the store atomically writes `rollbackPending`/`legacySelected` and constructs
legacy mode. A crashed `commitHomeMigration` therefore cannot leave a profile
claiming Home while its verified phase is missing. Explicit rollback performs
one idle-boundary atomic write to legacy mode, retains both references, and
never deletes the Home credential merely because the public adapter is absent.

### Apple lifecycle inputs and transitions

`AppleLifecycleCoordinator` is a main-actor boundary with injected inputs from
iOS `scenePhase` and macOS scene/window visibility. It exposes
`handle(.active)`, `handle(.inactive)`, `handle(.background)`,
`handle(.suspended)`, `handle(.windowDisappeared)`, and `handle(.relaunch)`;
tests inject those events rather than depending on UIKit/AppKit notifications.
Its deactivation order is `persist local history/draft/uncertainty → cancel
send/reconnect tasks → stop capture → stop or drain native playback → suppress
Home operations`. `ConversationStore.lifecycleWillDeactivate()` and
`VoiceSessionCoordinator.stopForLifecycle()` are the explicit methods; neither
performs network work while inactive.

The concrete boundary is `@MainActor` and has async semantics so callers cannot
declare deactivation complete before persistence and native teardown finish:

```swift
enum AppleLifecycleInput: Sendable {
    case active
    case inactive
    case background
    case suspended
    case windowDisappeared
    case relaunch
}

@MainActor
final class AppleLifecycleCoordinator {
    init(
        store: ConversationStore,
        voice: VoiceSessionCoordinator,
        homeClientFactory: HomeBridgeSessionClientFactory,
        clock: any HomeMonotonicClock
    )

    func handle(_ input: AppleLifecycleInput) async
}
```

All inputs are serialized on the main actor. A deactivation increments a
generation token, marks the surface inactive, and awaits
`store.lifecycleWillDeactivate()` followed by
`voice.stopForLifecycle()`; those methods return only after local persistence,
task cancellation, capture stop, and playback stop/drain have completed. The
coordinator then closes the Home client and suppresses any late result whose
generation is stale. A later `.active`/`.relaunch` starts a new generation,
restores `ConversationPersistence`, obtains the approved route, and performs
Home open/reconnect only after restoration. If active arrives during teardown,
the serialized handler completes the deactivation first; no cancelled task may
publish `ready`, acceptance, terminal, or playback state afterward. Repeated
inactive/window-disappeared events are idempotent. iOS maps `scenePhase` to
these inputs; macOS maps scene/window appearance and disappearance to the same
coordinator, with no platform-specific network path. `ContentView` and the app
delegate no longer call `autoConnectIfNeeded` or stop resources independently,
so there is one owner for the lifecycle race.

| Lifecycle point | Required transition |
|---|---|
| Before capture or before submit | Cancel local action; preserve text draft if present; never persist microphone PCM; no turn marker is invented. |
| Capture or `awaitingAcceptance` | Persist the text/delivery record before stopping resources; if the request may have crossed the boundary, classify it `uncertain`; never send after deactivation. |
| Accepted/uncertain turn | Freeze Profile, route, Household binding, handle, and turn; persist unresolved state; stop capture/playback safely; resume with same-binding reconnect only. |
| Control terminal while audio drains | Preserve the known text terminal; stop/drain playback at the boundary and classify only audio as stopped/unavailable, not the prompt as newly uncertain. |
| Reconnect in flight | Cancel the bounded attempt and retain the binding/marker; restart from persisted state only after active and Home-ready prerequisites. |
| Relaunch or foreground | Restore per-Profile local history/draft/uncertainty first, then obtain the approved route and perform Home-ready open/reconnect; do not project `Connected` before that result. |
| macOS window disappearance | Treat as deactivation with the same persist-before-stop and no-network guarantees; a later appearance is a fresh active transition. |

On active, a later route boundary may choose a higher-priority approved route
only when no active/uncertain turn is frozen. The coordinator never retargets
an existing binding and never clears uncertainty merely because the app resumed.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Public adapter absent | Home-mode profile with pre-issued Device credential; endpoint refusal/`404` | Production wiring shows typed `public_adapter_unavailable`; legacy mode remains explicit and selectable | Do not delete credentials, label the credential invalid, or call vanilla `/api/ws` |
| Ready text turn | Fake Home bridge sends schema-1 ready, accepted prompt, ordered cumulative events, and terminal event | ConversationStore receives normalized start/delta/replace/activity/complete semantics and one new opaque turn binding | Bad schema, missing handle, wrong route, unknown method, or unrelated turn becomes safe `protocol_error` and cannot complete the turn |
| Ready voice turn | Same fake sends valid `audio.frame` start, split binary PCM, terminal audio frame, and control terminal | Voice coordinator plays verified PCM and settles only after control terminal plus playback/audio terminal | Invalid metadata, bytes before start/after terminal, duplicate start, odd terminal aggregate (not an individual transport chunk), or late generation becomes typed audio failure; text survives |
| Timing absent | Capabilities contain `timing: absent`; legacy timing-shaped event or ping arrives | UI/evidence exposes unavailable timing or uses final local playback duration/clock | Network arrival, ping latency, transcript timestamps, and `speech_timing` cannot create timing evidence |
| Interrupt | Advertised interrupt receives ack and matching interrupted/cancelled terminal | Playback stops, stale events are ignored, and surface says Interrupted only after terminal confirmation | Unsupported/rejected is not success; ack/timeout without terminal triggers close/reconnect fallback and leaves delivery unconfirmed |
| Structured prompt | Correlated approval/clarify/secret/sudo request with options and expiry | Typed pending prompt is rendered/resolved with the fixed response key | Stale/uncorrelated response, unsupported UI, or secret logging yields typed unavailable/rejected; never submit as model text |
| Command | `command.dispatch` advertised or absent | Only advertised command is dispatched and result classified | Absent/rejected/transport-uncertain remains distinct; no automatic replay |
| Route/transport loss | Loss before, during, or after acceptance | State follows the route-loss matrix; reconnect preserves handle and unresolved marker | No automatic prompt resend, route switch during active/uncertain delivery, or false Connected state |
| Configuration conversion | Existing Profile/history/draft/legacy credential plus pre-issued Home Device credential | Keychain read-back and a successful fake Home binding complete conversion; legacy record remains for explicit rollback | Crash/write/read-back/adapter failure leaves legacy selected and retryable; rollback/conversion is deferred outside idle safe boundary |
| Lifecycle/relaunch | iOS/macOS inactive, background, suspension, relaunch during capture, playback, reconnect, or uncertainty | Capture/playback resources stop at the target lifecycle boundary; no send/reconnect while inactive; relaunch restores local history/draft/uncertainty and reconnects only through Home readiness | Active/uncertain binding is not retargeted; safe unavailable state remains visible |

</intent-contract>

## Code Map

- `HermesRelay/Models/SessionModels.swift:3-33,73-206,289-308` -- current
  connection/voice projections, `SessionMetadata.sessionID`,
  `HermesTurnBinding`, `AudioFormat`, and normalized `HermesEvent`; introduce
  a typed Home-versus-legacy binding and explicit PCM byte order without
  putting an opaque Home handle or Standard runtime ID in `sessionID`.
- `HermesRelay/Services/HermesSessionClient.swift:3-35` -- the async
  normalized client seam and Boolean interrupt result; add typed Home operation
  and interruption outcomes while keeping the legacy adapter usable only for
  explicit rollback.
- `HermesRelay/Services/HermesEventNormalizer.swift:17-169,171-215,217-367`
  -- existing Standard/fork event mapping, cumulative preview replacement, and
  legacy `speech_timing`; add an envelope-validation wrapper and Home timing
  gate here, not a second Standard parser.
- `HermesRelay/Services/WebSocketConnection.swift:8-16,44-157` -- injectable
  text/binary socket and exactly-once receive continuation; retain it as the
  single receive-owner seam for the Home socket.
- `HermesRelay/Services/URLSessionHermesSessionClient.swift:33-191,222-333,340-485`
  -- current legacy bearer, `hello`/`turn`/`interrupt`, binary gating,
  generation guards, and bounded sends; preserve as rollback-only and ensure
  no Home method is routed through it.
- `HermesRelay/Models/HomeBridgeModels.swift` -- add endpoint-safe schema-1
  JSON-RPC envelopes, approved route identity, opaque conversation/turn
  binding, bridge/delivery/audio states, capabilities, stable failures,
  structured prompts/commands, typed interruption outcomes, deadlines,
  `HomeBridgeEvent`/`HomePCMAccumulator`, and migration records. This file
  does not exist yet.
- `HermesRelay/Services/HomeBridgeSessionClient.swift`,
  `HermesRelay/Services/URLSessionHomeBridgeSessionClient.swift`, and
  `HermesRelay/Services/FakeHomeBridgeSessionClient.swift` -- add the Home
  session boundary, opt-in URLSession adapter, deterministic fake, one-reader
  JSON/binary demultiplexing, request correlation, and production
  `public_adapter_unavailable` gate. These files do not exist yet.
- `HermesRelay/ViewModels/ConversationStore.swift:18-161,163-306,375-508`
  and `HermesRelay/Services/ReconnectPolicy.swift:7-30` -- current binding
  proof, local transcript/draft/uncertainty persistence, reconnect ladder, and
  no-replay seam; separate route, bridge, and turn delivery and freeze the
  Home binding through recovery.
- `HermesRelay/Services/ConversationPersistence.swift:3-90` -- per-Profile
  local messages, draft, and `unconfirmedTurnText`; extend the same atomic
  record with optional `PersistedHomeRecovery` and old-file decoding while
  keeping credentials, raw PCM, server IDs, and structured secret values
  outside it.
- `HermesRelay/Models/RelayProfile.swift:29-95`,
  `HermesRelay/Models/RelayProfileCollection.swift:7-44`,
  `HermesRelay/Services/RelayConfigurationStore.swift:24-177`, and
  `HermesRelay/Services/SecureValueStore.swift:4-70` -- profile identity and
  verified Keychain copy/read-back; extend them with Home/legacy mode, a
  secure-only pre-issued Device credential reference, and crash-safe phase
  storage without altering legacy token deletion semantics for unrelated users.
- `HermesRelay/Services/HomeCredentialStore.swift` and
  `HermesRelay/Services/HomeConfigurationMigration.swift` -- new secure
  credential-reference and reversible conversion seams. Store no raw
  credential in Codable profiles, snapshots, logs, or diagnostics; activate
  Home only after secure read-back and fake-ready verification, and retain
  the legacy credential for explicit rollback.
- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift:469-576,731-840,891-1238`
  -- capture binding, interrupt flow, generation guards, native playback
  drain, local playback clock, and final PCM duration; add Home control/audio
  joining, typed audio failures, confirmed interrupt projection, and lifecycle
  teardown while preserving text when audio fails.
- `HermesRelay/Services/AppleLifecycleCoordinator.swift` -- new main-actor
  lifecycle owner for injected iOS scenePhase and macOS scene/window inputs;
  serialize persist-before-stop, generation cancellation, client close, and
  restore-before-reconnect. This file does not exist yet.
- `HermesRelay/Services/AudioOutput.swift:4-63,196-329`,
  `HermesRelay/Services/AppleAudioOutput.swift:4-173`, and
  `HermesRelay/Views/RecentTranscriptRail.swift:111-175,418-605` -- strict
  PCM validation, frame accumulation, platform playback, and verified local
  timing projection.
- `HermesRelay/Views/AmbientHUD.swift:86-259,281-285`,
  `HermesRelay/Views/ContentView.swift:85-220,223-375`,
  `HermesRelay/Views/RelayConfigurationView.swift:121-475`, and
  `HermesRelay/Views/VoiceControl.swift:3-26,96-213` -- current SwiftUI
  connection projection, scene handling, configuration form, and voice
  actions; expose typed Home route/bridge/delivery/timing/audio/prompt state
  and explicit fresh-action/rollback controls without content-bearing
  diagnostics.
- `HermesRelay/HermesRelayApp.swift:5-76` -- app-owned persistence ordering,
  configured-client construction, and debug factory seam; select
  `-HomeBridgeFake` only in Debug and keep production Home mode unavailable
  until the public route adapter is served.
- `HermesRelayTests/HermesEventNormalizerTests.swift:5-311`,
  `HermesRelayTests/URLSessionHermesSessionClientTests.swift:204-695,801-917`,
  `HermesRelayTests/ConversationStoreTransportTests.swift:7-468,482-713`,
  `HermesRelayTests/ConversationStoreReconnectTests.swift:7-181,211-247`,
  `HermesRelayTests/RecoveryTests.swift:7-101`,
  `HermesRelayTests/VoiceSessionCoordinatorTests.swift:8-2068,2077-2885`,
  `HermesRelayTests/AudioOutputTests.swift:7-348,392-494`, and
  `HermesRelayTests/RelayConfigurationTests.swift:6-633` -- existing
  deterministic fakes and regression seams to extend; no Home-focused test
  files currently exist.
- `HermesRelayTests/HomeBridgeEnvelopeTests.swift`,
  `HermesRelayTests/HomeBridgeSessionClientTests.swift`,
  `HermesRelayTests/HomeBridgeAudioTests.swift`,
  `HermesRelayTests/HomeConfigurationMigrationTests.swift`, and
  `HermesRelayTests/AppleLifecycleTests.swift` -- new focused tests for
  schema/error allowlists, one-reader correlation, split PCM, journal recovery,
  and lifecycle race ownership.
- `Hermes Relay.xcodeproj/project.pbxproj:167-228,350-412` -- one app target
  and one `HermesRelayTests` target; register each new source/test explicitly.
- `.github/workflows/ci.yml:17-100`,
  `docs/plans/2026-08-30-ios-voice-interface-testing-plan.md:13-149`, and
  `docs/workflow.md:33-87` -- actual iOS/macOS build ladder and stale manual
  commands; update the plan to the real project/scheme and fake-only smoke
  boundary.
- Canonical Home bridge contract v1, route/session state, credential lifecycle,
  and pinned Standard baseline -- external planning authority read during
  investigation. The fixed rules are schema-1 JSON-RPC, the seven Home
  methods, `event`/`audio.frame` notifications, `Authorization: Device`, safe
  opaque handles, `timing: absent`, and no direct public adapter claim.

## Tasks & Acceptance

**Execution:**

1. `HermesRelay/Models/HomeBridgeModels.swift`,
   `HermesRelay/Models/SessionModels.swift`,
   `HermesRelay/Services/HermesSessionClient.swift`, and
   `HermesRelay/Services/HermesEventNormalizer.swift` -- define the typed
   endpoint-safe schema-1 request/response/notification envelope and the
   Home-versus-legacy binding. Validate `jsonrpc: "2.0"`, `schema: 1`, unique
   request IDs, matching opaque conversation/turn/correlation fields, stable
   Home failure codes plus separate route-attempt reasons, the explicit
   `reconnect_required` open result, typed deadlines, capability
   `timing: absent`, and strict audio-frame metadata. Preserve Standard event
   names, semantic payload meaning, cumulative replacement, and global-event
   rules at the existing normalizer seam; map `sessionID` only for the legacy
   case and expose the typed `HomePromptSubmissionOutcome` to the store.
2. `HermesRelay/Services/HomeBridgeSessionClient.swift`,
   `HermesRelay/Services/URLSessionHomeBridgeSessionClient.swift`,
   `HermesRelay/Services/FakeHomeBridgeSessionClient.swift`, and
   `HermesRelay/Services/WebSocketConnection.swift` -- implement one Home
   receive owner over the planned
   `/api/v1/bridge/ws`, with JSON-RPC methods limited to
   `conversation.open`, `conversation.reconnect`, `prompt.submit`,
   `session.interrupt`, `prompt.respond`, `command.dispatch`, and
   `bridge.ping`; carry `event`/`audio.frame` JSON and binary PCM on that
   socket. Consume a `HomeApprovedRoute` from
   `HomeApprovedRouteProvider`, validate its exact `wss` endpoint/path and
   returned `route.class`/`route.id` against the approved route; retain the
   Household binding only as a local Home receipt and never perform Apple-side
   discovery or route selection. Send only `Authorization: Device
   <device-credential>` on
   the upgrade, keep the credential and server/runtime identifiers out of all
   other frames, and make the production factory return
   `public_adapter_unavailable` while the public Home adapter is absent. The
   Debug fake must accept an injected approved-route record and be explicit and
   deterministic; it may model Home's internal Standard gateway/audio join but
   must never open vanilla `/api/ws` or `/api/audio/speak-stream`.
3. `HermesRelay/Models/RelayProfile.swift`,
   `HermesRelay/Models/RelayProfileCollection.swift`,
   `HermesRelay/Services/SecureValueStore.swift`,
   `HermesRelay/Services/HomeCredentialStore.swift`,
   `HermesRelay/Services/HomeConfigurationMigration.swift`, and
   `HermesRelay/Services/RelayConfigurationStore.swift` -- add explicit
   Home/legacy mode and the exact Home-approved route reference, consume only a
   pairing-supplied `HomeCredentialReference` at the
   `com.achappell.HermesRelayIOS.home-device` / `device-credential.<profile
   UUID>` Keychain location, persist idempotent migration phases, and verify
   private Keychain read-back before probing a fake Home `conversation.open`.
   Persist Home mode only after the binding is `ready`; leave legacy mode and
   its bearer available after any write/read-back/fake-ready/crash failure.
   Tests seed an in-memory secure store and inject the non-secret reference;
   no UI pairing or credential bytes are required. Allow explicit rollback
   only at an idle boundary and never derive or issue a Device credential in
   Apple code.
4. `HermesRelay/ViewModels/ConversationStore.swift`,
   `HermesRelay/Services/ConversationPersistence.swift`, and
   `HermesRelay/Services/ReconnectPolicy.swift` -- keep local Profile
   messages/drafts intact while separating route state, Home bridge state, and
   turn-delivery state. Extend the atomic per-Profile persistence record with
   optional `PersistedHomeRecovery` (route endpoint/class/id, local Household
   receipt, opaque conversation/turn/correlation, cursor, and accepted or
   uncertain state) and decode old files with that field absent. Write the
   binding/turn/uncertainty updates before their corresponding UI or teardown
   transitions, restore them before auto-connect, and preserve mismatches for
   safe unavailable projection. Consume the typed `HomePromptSubmissionOutcome` seam:
   classify `request_rejected` as known non-delivery and
   `transport_unavailable`/`transport_timeout` as uncertain; persist
   `unconfirmedTurnText` only for the latter, retain it through reconnect, and
   clear/replace it only after a fresh explicit user action creates a new
   Home turn. Freeze Profile, Household, route, conversation handle, and
   active turn identity while active or uncertain; reconnect the same binding
   with bounded 10-second operations and never resend or replay. Cover the
   pre-acceptance rejection, no-response-after-send, accepted-then-loss,
   reconnect-with-unresolved-marker, and fresh-action transitions explicitly.
   Reconnect restores a persisted cursor when Home supplies one, accepts
   `unresolved_turn` as unresolved, and never resends persisted text; only an
   explicit fresh action may replace the old record after its own outcome is
   known.
5. `HermesRelay/ViewModels/VoiceSessionCoordinator.swift`,
   `HermesRelay/Services/AudioOutput.swift`,
   `HermesRelay/Services/AppleAudioOutput.swift`, and
   `HermesRelay/Views/RecentTranscriptRail.swift` -- join the Home control
   terminal with an audio terminal (`ended`, `fallback`, `unavailable`, or
   `invalid`) and native playback drain; accept PCM only after a positive-rate,
   mono, signed-16, little-endian `audio.frame` start. Feed arbitrary binary
   transport chunks to a per-turn `HomePCMAccumulator`, retain one trailing
   byte between chunks, and reject only a misaligned aggregate at an audio
   terminal; reject pre-start, duplicate, late, or wrong-generation bytes and
   discard the accumulator on fallback/unavailable/invalid. Keep text usable
   after audio failure. Treat Home `timing: absent` and legacy
   `speech_timing` as non-authoritative in Home mode; expose unavailable timing
   or the already verified local playback clock/final PCM duration only.
6. `HermesRelay/Services/HermesSessionClient.swift`,
   `HermesRelay/Services/URLSessionHermesSessionClient.swift`,
   `HermesRelay/ViewModels/ConversationStore.swift`,
   `HermesRelay/ViewModels/VoiceSessionCoordinator.swift`, and
   `HermesRelay/Services/ReconnectPolicy.swift` -- replace optimistic Boolean
   interruption at the normalized seam with typed
   `confirmed`/`rejected`/`unavailable`/`uncertain` outcomes. Use the 2-second
   interrupt acknowledgement bound, wait for the matching
   `interrupted`/`cancelled` terminal before showing Interrupted, and use
   close/reconnect fallback for timeout or transport loss without replay.
   Apply the 10-second open/reconnect and prompt-acceptance, 5-second ping,
   and 5-second audio-start bounds through injected clocks/sleepers; preserve
   late-event and generation guards.
7. `HermesRelay/Services/AppleLifecycleCoordinator.swift`,
   `HermesRelay/ViewModels/VoiceSessionCoordinator.swift`,
   `HermesRelay/ViewModels/ConversationStore.swift`, and
   `HermesRelay/Views/ContentView.swift` -- add a main-actor Apple lifecycle
   seam used by both iOS and macOS. Feed it iOS `scenePhase` and macOS
   scene/window visibility through the named lifecycle inputs; on
   inactive/background/suspension/window disappearance, persist local
   history/draft/uncertainty before stopping capture/playback, cancel or freeze
   reconnect/send work, and prevent readiness claims or Home operations until
   active again. On relaunch/foreground, restore the per-Profile local state
   before a fresh Home-approved-route and Home-ready reconnect; never retarget
   an active or uncertain binding. Test every delivery phase, including
   capture-before-submit, awaiting acceptance, accepted/uncertain delivery,
   audio draining, reconnect cancellation, resume, and relaunch.
   The coordinator owns the async `handle(_:)` input boundary, generation token,
   cancellation precedence, and `close()` ordering; ContentView/app scene
   hooks only map platform events to it and do not independently connect or
   tear down.
8. `HermesRelay/Views/AmbientHUD.swift`,
   `HermesRelay/Views/RelayConfigurationView.swift`,
   `HermesRelay/Views/VoiceControl.swift`, and
   `HermesRelay/HermesRelayApp.swift` -- project safe route/bridge/turn,
   timing, audio, structured-prompt, command, and uncertainty states. Keep
   structured prompt responses typed with fixed keys (`choice`/`all`,
   `answer`, `value`, `password`) and out of ordinary transcript history;
   expose explicit rollback and fresh-action recovery. Wire
   `-HomeBridgeFake` only for Debug and render
   `public_adapter_unavailable` as unavailable, never as invalid credentials
   or live Home connectivity.
9. `HermesRelayTests/HomeBridgeEnvelopeTests.swift`,
   `HermesRelayTests/HomeBridgeSessionClientTests.swift`,
   `HermesRelayTests/HomeBridgeAudioTests.swift`,
   `HermesRelayTests/HomeConfigurationMigrationTests.swift`,
   `HermesRelayTests/AppleLifecycleTests.swift`,
   `HermesRelayTests/ConversationStoreTransportTests.swift`,
   `HermesRelayTests/ConversationStoreReconnectTests.swift`,
   `HermesRelayTests/RecoveryTests.swift`,
   `HermesRelayTests/VoiceSessionCoordinatorTests.swift`,
   `HermesRelayTests/AudioOutputTests.swift`, and
   `HermesRelayTests/RelayConfigurationTests.swift` -- add deterministic
   fixtures for envelope/error redaction, one-reader ordering, method
   allowlisting, Device-header construction, production adapter absence,
   opaque-handle isolation, route-loss phases, known-versus-uncertain
   delivery, no-replay/fresh action, interrupt terminal confirmation,
   structured prompt/command gating, strict PCM and control/audio joining,
   timing absence, crash-safe migration/rollback, and iOS/macOS lifecycle.
   Fixtures may construct synthetic, non-sensitive in-memory placeholders (for
   example `delta-1`/`delta-2`, fixed structured keys, and a numeric PCM sample
   array) solely to prove ordering, cumulative replacement, schema, and byte
   joining. They must never use real/private prompts or responses, real
   credentials, microphone captures, or persisted/logged/snapshotted raw
   frames or PCM; validation assertions record only counts, safe reason codes,
   format metadata, and ordering.
10. `Hermes Relay.xcodeproj/project.pbxproj`, `.github/workflows/ci.yml`,
    `docs/plans/2026-08-30-ios-voice-interface-testing-plan.md`, and
    `_bmad-output/implementation-artifacts/next-wave-standard-hermes-migration/stories/validation-0-I-4-apple-migrate-ios-macos-client.md`
    -- register every new source/test in the single
    app/test targets, correct the manual commands to `Hermes Relay.xcodeproj`
    and `HermesRelay`, pin fake provenance to Standard `0.21.1` commit
    `2237be355906fbe6065ce1815711eee52b2d646e`, and record fake-backed results
    separately from the blocked public-adapter gate. Do not run or claim live
    Home route evidence until that adapter is served.

**Acceptance Criteria:**

- Given a selected Profile with local history, draft, uncertainty marker, and
  legacy credential, when a pairing-supplied `HomeCredentialReference` is
  staged and the user explicitly starts conversion, then private Keychain
  read-back and a fake-ready `conversation.open` binding are required before
  the Apple surface selects Home mode; the Profile identity and local state
  survive, the exact Home Keychain reference is used, and the legacy
  credential remains available for idle-boundary rollback.
- Given a `HomeApprovedRoute` supplied by `HomeApprovedRouteProvider` and an
  opaque conversation handle, when schema-1 `conversation.open` returns
  `status: ready` with the same handle, matching `route.class`/`route.id`, and
  capabilities, then the Apple surface may show Connected and accept input;
  the approved record's Household binding is a local non-secret receipt, while
  successful Home Device authorization and identity-valid route selection are
  Home-owned proof. Route reachability alone, Apple-side discovery,
  `unavailable`, `reconnect_required`, refusal, or `404` never does.
- Given a route attempt or open/reconnect result with
  `route_unavailable`, `route_unauthorized`, `route_identity_mismatch`,
  `route_timeout`, or `reconnect_required`, when the result is projected,
  then the typed route reason remains distinct from Device authorization,
  `public_adapter_unavailable`, and turn delivery; only an existing binding
  may issue same-binding reconnect for `reconnect_required`, and no reason
  alone projects to Connected.
- Given Home mode is selected while the public adapter is absent, when the app
  loads the selected Profile, then it shows typed
  `public_adapter_unavailable` and offers explicit recovery/rollback without
  sending a Home method to vanilla `/api/ws`, opening
  `/api/audio/speak-stream`, sending a bearer, or claiming live Home route
  integration.
- Given a Home-ready binding, when the user performs one text or voice action,
  then exactly one allowlisted `prompt.submit` is correlated to a new opaque
  Home turn, matching Standard events reach the normalized store with their
  cumulative-preview and terminal meaning intact, and the Apple surface never
  exposes a Standard runtime Session ID.
- Given an accepted or rejected input operation, when the transport returns
  an accepted result, `request_rejected`, or
  `transport_timeout`/`transport_unavailable` through
  `HomePromptSubmissionOutcome`, then the surface distinguishes
  completed/known-failed/uncertain delivery, persists the uncertainty marker
  only for the uncertain cases, and on reconnect retains the same binding
  without resubmission until a fresh user action. A transport loss after
  `prompt.submit` is sent but before acceptance is uncertain, not a known
  rejection.
- Given a valid or invalid Home audio sequence, when control and audio
  terminals arrive in either permitted order, then the surface plays only
  validated mono signed-16 little-endian PCM and settles text/audio after the
  control terminal plus an audio terminal or typed audio failure; late or
  invalid audio cannot create a second answer or erase readable text.
- Given `timing: absent` and either a legacy timing-shaped event or ping
  response, when the Apple surface presents the turn, then it reports timing
  absence or uses only verified local playback duration/clock and never treats
  network arrival, ping latency, transcript timestamps, or `speech_timing` as
  timing authority.
- Given an approval, clarify, secret, or sudo request or an advertised command,
  when the user resolves or dispatches it, then the surface uses the fixed
  typed response key or advertised command only, preserves handle/turn/
  correlation and sensitivity metadata, and keeps secret/password values out
  of transcript, persistence, diagnostics, and evidence.
- Given interrupt support is advertised, when an acknowledgement is received
  without a matching `interrupted`/`cancelled` terminal, then the surface does
  not show Interrupted; the bounded timeout/transport path stops local audio,
  reconnects through the same binding, and leaves delivery uncertain. Only the
  matching terminal confirms interruption and invalidates stale generations.
- Given route loss, revocation, or lifecycle deactivation occurs before,
  during, or after a turn, when recovery or relaunch runs, then route,
  Profile, Household, handle, and delivery state follow the route-loss matrix,
  `AppleLifecycleCoordinator` persists before stopping native resources at the
  Apple boundary, inactive operations are suppressed, local state restores
  before Home readiness, reconnect cancellation/resume is bounded, and no
  uncertain prompt or response is replayed. Capture-before-submit,
  awaiting-acceptance, accepted/uncertain delivery, audio draining, and
  macOS-window disappearance are each covered.
- Given deterministic fake traffic, when tests prove cumulative text,
  structured response keys, split PCM joining, or redaction, then all payloads
  and samples are synthetic and in-memory only; no real/private content,
  credential bytes, microphone capture, raw frame, or PCM bytes appear in a
  log, snapshot, persisted record, or validation artifact.
- Given the deterministic fake suite and iOS/macOS gates pass, when the
  validation record is reviewed, then it contains only safe states, counts,
  timings from approved local clocks, reason codes, build/test destinations,
  and the pinned fake provenance; live Home integration remains explicitly
  blocked until the public adapter exists.

## Spec Change Log

- 2026-09-14: Rewritten against the now-published Home bridge contract. The
  Apple-facing transport is one planned Home WebSocket; Standard's two sockets
  remain Home-owned internals. Added typed binding/state/outcome models,
  credential phases, deadlines, prompt/command ownership, audio join rules,
  lifecycle injection, and the explicit public-adapter gate.

## Review Triage Log

- 2026-09-14: The prior auto-loop plan review failed because it linked the
  sibling companions incorrectly and left the endpoint/Standard socket
  boundary, opaque binding, credential conversion, typed readiness/errors,
  audio join, prompts/commands, timing absence, lifecycle injection, and pinned
  evidence insufficiently specified. This revision addresses those findings.
  The Home contract is now readable and stable enough for fake-backed
  implementation; only the public live adapter remains an explicit external
  gate.
- 2026-09-14: The independent repair review found six remaining gaps in the
  route/error mapping, approved-route input, credential handoff, typed
  acceptance result, lifecycle transition source, and synthetic fixture
  wording. Added exact provider/Keychain/handoff seams, wire-to-state tables,
  delivery and lifecycle transition matrices, and the safe fixture rule. The
  public adapter remains blocked and no live route is implied.
- 2026-09-14: A stricter independent review found eleven concrete gaps in the
  operation API, credential handoff, crash journal, persisted opaque binding and
  cursor, route-proof wire shape, injected deadlines, lifecycle race ownership,
  typed prompt/command events, transport-split PCM, payload allowlisting, and
  test mapping. Added those implementation contracts and the focused seam
  matrix. Source implementation remains intentionally deferred until this
  gate passes.

## Design Notes

The Apple adapter is a narrow endpoint client, not a second Hermes gateway.
Home's endpoint exposes one receive stream: `event` and `audio.frame` JSON
notifications plus binary PCM are demultiplexed by one reader. Home—not this
repository—owns the join between Standard's JSON gateway and response-audio
sidecar. The fake uses the same endpoint shape and may drive deterministic
internal fixtures to prove that join.

The route selector and Household Identity proof remain Home-owned. Apple stores
only Home-provided safe route metadata, the opaque conversation handle, the
local Profile UUID, and the capability snapshot. The chosen Apple-local
transport mode is explicit: Home mode is selected only after migration
verification; the legacy client is retained as an explicit rollback mode.
Reconnect restores the existing binding and any unresolved turn; it never
creates a new Profile, infers a route, resubmits input, or declares completion
from readiness.

The canonical Home prompt response keys are fixed: approval uses `choice` with
optional `all`, clarification uses `answer`, secret uses `value`, and sudo uses
`password`. These values are transient typed input and never ordinary model
text. The pinned Standard baseline has no authoritative timing event, so Home
mode reports `timing: absent` and may use only the existing verified playback
clock/final PCM duration.

## Verification test matrix

The focused gate names every changed contract seam so a green result cannot
hide an untested migration branch:

| Changed seam / acceptance branch | Named deterministic proof |
|---|---|
| JSON-RPC schema, method allowlist, route class/id, safe error mapping, and credential/header redaction | `HomeBridgeEnvelopeTests` |
| One socket, one reader, pending correlation, typed open/reconnect/prompt/interrupt/prompt-response/command/ping outcomes, close cancellation, public-adapter absence | `HomeBridgeSessionClientTests` |
| Standard payload allowlist, cumulative replacement, global-event isolation, and timing absence | `HomeBridgeEnvelopeTests`, `HermesEventNormalizerTests` |
| Split binary PCM, start metadata, terminal join, late generations, and audio failure preserving text | `HomeBridgeAudioTests`, `AudioOutputTests`, `VoiceSessionCoordinatorTests` |
| Home credential reference/account, private read-back, idempotent journal, crash recovery, fake-ready commit, and idle rollback | `HomeConfigurationMigrationTests`, `RelayConfigurationTests`, `RecoveryTests` |
| Persisted opaque binding/cursor, old-file decode, uncertainty-before-teardown, mismatch preservation, relaunch restore, and no replay/fresh action | `ConversationPersistenceTests`, `HomeConfigurationMigrationTests`, `ConversationStoreReconnectTests` |
| Known rejection versus uncertain transport, route-loss phases, reconnect exhaustion, and legacy no-replay regressions | `ConversationStoreTransportTests`, `ConversationStoreReconnectTests`, `ReconnectPolicyTests`, `URLSessionHermesSessionClientTests` |
| Typed structured prompt/command response keys, pending ownership, expiry, stale correlation, capability gating, and secret exclusion | `HomeBridgeSessionClientTests`, `HomeBridgeEnvelopeTests` |
| Interrupt acknowledgement versus matching terminal, timeout fallback, and stale generation suppression | `HomeBridgeSessionClientTests`, `VoiceSessionCoordinatorTests`, `ConversationStoreTransportTests` |
| Injected monotonic deadlines and cancellation of per-attempt versus overall reconnect work | `HomeBridgeSessionClientTests`, `ConversationStoreReconnectTests`, `ReconnectPolicyTests` |
| iOS scenePhase/macOS window mapping, persist-before-stop, inactive suppression, close ordering, cancellation races, and relaunch | `AppleLifecycleTests` |
| Existing legacy protocol remains explicit rollback-only and all fake evidence is synthetic | `URLSessionHermesSessionClientTests`, `RelayConfigurationTests`, `HermesRelayTests` |

## Verification

**Commands:**

- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test -only-testing:HermesRelayTests/HomeBridgeEnvelopeTests -only-testing:HermesRelayTests/HomeBridgeSessionClientTests -only-testing:HermesRelayTests/HomeBridgeAudioTests -only-testing:HermesRelayTests/HomeConfigurationMigrationTests -only-testing:HermesRelayTests/AppleLifecycleTests -only-testing:HermesRelayTests/HermesEventNormalizerTests -only-testing:HermesRelayTests/ConversationPersistenceTests -only-testing:HermesRelayTests/ConversationStoreTransportTests -only-testing:HermesRelayTests/ConversationStoreReconnectTests -only-testing:HermesRelayTests/RecoveryTests -only-testing:HermesRelayTests/URLSessionHermesSessionClientTests -only-testing:HermesRelayTests/VoiceSessionCoordinatorTests -only-testing:HermesRelayTests/AudioOutputTests -only-testing:HermesRelayTests/RelayConfigurationTests` -- expected: focused deterministic Home/lifecycle plus legacy regression XCTest pass.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: iOS Simulator build succeeds.
- `simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')"; test -n "$simulator_id"; xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination "platform=iOS Simulator,id=$simulator_id" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: complete iOS XCTest suite passes on the first available iPhone simulator, or the inability to launch is recorded as an environment limitation.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: macOS build succeeds.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: complete macOS XCTest suite passes.
- `git diff --check` -- expected: no whitespace errors, generated build products, credentials, audio, or unrelated repository edits.

**Manual checks:**

- On both iOS and macOS, launch Debug with `-HomeBridgeFake`; confirm
  Home-ready state precedes capture, one text turn preserves Standard event
  meaning, one voice turn joins split PCM with the control terminal, timing
  absence is visible, audio failure preserves text, and confirmed interruption
  waits for its matching terminal.
- Exercise loss before acceptance, during acceptance, after acceptance, after
  control completion while audio drains, revocation, reconnect exhaustion,
  explicit idle-boundary rollback, and one fresh user action after uncertainty.
  Confirm no prompt is resent, no route/Profile/Household binding changes
  mid-turn, and no readiness state is mistaken for old-turn completion.
- Exercise inactive/background/suspension/relaunch/window disappearance during
  capture, playback, reconnect, and uncertainty. Confirm native resources stop,
  local history/draft/uncertainty survive, and no inactive Home operation or
  readiness claim occurs.
- Confirm the UI displays safe route/bridge/delivery/audio/timing/prompt/
  command/unresolved states. Review diagnostics and validation evidence for
  absence of credentials, prompts, responses, runtime IDs, raw frames, PCM,
  microphone captures, and screenshots with private content. Record the
  public-adapter absence as blocked integration evidence; do not call it a
  credential failure.

## Auto Run Result

Status: ready-for-dev.

Planning result: the story has a file-anchored, fake-backed implementation
plan. The normalized session boundary, schema-1 Home envelope, approved Device
credential boundary, opaque handles, explicit rollback, fresh-action recovery,
strict Standard audio/event meaning, timing absence, and Apple lifecycle
ownership are all specified. The public Home adapter remains an explicit
blocked evidence gate; no implementation, build, test, or live-route check ran
in this planning pass.
