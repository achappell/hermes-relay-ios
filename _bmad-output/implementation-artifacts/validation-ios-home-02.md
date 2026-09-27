---
story: IOS-HOME-02
slice: 1 — pair and connect through a client claim
spec: spec-ios-home-02-pair-and-connect.md
home_contract: hermes-relay-home 7fb5e2a (HOME-NW-17)
status: slice-1-merged-live-partial
updated: 2026-09-26
---

# IOS-HOME-02 validation record

This record keeps four gates separate. A gate is complete only when its evidence is recorded here. Session management and Profile-owner administration remain open IOS-HOME-02 scope (`deferred-work.md`); this record does not close the story.

| Gate | Status | Evidence |
| --- | --- | --- |
| Local (deterministic) | Complete for slice 1 | Xcode 26.6 suite, macOS build, and built Info.plist checks below |
| Merge | Complete for slice 1 | PR #95 (`33d0852`), CI green; follow-ups #96–#99 |
| iOS live | Partial | Connect, typed and voice turns, and reconnect observed on 2026-09-26; pairing flows, stop, Disconnect and renewal not yet recorded |
| macOS live | Not run | — |

## Local gate

### Xcode (2026-09-26)

Run on Xcode 26.6 against the iPhone 17 Pro Max simulator (iOS 26) and macOS, on the tree merged as `93fb082`:

- Full iOS Simulator suite: 498 tests, 0 failures. This includes all 44 `HomeClientPairingTests`, `HomeConfigurationMigrationTests`, and `ConversationStoreReconnectTests`, and compiles the SwiftUI and AVFoundation files the Linux stand-in could not (`HomePairingView.swift`, `HomePairingScannerView.swift`, `ContentView.swift`, `RelayConfigurationView.swift`, `HermesRelayApp.swift`).
- macOS build: succeeded.
- Built Info.plist, Debug and Release simulator products: both contain the `hermes-home` URL scheme and `NSCameraUsageDescription` ("Hermes uses the camera only to scan the Home pairing QR code."). Debug reads `Development-Info.plist`; Release merges the generated Info.plist with `Release-Info.plist`, with the camera string from `INFOPLIST_KEY_NSCameraUsageDescription`.

### Earlier stand-in (2026-09-24)

