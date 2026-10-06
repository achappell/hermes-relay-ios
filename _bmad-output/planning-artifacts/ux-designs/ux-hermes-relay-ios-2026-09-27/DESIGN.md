---
name: Hermes Relay
description: Voice-first conversation doorway to Hermes on iOS and macOS. Night Console identity; calm at rest, explicit in every state. This spine covers the voice controls on the conversation screen.
status: final
scope: voice controls (central voice orb, status line, hands-free pill, reply rail, bottom bar)
updated: 2026-09-27
colors:
  canvas: '#F5F7FB'
  canvas-dark: '#0B101B'
  console-surface: '#FFFFFF'
  console-surface-dark: '#101725'
  panel: '#F0F3F8'
  panel-dark: '#0D1320'
  raised-panel: '#E6ECF5'
  raised-panel-dark: '#182338'
  ink-primary: '#0B101B'
  ink-primary-dark: '#EAF7FF'
  ink-secondary: '#526176'
  ink-secondary-dark: '#B3C0D2'
  live: '#087A4A'
  live-dark: '#62E6C7'
  attention: '#8C6300'
  attention-dark: '#FFCF5C'
  identity: '#4C59D9'
  identity-dark: '#7C8CFF'
  on-identity: '#FFFFFF'
  on-identity-dark: '#0B101B'
  unavailable: '#BE3455'
  unavailable-dark: '#FF7D9C'
typography:
  state:
    family: SF Pro
    style: headline
    weight: semibold
  action-hint:
    family: SF Pro
    style: headline
    weight: regular
  body:
    family: SF Pro
    style: body
  caption:
    family: SF Pro
    style: caption
  metadata:
    family: SF Mono
    style: caption
rounded:
  card: 16
  control: 12
  outer: 20
  pill: 999
spacing:
  xs: 4
  sm: 8
  md: 12
  lg: 16
  xl: 24
  xxl: 32
components:
  voice-orb:
    diameter: 260
    core-diameter: 142
    glyph-size: 34
    press-scale: 0.94
    min-hit-target: 260
  status-line:
    typography: '{typography.state}'
    action-typography: '{typography.action-hint}'
  hands-free-pill:
    height: 30
    min-hit-target: 44
    glyph: arrow.triangle.2.circlepath
    rounded: '{rounded.pill}'
    off-border: '{colors.ink-secondary}'
    off-ink: '{colors.ink-secondary}'
    on-fill: '{colors.identity}'
    on-ink: '#FFFFFF'
    typography: '{typography.caption}'
  recent-prompts-button:
    diameter: 32
    min-hit-target: 44
    glyph: clock.arrow.circlepath
    ink: '{colors.ink-secondary}'
  cancel-link:
    min-hit-target: 44
    typography: '{typography.caption}'
  reply-rail:
    background: '{colors.panel}'
    rounded: '{rounded.card}'
---

# Hermes Relay — Design Spine (voice controls)

> Scope: the voice controls on the conversation screen. The Night Console direction approved on 2026-09-11 (`_bmad-output/implementation-artifacts/ios-visual-design-pass.md`) remains the visual identity for everything else; this spine refines it for voice and supersedes one rule there (capture moves from the bottom surface to the orb). Tokens mirror the shipped asset catalog (`Hermes*` color sets); the spine wins on conflict with any mock.

## Brand & Style

Hermes is a conversation you speak to, not a recorder. The live screen is calm at rest and explicit when something is happening. The central orb is the one place you touch to talk; everything around it explains state in plain words. It should feel polished enough to hand to someone who has never seen it: the first thing they try (tapping the big orb) works.

## Colors

Semantic roles only; never literal colors in views. Each role has a light and dark value (`{colors.canvas}` / `{colors.canvas-dark}` and so on).

- `live` — listening and healthy activity.
- `attention` — the current phase while Hermes works (thinking, speaking).
- `identity` — the Profile and interactive focus; hands-free when on.
- `unavailable` — connection, permission and identity failure.
- `ink-primary` for state words; `ink-secondary` for supporting text.

