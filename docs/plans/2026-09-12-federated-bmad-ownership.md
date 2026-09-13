# Federated BMAD Surface Ownership Implementation Plan

> **For Gemini:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make each Hermes implementation repository authoritative for its own BMAD stories and delivery status, while generating a read-only cross-repository status report.

**Architecture:** Add a small `bmad-surface.yaml` registration to each repository, a local `story-index.yaml` where story titles and artifact links live, and a local `sprint-status.yaml` for formal delivery status. The TUI repository will own only TUI/home-device/web surface status and will provide a PyYAML-based report command that reads registrations without writing to sibling repositories.

**Tech Stack:** Existing BMAD YAML/Markdown artifacts, Python 3.14, PyYAML already used by `hermes-relay-tui`, and the existing repository documentation.

---

### Task 1: Record and commit the approved design

**Files:**
- Create: `docs/plans/2026-09-12-federated-bmad-ownership-design.md`
- Create: `docs/plans/2026-09-12-federated-bmad-ownership.md`

**Step 1: Review the design against the current repository rules**

Confirm that the design preserves the private product hub boundary, keeps the
external board paused, avoids a duplicate product PRD, and makes local status
authoritative for iOS delivery.

**Step 2: Commit the design and implementation plan**

Run:

```bash
git add docs/plans/2026-09-12-federated-bmad-ownership-design.md docs/plans/2026-09-12-federated-bmad-ownership.md
git commit -m "docs: define federated bmad ownership"
```

Expected: one commit containing only the two planning documents.

---

### Task 2: Register iOS and give it a local story/status authority

**Files:**
- Create: `bmad-surface.yaml`
- Create: `_bmad-output/implementation-artifacts/story-index.yaml`
- Create: `_bmad-output/implementation-artifacts/sprint-status.yaml`
- Modify: `AGENTS.md`
- Modify: `docs/bmad-upstream.md`
- Modify: `docs/workflow.md`

**Step 1: Add the iOS registration**

Use this shape, with repository-relative paths only:

```yaml
schema_version: 1
repository: hermes-relay-ios
planning: bmad
surfaces:
  - id: I
    name: iOS Client
status_tracker: _bmad-output/implementation-artifacts/sprint-status.yaml
story_index: _bmad-output/implementation-artifacts/story-index.yaml
coordination_authority: product-hub
```

**Step 2: Add the local story index**

Record the existing iOS surface identities (`1-I-1` through `1-I-3`,
`2-I-1`/`2-I-2`, `3-I-1` through `3-I-6`, and `5-I-1`) plus the existing local
UX/design/brand and macOS distribution tickets. Each row contains only its
ID, parent product epic when applicable, title, kind, and local spec or
validation path. `3-I-4` remains backlog with no invented specification while
the shared Home contract is unsettled.

**Step 3: Add the local status tracker**

Use the existing BMAD `development_status` mapping and record the observed
state: Epics 1, 2, and 5 are done; Epic 3 is in progress because `3-I-4`
remains open; completed local tickets are done; future distribution tickets
are backlog. The tracker is the formal delivery status for this repository.

**Step 4: Update iOS workflow language**

State explicitly that ordinary iOS status and story-map edits stay in this
repository. Existing TUI maps may be consulted for imported identity context,
but no iOS status transition requires a TUI or hub-repository edit. Shared
product decisions still flow to the product hub.

**Step 5: Validate the local records**

Run:

```bash
git diff --check
rg -n "status_tracker|story_index|product-hub|local status|local tracker" bmad-surface.yaml AGENTS.md docs _bmad-output/implementation-artifacts
```

Expected: no whitespace errors and no instruction that makes TUI status
authoritative for iOS.

**Step 6: Commit the iOS migration**

```bash
git add bmad-surface.yaml _bmad-output/implementation-artifacts/story-index.yaml _bmad-output/implementation-artifacts/sprint-status.yaml AGENTS.md docs/bmad-upstream.md docs/workflow.md
git commit -m "chore: make ios bmad status local"
```

