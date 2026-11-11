# Validation Report — Hermes Relay

- **DESIGN.md:** `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/DESIGN.md`
- **EXPERIENCE.md:** `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/EXPERIENCE.md`
- **Run at:** 2026-11-10

## Overall verdict

The spines now match the latest confirmed Keep listening flow: Pending is visible and cancellable during tapped capture; successful submission shows On while the reply plays without monitoring; a no-speech capture submits no empty turn and starts monitoring immediately; cancellation and disconnect clear the request. Full-response reveal selection and Talk/Transcript focus fallback are also explicit. The draft still has unresolved owner decisions for Complete interaction, permission recovery, constrained layouts and traversal, plus a direct state-copy contradiction in DESIGN.md. These are specification/readiness findings, not observed application defects.

No implementation or device/accessibility validation was performed. Several findings are decisions explicitly left open by the owner, not defects to resolve by reviewer invention.

## Category verdicts
- Flow coverage — adequate
- Token completeness — thin
- Component coverage — thin
- State coverage — thin
- Visual reference coverage — strong
- Bloat & overspecification — adequate
- Inheritance discipline — thin
- Shape fit — adequate

## Findings by severity

### Critical (0)
None.

### High (0)
None.

### Medium (14)

**Flow coverage — Missing voice-flow failure branches**
The quick-question and hands-free journeys do not show permission/input, capture-failure or connection-loss alternatives even though partial recovery rules exist in the state prose (EXPERIENCE.md:145, 180–197). Add only source-grounded alternatives. **Type:** coverage gap.

**Token completeness — Nonconforming typography fields and untyped dimensions**
DESIGN.md typography uses `family`/`style`/`weight`, and dimensions/radii are unitless, unlike the referenced schema (DESIGN.md:30–91; `.agents/skills/bmad-ux/references/design-md-spec.md`:11–19, 45–49). **Type:** machine-readability/schema gap.

**Token completeness — Contrast assurance is incomplete**
Orb and pill have contrast guidance; other load-bearing text/control pairings lack stated targets in both appearances (DESIGN.md:102–112, 158–190). **Type:** contract gap; no rendered contrast testing claimed.

**Component coverage — Missing dedicated visual/inheritance mapping**
The outer-mode toggle has behavior/hit target but no dedicated DESIGN component rule; composer/send and header/recovery inheritance boundaries are imprecise (DESIGN.md:120–143; EXPERIENCE.md:37–52, 97–103). **Type:** contract mapping gap.

**State coverage — Permission recovery is an implementation blocker**
The user must receive a permission-specific next action distinct from relay recovery, but the exact recovery action/presentation is open (EXPERIENCE.md:145). **Type:** explicit owner decision required before implementing this state.

**State coverage — Empty/no-profile state is unspecified**
The initial empty rail/composer and how the inherited Configure relay route appears in each outer mode are not mapped (EXPERIENCE.md:37–52, 129–145). **Type:** explicitly open state coverage.

**Inheritance discipline — Direct state/action copy contradiction**
DESIGN.md says to show state and action “every time” (line 203), while its status-line rule makes hands-free waiting/hearing and disconnected states state-only (line 180), as does EXPERIENCE.md:56. Qualify the visual Do rule. **Type:** direct contradiction.

**Shape fit — Duo transition/reflow readiness remains open**
Transition stability, compact keyboard reflow and behavior under unavailable/unstable posture geometry remain explicitly open (EXPERIENCE.md:172–175, 219–230). Resolve/validate load-bearing cases before claiming implementation readiness. **Type:** explicitly open product/validation decision.

**Accessibility — Pending hint omits repeat-tap cancellation**
The value Pending and second-tap cancellation are specified, but the hint remains generic (EXPERIENCE.md:70, 95, 107, 132–133, 149). Supply a state-specific accessible action hint and announce the transition once. **Type:** accessibility contract gap.

**Accessibility — Complete action/transition remains open**
Non-hands-free Complete is stable until a new capture/send, but copy/action and the Transcript action at Complete remain unspecified (EXPERIENCE.md:95, 141–142, 187). The hands-free no-Complete override is clear. **Type:** explicit owner decision; blocks fully specifying the Complete interaction.

**Accessibility — Mid-reply/paused full-response behavior remains open**
The Settings selection is accessible and the full-response option is approved, but the effect of changing it mid-reply and its interaction with follow/pause and scroll are unresolved (EXPERIENCE.md:122, 171, 174). **Type:** explicitly open interaction detail.

**Accessibility — Traversal outside the mode-switch fallback remains open**
VoiceOver moves to the Talk/Transcript toggle and announces the new view when that switch removes focus; outer Transcript traversal and other focus-loss destinations remain open (EXPERIENCE.md:163, 169–170). **Type:** explicit traversal decision; the mode-switch fallback itself is resolved.

**Accessibility — Large-text/reflow behavior needs validation**
The reachability floor is stated, while compact reflow is open; no device validation of large text, keyboard states or the Duo postures was performed (EXPERIENCE.md:168, 172–175, 224). **Type:** confirmed requirement plus implementation validation gap, not a claim of failure.

**Accessibility — Fold transition accessibility needs validation**
Focus/turn continuity and lifecycle-disarm distinctions are specified; transition stability and actual fallback behavior still need design/validation (EXPERIENCE.md:50, 109, 157–159, 226–228). **Type:** explicitly open posture/validation item.

### Low (1)

**Bloat & overspecification — Transient probe details in contract**
Exact standalone probe coordinates and local `/tmp` screenshot path are retained in EXPERIENCE.md:230 despite the durable conclusion being stated. Keep only durable decision-relevant evidence or archive the raw probe separately. **Type:** maintenance concern.

## Reviewer files
- `review-rubric.md` — 8 medium, 1 low; no critical/high.
- `review-accessibility.md` — 6 medium; no critical/high.

## Mechanical checks and scope

- Read current EXPERIENCE.md, DESIGN.md and `.memlog.md`; reviewed the latest decision history, including the Pending display decision.
- Followed the BMad UX Validate rubric and synthesis template; read all configured design/experience examples and DESIGN token schema.
- Confirmed all ten local source paths in EXPERIENCE.md and both visual reference files are present; checked referenced story requirements for empty capture, permission failure, Complete/audio failure, disconnection, hands-free lifecycle and Duo keyboard validation. External Apple pages were not re-fetched.
- Checked line-level consistency for Pending/On/Off, no-speech, cancellation/disconnect, Complete, hands-free lifecycle, fold/lifecycle and keyboard requirements. Identified the one direct copy-rule contradiction listed above; no direct contradiction in the latest pending-request sequence.
- No application code, build, tests, app/device run, VoiceOver, Dynamic Type, keyboard, or rendered contrast verification was performed. No finalization or commit was performed.
- Review-worker note: no subagent/worker dispatch capability was exposed in this run, so both review lenses and synthesis were completed inline; no unavailable Sonnet reviewer was claimed.

## Artifacts
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/review-rubric.md`
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/review-accessibility.md`
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/validation-report.md`
- `_bmad-output/planning-artifacts/ux-designs/ux-hermes-relay-ios-2026-09-27/validation-report.html`

Offer to update: yes.