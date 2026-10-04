# IOS-DIAG-03 validation — 2026-10-04

Status: review. Local implementation verified on macOS and on the iOS 27.2 Simulator. The Settings smoke step and device acceptance with a HOME-NW-06 Home remain pending.

## Automated evidence

Toolchain: installed Xcode 27.2 beta 2 (`DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer`); the Xcode 26.6 baseline is not installed.

- Focused XCTest (macOS): `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO "-only-testing:Hermes RelayTests/AutomaticDiagnosticsTests" "-only-testing:Hermes RelayTests/DiagnosticsJournalTests" "-only-testing:Hermes RelayTests/HomeBridgeSessionClientTests" test` — 82 passed (13 automatic diagnostics, 6 journal, 63 HomeBridge session).
- Full suite (macOS): same command without `-only-testing` — 573 passed.
- iOS Simulator build: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing` — app and tests build.
- iOS Simulator runtime installed with `xcodebuild -downloadPlatform iOS`: iOS 27.2 (24B5089g), arm64. Device: iPhone 18 Pro (EB0B6151-6DAA-4935-BF0A-3881622F97F1).
- Focused XCTest (iOS Simulator): `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO "-only-testing:Hermes RelayTests/AutomaticDiagnosticsTests" "-only-testing:Hermes RelayTests/DiagnosticsJournalTests" "-only-testing:Hermes RelayTests/HomeBridgeSessionClientTests" test` — 82 passed (13/6/63). No iOS-only failures.
- Full suite (iOS Simulator): same command without `-only-testing` — 574 passed, 0 failed, 0 skipped (from the xcresult summary).
- macOS build: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build` — succeeded.
- New coverage: decoder strictness (ten malformed ready envelopes, malformed submit echo), upgrade header exactly once, capability-gated negotiation (five partial/malformed capability sets), reconnect to legacy and to a new opted-in socket, unique request IDs, `request_started` recorded before the frame write, correlated accepted/rejected responses, legacy frame unchanged, schema-2 report shape, legacy schema-1 report, packing bounds/determinism/drops/referenced origins, origin null rules.
- Diff reviewed: no credentials, recordings, generated build files or unrelated edits.

## Remaining acceptance

- Settings smoke. On iPhone 18 Pro / iOS 27.2, `simctl install` and `simctl launch com.achappell.HermesRelay -HomeBridgeFake` both worked, and the app reached its main screen (Debug Home; Home bridge unavailable, authorization_unavailable). The Settings screen and its toggle could not be reached:
  - This Xcode 27.2 beta install has no Simulator.app, and `simctl` cannot tap, so the headless simulator could not be navigated.
  - On a fresh simulator the reporting toggle only appears once a Home is paired, which needs a synthetic pairing.
  - The disclosure sentence is checked in source only (`AutomaticDiagnosticsSettings.swift` footer).
- Device acceptance per the Home hand-off §3 against a HOME-NW-06 Home: ready carries `conn-…`, submit carries `req-…`, response returns `corr-…`; induce a failure, close the carrying socket before checking `/pair` (associations become `linked` only at socket finalize, D1); a duplicate token shows `ambiguous`; a legacy Home shows no decode failures, header errors or reconnect mismatches.
