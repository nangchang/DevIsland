---
name: devisland-settings-preferences
description: Change DevIsland settings, preferences, UserDefaults persistence, settings windows, localized setting labels, default values, migration behavior, or SettingsStore/AppSettings tests. Use for SettingsStore, SettingsWindow, DisplaySettings, settings docs, and feature settings added by other DevIsland domains.
---

# DevIsland Settings And Preferences

Use this when a DevIsland change adds, removes, renames, persists, displays, or documents a setting. Pair with the relevant domain skill, such as `devisland-notch-ui`, `devisland-openpeon-cesp`, or `devisland-approval-proxy`.

## Start

Read:

- `AGENTS.md`
- `docs/agent/ui-customization.md` for notch/display settings
- `docs/agent/openpeon-cesp.md` for OpenPeon settings
- The relevant feature doc when the setting controls hook, proxy, terminal, or packaging behavior

Inspect existing patterns in:

- `DevIsland/Settings/SettingsStore.swift`
- `DevIsland/Settings/SettingsWindow.swift`
- `DevIsland/Settings/DisplaySettings.swift`
- `DevIsland/Utility/Localizable.swift`
- `DevIslandTests/SettingsStoreTests.swift`

## Implementation Rules

Keep setting ownership explicit:

- Store persisted values in `SettingsStore` / `AppSettings`.
- Keep defaults stable and documented.
- Use existing SwiftUI settings controls and layout patterns.
- Add localization entries when user-facing labels or menu text change.
- Avoid duplicating the same setting state in UI views.

When changing an existing key, preserve backward compatibility unless the user explicitly wants a reset or migration.

## Validation

Add or update focused `SettingsStoreTests` for:

- Default values.
- Persistence round trips.
- Range clamping or enum decoding.
- Backward-compatible behavior for renamed or missing values.

If the setting changes visible UI or behavior, update the relevant `docs/agent/*` file and run:

```bash
./scripts/run-tests.sh
```

Use `devisland-change-verification` before handoff.
