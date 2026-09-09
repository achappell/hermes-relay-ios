# IOS-16 — Opt-in hands-free mode and barge-in

## Outcome

The iOS client can be explicitly armed for hands-free conversation without
opening the microphone at launch. Speech activity starts one local capture,
silence ends it, and the existing verified Hermes turn path submits at most one
turn for that capture. While Hermes responds, automatic barge-in is permitted
only on an echo-safe headphone route.

## Boundaries

- The selected, `hello_ack`-verified Hermes session remains the prerequisite for
  arming and submission.
- Hands-free mode is an iOS capability. The macOS target keeps the shared
  coordinator and protocol types buildable but does not expose the control.
- The microphone is never implicitly armed at launch, on connection, or after
  a response. The user taps Hands-free mode to arm it.
- The built-in speaker, remote speakers, and unknown routes do not permit
  automatic barge-in. Wired headphones, Bluetooth HFP, and Bluetooth LE
  routes are the current echo-safe set.
- No microphone bytes or new Hermes operation are introduced; the existing
  local SpeechInput adapter and server-confirmed interruption are reused.

## Acceptance and validation

- [x] Explicit arming starts the injected input only after a verified session
      and authorized microphone/speech access.
- [x] Silence and background noise do not submit a turn.
- [x] Speech followed by the bounded silence endpoint submits one trimmed turn,
      accepts the final recognition result, and restarts monitoring while the
      mode remains armed.
- [x] No-speech expiry closes and restarts monitoring without submission.
- [x] Disarming cancels active capture, clears provisional text, and releases
      the microphone input.
- [x] Permission and unavailable-input failures remain typed and actionable.
- [x] Safe-route speech interrupts the active response once and enters one new
      capture; unsafe and unknown routes remain blocked.
- [x] Leaving the active scene, disappearing from the app, or losing the relay
      connection disarms hands-free mode.
- [x] The merged hands-free input adapter is covered with deterministic fake
      activity and recognition events.
- [ ] Real-device smoke: arm, speak, receive an answer, speak over it using an
      echo-safe route, then repeat silence/noise, disarm, permission denial,
      route change, session end, and audio interruption.

The device pass must record only state transitions, counts, device/OS, route,
and pass/fail outcomes. Do not capture prompts, responses, tokens, raw frames,
PCM, or microphone audio.
