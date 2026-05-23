# UI Customization Specification

This document details the customizable appearance and behavior settings for the DevIsland notch and expanded window.

## Visual Defaults

The default state is designed to be visually compatible with the macOS notch area:

- **Collapsed notch size**: `260 x 32`
- **Expanded window size**: `692 x 300`
- **Panel opacity**: `100%` (fully opaque black)
- **Backdrop shadow**: Enabled
- **Notification auto-collapse**: `5 seconds`
- **Characters**: Randomly selected from enabled kinds.

## Appearance Settings

These settings are managed in `SettingsStore` and applied in `NotchView` / `NotchWindowController`.

| Setting | Type | Default | Range / Values | Description |
|---|---|---:|---|---|
| `notchPanelOpacity` | Double | `1.0` | `0.4...1.0` | Opacity of both collapsed and expanded panels. |
| `notchBackdropShadowEnabled` | Bool | `true` | `true / false` | Whether to draw a soft shadow behind the notch. |
| `collapsedNotchWidth` | Double | `260` | `180...420` | Base width of the collapsed notch. |
| `collapsedNotchHeight` | Double | `32` | `24...56` | Base height of the collapsed notch. |
| `expandedNotchWidth` | Double | `692` | `560...1200` | Width of the expanded dashboard window. |
| `expandedNotchHeight` | Double | `300` | `240...720` | Height of the expanded dashboard window. |
| `notchCharacterVerticalOffset` | Double | `4` | `-8...12` | Vertical alignment of characters in the collapsed notch. |

## Behavior Settings

| Setting | Type | Default | Values | Description |
|---|---|---|---|---|
| `notchAutoCollapseDelay` | Enum | `5 seconds` | `off, 3s, 5s, 10s, 30s` | Delay before auto-collapsing informational notifications. |
| `left/rightCharacterMode` | Enum | `random` | `hidden, random, specific` | Visibility and selection mode for side characters. |

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

### Character Management
- `MascotState` handles the randomization logic for side characters.
- Vertical offset is applied during collapsed rendering to allow centering characters within custom-height notches.
