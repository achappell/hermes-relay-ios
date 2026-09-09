# Epic 1 iOS Device Validation Pass

This is the single supervised physical-device run for the current iOS Epic 1
slices. It closes the device-only gaps for Story 1.1 (IOS-36) and Story 1.2
(IOS-29) together instead of repeating a separate hardware walkthrough for
each card.

The pass complements deterministic XCTest. XCTest remains the authority for
stale-event ordering, unknown events, transport framing, file ordering, and
playback-failure races that a physical device cannot reproduce reliably. This
pass proves the signed app, Keychain, permissions, microphone, speaker route,
live relay, and user-visible lifecycle work together.

## Preconditions

- Use Xcode 26.6 or newer, a signed build, and a real iOS 26 device.
- Use a locally configured test Hermes Profile and token. Never put either in
  this plan, screenshots, tickets, console output, or test artifacts.
- Use only non-sensitive test speech. Record pass/fail, state transitions, turn
  counts, error wording, and device/OS; do not record prompts, responses,
  microphone captures, PCM, raw frames, or credentials.
- Start with the app in a known state and keep the selected Profile visible.

## One-pass run order

### 1. Authorization boundary and profile storage — Story 1.1

1. Launch with no saved Profile or token. Confirm the app stays disconnected,
   voice capture does not open, and the message identifies configuration or
   authorization as the missing prerequisite.
2. Open Configure Relay, save the test Profile and token, return to the
   conversation, and confirm the selected Profile is visible.
3. Confirm the connection becomes Connected only after Hermes sends
   `hello_ack`.
4. Reopen Configure Relay. Confirm metadata is present, the token is shown
   only through the stored-token indicator, and leaving the token blank
   preserves it. Remove the token and confirm the Profile remains while
   connection reports the missing-token state.

### 2. Verified capture binding — Story 1.1

1. Grant microphone and speech-recognition permissions.
2. Press and hold voice control. Confirm `Ready → Listening → Transcribing`
   and provisional text appear outside the committed transcript.
3. While capture is active, change or invalidate the selected Profile/session.
   Confirm the captured phrase is not submitted to the replacement identity;
   the user receives an actionable local error and can begin a fresh turn.
4. Restore the selected test Profile and verify the session again before
   continuing.

### 3. Complete authorized turn — Stories 1.1 and 1.2

1. Capture one non-empty phrase and release once.
2. Confirm exactly one user turn and one assistant response are rendered.
3. Confirm the visible lifecycle is justified and monotonic:
   `Thinking → Buffering/Speaking → Complete`.
4. Confirm the response audio is heard on the valid speaker route and that the
   HUD does not return to Ready before delivery finishes.
5. If the relay emits multiple response segments, confirm they remain one
   assistant response with no duplicate or invented text.

### 4. Honest failure and fallback paths — Story 1.2

1. Exercise an unavailable or interrupted speaker route. Confirm the completed
   response text remains readable, the UI reports playback unavailable or
   failed, and it never presents Speaking without delivered audio.
2. If the configured relay emits file-backed WAV fallback audio, repeat a
   turn and confirm completion waits for file delivery and playback drain. If
   this route is unavailable in the test environment, record `not observed`;
   the deterministic file-order and drain tests remain the verification for
   that branch.
3. If the relay can emit a controlled late status/timing event, inject it
   after buffering or speaking and confirm the visible phase does not regress.
   Otherwise record `not observed`; the deterministic stale-event tests are
   authoritative for this branch.

### 5. Cancellation, interruption, and recovery — Epic 1 boundary checks

1. Start a later capture, cancel it, and confirm no turn is submitted, the
   provisional text clears, and any existing draft remains unchanged.
2. Deny microphone or speech permission on a fresh attempt. Confirm the error
   names the local permission and directs the user to Settings rather than
   presenting a relay failure.
3. During a speaking response, use the supported interruption control when
   Hermes advertises that capability. Confirm playback stops, no replacement
   turn is created, and the existing partial text remains visible. If the
   endpoint does not advertise interruption, record that the capability was
   unavailable rather than inventing a result.
4. Drop the network during an active turn. Confirm the connection is no longer
   shown as connected, the uncertain turn is marked unconfirmed, reconnect does
   not replay it, and an explicitly submitted later turn can complete.

### 6. Privacy and artifact review

1. Review the device console, diagnostics, screenshots, and any captured test
   artifacts.
2. Confirm none contains a prompt, response, token, raw WebSocket frame,
   microphone audio, PCM data, or device-specific credential.

## Evidence record

Record one entry for the entire pass:

```text
Date/time:
Commit / PR:
Device / iOS:
Xcode:
Profile and hello_ack:
Capture and binding:
Complete turn count:
Audio / fallback result:
Failure and interruption result:
Network recovery result:
Privacy review:
Known limitations:
Overall result:
```

## Exit criteria

- Steps 1–3 pass for the signed device build.
- The text/audio, failure, and privacy results are recorded, including any
  `not observed` branch with its deterministic-test substitute.
- IOS-36 and the IOS-29 deferred-work record link to this single evidence
  entry.
- Future iOS work for Epic 1 Stories 1.3 and 1.4 extends this same plan when
  those behaviors are delivered; it does not create a second Epic 1 device
  validation task.