---

### Task 3: Register Android, Home, and the non-BMAD agent repository

**Files:**
- Android: create `bmad-surface.yaml`, `_bmad-output/implementation-artifacts/story-index.yaml`, and `_bmad-output/implementation-artifacts/sprint-status.yaml`; modify `README.md`.
- Home: create `bmad-surface.yaml`, `_bmad-output/implementation-artifacts/story-index.yaml`, and `_bmad-output/implementation-artifacts/sprint-status.yaml`; modify `README.md`.
- Agent: create `bmad-surface.yaml`.

**Step 1: Add Android’s local records**

Register surface `A`. Move formal status ownership for `1-A-1` through
`1-A-9`, `2-A-1`/`2-A-2`, `3-A-1` through `3-A-6`, and `5-A-1` through
`5-A-3` into the Android tracker. Preserve the existing
`done-with-environment-limitation` detail in validation files; formal status
remains `done` where the local artifact says the story is accepted. The
Android story index links each completed story to its local spec and
validation record and keeps the six Device-administration stories plus
`5-A-3` as backlog.

**Step 2: Add Home’s local records**

Register the Home service surface and use `SPEC-home-service-foundation` as
the local delivery identity. Its tracker records the implemented foundation as
done, with the spec and architecture spine as local evidence. Do not turn the
Home service into a product-planning authority.

**Step 3: Register the agent repository as not applicable**

Use `planning: not-applicable`, an empty `surfaces` list, and a short reason.
Do not create a dummy status file or read its ignored credential file.

**Step 4: Update Android and Home documentation**

Replace wording that says TUI owns their story specifications or status. Keep
TUI links as read-only imported context and point ordinary status changes to
the local tracker.

**Step 5: Validate and commit each repository separately**

For each repository, run `git diff --check`, parse the new YAML with the
repository’s supported tooling, inspect staged paths, and commit with a
repository-local conventional message. Do not include existing unrelated
worktree changes.

---

### Task 4: Make TUI the local owner of only its own status

**Files:**
- Create: `bmad-surface.yaml`
- Modify: `_bmad-output/implementation-artifacts/sprint-status.yaml`
- Modify: `_bmad-output/planning-artifacts/epics.md`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Step 1: Register TUI-owned surfaces**

Declare the local surfaces as `T`, `P`, `E`, and `W/K`, with the existing
`sprint-status.yaml` as the local tracker. Make clear that the imported mobile
rows in `epics.md` are compatibility context, not TUI-owned delivery work.

**Step 2: Remove sibling mobile rows from the TUI tracker**

Remove the `1-I-*`, `1-A-*`, `2-I-*`, `2-A-*`, `3-I-*`, `3-A-*`, `5-I-*`, and
`5-A-*` entries from `development_status`. Retain TUI-owned epic, Puck,
Display, web, and TUI rows. Do not alter unrelated status changes already
present in the base branch.

**Step 3: Mark the epic map’s role**

Add a short note near the top of `epics.md`: it is an imported cross-surface
planning snapshot and historical scope reference; it is not the delivery
status authority for sibling repositories.

**Step 4: Update TUI governance text**

Document that TUI status changes remain local, sibling status is read from the
sibling tracker, and the matrix/report is read-only. Preserve the paused-board
rule and do not run `gh`.

**Step 5: Commit only TUI workflow changes**

```bash
git add bmad-surface.yaml _bmad-output/implementation-artifacts/sprint-status.yaml _bmad-output/planning-artifacts/epics.md AGENTS.md README.md
git commit -m "chore: scope tui bmad ownership locally"
```

---

### Task 5: Move and test the derived cross-repository status report

**Files:**
- Create: sibling `hermes-relay-coordinator/scripts/render_surface_status.py`
- Create: sibling `hermes-relay-coordinator/tests/test_surface_status_report.py`
- Create: sibling `hermes-relay-coordinator/surface-repositories.yaml`
- Modify: sibling `hermes-relay-tui/README.md`
- Modify: sibling `hermes-relay-tui/AGENTS.md`

