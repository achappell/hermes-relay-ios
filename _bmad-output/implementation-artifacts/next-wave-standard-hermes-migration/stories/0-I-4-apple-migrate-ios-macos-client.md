---
title: '[Apple] Migrate the iOS/macOS client'
type: 'feature'
created: '2026-09-14'
status: 'draft'
review_loop_iteration: 0
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
  rate, `channels: 1`, `sample_width: 2`, and `byte_order: little`; enforce
  signed-16 little-endian frame alignment and the `end`, `fallback`, and
  `unavailable` terminal kinds. Text remains usable when audio is unavailable.
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
| `HomeRouteIdentity` / `HomeRouteState` | The safe class/label supplied by Home (`home`, `tailscale`, or explicitly enabled `public`) and the route attempt result. Apple does not discover unapproved routes or prove Household Identity itself; it accepts only Home's same-identity proof and rejects a missing or changed route binding. |
| `HomeConversationBinding` | Profile UUID plus opaque Home conversation handle, selected route identity, and safe capability snapshot. It contains no Profile ID on the wire and no Standard runtime Session ID. |
| `HomeBridgeState` | `unconfigured`, `connecting`, `ready`, `disconnected`, or `unavailable` with safe Home reason. Only a schema-1 `conversation.open`/`conversation.reconnect` result with `status: ready` can project to `Connected`. |
| `HomeTurnDeliveryState` | `idle`, `awaitingAcceptance`, `accepted`, `completed`, `interrupted`, `failedKnown`, or `uncertain`, carrying the opaque Home turn/correlation. It is independent from route and bridge state. |
| `HomeBridgeFailure` | Stable Home code (`invalid_request`, `authorization_unavailable`, `unauthorized`, `stale_conversation`, `conversation_mismatch`, `request_rejected`, `transport_unavailable`, `transport_timeout`, `protocol_error`, `capability_unavailable`, `hermes_unavailable`, or `public_adapter_unavailable`) plus safe phase and delivery classification. |
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

### Operation deadlines and transitions

Use an injected clock/sleeper and these Apple-local bounds so every wait is
testable and reconnect remains bounded:

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

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Public adapter absent | Home-mode profile with pre-issued Device credential; endpoint refusal/`404` | Production wiring shows typed `public_adapter_unavailable`; legacy mode remains explicit and selectable | Do not delete credentials, label the credential invalid, or call vanilla `/api/ws` |
| Ready text turn | Fake Home bridge sends schema-1 ready, accepted prompt, ordered cumulative events, and terminal event | ConversationStore receives normalized start/delta/replace/activity/complete semantics and one new opaque turn binding | Bad schema, missing handle, wrong route, unknown method, or unrelated turn becomes safe `protocol_error` and cannot complete the turn |
| Ready voice turn | Same fake sends valid `audio.frame` start, split binary PCM, terminal audio frame, and control terminal | Voice coordinator plays verified PCM and settles only after control terminal plus playback/audio terminal | Invalid metadata, bytes before start/after terminal, duplicate start, odd sample count, or late generation becomes typed audio failure; text survives |
| Timing absent | Capabilities contain `timing: absent`; legacy timing-shaped event or ping arrives | UI/evidence exposes unavailable timing or uses final local playback duration/clock | Network arrival, ping latency, transcript timestamps, and `speech_timing` cannot create timing evidence |
| Interrupt | Advertised interrupt receives ack and matching interrupted/cancelled terminal | Playback stops, stale events are ignored, and surface says Interrupted only after terminal confirmation | Unsupported/rejected is not success; ack/timeout without terminal triggers close/reconnect fallback and leaves delivery unconfirmed |
| Structured prompt | Correlated approval/clarify/secret/sudo request with options and expiry | Typed pending prompt is rendered/resolved with the fixed response key | Stale/uncorrelated response, unsupported UI, or secret logging yields typed unavailable/rejected; never submit as model text |
| Command | `command.dispatch` advertised or absent | Only advertised command is dispatched and result classified | Absent/rejected/transport-uncertain remains distinct; no automatic replay |
| Route/transport loss | Loss before, during, or after acceptance | State follows the route-loss matrix; reconnect preserves handle and unresolved marker | No automatic prompt resend, route switch during active/uncertain delivery, or false Connected state |
| Configuration conversion | Existing Profile/history/draft/legacy credential plus pre-issued Home Device credential | Keychain read-back and a successful fake Home binding complete conversion; legacy record remains for explicit rollback | Crash/write/read-back/adapter failure leaves legacy selected and retryable; rollback/conversion is deferred outside idle safe boundary |
| Lifecycle/relaunch | iOS/macOS inactive, background, suspension, relaunch during capture, playback, reconnect, or uncertainty | Capture/playback resources stop at the target lifecycle boundary; no send/reconnect while inactive; relaunch restores local history/draft/uncertainty and reconnects only through Home readiness | Active/uncertain binding is not retargeted; safe unavailable state remains visible |

