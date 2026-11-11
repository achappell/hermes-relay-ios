# Spine Pair Review — Hermes Relay

## Overall verdict

The spines now capture the latest Keep listening handoff, including the visible Pending state, second-tap cancellation, On during a successful reply, and immediate monitoring after no-speech capture without an empty turn. The pair is a useful behavioral contract but remains draft-level: a few owner-open presentation decisions still block a fully specified implementation, and one direct copy-rule contradiction plus token-schema and component-mapping gaps remain. This is a document review, not application or device verification.

## 1. Flow coverage — adequate

Checked the three named-protagonist flows, numbered steps and climax beats against the source outcomes for capture acknowledgement/empty capture (Story 2-I-1), turn phases/audio failure (Story 1.2), disconnection/no replay (Story 2-I-2), hands-free and interruption (IOS-16), and Duo continuity/layout (IOS-UX-F11). The source set does not supply a PRD with enumerated UJ names. The Duo flow covers connection loss and keyboard obstruction; the two voice flows do not show permission/input or capture failure journeys.

### Findings
- **medium** The quick-question and hands-free flows omit failure alternatives for denied/unavailable microphone or speech input, capture failure, and hands-free authorization/input or connection loss (EXPERIENCE.md:180–197). The state prose supplies partial recovery behavior, but the flows do not show how a person reaches it. *Fix:* Add only source-grounded failure branches; do not invent recovery UX.

## 2. Token completeness — thin

Extracted the DESIGN.md frontmatter token families and literal `{path.to.token}` references in both spines. All color values are hex, light/dark roles are present, and the referenced token paths resolve. The orb's foreground pairings include calculated contrast results and a 3:1 non-text target; other load-bearing text/control pairings have no stated contrast targets.

### Findings
- **medium** The declared typography objects use `family`, `style` and `weight`, rather than the design.md spec's `fontFamily`, `fontWeight`, etc. or a platform-native `note`; radii, spacing and component dimensions are bare numbers without machine-readable units (DESIGN.md:30–91; `.agents/skills/bmad-ux/references/design-md-spec.md`:11–19, 45–49). *Fix:* Use the supported native-style note and explicit dimension units while preserving Dynamic Type.
- **medium** Contrast assurance is specific to the orb glyph and hands-free pill, not all load-bearing status, secondary-control and state text in both appearances (DESIGN.md:102–112, 158–190). *Fix:* State the required text/non-text contrast targets and pairings for remaining meaningful combinations; verify rendered states separately.

## 3. Component coverage — thin

Walked the orb, outer Transcript voice action, mode toggle, status line, Cancel, Keep listening control, recent-prompts button/menu, reply rail, composer/send, header/profile/settings/recovery and transcript. Major voice components have behavioral and visual rules; some base app controls are described as retained from the earlier visual pass.

### Findings
- **medium** The Talk/Transcript toggle has behavior and a hit target but no dedicated DESIGN.md component visual rule; composer/send and header/settings/recovery lack a precise cross-spine component map or exact inheritance boundary (DESIGN.md:120–143; EXPERIENCE.md:37–52, 97–103). *Fix:* Map these to explicit visual/behavioral contracts or identify the inherited source contract, retaining the deliberately open placements.

## 4. State coverage — thin

Walked header, voice zone, rail/transcript, typing/composer, outer modes and hands-free through idle, capture/transcribing, Pending/On handoff, working/output, Complete, disconnect/recovery, permission denial, empty capture, focus, keyboard and fold states. The new pending display and cancellation behavior agree across both spines; no-empty-turn and immediate no-speech monitoring are preserved.

### Findings
- **medium — implementation blocker:** Permission denial identifies which permission is blocked and requires a distinct next action, but the recovery action/presentation is explicitly unresolved (EXPERIENCE.md:145). A downstream implementation cannot provide the required actionable recovery without this owner decision. *Fix:* Choose the microphone/speech-permission-specific next action, separate from relay recovery.
- **medium — explicitly open:** The state table says the rail shows the last exchange in Idle but does not define the first-run empty rail/composer or the no-profile treatment in each outer mode (EXPERIENCE.md:37–52, 129–145). The inherited visual pass has a Configure relay route, but the spines do not state how it maps to all modes. *Fix:* Confirm the inherited route and empty-state behavior without expanding setup scope.

## 5. Visual reference coverage — strong

The workspace contains `mockups/key-conversation.html` and `.working/flow-duo-postures-2026-11-09.excalidraw`. Both spines link to the regular-phone mock and identify the Duo wireframe as exploratory; both state that the spines win on conflict. No orphan visual reference was found.

### Findings
- None.

## 6. Bloat & overspecification — adequate

Component dimensions describe controls rather than arbitrary page layouts; Dynamic Type and responsive behavior remain semantic. The posture evidence is scoped to the keyboard/layout decision, although some transient investigative detail appears in the behavioral contract.

### Findings
- **low** EXPERIENCE.md retains exact standalone-probe coordinates and a local `/tmp` screenshot path (line 230); the conclusion is also stated without those transient values. *Fix:* Keep only durable, decision-relevant evidence or move the raw probe record to durable evidence storage.

## 7. Inheritance discipline — thin

The ten local source paths resolve; the three Apple references are external and were not revalidated. Relative links to DESIGN.md, the source stories, mock, and working wireframe resolve. Named token references resolve, and the large-layout proposal is explicitly not adopted. Key decisions in the latest memlog are represented in the spines.

### Findings
- **medium — direct contradiction:** DESIGN.md says “Do show state and action in words every time” (line 203), but its own status-line rule makes hands-free waiting/hearing and disconnected states state-only (line 180), matching EXPERIENCE.md:56. *Fix:* Qualify the Do rule with those state-only exceptions.

## 8. Shape fit — adequate

DESIGN.md follows the canonical section order. EXPERIENCE.md contains the required Foundation, IA, Voice and Tone, Component Patterns, State Patterns, Interaction Primitives, Accessibility Floor and Key Flows sections, plus Responsive & Platform for its multi-platform/posture scope. No separate Inspiration section is triggered by the inspected source/memlog set.

### Findings
- **medium — explicitly open:** Duo transition stability, exact keyboard reflow and compact presentation remain open, as the spines say; the fold trigger/orientation does not itself resolve geometry changes or absent/unavailable posture data (EXPERIENCE.md:172–175, 219–230). These are product/validation decisions, not invitations for a reviewer to invent behavior. *Fix:* Resolve and validate the load-bearing fallback/transition cases before treating the layout contract as implementation-ready.

## Mechanical notes

- Severity counts: **0 critical, 0 high, 8 medium, 1 low** (nine findings total).
- All declared color values are hex; the explicit token paths checked resolve. Typography field names and unitless dimensions are recorded under Token completeness.
- All ten local source paths in EXPERIENCE.md resolve. External Apple links are cited but were not independently revalidated.
- Both in-scope visual references are linked and described as mockup/exploration; no orphan was found.
- This pass read current EXPERIENCE.md, DESIGN.md, `.memlog.md`, all configured BMad UX design/experience examples, validation procedure/schema/template, and source sections on capture, permissions, Complete, disconnection, hands-free and Duo validation. No build, app run, device test, or rendering verification was performed.