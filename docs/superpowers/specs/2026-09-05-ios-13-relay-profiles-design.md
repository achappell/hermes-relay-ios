# IOS-13 — Saved relay profiles and connection switching

Design, 2026-09-05.

## Outcome

Amanda can save several Hermes relay connections and switch between them
without re-entering credentials. One profile is active at a time; Connect and
auto-connect target that profile and no other.

## Decisions taken

- **iOS-only schema.** TUI-02 and HOME-13 need the same capability, but the TUI
  stores configuration as dotenv and CLI flags, so a shared file format is not
  obviously right. Those clients may borrow this shape later.
- **Switching connects immediately.** Selecting a different profile
  disconnects the current relay and connects the new one as a single action,
  consistent with the auto-connect behaviour from IOS-12.
- **Full CRUD in this slice.** Create, edit, delete, select. The card is one
  coherent outcome and splitting it leaves half a feature in the app.

## Model

`RelayProfile` gains a stable `id: UUID`. Endpoint, client identity, device
identity and display name are unchanged.

The display name stays cosmetic. It is not the key for anything, because
renaming a profile must never orphan its token — which is exactly what a
name-keyed secret would do.

```swift
struct RelayProfileCollection: Codable, Equatable, Sendable {
    var schemaVersion: Int      // 1
    var profiles: [RelayProfile]
    var selectedID: UUID?
}
```

`schemaVersion` is present from the start so a future change is a cheap
migration rather than a guessing game about which shape is on disk.

## Storage

`RelayConfigurationStore` gains:

| Method | Purpose |
|---|---|
| `loadCollection()` | Read the collection, migrating a legacy file if found |
| `saveProfile(_:)` | Insert or update by id |
| `deleteProfile(id:)` | Remove the profile *and* its Keychain secret |
| `selectProfile(id:)` | Set the active profile |
| `loadToken(for:)` / `saveToken(_:for:)` | Per-profile secrets |

The Keychain **account becomes the profile's UUID string**; the service is
unchanged. Today every token shares one fixed account, which is precisely why
a second profile is impossible.

`loadProfile()` and `loadToken()` remain as thin accessors for the selected
profile. `ConversationStore.loadConfiguredClient()` and the auto-connect path
then need no structural change — a deliberate choice to keep this slice's blast
radius inside the configuration layer.

## Migration

The dangerous part. An existing install has a working profile and a bearer
token that may not be written down anywhere else, so losing it is a real
failure, not a test inconvenience.

On first `loadCollection()`, if the file holds the legacy single-profile shape:

1. Mint a UUID and wrap the existing profile as the sole entry, selected.
2. **Copy** the token from the legacy fixed account to the new per-profile
   account.
3. **Verify** it reads back from the new account.
4. Write the collection file atomically.
5. **Only then** delete the legacy Keychain entry.

Copy, verify, then delete. A crash at any step leaves the token readable from
at least one account, and re-running the migration is safe. The legacy JSON is
kept as a one-time backup rather than overwritten in place.

A profile whose token has gone missing is surfaced as a profile needing a
token, never as a silent connection failure.

## UI

`RelayConfigurationView` — currently inline in `ContentView.swift` — becomes a
compact list: one row per profile, the selected one clearly marked, an Add
action, tap to edit, swipe to delete. Deleting the selected profile clears the
selection rather than silently promoting a neighbour.

`RelayConfigurationDraft` and its existing validation are reused per profile;
no second validation path is introduced.

Tokens are never rendered. Editing an existing profile shows that a token is
saved with a field to replace it, which `tokenToSave(existingToken:)` already
models.

## Switching

Selecting a different profile: disconnect, reload the configured client,
connect. Failure surfaces through the existing `.failed` connection state, and
there is no silent fall back to the previous profile — an honest failure on the
profile the user chose beats a working connection to one they didn't.

## Testing

With a fake secure store and a temporary file:

- Two profiles with distinct endpoints; switching makes Connect target only the
  selected one.
- Relaunch selects the same profile for auto-connect.
- Migration from the legacy shape preserves the token and the connection
  details.
- A simulated crash between copy and delete still leaves the token recoverable,
  and re-running migration is idempotent.
- Deleting a profile removes its Keychain item.
- No token ever appears in the persisted JSON.

Tokens stay out of fixtures, logs and screenshots.

## Out of scope

- Cross-client schema sharing (TUI-02, HOME-13).
- Import/export of profiles.
- Any change to the connection or turn protocol.
