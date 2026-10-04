# IOS-DIAG-03 validation — 2026-10-04

Status: review. Local implementation verified on macOS; iOS Simulator tests, manual smoke and device acceptance with a HOME-NW-06 Home remain pending.

## Automated evidence

Toolchain: installed Xcode 27.2 beta 2 (`DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer`); the Xcode 26.6 baseline is not installed.

- Focused XCTest (macOS): `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO "-only-testing:Hermes RelayTests/AutomaticDiagnosticsTests" "-only-testing:Hermes RelayTests/DiagnosticsJournalTests" "-only-testing:Hermes RelayTests/HomeBridgeSessionClientTests" test` — 82 passed (13 automatic diagnostics, 6 journal, 63 HomeBridge session).
- Full suite (macOS): same command without `-only-testing` — 573 passed.
- iOS Simulator: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing` — app and tests build. Tests not run: this machine has no iOS Simulator runtime installed (`xcrun simctl runtime list` reports 0 images).
- macOS build: `xcodebuild -project "Hermes Relay.xcodeproj" -scheme HermesRelay -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build` — succeeded.
- New coverage: decoder strictness (ten malformed ready envelopes, malformed submit echo), upgrade header exactly once, capability-gated negotiation (five partial/malformed capability sets), reconnect to legacy and to a new opted-in socket, unique request IDs, `request_started` recorded before the frame write, correlated accepted/rejected responses, legacy frame unchanged, schema-2 report shape, legacy schema-1 report, packing bounds/determinism/drops/referenced origins, origin null rules.
- Diff reviewed: no credentials, recordings, generated build files or unrelated edits.

## Remaining acceptance

- Run the iOS Simulator test command on an installed iPhone runtime.
- Manual smoke: Settings disclosure copy shows the new identifier sentence; reporting toggle behavior is unchanged.
- Device acceptance per the Home hand-off §3 against a HOME-NW-06 Home: ready carries `conn-…`, submit carries `req-…`, response returns `corr-…`; induce a failure, close the carrying socket before checking `/pair` (associations become `linked` only at socket finalize, D1); a duplicate token shows `ambiguous`; a legacy Home shows no decode failures, header errors or reconnect mismatches.
