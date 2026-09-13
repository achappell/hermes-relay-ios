# iOS/macOS Workflow

## Local tracker flow

Use `_bmad-output/implementation-artifacts/sprint-status.yaml` as the formal
delivery-status authority for iOS. Keep one vertical slice in `in-progress`
and move it promptly through:

`backlog` → `ready-for-dev` → `in-progress` → `review` → `done`

Use a local note or dependency reference when work depends on a Hermes
protocol change, an external service, or a product decision. Do not change a
sibling repository's tracker to represent an iOS dependency.

The TUI coverage index is a read-only cross-repository context view. A normal
iOS status transition is committed only in this repository. The product hub is
updated only when implementation changes durable shared intent or a decision
another surface must consume.

## Slice shape

Each slice should state:

- The user outcome.
- Acceptance criteria.
- The expected interaction and failure wording.
- A deterministic validation scenario.

Prefer a small end-to-end path over a layer-first build. For example, connect,
send one typed turn, render streamed text, and show a recoverable connection
failure before adding session browsing or media polish.

## Code workflow

1. Read the active local story entry, specification, and this repository's
   `AGENTS.md`.
2. Add or update a focused XCTest before changing behavior.
3. Run the focused test to establish the failure or boundary.
4. Implement the smallest test-backed change.
5. Build and test the iOS simulator target.
6. Build the macOS target.
7. Run the manual smoke plan and record evidence in the local validation record.
8. Update the local tracker and validation record, then commit one coherent
   slice with a conventional commit message.

## Story records

`_bmad-output/implementation-artifacts/story-index.yaml` owns iOS story
identity, the parent product-epic reference, and links to local evidence. It
does not copy product acceptance criteria. The individual specification owns
the acceptance contract; the validation record owns observed evidence; the
local tracker owns formal delivery status.

When a story is iOS-only, create or update these local records without editing
the TUI repository. When a change affects a shared protocol, household rule,
or product outcome, record the shared decision in the product hub and link it
from the local story.

For the voice path, the manual plan is
[`docs/plans/2026-08-30-ios-voice-interface-testing-plan.md`](plans/2026-08-30-ios-voice-interface-testing-plan.md).
It is the authority for device-only microphone, speaker-route, permission, and
network-loss checks.

## Validation ladder

```text
Focused XCTest
    ↓
Simulator build
    ↓
Simulator XCTest
    ↓
macOS build
    ↓
Manual smoke test
    ↓
Board evidence and merge
```

Unit tests use fake session clients. Live testing is reserved for the manual
plan and must use a token supplied through secure local configuration; never
put a token in source, test fixtures, screenshots, or logs.

Voice-specific evidence records state transitions, turn counts, error wording,
and build/test destinations. It does not record prompts, responses, bearer
tokens, raw WebSocket frames, microphone captures, PCM bytes, or screenshots
containing private content.

## Commit boundaries

Keep commits reviewable and reversible. Good first messages include:

- `chore: add iOS SwiftUI foundation`
- `test: cover typed turn event normalization`
- `feat: connect iOS client to Hermes relay`

Do not combine a protocol contract change, UI redesign, and credential setup in
one slice.
