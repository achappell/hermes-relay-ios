---
story: IOS-HOME-02
slice: 1 — pair and connect through a client claim
spec: spec-ios-home-02-pair-and-connect.md
home_contract: hermes-relay-home 7fb5e2a (HOME-NW-17)
status: local-evidence-partial
updated: 2026-09-24
---

# IOS-HOME-02 validation record

This record keeps four gates separate. A gate is complete only when its
evidence is recorded here. Session management and Profile-owner
administration remain open IOS-HOME-02 scope (`deferred-work.md`); this record
does not close the story.

| Gate | Status | Evidence |
| --- | --- | --- |
| Local (deterministic) | Partial: Linux type-check and tests pass; Xcode gates not yet run | Below |
| Merge | Not started | No pull request has been opened or merged for this slice |
| iOS live | Deferred | HOME-NW-17 is not deployed; nothing was run against a live Home |
| macOS live | Deferred | HOME-NW-17 is not deployed; nothing was run against a live Home |

## Local gate

### What ran

The implementation container has no Xcode. As a stand-in, the Apple-agnostic
sources and tests were compiled with Swift 6.2 (`swift:6.2-noble`, Swift 6
language mode) in a scratch SwiftPM package. Security, Network, SwiftUI and
AVFoundation files were excluded or stubbed; `HomePairingView.swift` was
compiled up to its SwiftUI view.

- New `HomeClientPairingTests`: 44 tests, 0 failures (after the review follow-ups).
- `HomeConfigurationMigrationTests` (11, including the new credential-reference
  account test) and `ConversationStoreReconnectTests` (14): 0 failures with the
  change applied.
- Existing `HomeBridgeSessionClientTests`: 10 failures on Linux both at the
  baseline commit and with the change applied. They come from the Linux stub
  for `CFGetTypeID`/`CFBooleanGetTypeID` (JSON boolean detection), not from
  this change.
- `git diff --check`: clean.

### Still required before this gate is complete

These have not been run and must pass on Xcode 26.6 (CI `macos-26`):

1. `xcodebuild test -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HermesRelayTests/HomeClientPairingTests`
2. The full iOS Simulator test run and the macOS build from `.github/workflows/ci.yml`.
3. A compile of the SwiftUI and AVFoundation files, which Linux could not check:
   `HomePairingView.swift`, `HomePairingScannerView.swift`, and the edits to
   `ContentView.swift`, `RelayConfigurationView.swift` and `HermesRelayApp.swift`.
4. Info.plist checks: the `hermes-home` URL scheme and `NSCameraUsageDescription`
   are present in both the Debug (`Development-Info.plist`) and Release
   (generated Info.plist merged with `Release-Info.plist`) products.

### I/O matrix coverage

| Scenario | Deterministic evidence |
| --- | --- |
| Link opened | `testPairingLinkPrefillsHomeAndCode`, `testMalformedOrNonHTTPSLinksAreRejectedWithSpecificMessages`, `testMalformedLinkSubmitsNothing` |
| Typed code | `testTypedCodeAcceptsAnyCaseWithOrWithoutTheDash` |
| Enrollment body | `testEnrollmentConsumeRenewAndClaimBodiesMatchTheHomeContract`, `testEndpointIDIsStablePerInstallPerHome` |
| Waiting | `testWaitingPollsAboutEveryTwoSecondsUntilApproval`, `testWaitingEndsAtExpiresAt` |
| Rejected / expired | `testRejectedAndExpiredAreTerminalAndStoreNothing` |
| Approved | `testApprovalStoresOneCredentialPerHomeAndOneProfilePerActiveGrant`, `testHomeIsSelectedOnlyAfterTheFirstLiveReady`, `testKeychainFailureSavesNoPairing`, `testRefreshAddsAProfileWhenAGrantBecomesActive` |
| Connect | `testConnectReadsRevisionThenClaimsANewSession`, `testStaleConfigurationRefreshesOnceAndRetries`, `testPairedConnectCompletesATypedTurnWithoutAPastedCredentialOrHandle`, `testAHeldClaimIsReopenedAfterForegroundAndReplacedOnceItHasEnded` |
| Renewal before claim | `testPastItsRenewalPointConnectRenewsBeforeClaimingAndStaysPaired`, `testInterruptedRenewalFinishesFromKeychainWithoutAnotherRequest` |
| Claim denied | `testClaimDenialsArePlainAndSpecificWithoutRetry`, `testClaimDenialLeavesASpecificDisconnectedState`, `testTypedDenialsAndUnknownFieldsAreRejected` |
| Credential invalid | `testUnauthorizedMarksTheCredentialUnusableAndAsksToPairAgain`, `testExpiredCredentialAsksToPairAgainWithoutSendingIt` |
| Route pin | `testApprovalStores…` (pin on first `ready`), `testLaterClaimsRequireThePinnedRoute`, `testAnUnpinnedClaimFailsClosedWithoutARecorder` |
| Close / divider / no replay | `testExplicitDisconnectAndProfileSwitchCloseThePairedConversation`, `testANewSessionOnAProfileWithHistoryAddsALocalDivider`, `testAnUncertainTurnIsNeverReplayedAfterContinuityIsLost` |
| No secrets persisted | `testNoSecretHandleOrProfileIDReachesAnyPersistedFile` |
| Legacy unchanged | `testOperatorHandleProfilesBehaveExactlyAsBefore`, plus the unchanged migration and reconnect suites |
| Removal | `testRemovingTheLastPairedProfileRemovesTheCredential` |

## Merge gate

Not started.

## iOS live gate

Deferred until HOME-NW-17 is deployed. When it runs, record separately:
pairing from a link, from the QR scanner and from a typed code; camera-denied
fallback; confirmation-code match on the Home page; a typed turn; a voice
turn; stop; reconnect within the grace period; Disconnect; and renewal (or
its deferral).

## macOS live gate

Deferred until HOME-NW-17 is deployed. When it runs, record separately:
pairing from a pasted link and from a typed code, a typed turn, a voice turn,
stop, reconnect within the grace period, and Disconnect.

## Known limits of this slice

- Leaving the foreground closes the socket but not the claim. Home closes it
  after its reconnect grace (default 120 s). Frequent background and
  foreground cycles beyond the grace each create a claim, which counts toward
  `claim_limit` until Home closes the old ones.
- A paired claim's handle is never written to disk. After a relaunch, an
  uncertain turn therefore reports lost continuity and offers a new
  conversation; it cannot be reconnected.
- If a Keychain write succeeds but its reference metadata write does not
  during renewal, the next connect asks the user to pair again.