</intent-contract>

## Code Map

- `HermesRelay/Models/HomeBridgeModels.swift` -- endpoint-safe route,
  binding, capability, credential-migration, structured-prompt, audio, error,
  connection, and turn-delivery types.
- `HermesRelay/Models/SessionModels.swift:176-246,289-307` -- replace the
  public Home use of `sessionID`, add endpoint-safe binding/correlation and
  explicit audio byte order while retaining legacy-only compatibility.
- `HermesRelay/Services/HermesSessionClient.swift:3-25` -- introduce typed
  operation and interruption outcomes; map the existing legacy client without
  changing its explicit rollback behavior.
- `HermesRelay/Services/HomeBridgeSessionClient.swift` and
  `HermesRelay/Services/URLSessionHomeBridgeSessionClient.swift` -- one
  endpoint-facing Home WebSocket, upgrade credential boundary, request-ID
  correlation, deadlines, reconnect, typed errors, and stream demultiplexing.
  The production adapter must remain an explicit unavailable gate while the
  public Home endpoint is absent; it must not open Standard sockets.
- `HermesRelay/Services/WebSocketConnection.swift:8-25` -- retain the
  injectable one-socket boundary and document one reader/close ownership.
- `HermesRelay/Services/HermesEventNormalizer.swift:17-337` -- extend the
  existing normalization boundary for schema-1 Home event envelopes,
  cumulative replacement, safe error mapping, audio validation, interrupt
  terminals, and timing absence. Do not add a second Standard parser.
- `HermesRelay/ViewModels/ConversationStore.swift:30-131,163-358,375-507`
  and `HermesRelay/Services/ReconnectPolicy.swift:1-28` -- construct and
  freeze a verified binding, project separate route/bridge/turn state, persist
  known-versus-uncertain outcomes, preserve the old client for explicit
  rollback, and reconnect only through Home with no replay.
- `HermesRelay/ViewModels/VoiceSessionCoordinator.swift:469-576,731-840,891-1238`
  and `HermesRelay/Services/AudioOutput.swift:1-44` -- preserve native
  capture/playback, generation guards, audio-terminal join, playback drain,
  and verified duration/clock timing.
- `HermesRelay/Views/AmbientHUD.swift:1-220,283-418`,
  `HermesRelay/Views/ContentView.swift:1-220`, and
  `HermesRelay/Views/RelayConfigurationView.swift:1-380` -- project the
  typed Home/route/turn/timing/audio/unresolved states, expose safe unavailable
  and fresh-resend actions, and keep structured prompt/secret presentation out
  of ordinary text.
- `HermesRelay/HermesRelayApp.swift:1-90` -- inject a Debug-only
  `-HomeBridgeFake` factory for deterministic iOS/macOS manual evidence;
  production Home mode remains unavailable until the public adapter exists.
- `HermesRelay/Services/RelayConfigurationStore.swift:24-177`,
  `HermesRelay/Models/RelayProfile.swift:29-95`,
  `HermesRelay/Models/RelayProfileCollection.swift:3-44`, and
  `HermesRelay/Services/SecureValueStore.swift:4-70` -- persist versioned
  Home/legacy credential references and crash-safe migration phases without
  writing secret values to Codable profile files.
