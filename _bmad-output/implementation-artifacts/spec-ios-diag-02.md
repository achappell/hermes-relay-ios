---
id: IOS-DIAG-02
title: Automatically send opted-in connection reports to Home
status: review
product_epic: 6
---

# IOS-DIAG-02 — Automatic Home connection reports

Amanda explicitly selected this follow-up to IOS-DIAG-01 on 2026-09-28 and required reports to survive quitting/reopening. This authorizes the diagnostics slice ahead of the normal epic order; it does not close migration gates.

## Acceptance

- Off by default, with explicit per-paired-Home consent in Settings. No special child build or silent enablement.
- Only typed connection/request outcomes, allowlisted error codes, timestamps, durations, launch IDs, app/build/OS/model metadata. No raw journal strings, messages, audio, handles, credentials or arbitrary text.
- Queue failure context on disk, retain it across launches, retry while foreground using the existing Device credential and approved paired HTTPS origin. Refuse redirects and require an acknowledgment naming the exact report.
- At most 100 context events and ten queued reports per Home, sixteen Homes, seven-day retention, one new report per minute. One upload at a time, retries at most once per 30-second foreground pass. No recursive reporting of upload failures.
- Disabling reporting cancels the upload and removes unsent local reports. Unpairing/re-pairing or changing the Home binding must not reroute old reports. Uploaded copies expire on Home.
- Show opt-in state, queued count and last successful upload. Keep manual Share diagnostics available.
- Validate persistence/relaunch, offline retry/idempotency, consent, expiry/bounds, identity isolation, cancellation and the Home wire contract; run focused XCTest, simulator tests and macOS build. Record local and deployed acceptance separately.

## Dependency

Home owns the device-authenticated `/api/v1/client-diagnostics` endpoint and signed-in reviewer surface under HOME-NW-06's client-report follow-up. No upstream Hermes change.
