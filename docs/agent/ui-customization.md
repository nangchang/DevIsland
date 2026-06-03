# Island UI Customization Specification

This document details the customizable appearance and behavior settings for the DevIsland Island panel and expanded window. The persisted setting keys still use the older `notch` prefix for compatibility.

## Visual Defaults

The default state is designed to be visually compatible with the macOS menu bar and notch area:

- **Compact Island size**: `260 x 32`
- **Expanded window size**: `692 x 300`
- **Panel opacity**: `100%` (fully opaque black)
- **Backdrop shadow**: Enabled
- **Notification auto-collapse**: `5 seconds`
- **Buddies**: Randomly selected from enabled kinds.

## Settings Window

User-facing settings are grouped as:

- **General**: language, terminal, startup, updates, and reset.
- **Island**: display target, appearance, compact/expanded size, buddies, request display, and expand/collapse behavior.
- **Approval**: automatic approvals, permission timeout, replay retention, and fallback policy.
- **Sound**: OpenPeon CESP sound packs, playback, categories, and validation.
- **Integrations**: opt-in app integrations.
- **Advanced**: provider, Bridge / IPC, and experimental PTY settings.

## Appearance Settings

These settings are managed in `SettingsStore` and applied in `NotchView` / `NotchWindowController`.

| Setting | Type | Default | Range / Values | Description |
|---|---|---:|---|---|
| `notchPanelOpacity` | Double | `1.0` | `0.4...1.0` | Opacity of both collapsed and expanded panels. |
| `notchBackdropShadowEnabled` | Bool | `true` | `true / false` | Whether to draw a soft shadow behind the Island. |
| `collapsedNotchWidth` | Double | `260` | `180...420` | Base width of the compact Island. |
| `collapsedNotchHeight` | Double | `32` | `24...56` | Base height of the compact Island. |
| `expandedNotchWidth` | Double | `692` | `610...1200` | Width of the expanded dashboard window. |
| `expandedNotchHeight` | Double | `300` | `240...720` | Height of the expanded dashboard window. |
| `notchCharacterVerticalOffset` | Double | `4` | `-8...12` | Vertical alignment of buddies in the compact Island. |

## Behavior Settings

| Setting | Type | Default | Values | Description |
|---|---|---|---|---|
| `notchAutoCollapseDelay` | Enum | `5 seconds` | `off, 3s, 5s, 10s, 30s` | Delay before auto-collapsing informational notifications. |
| `left/rightCharacterMode` | Enum | `random` | `hidden, random, specific` | Visibility and selection mode for side buddies. |

## Implementation Details

### Rendering
- `NotchView` uses `settings.notchPanelOpacity` to fill the background shape.
- Shadows are implemented as a downward-offset SwiftUI blur layer behind the main shape to avoid native `NSPanel` shadow artifacts.
- `NotchLayout` provides dynamic size calculations based on current settings for both window frames and hit testing.

### Auto-Collapse Logic
- Managed in `AppState` using a `notificationTimer`.
- Informational events (starts, task completions, notifications) trigger the timer.
- Approval requests (`currentResponseHandler != nil`) **do not** auto-collapse; they rely on the permission timeout.
- New events reset the timer if one is already running.

### Buddy Management
- `MascotState` handles the randomization logic for side buddies.
- Vertical offset is applied during collapsed rendering to allow centering buddies within custom-height Islands.
