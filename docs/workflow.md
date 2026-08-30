# iOS Workflow

## Board flow

Use GitHub Project #3 as the source of truth. IOS-01 is the current foundation
slice. Keep one vertical slice in `Building` and move it promptly through:

`Inbox` → `Ready` → `Building` → `Verify` → `Done`

Use `Blocked` when work depends on a Hermes protocol change, an external
service, or a design decision. Keep the built-in status aligned with the
workflow state.

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

1. Read the active board item and this repository's `AGENTS.md`.
2. Add or update a focused XCTest before changing behavior.
3. Run the focused test to establish the failure or boundary.
4. Implement the smallest test-backed change.
5. Build and test the simulator target.
6. Run the manual smoke plan and record evidence on the board item.
7. Commit one coherent slice with a conventional commit message.

## Validation ladder

```text
Focused XCTest
    ↓
Simulator build
    ↓
Simulator XCTest
    ↓
Manual smoke test
    ↓
Board evidence and merge
```

Unit tests use fake session clients. Live testing is reserved for the manual
plan and must use a token supplied through secure local configuration; never
put a token in source, test fixtures, screenshots, or logs.

## Commit boundaries

Keep commits reviewable and reversible. Good first messages include:

- `chore: add iOS SwiftUI foundation`
- `test: cover typed turn event normalization`
- `feat: connect iOS client to Hermes relay`

Do not combine a protocol contract change, UI redesign, and credential setup in
one slice.