- `HermesRelay/Services/ConversationPersistence.swift:3-90` -- preserve
  per-Profile messages, draft, and `unconfirmedTurnText`; do not export them
  into diagnostics or use this store as a wire parser.
- `HermesRelayTests/HomeBridgeSessionClientTests.swift`,
  `HermesRelayTests/HomeBridgeEnvelopeTests.swift`,
  `HermesRelayTests/HomeBridgeAudioTests.swift`,
  `HermesRelayTests/ConversationStoreTransportTests.swift`,
  `HermesRelayTests/ConversationStoreReconnectTests.swift`,
  `HermesRelayTests/RecoveryTests.swift`,
  `HermesRelayTests/RelayConfigurationTests.swift`,
  `HermesRelayTests/ConversationPersistenceTests.swift`, and
  `HermesRelayTests/VoiceSessionCoordinatorTests.swift` -- deterministic
  one-Home-socket fixtures plus regression coverage for every table above.
- `Hermes Relay.xcodeproj/project.pbxproj:167-185,259-294,392-408`,
  `.github/workflows/ci.yml:17-89`, and `docs/workflow.md:33-87` -- add source
  membership and use the repository's iOS/macOS build-test ladder.

## Tasks & Acceptance

**Execution:**

1. **Define the safe model boundary.** Add the typed Home route, binding,
   capability, connection, turn-delivery, prompt/command, audio, failure, and
   credential-migration models. Replace the Home path's public `sessionID`
   assumption with an opaque binding case and retain a legacy-only case. Add
   byte order to `AudioFormat`; no missing metadata defaults.
2. **Build the endpoint-facing adapter.** Add the one-socket Home bridge client
   and fake transport. Encode/decode schema-1 JSON-RPC, unique request IDs,
   `Authorization: Device`, Home methods, `event` and `audio.frame` JSON, and
   binary PCM. Enforce the endpoint-safe allowlist and keep Standard runtime
   identity, Profile IDs, and bearers private. The fake may join internal
   Standard gateway/audio fixtures, but Apple code must never send directly to
   vanilla `/api/ws` or `/api/audio/speak-stream`.
3. **Normalize and join streams.** Extend the existing normalizer and session
   client so only matching handle/route/Profile/turn/correlation events reach
   the store; cumulative previews replace rather than append; global events do
   not complete; structured prompts and advertised commands have typed APIs;
   and the control/audio state machine settles on control terminal plus an
   audio terminal or typed audio failure. Add the full PCM validation and
   generation/late-frame guards.
4. **Make outcomes and recovery explicit.** Update `HermesSessionClient`,
   `ConversationStore`, and `ReconnectPolicy` for typed ready/unavailable,
   operation deadlines, known rejection versus uncertain transport,
   `conversation.reconnect`, phase-specific route loss, unresolved-turn
   persistence, fresh-resend-only recovery, confirmed/unconfirmed interrupt,
   and no route/Profile/Household switch during active or uncertain delivery.
5. **Migrate configuration without losing rollback.** Consume only a
   pre-issued Home Device credential from the secure store. Persist separate
   Home and legacy credential records plus an idempotent migration phase; write
   the active-mode change only after Keychain read-back and a successful fake
   Home ready binding. Keep the legacy source until explicit verified rollback.
   Defer conversion or rollback while capture, playback drain, active delivery,
   or uncertainty is in progress, and leave legacy mode selected after any
   failure.
6. **Project Apple lifecycle and UI state.** Update `AmbientHUD`, `ContentView`,
   `RelayConfigurationView`, `HermesRelayApp`, and the voice coordinator so
   iOS and macOS stop capture/playback at their existing deactivation boundary,
   do not send or claim reconnect readiness while inactive, restore
   history/draft/uncertainty on relaunch, and resume only through Home ready.
   Add the Debug-only `-HomeBridgeFake` injection path and show typed route,
   bridge, timing, audio, prompt, command, and unresolved states without
   content-bearing diagnostics.