Before Xcode was available, the Apple-agnostic sources and tests were compiled with Swift 6.2 on Linux in a scratch SwiftPM package: 44 `HomeClientPairingTests`, 11 `HomeConfigurationMigrationTests` and 14 `ConversationStoreReconnectTests` passed. Ten `HomeBridgeSessionClientTests` failures there came from the Linux `CFGetTypeID` stub, not the change; the Xcode run above supersedes that stand-in.

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
| Reconnect after refusal | `testRefusedOpenLetsAFreshClaimOpenOnItsOwnSocket` (#99) |
| No secrets persisted | `testNoSecretHandleOrProfileIDReachesAnyPersistedFile` |
| Legacy unchanged | `testOperatorHandleProfilesBehaveExactlyAsBefore`, plus the unchanged migration and reconnect suites |
| Removal | `testRemovingTheLastPairedProfileRemovesTheCredential` |

## Merge gate

Slice 1 merged on 2026-09-24 as PR #95 (`33d0852`); its checks passed (Build and test, CodeQL, BMAD issue-tracking validation). Follow-ups found in live use have since merged:

- #96 — release finished Home turns on every playback exit; profile Delete menu.
- #97 — publish the pairing finished phase after the activation announcement.
- #98 — instrument the Home prompt delivery boundary.
- #99 — keep the composer usable with the keyboard up, and stop `conversation_mismatch` after backgrounding, both within Home's reconnect grace and after it.

## iOS live gate

Home HOME-NW-17 is deployed on CaticornQueen. Observed on 2026-09-26 on a physical iPhone 17 Pro Max running a Debug build, paired to the `amanda` Profile through a client claim (Home `conversation_claims`, `claim_kind: client`):

| Check | Result | Evidence |
| --- | --- | --- |
| Connected state | Pass | App showed `Home bridge · Ready` and `Route · Approved route reachable` |
| Typed turn | Pass | Home diagnostics timeline recorded turn accepted, audio started and completed; the reply played |
| Voice turn | Pass | Same timeline for spoken turns; phone audio logs recorded the stream and completed playback |
| Reconnect within grace (~30 s in background) | Pass after #99 | No `conversation_mismatch`; conversation continued |
| Reconnect after grace (3+ min in background) | Pass after #99 | Before #99 the fresh claim was never opened (`first_open_expired`); after #99 it opened |

Not yet recorded here: pairing from a link, from the QR scanner and from a typed code; camera-denied fallback; confirmation-code match on the Home page; stop; Disconnect; and renewal (or its deferral).

Related live finding (Home, not this story): spoken replies stuttered at about 0.63× real time because Home recorded a diagnostic per PCM frame; fixed and deployed in hermes-relay-home PR #62.

## macOS live gate

Not run. Record separately: pairing from a pasted link and from a typed code, a typed turn, a voice turn, stop, reconnect within the grace period, and Disconnect.

## Slice 2 — session management

Spec: [spec-ios-home-02-sessions.md](spec-ios-home-02-sessions.md). Gates are kept separate from slice 1.

| Gate | Status | Evidence |
| --- | --- | --- |
| Local (deterministic) | Complete | Below |
| Merge | Not started | — |
| iOS live | Not run | — |
| macOS live | Not run | — |

### Local gate (2026-09-26, Xcode 26.6)

- Full iOS Simulator suite: 517 tests, 0 failures, on the branch rebased onto `main` at `96fef32` (after #103 and #104), including 12 new `HomeClientPairingTests` for this slice (56 in that class).
- macOS build: succeeded.

| Scenario | Deterministic evidence |
| --- | --- |
| Claim names the session; resumed/new decoded; refs redacted in descriptions | `testClaimBodiesNameTheChosenSessionAndDecodeWhatHomeBound` |
| A resume bound to another session is rejected | `testAResumeGrantBoundToAnotherSessionIsRejected` |
| List and claim-session lookup bodies, auth and decoding | `testSessionListAndClaimLookupMatchTheHomeContract`, `testSessionRowsRejectUnknownFieldsAndImpossibleValues` |
| Connect continues the most recent session, no divider | `testConnectContinuesTheMostRecentSessionWithoutADivider` |
| New session closes the claim and adds a divider | `testNewSessionClosesTheCurrentClaimAndAddsADivider` |
| Resume adds "Resumed: <title>", resends nothing, no ref on disk | `testResumingFromTheListAddsATitledDividerAndNeverResends` |
| Session in use elsewhere is refused without closing | `testASessionInUseElsewhereIsNotSwitchedTo` |
| Refused resume falls back to the latest session once | `testARefusedResumeContinuesTheLatestSessionOnceAndSaysSo` |
| Switching waits for the current turn | `testSwitchingWaitsForTheCurrentTurn` |
| Rename via Hermes `title` only when advertised | `testRenameUsesHermesTitleCommandOnlyWhenAdvertised` |
| A new session's reference is learned after its first turn | `testLoadingSessionsLearnsANewSessionsReferenceAfterItsFirstTurn` |

### Live checks to record (iOS and macOS separately)

Connect lands in the most recent session; the sheet lists sessions started on another client (TUI or a Room device); resume one; New conversation; rename (if Hermes advertises `title`); `session_busy` against a session held by another claim; background beyond the grace returns to the same session.

## Slice 3 — Profile-owner administration

Spec: [spec-ios-home-02-owner-administration.md](spec-ios-home-02-owner-administration.md). Implemented on branch `claude/ios-grant-approval-e7uc0p` against the Home `main` `profile-grants` routes.

### Local gate (2026-09-27): open

The implementation container has no Swift toolchain. Its network policy also denied `download.swift.org`, so no Linux stand-in could be installed. Nothing in this slice has been compiled or run. Before review, record:

- Focused `HomeClientPairingTests` (the slice-3 tests below), the full iOS Simulator suite, and the macOS build on Xcode 26.6.

| Matrix row | Test |
| --- | --- |
| Routes, methods, `Device` authorization, `{"schema": 1}` body, holder decoding, redacted descriptions | `testProfileGrantRoutesMatchTheHomeContract` |
| Decision for another grant, unknown holder field, `401` surfaced as a denial | `testProfileGrantResponsesOutsideTheContractAreRejected` |
| Approve a pending grant; holders grouped by Profile | `testOwnerApprovesAPendingGrantAndSeesItAmongTheHolders` |
| `401` on a decision with a readable pending list: not allowed, credential kept | `testARefusedDecisionKeepsAUsableCredential` |
| `401` on a decision and on the list: Pair again, pairing marked unusable | `testARefusedDecisionWithARefusedCredentialMeansPairAgain` |
| `404 not_found`: expired or already decided | `testAnExpiredOrDecidedRequestSaysSo` |
| Unreachable Home leaves the pairing usable | `testOwnerListsReportAnUnreachableHomeWithoutMarkingThePairing` |
| Screen model: outcome message, refresh, busy state cleared | `testOwnerModelShowsTheOutcomeAndRefreshes` |
| Unpair removes profiles, transcripts, record and Keychain credential, keeps unrelated profiles, and makes no Home call | `testUnpairForgetsTheHomeLocallyWithoutCallingHome` |

### Live checks to record (iOS and macOS separately)

- Approve a second client's `pending_owner` grant from the phone; the requester's Refresh gains the profile.
- Reject a request.
- Revoke a holder of an owned Profile.
- Attempt to revoke another holder of a shared Profile and see "Home did not allow this change".
- Holders show "This device" and the bootstrap device.
- Unpair, then confirm that the Home page still lists the device until it is removed there.

## Evidence safety

This record contains no credentials, pairing codes, handles, prompts, response text, raw protocol frames, PCM data, or microphone captures.

## Known limits of this slice

- Leaving the foreground closes the socket but not the claim. Home closes it after its reconnect grace (default 120 s). Frequent background and foreground cycles beyond the grace each create a claim, which counts toward `claim_limit` until Home closes the old ones.
- A paired claim's handle is never written to disk. After a relaunch, an uncertain turn therefore reports lost continuity and offers a new conversation; it cannot be reconnected.
- If a Keychain write succeeds but its reference metadata write does not during renewal, the next connect asks the user to pair again.
