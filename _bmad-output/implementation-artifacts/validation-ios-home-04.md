---
story: IOS-HOME-04
spec: spec-ios-home-04-foreground-reconnect.md
home_contract: hermes-relay-home 082e593 (HOME-NW-18)
status: local-verified-live-gates-open
updated: 2026-10-04
---

# IOS-HOME-04 validation record

Defect: on the pilot iPhone (build from main 66477da), after more than two minutes in the background the app stayed "Disconnected · transport_unavailable" and did not reconnect to Home. Home's read-only claim and diagnostics records showed no refusal from Home. The app's held claim was later closed by the client (`client_closed`), and no new claim was requested.

| Gate | Status | Evidence |
| --- | --- | --- |
| Regression tests fail before the fix | Confirmed | All three new tests failed against main 66477da (output below) |
| macOS XCTest + app/test build | Passed | 565 tests, 0 failures |
| Generic iOS Simulator build | Passed (compile only) | `xcrun simctl list runtimes` lists none, so no simulator tests ran |
| Physical iOS / live Home | Not run | No household requests, claim closes, or prompts |
| Merge / release | Not performed | Local commit only; no push or PR |

## Regression tests

- `AppleLifecycleTests/testInterleavedInactiveAndActiveLeaveTheStoreActiveAndReconnect`. Before the fix: the store was left inactive, and the newer active never reopened (1 open instead of 2).
- `HomeClientPairingTests/testForegroundTransportFailureRetriesTheHeldClaimUntilReady`. Before the fix: the store never reached connected, and the held claim was opened only once. Also verifies that Disconnect stops the retries and that no fresh claim is requested.
- `HomeClientPairingTests/testReconnectRefusedAsStaleWithoutRecoveryOpensAFreshClaim`. Before the fix: the state was `failed("stale_conversation")` and no fresh claim was requested.

Before-fix command (main 66477da with only the tests applied):

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-reconnect-dd test '-only-testing:Hermes RelayTests/AppleLifecycleTests' '-only-testing:Hermes RelayTests/HomeClientPairingTests/testForegroundTransportFailureRetriesTheHeldClaimUntilReady' '-only-testing:Hermes RelayTests/HomeClientPairingTests/testReconnectRefusedAsStaleWithoutRecoveryOpensAFreshClaim'
```

Result: 3 failed tests, 7 assertion failures.

## Final gates

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-reconnect-dd test
```

Result: 565 tests passed, 0 failures. Result bundle: `/tmp/ios-reconnect-dd/Logs/Test/Test-HermesRelay-2026.10.04_10-35-30--0500.xcresult`.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-reconnect-dd-sim build
```

Result: BUILD SUCCEEDED. No iOS Simulator runtime is installed.

## Open live gate

Pilot check on the iPhone: background the app for more than 120 seconds, then bring it back. It should reach Ready without a tap, or show a fresh claim if Home ended the old one.
