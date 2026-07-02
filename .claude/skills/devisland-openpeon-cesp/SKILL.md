---
name: devisland-openpeon-cesp
description: Change DevIsland OpenPeon CESP sound pack support, pack scanning, manifest validation, event-to-category mapping, audio playback, mute/debounce settings, or OpenPeon docs/tests. Use for DevIsland/Plugins/BuiltIn/OpenPeon files, SettingsStore OpenPeon values, and CESP tests.
---

# DevIsland OpenPeon CESP

Use this for OpenPeon CESP work. Read `docs/agent/openpeon-cesp.md` and `docs/agent/stability-standards.md` before editing.

## Boundaries

OpenPeon is a best-effort side effect. Sound playback and pack validation must never delay hook responses or change approval/deny behavior.

Bridge scripts remain unchanged for CESP work. Keep pack loading, mapping, settings, and audio in the macOS app.

## Runtime Modules

Inspect the relevant module under `DevIsland/Plugins/BuiltIn/OpenPeon/` before editing:

- `CESPModels.swift`: manifest and runtime models.
- `CESPPackStore.swift`: background scan and active pack selection.
- `CESPPackValidator.swift`: manifest, file, path, and audio validation.
- `CESPEventMapper.swift`: hook event to CESP category mapping.
- `CESPAudioPlayer.swift`: sound choice, debounce, mute, volume, playback.
- `SettingsStore.swift`: OpenPeon settings persistence.

## Validation Rules

Preserve these checks unless intentionally changing the spec:

- `openpeon.json` exists and decodes.
- `cesp_version == "1.0"`.
- Pack name matches the documented pattern.
- Version is semver-compatible.
- Categories are non-empty.
- Sound paths are relative, contain no `..`, and stay under the pack root.
- Audio files exist and use `.wav`, `.mp3`, or `.ogg`.
- Individual file and total pack size limits are enforced with `Int64`.

Stop pack-size enumeration once the limit is exceeded.

## Playback Rules

Active pack missing, category missing, muted category, global mute, and debounce should no-op. Avoid immediate repeat when possible. Playback failure should log only.

`.ogg` may be recognized by validation but should remain a warning for playback unless stock macOS playback support is deliberately added.

## Tests

Use or update:

- `OpenPeonManifestTests`
- `OpenPeonPackValidatorTests`
- `OpenPeonEventMapperTests`
- `OpenPeonAudioSelectionTests`
- `SettingsStoreTests`

Run `./scripts/run-tests.sh` before handoff.
