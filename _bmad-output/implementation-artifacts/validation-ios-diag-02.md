# IOS-DIAG-02 validation — 2026-09-28

Status: done (owner acceptance 2026-10-08; see the section at the end). Earlier status was: review. Local implementation verified; deployment and physical-device acceptance remain pending.

## Automated evidence

- Focused XCTest: 65 passing tests on macOS and 65 on iPhone 17 / iOS 26.5 Simulator, using installed Xcode 27. Both invocations build their platform target. Suites: AutomaticDiagnosticsTests (9), DiagnosticsJournalTests (6), HomeBridgeSessionClientTests (50). No live Home required.
- Covers opt-in, disk persistence across reporter instances, offline retry with stable report ID, rapid restart/recovery follow-up after throttling, opt-out cancellation/purge, changed Home/device binding, expiry, bounded context/queue, single-flight upload, closed body fields and exact acknowledgment.
- Source diff and whitespace review passed; no credentials, recordings, generated build artifacts or unrelated local configuration staged.

## Manual smoke

- Simulator launched with fake Home transport and a synthetic non-routable Home pairing; no household credentials used.
- Settings showed reporting off by default. Enabling displayed an empty queue. Terminating and relaunching retained the enabled switch. Disabling persisted an empty state. Manual Share diagnostics remained visible.
- Original simulator pairing/report files restored after smoke. Reopening Simulator resolved an automation focus problem after relaunch; a process sample showed the main thread idle in its run loop.
- Home signed-in report viewer tested separately with a local synthetic fixture: refresh, report expansion, launch marker, recent Home events and sign-out clearing.

## Remaining acceptance

Install the Home endpoint and its documented tailnet route, then install the Apple build on an opted-in device. Reproduce a connection failure, force-quit/reopen, verify upload and recovery context in the signed-in Home page. Confirm real-device protected storage and foreground/background behavior. This local evidence does not claim deployment, TestFlight distribution or child-device enablement. The iOS 26.6 baseline runtime was not installed; simulator validation used 26.5.

## PR #115 base refresh — 2026-09-28

Rebased the diagnostics commit onto updated recovery branch `d0b6689`. Preserved reconnect's current-binding capability handling, the voice interruption setting, and both story tracker entries while retaining diagnostics wrappers. Focused builds/tests passed again: 71 tests on macOS and 71 on iOS Simulator (nine automatic diagnostics, six journal, 56 HomeBridge session tests). Diff/whitespace checks passed. The earlier synthetic manual smoke remains applicable; no new UI behavior was introduced by conflict resolution.

## Owner acceptance - 2026-10-08

Amanda manually tested IOS-DIAG-02 on her own device and accepted it as `done` on 2026-10-08, saying it works well enough to accept.

- No instrumented evidence, steps, or build number were captured by the agent.
- The specific remaining device checks listed in this record were not individually exercised by the agent and remain unverified.
- The earlier evidence and limitations above are unchanged; this section records an owner decision, not a new test run.
