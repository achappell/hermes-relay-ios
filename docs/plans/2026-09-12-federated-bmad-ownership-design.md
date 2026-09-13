# Federated BMAD ownership design

**Status:** Approved 2026-09-12

## Decision

Hermes Home will use federated delivery ownership with a derived portfolio
view. Each implementation repository owns the story map, status, acceptance
evidence, and validation record for its own surface. The private product hub
continues to own durable product intent, shared decisions, and cross-repository
dependency edges. A generated report may summarize local records, but it is
never a second status authority.

This removes the accidental dependency on `hermes-relay-tui` for iOS, Android,
or Home delivery status. A normal local story transition is committed only to
the repository doing that work. A hub update is reserved for a product-level
decision or a dependency that another surface must consume.

## Authority boundaries

| Concern | Authority | Update trigger |
|---|---|---|
| Product outcomes and cross-surface decisions | Private product hub | New or changed shared intent |
| Surface story identity and acceptance scope | Owning repository | A surface slice is created or reshaped |
| Delivery status and validation evidence | Owning repository | Work starts, reaches review, or closes |
| Portfolio status and missing-record warnings | Generated report | A report run reads local records |
| External board fields | Paused mechanical mirror | Only after board work is explicitly reopened |

The existing TUI `epics.md` and coverage matrix remain useful imported history
and cross-surface context. They must not be edited for a sibling repository's
ordinary status transition and must not be used to infer closure.

## Local record shape

Every BMAD delivery repository registers itself with a small
`bmad-surface.yaml`. BMAD repositories provide a local story index and local
`sprint-status.yaml`. The tracker uses the existing BMAD status vocabulary:
`backlog`, `ready-for-dev`, `in-progress`, `review`, and `done`.

The story index contains IDs, parent product-epic references, titles, and
links to the local specification and validation record. It deliberately does
not copy acceptance criteria from the product hub. The status tracker is the
formal delivery authority; frontmatter in an individual artifact describes
that artifact and must remain aligned when the local workflow requires it.

Repositories without BMAD delivery scope may register with
`planning: not-applicable`; they do not need a dummy backlog.

## Operational flow

1. Select or create a story in the owning repository's local story index.
2. Set its local tracker status and add the local specification/evidence.
3. If implementation discovers a shared product decision or dependency, record
   that decision in the product hub and link it from the local story.
4. Run the cross-repository report when choosing the next slice or reviewing
   dependencies. Treat its rows as a read-only roll-up.
5. When the board is reopened, synchronize from the local trackers; never
   reverse that direction.

The first migration adds the contract and local ledgers for iOS, Android, and
Home, registers TUI as the owner of only its own delivery surfaces, explicitly
marks `hermes-agent` as outside the BMAD surface set, and adds a report command
to the TUI tooling. No product behavior or external board item changes.

## Rejected alternatives

- Keeping all story status in TUI preserves the current synchronization cost
  and makes a UI repository the program-management bottleneck.
- Moving everything to a new planning repository adds a sixth repository and
  still requires local evidence synchronization.
- Treating the generated report as canonical recreates the same split authority
  under a different filename.
