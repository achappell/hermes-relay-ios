---
title: 'Use iOS as an independent conversation doorway (5-I-1)'
type: 'feature'
created: '2026-09-11'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '../hermes-relay-tui/_bmad-output/planning-artifacts/epics.md'
  - 'private canonical product hub'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 5 Story 5.1 / surface story `5-I-1` requires iOS to be a
complete, independent Hermes doorway: typed and tap-to-speak turns, visible
profile and phase state, response text and audio, intentional local history,
safe recovery, and fail-closed authorization and permission boundaries. The
client already contains these seams, but it had no local story artifact tying
the implementation and validation evidence to the upstream story.

**Approach:** Audit the existing profile-bound `ConversationStore`, typed and
voice submission paths, `VoiceSessionCoordinator`, SwiftUI conversation HUD,
per-profile persistence, and recovery tests against the upstream `5-I-1`
scope. Record the closure evidence locally rather than creating a second
transport, history store, or cross-repository contract.

## Boundaries & Constraints

**Always:** Keep the selected Profile and verified `hello_ack` session as the
identity boundary for capture and submission; render only normalized Hermes
events; retain one coherent response's text while its audio is delivered;
persist intentional transcript/draft state per Profile; recover through a
fresh verified session without automatically replaying an uncertain turn; and
keep permission, configuration, and unavailable-identity failures actionable
and fail closed.

**Never:** Share iOS history with a Puck, Display, TUI, or other Client; do not
persist microphone/PCM/audio contents; invent Hermes operations or fallback
response prose; open capture before a verified session; or silently resume a
turn after transport loss.

## Local delivery evidence

| Upstream behavior | iOS implementation seam | Evidence |
|---|---|---|
| Independent Profile and Hermes Session | `ConversationStore.loadConfiguredClient`, `verifiedTurnBinding`, `URLSessionHermesSessionClient`, and `AmbientHUD`'s session header | `ConversationStoreTransportTests` profile/session tests; Epic 1 device validation record |
| Tap-to-speak doorway | `VoiceSessionCoordinator.beginCapture`, `endCaptureAndSend`, and verified capture binding | `VoiceSessionCoordinatorTests` capture, cancellation, permission, and binding tests |
| Typed doorway | `ContentView.sendDraftIfPossible` → `VoiceSessionCoordinator.sendDraft` → `ConversationStore.sendDraft` | `testTypedDraftSendsSlashCommandAndPlaysWAVResponse`; transport send tests |
| Honest phase and response delivery | `VoiceState`, `ConversationStore.apply`, `RecentTranscriptRail`, and `AppleAudioOutput` | `VoiceSessionCoordinatorTests`, `HermesRelayIOSTests`, and prior IOS-26/IOS-16 device evidence |
| Intentional Local History | `JSONConversationPersistence`, one file per Profile, `TranscriptHistoryView`, and app startup/profile-switch loading | `ConversationPersistenceTests`, `ConversationStoreReconnectTests`, and `RelayConfigurationTests` |
| Recovery without replay | `ConversationStore` reconnect ladder, `unconfirmedTurnText`, and explicit resend action | `ConversationStoreReconnectTests`, `RecoveryTests`, `ConversationStoreTransportTests` |
| Permission/auth/profile failure closes capture | `verifiedTurnBinding`, `VoiceFailure`, `AppleSpeechInput`, and Settings recovery presentation | `VoiceSessionCoordinatorTests`, `SpeechInputTests`, and `HermesRelayIOSTests` |

## Tasks & acceptance

- [x] Audit the profile/session boundary and active Profile presentation before capture.
- [x] Audit typed and tap-to-speak submission against the same verified iOS session.
- [x] Audit normalized phase, streamed/completed text, response audio, and completion ordering.
- [x] Audit per-profile Local History and confirm persisted state contains no raw audio.
- [x] Audit transport recovery and explicit-only resend behavior.
- [x] Audit permission, authorization, and missing-profile failure paths.
- [x] Run the final iOS simulator test, macOS build, manual smoke, and privacy/diff review; record results below.

</frozen-after-approval>

## Implementation notes

This slice is an audit-and-closure slice. The existing implementation already
owns the required behavior; no production code change is planned unless the
final verification exposes a gap. The local artifact is the iOS delivery
record for upstream Epic 5 Story 5.1 / `5-I-1`, not a replacement for the
canonical product story or the cross-repository surface matrix.

## Verification

- `xcodebuild test -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=iOS Simulator,id=032066B0-9B2C-4EC7-96A0-BCD9F46D47C2' -parallel-testing-enabled NO` — 313 tests passed, 0 failures, 2026-09-11.
- `xcodebuild build -project HermesRelayIOS.xcodeproj -scheme HermesRelayIOS -destination 'platform=macOS'` — `BUILD SUCCEEDED`, 2026-09-11.
- Manual smoke: the existing `docs/plans/2026-09-09-epic-1-ios-device-validation-plan.md` records the signed iOS conversation/profile/session walkthrough; the current IOS-26 and IOS-16 real-device validation passes were confirmed complete before this slice began.
- Privacy/diff review: no production code changed; the artifact contains no prompts, responses, tokens, raw frames, PCM, microphone audio, or device-specific credentials; `git diff --check` is clean.

The iOS Client therefore closes `5-I-1` as a local delivery artifact and
verification slice. Hermes protocol ownership remains in the session client,
and Local History remains isolated to the selected iOS Profile.
