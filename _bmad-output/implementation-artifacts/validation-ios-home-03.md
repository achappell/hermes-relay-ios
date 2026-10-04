---
story: IOS-HOME-03
spec: spec-ios-home-03-claim-lifecycle.md
home_contract: hermes-relay-home 082e593 (HOME-NW-18)
status: local-verified-live-gates-open
updated: 2026-10-04
---

# IOS-HOME-03 validation record

Final post-review macOS XCTest (which built the app and test targets) and generic iOS Simulator SDK compile succeeded. No iOS Simulator runtime/device was available, and no physical-device pilot or live household operation was performed.

| Gate | Status | Evidence |
| --- | --- | --- |
| macOS XCTest + app/test build | Passed post-review | 562 tests, 0 failures; final result bundle is recorded below |
| Generic iOS Simulator build | Passed post-review (compile-only) | SDK 27.2, arm64 and x86_64; no runtime/device was available for test execution |
| macOS UI smoke | Complete with synthetic fixtures | Claim controls, prior Settings layout, and paired-profile Settings smoke exercised without Home traffic or user app-support writes |
| Physical iOS / live Home | Not run | No device/pilot/household requests or prompts |
| Merge / release | Not performed | No commits, pushes, Home repository edits, deployment, or release |

## Local build and test gate

Xcode 27.2 Beta 2 was selected per command with `DEVELOPER_DIR`; all builds used `CODE_SIGNING_ALLOWED=NO` and an isolated derived-data directory.

### Focused delayed-provider regressions

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-final test '-only-testing:Hermes RelayTests/HomeClientPairingTests/testLateNilOpenClaimsResponsePreservesTheNewProfileList' '-only-testing:Hermes RelayTests/HomeClientPairingTests/testLateNilCloseResponsePreservesTheNewProfileList' '-only-testing:Hermes RelayTests/HomeClientPairingTests/testLateTitleSupportResponseCannotOverwriteTheCurrentListTitles'
```

Result: 3 tests passed, 0 failures. Result bundle: `/tmp/ios-home03-derived-final/Logs/Test/Test-HermesRelay-2026.10.03_23-26-48--0500.xcresult`.

### Review follow-up: ambiguous claim expiry

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-final-review test '-only-testing:Hermes RelayTests/HomeClientPairingTests/testLostClaimResponseIsNotAutomaticallyRetried'
```

Result: 1 test passed, 0 failures. The test verifies an immediate second connect is blocked after an ambiguous response, then permits a new claim after Home's 90-second first-open expiry window. Result bundle: `/tmp/ios-home03-derived-final-review/Logs/Test/Test-HermesRelay-2026.10.03_23-57-38--0500.xcresult`.


### Final post-review macOS XCTest suite

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-postreview-final test
```

Result: 562 tests passed, 0 failures. The command built the app and test targets. Result bundle: `/tmp/ios-home03-derived-postreview-final/Logs/Test/Test-HermesRelay-2026.10.04_00-03-27--0500.xcresult`.

### Full macOS XCTest suite (pre-review follow-up)

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-final test
```

Result: 562 tests passed, 0 failures. Result bundle: `/tmp/ios-home03-derived-final/Logs/Test/Test-HermesRelay-2026.10.03_23-30-08--0500.xcresult`.

### macOS app build (pre-review follow-up)

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-final build
```

Result: `BUILD SUCCEEDED`.

### Generic iOS Simulator compile (pre-review follow-up)

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-final-ios build
```

Result: `BUILD SUCCEEDED` for the iOS Simulator 27.2 SDK (arm64 and x86_64). This is compile-only; no simulator runtime/device was installed, so simulator test execution was not attempted. The asset catalog emitted existing missing-iOS-app-icon-size warnings; the build completed successfully.

The first focused-test attempt failed because the test changed Home mode without selecting the target profile. The test setup now explicitly selects the profile; the rerun above passed. This was test-fixture setup, not a product failure.

### Final post-review generic iOS Simulator compile

```sh
DEVELOPER_DIR="/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer" xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath /tmp/ios-home03-derived-postreview-final-ios build
```

Result: `BUILD SUCCEEDED` for the iOS Simulator 27.2 SDK (arm64 and x86_64). This is compile-only; no simulator runtime/device was installed, so simulator tests were not run. The build emitted existing missing-iOS-app-icon-size warnings and an AppIntents metadata-skip warning.

## Async lifecycle regressions