7. **Add deterministic evidence and validate the repository.** Add one-socket
   fake fixtures for ready/unavailable, adapter absence, identity mismatch,
   cumulative text, prompts/commands, valid/invalid PCM, audio loss,
   timing-absent, interrupt confirmation/fallback, each route-loss phase,
   conversion/rollback/crash, lifecycle, and no-replay behavior. Pin fake
   provenance to Hermes `0.21.1` commit
   `2237be355906fbe6065ce1815711eee52b2d646e`. Update the local validation
   record with fake results and the separately blocked live-adapter gate, then
   run focused XCTest, iOS Simulator build/test, macOS build/test, and the
   target-specific fake smoke plan.

**Acceptance Criteria:**

- Given an existing selected Profile with local history, draft, uncertainty
  marker, and a legacy bearer record, when a pre-issued Home Device credential
  is staged, then secure-store read-back and a ready fake Home binding are
  required before Home mode becomes active; Profile UUID, device identity,
  history, draft, and uncertainty survive, and the legacy source remains
  available for explicit idle-boundary rollback.
- Given a Home route is selected by Home and `conversation.open` returns
  schema-1 `status: ready` with the same opaque handle, route binding, and
  capabilities, then the store may project Connected and accept input. A
  route-only success, `status: unavailable`, `reconnect_required`, refusal, or
  `404` cannot project Connected or be reported as invalid credentials.
- Given a ready binding, when a user sends text or voice, then the adapter
  sends one Home `prompt.submit`, the store receives only matching normalized
  Standard event semantics, cumulative previews replace correctly, a known
  rejection is not marked uncertain, and an accepted turn retains its opaque
  Home IDs without exposing a Standard runtime Session ID.
- Given a voice turn, when valid `audio.frame` metadata, split binary PCM, and
  control/audio terminal conditions arrive in either permitted order, then only
  verified signed-16 little-endian mono PCM reaches native playback and the
  response settles after control terminal plus playback/audio terminal. Invalid,
  fallback, unavailable, or late audio produces typed audio state while
  readable text remains available.
- Given the pinned Standard capability reports `timing: absent`, then the
  Apple surface exposes timing absence or the existing verified final playback
  duration/clock and never uses network arrival, ping, transcript timestamps,
  or legacy `speech_timing` as timing authority.
- Given an approval, clarify, secret, or sudo event, then the native surface
  preserves its fixed response key, sensitivity, options, expiry, handle, turn,
  and correlation; unsupported or stale resolution is typed unavailable or
  rejected, and secret/password values are absent from transcript, persistence,
  diagnostics, and evidence. Given a command, only an advertised name is
  dispatched and its known/uncertain outcome remains distinct.
- Given interrupt capability is advertised, then an accepted request changes
  the surface to Interrupted only after a matching interrupted/cancelled
  terminal event, stops native playback, and discards stale generations. An
  unsupported/rejected request remains distinct; an acknowledgement or timeout
  without terminal confirmation uses the existing close/reconnect fallback and
  leaves delivery unconfirmed.
- Given route or transport loss occurs at any phase in the route-loss matrix,
  then recovery uses fresh Home authorization/readiness and the same binding,
  never changes route during active/uncertain delivery, never resubmits or
  replays, retains `unconfirmedTurnText` through reconnect, and requires a
  fresh explicit user action for a new turn. Exhaustion or revocation leaves a
  safe unavailable/disconnected state with no new submission.
- Given iOS or macOS becomes inactive, backgrounds, suspends, relaunches, or
  closes a window during capture/playback/reconnect/uncertainty, then native
  resources stop at the defined boundary, no inactive send or readiness claim
  occurs, and relaunch restores local history/draft/uncertainty before a new
  Home-ready connection. The `-HomeBridgeFake` launch path reproduces the fake
  scenarios on both targets; production does not claim a live Home route while
  the adapter is absent.
