---
name: devisland-openpeon-cesp
description: Change DevIsland OpenPeon CESP sound pack support, plugin-owned runtime playback, scoped pack scanning, manifest validation, event-to-category mapping, audio playback effects, mute/debounce settings, or OpenPeon docs/tests. Use for DevIsland/Plugins/BuiltIn/OpenPeon files, scoped file/audio broker interactions, SettingsStore OpenPeon values, and CESP tests.
---

# DevIsland OpenPeon CESP

Use this for OpenPeon CESP work. Read `docs/agent/openpeon-cesp.md` and `docs/agent/stability-standards.md` before editing.

## Boundaries

OpenPeon is a built-in plugin and best-effort side effect. Sound playback and pack validation must never delay hook responses or change approval/deny behavior.

Bridge scripts remain unchanged for CESP work. Keep pack loading, mapping, settings, and audio in the macOS app.

The runtime hook path is:

```text
OpenPeonPlugin -> OpenPeonRuntime -> CESPScopedPackResolver -> PluginContext.scopedFiles -> audio.playFile effect
```

The runtime path must read packs only through the scoped file broker and must not use absolute paths, `FileManager`, or `SettingsStore.shared` directly. The host validates plugin-scoped audio effects before playback.

## Runtime Modules

Inspect the relevant module under `DevIsland/Plugins/BuiltIn/OpenPeon/` before editing:

- `OpenPeonPlugin.swift`: hook observation and category mapping entrypoint.
- `OpenPeonRuntime.swift`: runtime debounce, mute, active-pack selection, and audio effect generation.
- `CESPScopedPackResolver.swift`: plugin-owned pack discovery/validation through scoped files.
- `CESPModels.swift`: manifest, category, validation, pack, and file-index models.
- `CESPPackValidator.swift`: manifest, file, path, and audio validation over `CESPPackFileIndex`.
- `CESPEventMapper.swift`: hook event to CESP category mapping.
- `CESPPackStore.swift`: Settings Sound tab scan and active-pack display only.
- `CESPAudioPlayer.swift`: Settings preview playback only.
- `SettingsStore.swift`: OpenPeon settings persistence and defaults.
- `PluginScopedResources.swift` / `PluginEffectExecutor.swift`: scoped file and audio effect enforcement when touched.

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
- Runtime scoped-broker directory scans enforce the documented entry cap.

Stop pack-size enumeration once the limit is exceeded.

## Playback Rules

Active pack missing, category missing, muted category, global mute, and debounce should no-op. Run cheap gates before broker file access. Avoid immediate repeat when possible. Playback failure should log only.

Runtime hook playback is requested with generic `audio.playFile` and a plugin-scoped relative path. Do not make the host understand CESP categories or pack selection.

`.ogg` may be recognized by validation but should remain a warning for playback unless stock macOS playback support is deliberately added.

## Tests

Use or update:

- `CESPScopedPackResolverTests`
- `OpenPeonManifestTests`
- `OpenPeonPackValidatorTests`
- `OpenPeonEventMapperTests`
- `OpenPeonPluginTests`
- `OpenPeonAudioSelectionTests`
- `PluginScopedResourcesTests`
- `SettingsStoreTests`

Run `./scripts/run-tests.sh` before handoff.
