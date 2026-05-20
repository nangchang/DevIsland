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

| Module | Responsibility |
|---|---|
| `CESPModels.swift` | Manifest, category, sound, validation, and runtime pack models |
| `CESPPackStore.swift` | Pack directory reload, background scan, active pack selection |
| `CESPPackValidator.swift` | Manifest/file/path/audio validation |
| `CESPEventMapper.swift` | Hook event to CESP category mapping |
| `CESPAudioPlayer.swift` | Sound selection, debounce, mute, volume, playback |

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

Failure detection is intentionally conservative. Claude tool execution failure is detected through `PostToolUseFailure`; Claude `PostToolUse` does not produce sound feedback even when stdout/stderr mention errors. Codex `PostToolUse` is per-tool output rather than turn completion, so it does not produce completion sound feedback unless structured machine-readable `success: false`, `status: "failed"`, or meaningful non-empty `error`, `errors`, `exception`, `failed`, or `failure` values map it to `task.error`. Codex string `tool_response` is treated as command output and does not trigger `task.error` by keyword.

## Settings

`AppSettings` owns:

- `openPeonEnabled`
- `openPeonPacksDirectory`
- `openPeonActivePackName`
- `openPeonMasterVolume`
- `openPeonGlobalMuted`
- `openPeonMutedCategories`
- `openPeonDebounceMilliseconds`

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
- Playback failure is logged only and must not affect hook responses.
- `.ogg` is recognized by validation but currently warned as not playable. MVP playback promises `.wav` and `.mp3` only because `AVAudioPlayer` does not reliably support OGG on stock macOS.

## Threading

- Pack scan and validation must not run on the main thread.
- `CESPAudioPlayer` mutable state and `AVAudioPlayer` lifecycle stay on `MainActor`; this avoids races and uses a run-loop thread for playback/delegate callbacks.