**Step 1: Write failing tests**

Cover these behaviors with temporary repository fixtures:

- A registered BMAD repository contributes its local stories and tracker
  statuses.
- A `planning: not-applicable` repository contributes no story rows and no
  error.
- A missing tracker, duplicate story ID, unknown status, or index/tracker
  mismatch fails validation with a useful message.
- The generated Markdown includes a warning that it is derived and a
  `Next candidates` section ordered `ready-for-dev`, then `backlog`.
- The renderer never edits an input repository.

Run from the coordinator repository:

```bash
uv run --no-project --python 3.14 --with pytest --with PyYAML \
  -- python -m pytest tests/test_surface_status_report.py -q
```

Expected: the new tests fail until the coordinator renderer is transferred.

**Step 2: Keep the renderer in the coordinator repository**

The public `hermes-relay-coordinator` repository owns the renderer, its
path-only roster, and its focused tests. Its standard roster points to the five
adjacent delivery repositories:

```text
uv run python scripts/render_surface_status.py \
  --config surface-repositories.yaml \
  --output surface-status-report.md
```

For isolated worktrees, pass all five paths explicitly:

```text
uv run python scripts/render_surface_status.py \
  --repo tui=../../hermes-relay-tui-worktrees/federated-bmad-ownership \
  --repo ios=../../hermes-relay-ios-worktrees/federated-bmad-ownership \
  --repo android=../../hermes-relay-android-worktrees/federated-bmad-ownership \
  --repo home=../../hermes-relay-home-worktrees/federated-bmad-ownership \
  --repo agent=../../hermes-agent-worktrees/federated-bmad-ownership \
  --output surface-status-report.md
```

The command reads each repository’s `bmad-surface.yaml`, local story index,
and local tracker. It validates status vocabulary and ID joins, renders one
row per local story, reports unregistered/missing records, and writes only the
requested output file. It accepts arbitrary repository paths so no machine-
specific path is stored in the report or source.

**Step 3: Run the focused coordinator tests**

```bash
uv run --no-project --python 3.14 --with pytest --with PyYAML \
  -- python -m pytest tests/test_surface_status_report.py -q
```

Expected: all coordinator renderer tests pass.

**Step 4: Run the TUI regression check**

```bash
.venv/bin/pytest -q
```

Expected: the existing TUI suite remains green.

**Step 5: Document the command and its authority**

Point the TUI README at the coordinator and state that its output is
disposable, read-only roll-up data. Do not overwrite the existing coverage
matrix in this slice; it still carries applicability and dependency evidence.

**Step 6: Commit the coordinator tooling**

```bash
git add scripts/render_surface_status.py tests/test_surface_status_report.py \
  surface-repositories.yaml README.md AGENTS.md
git commit -m "feat: add federated bmad coordinator"
```

---

### Task 6: Generate, inspect, and hand off the migration

**Files:**
- Create or modify only the generated report in the coordinator checkout:
  `surface-status-report.md`

**Step 1: Render the portfolio view from the coordinator**

Run the coordinator command from Task 5 against the five sibling repositories.
The report must show iOS and Android statuses from their own trackers, not the
TUI tracker, and must show `hermes-agent` as not applicable.

**Step 2: Inspect the authority boundary**

Search the new documentation for instructions that make the TUI map or matrix
the status authority. Any remaining references must explicitly describe
historical/context use or the generated roll-up.

**Step 3: Review the diff and privacy boundary**

Run `git diff --check`, inspect staged paths in each repository, and confirm no
tokens, profiles, audio, private hub paths, generated build products, or
ignored credential files entered the change.

**Step 4: Commit generated output only if useful**

If the report is intentionally tracked, commit it with a generated-file
message. Otherwise leave it disposable and document the command as the source
of the view. Do not commit a report containing machine-specific absolute paths.

**Step 5: Final verification**

Run the focused report tests, the existing TUI suite, and the existing iOS
simulator build. Report each repository’s commit and leave the current dirty
worktrees untouched.
