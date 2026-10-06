# IOS-DIAG-03 validation — 2026-10-04

Status: review. Local implementation verified on macOS and on the iOS 27.2 Simulator, and the Settings section was rendered on the simulator but not tapped. Device acceptance with a HOME-NW-06 Home remains pending.

## Automated evidence

Toolchain: installed Xcode 27.2 beta 2 (`DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer`); the Xcode 26.6 baseline is not installed.

- Focused XCTest (macOS): `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO "-only-testing:Hermes RelayTests/AutomaticDiagnosticsTests" "-only-testing:Hermes RelayTests/DiagnosticsJournalTests" "-only-testing:Hermes RelayTests/HomeBridgeSessionClientTests" test` — 83 passed (13 automatic diagnostics, 6 journal, 64 HomeBridge session).
- Full suite (macOS): same command without `-only-testing` — 574 passed.
- iOS Simulator build: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing` — app and tests build.
- iOS Simulator runtime installed with `xcodebuild -downloadPlatform iOS`: iOS 27.2 (24B5089g), arm64. Device: iPhone 18 Pro (EB0B6151-6DAA-4935-BF0A-3881622F97F1).
- Focused XCTest (iOS Simulator): `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO "-only-testing:Hermes RelayTests/AutomaticDiagnosticsTests" "-only-testing:Hermes RelayTests/DiagnosticsJournalTests" "-only-testing:Hermes RelayTests/HomeBridgeSessionClientTests" test` — 83 passed (13/6/64). No iOS-only failures.
- Full suite (iOS Simulator): previous baseline run, before this test — 574 passed, 0 failed, 0 skipped (from the xcresult summary); not rerun for this change.
- macOS build: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build` — succeeded.
- New coverage: decoder strictness (ten malformed ready envelopes, malformed submit echo), upgrade header exactly once, capability-gated negotiation (five partial/malformed capability sets), reconnect to legacy and to a new opted-in socket, unique request IDs, `request_started` recorded before the frame write, correlated accepted/rejected responses, legacy frame unchanged, schema-2 report shape, legacy schema-1 report, packing bounds/determinism/drops/referenced origins, origin null rules.
- Pending-submit loss: `testSocketLossDuringNegotiatedPromptSubmitRecordsUncertainCorrelation` passed on macOS and the iPhone 18 Pro iOS 27.2 Simulator; it verifies the uncertain transport result, loss/failure diagnostics with request correlation, and the packed schema-2 report. The deterministic report clock advances past the one-minute snapshot throttle to include both events.
- Diff reviewed: no credentials, recordings, generated build files or unrelated edits.

## Settings smoke — rendered, not tapped (iPhone 18 Pro / iOS 27.2 Simulator)

This Xcode 27.2 beta has no Simulator.app, so the app could not be navigated by hand. App install and launch with `simctl` worked; the app reached its main screen.

In its place, a throwaway hosted XCTest ran once and was then deleted without being committed. It ran `AutomaticDiagnosticsSettings` in a `Form` inside a `UIHostingController` window in the test host app, so the view's `.task` ran. It used the existing `AutomaticDiagnosticsTests` fixture, which provides one synthetic paired Home (`home.example`) and a temporary reporter store.

Observed in the PNG snapshots:
- Paired, off: the toggle "Send connection reports to home.example" renders off, and the footer shows the new sentence, "...with random connection and request identifiers so Home can match them to its own records. No messages, audio, or passwords..."
- Driving the single `UISwitch` in the hierarchy (`setOn` + `.valueChanged`) ran the view's binding. The stored setting became enabled (`reporter.settings().first?.enabled == true`), and the snapshot shows the toggle on with "No reports waiting to send."
- Flipping back stored disabled again. That snapshot is byte-identical to the first one.

`ImageRenderer` cannot draw the UIKit-backed `Form`: it produced the "unsupported view" placeholder. Because it also never runs `.task`, the live hosted snapshot was used. The macOS render was skipped.

## Covered by test

- Induce a failure: `testSocketLossDuringNegotiatedPromptSubmitRecordsUncertainCorrelation` closes the diagnostics-negotiated fake socket while `prompt.submit` is pending, then checks the uncertain transport outcome and schema-2 `connection_lost`/`request_failed` events, including `pending_state: unknown`.

## Legacy and device evidence (2026-10-04)

- `testLegacyHomeSubmitFrameIsUnchangedAndCarriesNoDiagnostics` (`HomeBridgeSessionClientTests`) and `testLegacyHomeReportStaysSchemaOneWithoutSchemaTwoEvents` (`AutomaticDiagnosticsTests`) provide local-fixture legacy wire/report coverage (a fake socket for the submit frame and a reporter fixture for schema 1). They are not live runs against an old Home device.
- Home [PR #73](https://github.com/achappell/hermes-relay-home/pull/73) includes the loopback test `test_duplicate_diagnostic_request_token_is_ambiguous_without_suppressing_prompts`, which verifies the repeated token becomes `ambiguous` without suppressing either prompt. This is Home server loopback evidence, not a phone/Standard or old-Home device run.
- User-observed device report (2026-10-04): schema 2 contained 7 `request_started`/`request_completed` events, 1 `client_response_received`, and 1 `client_request_resolved`; the Home server store showed `linked=1` after close. The observation included no raw IDs, and none are reproduced here.
- `/pair` presentation and exact ID-to-log comparison were not verified.

## Remaining acceptance

- Device acceptance per the Home hand-off §3 against a HOME-NW-06 Home: ready carries `conn-…`, submit carries `req-…`, response returns `corr-…`; close the carrying socket before checking `/pair` (associations become `linked` only at socket finalize, D1); a legacy Home shows no decode failures, header errors or reconnect mismatches.
- Known, accepted limit: real phone/Standard loss timing during a pending submit has not been tested on device.
