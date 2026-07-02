---
name: devisland-plugin-architecture
description: Change DevIsland built-in plugin architecture, PluginHost dispatch, PluginRunner lifecycle, PluginEventFactory redaction, plugin permissions, plugin storage/settings, host effect catalog, contribution rendering, compact region providers, or plugin architecture docs/tests.
---

# DevIsland Plugin Architecture

Use this for platform-level plugin work. Read `docs/agent/plugin-architecture.md`, `docs/agent/plugin-architecture-implementation-plan.md`, and `docs/agent/stability-standards.md` before editing.

## Boundaries

Plugins are compiled built-ins in the current implementation. Do not add external plugin loading, network access, process execution, raw hook payload access, or arbitrary SwiftUI plugin views unless the user explicitly asks for a larger design change.

Keep the hook and approval response path independent from plugin execution:

- `AppState` emits sanitized plugin events as best-effort side effects.
- `PluginEventFactory` owns snapshot creation and permission-based redaction.
- `PluginRunner` runs plugin code off the rendering path.
- UI reads cached `PluginUIContribution` values only.
- Host commands/effects go through validated catalogs and host-owned executors.

Do not make `SessionStore` depend on plugin types. Use neutral callbacks or host-owned adapters.

## Files To Inspect

Pick the relevant files:

- `DevIsland/Plugins/PluginHost.swift`
- `DevIsland/Plugins/PluginRunner.swift`
- `DevIsland/Plugins/PluginEventFactory.swift`
- `DevIsland/Plugins/PluginProtocol.swift`
- `DevIsland/Plugins/PluginPermission.swift`
- `DevIsland/Plugins/PluginStorage.swift`
- `DevIsland/Plugins/PluginSettingsStore.swift`
- `DevIsland/Plugins/HostEffectCatalog.swift`
- `DevIsland/Plugins/PluginEffectExecutor.swift`
- `DevIsland/UI/PluginContributionRenderer.swift`
- `DevIsland/Settings/PluginSettingsView.swift`
- Relevant built-ins under `DevIsland/Plugins/BuiltIn/`

## Rules

Renderer code must not call plugin code. Contribution caches should fail closed to empty or last valid display according to the documented surface behavior.

Plugin enable/disable, safemode, and storage reset are plugin settings. They must not mutate core app settings, approval settings, bridge config, or provider behavior.

Host-owned effects must validate permission, target session, scoped path, size/type limits, and lifecycle state at execution time.

## Tests

Use or update focused tests:

- `PluginEventFactoryTests`
- `PluginHostDispatchTests`
- `PluginSettingsTests`
- `PluginStorageTests`
- `PluginScopedResourcesTests`
- `HostEffectCatalogTests`
- `PluginContributionRendererTests`
- Built-in plugin tests such as `SessionTimerPluginTests`, `PomodoroPluginTests`, `SessionStatsPluginTests`, `SessionActionsPluginTests`, `CompactAppearancePluginTests`, or `OpenPeonPluginTests`

Run `./scripts/run-tests.sh` before handoff.
