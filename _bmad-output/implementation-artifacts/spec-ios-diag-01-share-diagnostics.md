---
id: IOS-DIAG-01
title: Share content-free connection diagnostics from the app
status: in-progress
---

# IOS-DIAG-01 — Share diagnostics

## Why

A household member's phone runs a Release (TestFlight) build. The Home
connection trace was Debug-only, so a `conversation_mismatch` on that phone
left no record anywhere, and diagnosing it needed a cable, Xcode, and a Debug
install. The person seeing the fault should be able to send the evidence.

## Scope

- Every build keeps a small on-device journal of Home connection events:
  open and reconnect outcomes, failure codes and phases, the name of any local
  check that refused a result, bridge request outcomes, transport loss, and app
  foreground/background changes.
- The journal survives relaunches, is capped, and is excluded from backup.
- Settings has a **Share diagnostics** row that opens the system share sheet
  with one text file: a header (app version, build, OS, device model) and the
  journal entries.

## Acceptance

- Entries contain fixed event names, codes, phases, check-site names,
  durations, and timestamps only. Never prompts, replies, transcripts, tokens,
  credentials, conversation handles, or audio.
- Per-frame audio and event-received notices are not journaled.
- The journal keeps at most 2,000 entries; older entries are dropped first.
- Sharing works with the app offline and without a Hermes profile.
- Debug builds still write the same events to the unified log.
- No new server operation; delivery is the share sheet only. Sending
  diagnostics to Home is a separate, later story that needs a Home endpoint.

## Validation

- Unit tests: journal append, cap, persistence across instances, export
  format, and that the connection trace reaches the journal.
- iOS simulator tests and macOS build.
- On a Release/TestFlight phone: reproduce a connect, background the app,
  return, tap Share diagnostics, AirDrop the file, and confirm it contains the
  connect/reconnect outcomes and no content.