Color is never the only signal: every state has text in the status line.

## Typography

SF Pro throughout, with Dynamic Type. The status line has two parts: the state (`{typography.state}`, strongest text on the screen) and the tap action (`{typography.action-hint}`), separated by " · ". SF Mono only for metadata (session duration, endpoint).

## Layout & Spacing

The conversation screen has four zones, top to bottom:

1. **Header** — Profile, conversation title, connection.
2. **Voice** — the voice orb, the status line under it, then Cancel (only while listening) and the hands-free pill.
3. **Reply rail** — the latest exchange.
4. **Typing** — Recent prompts button, composer, send.

The voice zone is vertically centred when there is room; with the keyboard up it scrolls away and the typing zone stays above the keyboard. Spacing follows `{spacing.*}` (4/8/12/16/24/32).

## Elevation & Depth

The orb sits directly on the canvas, not inside a card. The reply rail is a flat panel (`{colors.panel}`, hairline border). Liquid Glass is reserved for the grouped typing surface. The hands-free pill is a plain outlined or filled capsule, not glass. No glass on the orb.

## Shapes

Cards `{rounded.card}`, controls `{rounded.control}`, the outer typing container `{rounded.outer}`, status pills `{rounded.pill}`. The orb is a circle; the hands-free pill is a capsule.

## Components

Visual reference: [key-conversation.html](mockups/key-conversation.html) (ready, listening, speaking, hands-free, light). The spine wins on conflict.


### Voice orb (`{components.voice-orb}`)

A 260 pt tappable circle: three quiet rings and a coloured core with a single white glyph. The glyph shows **what a tap will do**, not the state:

| Tap will | Glyph |
|---|---|
| Start talking | `mic.fill` |
| Send now (while listening) | `stop.fill` |
| Interrupt Hermes | `hand.raised.fill` |
| (hands-free waiting) | `ear` — not tappable |
| (hands-free hearing you) | `waveform` — not tappable |

Core and ring colour follow the phase role (`live` listening, `attention` thinking/speaking, `identity` ready). Pressed: scales to `{components.voice-orb.press-scale}`. Disabled: rings still, glyph at reduced opacity. When not connected, the orb shows the connection glyph (configure, reconnecting, unavailable) and is not a button.

### Status line (`{components.status-line}`)

"State · Action", e.g. "Ready · Tap to talk", "Listening · Tap to send", "Speaking · Tap to interrupt". When not connected, the state alone ("Unavailable").

### Cancel link (`{components.cancel-link}`)

A small text button under the status line, only while a tapped recording is listening. Label "Cancel".

### Hands-free pill (`{components.hands-free-pill}`)

A small capsule under the status line: loop glyph + "Keep listening". It is deliberately quieter than the orb and status line. Off: hairline outline, `{colors.ink-secondary}` text and glyph. On: filled `{colors.identity}` with `on-identity` text and glyph (white in light, `{colors.canvas-dark}` in dark, so the label stays above 4.5:1). No caption. iOS only.

### Recent prompts button (`{components.recent-prompts-button}`)

A single small circular button left of the composer with a clock glyph, in `{colors.ink-secondary}`. It replaces the two ▲▼ arrows and appears only when there is history. It opens a native menu of recent prompts.

### Reply rail (`{components.reply-rail}`)

The last few turns. Hermes's reply appears in step with its voice; your words appear live while you talk.

## Do's and Don'ts

- **Do** make the orb the only way to talk on this screen.
- **Do** show state and action in words every time.
- **Don't** put a second microphone button anywhere on this screen.
- **Don't** use bare ▲▼ chevrons for prompt history; one labelled Recent prompts button.
- **Don't** let the hands-free control compete with the orb: a small pill, never a full switch row with a caption.
- **Don't** stream Hermes's text before it speaks.
- **Don't** animate the orb when idle; activity is for real activity. Reduced motion freezes it.
- **Don't** use a microphone glyph when a tap would do something else.
