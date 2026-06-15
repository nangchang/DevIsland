# OpenPeon CESP

DevIsland supports OpenPeon CESP v1.0 sound packs inside the macOS app. The bridge scripts remain unchanged and thin.

## Pack Layout

Default pack directory:

```text
~/.openpeon/packs/
  sample-pack/
    openpeon.json
    sounds/
      approval.mp3
      done.wav
```

`openpeon.json` uses CESP categories such as `input.required`, `task.complete`, and `task.error`.

## Runtime Modules

OpenPeon CESP implementation files live under `DevIsland/Plugins/BuiltIn/OpenPeon/`.

| Module | Responsibility |
|---|---|
| `CESPModels.swift` | Manifest, category, sound, validation, pack, and pack file-index models |
| `CESPPackValidator.swift` | Manifest/file/path/audio rule evaluation over a `CESPPackFileIndex` (shared by host scan and broker scan) |
| `CESPEventMapper.swift` | Hook event to CESP category mapping |
| `CESPScopedPackResolver.swift` | Plugin-owned pack discovery/validation over the scoped file broker; mirrors `CESPPackStore.activePack` selection |
| `OpenPeonRuntime.swift` | Runtime debounce/mute/selection state; turns a category into an `audio.playFile` effect (`@MainActor`) |
| `OpenPeonPlugin.swift` | Maps hook events to categories and delegates to `OpenPeonRuntime` |
| `CESPPackStore.swift` | **Settings UI only** — pack directory reload, background scan, active pack selection for the Sound tab |
| `CESPAudioPlayer.swift` | **Settings UI only** — sound selection, debounce, mute, volume, settings preview playback |

The runtime hook path (`OpenPeonPlugin` → `OpenPeonRuntime` → `CESPScopedPackResolver`) reads packs only through the scoped file broker (`PluginContext.scopedFiles`) and never touches absolute paths or `FileManager`. `OpenPeonPlugin` receives the current `AppSettings` through an injected host provider and passes that snapshot into `OpenPeonRuntime`; the runtime must not read `SettingsStore.shared` directly. `CESPPackStore`/`CESPAudioPlayer` remain as host services backing the Settings **Sound** tab until plugin settings schema covers them.

## Event Mapping

| Normalized event | CESP category |
|---|---|
| `sessionstart`, `startup`, `init` | `session.start` |
| `permissionrequest`, `beforetool`, `elicitation` | `input.required` |
| `pretooluse` | `task.acknowledge` |
| Codex `posttooluse` without structured failure | no sound event |
| Claude `posttooluse` | no sound event |
| Claude `posttoolusefailure` | `task.error` |
| structured failure-like `posttooluse` | `task.error` |
| `stop`, `afteragent` | `task.complete` |
| `sessionend`, `exit`, `shutdown` | `session.end` |
| `precompact` | `resource.limit` |
| permission/input notifications | `input.required` |
| rate/token/quota/context notifications | `resource.limit` |

`stop` maps to `task.complete` for sound feedback only. Do not change AppState session pruning semantics as part of sound mapping.

Failure detection is intentionally conservative. Claude tool execution failure is detected through `PostToolUseFailure`; Claude `PostToolUse` does not produce sound feedback even when stdout/stderr mention errors. Codex `PostToolUse` is per-tool output rather than turn completion, so it does not produce completion sound feedback. Codex `tool_response` maps to `task.error` only when top-level structured fields such as `success: false`, `status: "failed"`, or meaningful non-empty `error`, `errors`, `exception`, `failed`, or `failure` values are present. Nested diagnostic/output content under `tool_response` is treated as command output context. Codex string `tool_response` is treated as command output and does not trigger `task.error` by keyword.

## Settings

`AppSettings` owns:

- `openPeonEnabled`
- `openPeonPacksDirectory`
- `openPeonActivePackName`
- `openPeonMasterVolume`
- `openPeonGlobalMuted`
- `openPeonMutedCategories`
- `openPeonDebounceMilliseconds`

The settings window presents these under the user-facing **Sound** tab. Keep the persisted `openPeon` names because they describe the CESP implementation and preserve existing preferences.
The pack directory setting also defines the plugin's scoped file root. If the resolved pack directory string is empty, the host must not create a scoped file root because `URL(fileURLWithPath: "")` resolves to the process working directory.

Defaults:

| Setting | Default |
|---|---|
| `openPeonEnabled` | `false` |
| `openPeonPacksDirectory` | `~/.openpeon/packs` |
| `openPeonActivePackName` | `nil` |
| `openPeonMasterVolume` | `0.7` |
| `openPeonGlobalMuted` | `false` |
| `openPeonMutedCategories` | `task.acknowledge`, `task.progress`, `session.end`, `user.spam` |
| `openPeonDebounceMilliseconds` | `1500` |

## Validation

MVP validation requires:

- `openpeon.json` exists and decodes.
- `cesp_version == "1.0"`.
- `name` matches `^[a-z0-9][a-z0-9_-]*$`.
- `version` is semver-compatible.
- `categories` is non-empty.
- Sound file paths are relative, contain no `..`, and resolve under the pack root.
- Audio files exist.
- Extensions are `.wav`, `.mp3`, or `.ogg`.
- Individual audio files are 1 MB or less.
- Pack total size is 50 MB or less.

Use `Int64` for file size checks. Stop pack-size enumeration once the limit is exceeded.

## Playback Rules

- Active pack missing: no-op.
- Category missing: no-op.
- Category muted or globally muted: no-op.
- Debounce applies per category.
- Sound selection avoids immediate repeat when possible.
- Master volume applies to each player.
- Runtime hook playback is requested by `OpenPeonPlugin` through generic `audio.playFile` with a plugin-scoped relative path. The plugin owns pack scan, validation, active-pack selection, and sound selection (via `CESPScopedPackResolver`/`OpenPeonRuntime`), reading files only through the scoped broker. The host validates only the scope/path/audio constraints before playback.
- Cheap gates (enabled, global/category mute, debounce) run before any broker file access, so the runtime scan frequency is bounded by the debounce interval. There is no scan cache: each debounce-passed category event re-scans the active pack, so packs added at runtime are picked up immediately.
- Playback failure is logged only and must not affect hook responses.
- `.ogg` is recognized by validation but currently warned as not playable. MVP playback promises `.wav` and `.mp3` only because `AVAudioPlayer` does not reliably support OGG on stock macOS.

## Threading

- Pack scan and validation must not run on the main thread. The runtime path runs broker file I/O on the broker actor (off `MainActor`); only `OpenPeonRuntime`'s debounce/selection coordination is `MainActor`-isolated.
- `OpenPeonRuntime` mutable debounce/selection state is `MainActor`-isolated so it stays serialized even when `PluginRunner` (an actor) re-enters `onEvent` at suspension points.
- `CESPAudioPlayer` mutable state and `AVAudioPlayer` lifecycle stay on `MainActor`; this avoids races and uses a run-loop thread for playback/delegate callbacks.