- Given the deterministic fake scenarios pass, then the focused XCTest and the
  `HermesRelay` iOS Simulator and macOS build/test gates pass, and the
  validation record proves that no credentials, prompts, response text, raw
  frames, PCM bytes, audio captures, or generated build files entered evidence.

## Spec Change Log

- 2026-09-14: Rewritten against the now-published Home bridge contract. The
  Apple-facing transport is one planned Home WebSocket; Standard's two sockets
  remain Home-owned internals. Added typed binding/state/outcome models,
  credential phases, deadlines, prompt/command ownership, audio join rules,
  lifecycle injection, and the explicit public-adapter gate.

## Review Triage Log

- 2026-09-14: The prior auto-loop plan review failed because it linked the
  sibling companions incorrectly and left the endpoint/Standard socket boundary,
  opaque binding, credential conversion, typed readiness/errors, audio join,
  prompts/commands, timing absence, lifecycle injection, and pinned evidence
  insufficiently specified. This revision addresses those findings. The Home
  contract is now readable and stable enough for fake-backed implementation;
  only the public live adapter remains an explicit external gate.

## Design Notes

The Apple adapter is a narrow endpoint client, not a second Hermes gateway.
Home's future endpoint presents one receive stream. Its `event` and
`audio.frame` JSON notifications plus binary PCM are demultiplexed by one
reader, while Home—not this repository—owns the awkward join between the
Standard JSON gateway and the separate response-audio sidecar. The fake uses
that same endpoint shape and may drive two internal fixtures to prove the join.

The route selector and Household Identity proof belong to Home. Apple stores
only the safe selected route binding, opaque conversation handle, local Profile
UUID, and capability snapshot. Reconnect restores the existing binding; it does
not create a new Profile, infer a new route, or resend uncertain input.

The current coordinator already supports playback-position and final PCM
duration behavior. The migration therefore records Standard timing as absent
and keeps those verified local fallbacks, without allowing fork-era timing or
network arrival to leak back in.

## Verification

**Commands:**

- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test -only-testing:HermesRelayTests/HomeBridgeSessionClientTests -only-testing:HermesRelayTests/HomeBridgeEnvelopeTests -only-testing:HermesRelayTests/HomeBridgeAudioTests -only-testing:HermesRelayTests/HomeBridgeConfigurationTests` -- expected: focused Home bridge, envelope, audio, and migration XCTest pass.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: iOS Simulator build succeeds.
- `simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')" && test -n "$simulator_id" && xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination "platform=iOS Simulator,id=$simulator_id" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: the full iOS XCTest suite passes against the first available iPhone Simulator.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build` -- expected: macOS build succeeds.
- `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test` -- expected: macOS XCTest suite passes.

**Manual checks:**

- On both iOS and macOS, launch the Debug fake with `-HomeBridgeFake` and
  exercise readiness before capture, one text turn, one spoken turn with
  split-sidecar PCM, confirmed interruption, audio failure, each route-loss
  phase, explicit rollback, and one fresh resend after uncertainty.
- Exercise inactive/background/suspension/relaunch while capture, playback,
  reconnect, and uncertainty are active. Confirm native resources stop, local
  history/draft/uncertainty survive, and no inactive operation sends or claims
  readiness.
- Confirm `AmbientHUD` exposes route/bridge/turn/timing/audio/unresolved state
  without prompt or response content in diagnostics. Record the public Home
  adapter refusal/absence as blocked integration evidence; do not send any Home
  method to vanilla Hermes and do not call that absence a credential failure.
- Review the validation record and diff for bearer/device credentials, prompts,
  response text, runtime IDs, raw frames, PCM/audio captures, generated build
  files, and changes outside this repository.

## Auto Run Result

Status: pending plan review.

Planning boundary: the next unattended run must regenerate this plan, pass the
read-only specification gate, and only then dispatch implementation. The live
Home route remains blocked because the public adapter is not served; fake Home
bridge evidence is the permitted implementation boundary.