A delayed `HomeConversationClaimProvider` uses continuations rather than timing sleeps to hold responses at the real actor suspension points. Consumer-visible assertions cover:

- A late `nil` list response after loading a different profile leaves the new profile's claim list and management state intact.
- A late `nil` close response after loading a different profile leaves the new profile's list and management state intact.
- A title-support result released after a newer list/title load cannot replace that current list's title dictionary.

The corresponding cases are `testLateNilOpenClaimsResponsePreservesTheNewProfileList`, `testLateNilCloseResponsePreservesTheNewProfileList`, and `testLateTitleSupportResponseCannotOverwriteTheCurrentListTitles`.

## macOS UI regressions and evidence

### Open-on-Home claim controls

An actual macOS Debug app smoke using `-HomeBridgeFake` and an isolated `CFFIXED_USER_HOME` exercised the synthetic current/other claim rows. **Close** and **Close all others** removed only the synthetic non-current claim. Evidence:

- `/tmp/ios-home03-ui-smoke-final-manager-20261003.png`
- `/tmp/ios-home03-ui-smoke-final-close-20261003.png`
- `/tmp/ios-home03-ui-smoke-single-close-20261003.png`

No Home/deployment request, real prompt, or user app-support write was used.

### Settings layout

The reported defect was captured in `/Users/amandachappell/Library/Application Support/CleanShot/media/media_sUeECtrubQ/CleanShot 2026-10-03 at 11.03.13 PM@2x.png`: macOS Settings labels/help text were clipped at the left, and the sheet exceeded the host window. The fix presents Settings in a grouped, scrollable macOS `Form` with a flexible bounded sheet size.

The independent macOS UI smoke exercised a normal 708×762 host and a compact 620×480 host (compact sheet 480×408). Labels and wrapped help stayed readable; Troubleshooting/share remained reachable; Done stayed fixed. Clicking Done after scrolling dismissed the sheet, with Accessibility reporting zero sheets. Evidence:

- `/tmp/ios-settings-layout-normal-top.png`
- `/tmp/ios-settings-layout-normal-bottom.png`
- `/tmp/ios-settings-layout-small-top.png`
- `/tmp/ios-settings-layout-small-bottom.png`
- `/tmp/ios-settings-layout-small-fields.png`

These screenshots were made with synthetic/local state. No live household or Home service request was submitted.

### Paired-profile Settings smoke (2026-10-04)

An isolated macOS Debug app run with `-HomeBridgeFake` and a fresh `CFFIXED_USER_HOME` exercised synthetic Saved Profiles, a paired Home hostname ending in `.example.invalid`, and an empty automatic-report fixture. The saved relay profile remained unselected; the Home credential flag was synthetic and no credential material or relay token was present.

The normal host was 708×762 with a 480×625 Settings sheet; the compact host was 620×480 with a 480×408 sheet. At both sizes, the saved profile and paired Home rows were readable, and the long Home hostname and explanatory text wrapped without clipping. At compact size the Home row, `Refresh Profiles`, and help text were inspected across the top and paired-Home crops; the diagnostics label/help wrapped in the scrolled footer, with Troubleshooting/share controls and the fixed `Done` button reachable. Clicking `Done` after scrolling dismissed the sheet; Accessibility reported zero sheets.

`Refresh Profiles`, the diagnostics toggle, Pair, Share diagnostics, and Home administration actions were not activated. The diagnostics toggle remained off, the reports fixture was empty, and no network/service request could be triggered. No Home credential or write to the user's normal app-support directory was used; no product source change was needed.

Evidence (cropped to the app window and read back):

- `/tmp/ios-settings-paired-fixture-normal-top-20261004.png`
- `/tmp/ios-settings-paired-fixture-normal-bottom-20261004.png`
- `/tmp/ios-settings-paired-fixture-small-top-20261004.png`
- `/tmp/ios-settings-paired-fixture-small-home-20261004.png`
- `/tmp/ios-settings-paired-fixture-small-bottom-20261004.png`

## Limits and safety

- Simulator execution is unavailable; the generic iOS build establishes compile coverage only.
- No physical device, pilot, real Home claim, live household prompt, or deployment was used.
- No Home-repository file was changed. Secrets, claim refs, session refs, prompts, and replies were not added to logs or persisted fixture state.
- Story and sprint status remain `in-progress` until the unavailable simulator/device and live-pilot gates are separately completed.
