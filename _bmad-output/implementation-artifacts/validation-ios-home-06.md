---
story: IOS-HOME-06
spec: spec-ios-home-06-backgrounded-transport-disconnected.md
home_contract: hermes-relay-home 082e593 (HOME-NW-18)
status: local-verified-live-gates-open
updated: 2026-10-04
---

# IOS-HOME-06 validation record

Defect: on the pilot iPhone (app 0.6.0 build 1; reports carry no SHA), the app was backgrounded for about two minutes. Home parked claim `2pE5lS` as `client_disconnected` and closed it at 18:46:57 UTC. In the foreground the app still showed Connected. Tap-to-talk failed and left the app Disconnected. After the socket dropped, Home recorded no open, no fresh claim and no submission. The evidence was read-only.

| Gate | Status | Evidence |
| --- | --- | --- |
| Regression tests fail before the fix | Confirmed | All 3 new tests failed on 8c3f163 (7 assertion failures) |
| macOS XCTest | Passed | 570 tests, 0 failures (`/tmp/ios-stale-dd/Logs/Test/Test-HermesRelay-2026.10.04_14-20-22--0500.xcresult`) |
| Generic iOS Simulator build | Passed (compile only) | `xcrun simctl list runtimes` lists none, so no simulator tests ran |
| Physical iOS / live Home | Not run | No household traffic |
| Merge / release | Not performed | Local commit only |

## Regression tests

- `AppleLifecycleTests/testBackgroundLeavesTheStoreDisconnectedAndForegroundReopensTheClaim`. Before the fix: after the background the state was `connected` and the HUD doorway said Connected.
- `AppleLifecycleTests/testActiveWithAStaleConnectedStateButNoLiveTransportReconnects`. Before the fix: `.active` short-circuited, with no client and 1 transport instead of 2.
- `HomeClientPairingTests/testASubmitOnADeadTransportReconnectsWithoutResending`. Before the fix: the app never reconnected within 2 s and the held claim was not reopened. After the fix: the held claim is reopened, no fresh claim is requested, the prompt is submitted once, and the unconfirmed text is still offered.
- Case (c), `verifiedTurnBinding` nil without a live client and binding, is asserted inside the first two tests. Those assertions already held on 8c3f163.

Commands (`DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer`):

```sh
xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-stale-dd test
xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-stale-dd-sim build
```

## Open live gate

Background the app on the iPhone for more than 120 seconds, then bring it back. The HUD must not show Connected before Ready. Tap-to-talk must either work or reconnect without a manual Connect.

## Follow-up

Automatic diagnostics stopped uploading after 18:41:23 while the app was active, and reports carry no build SHA. These are not part of this story.
