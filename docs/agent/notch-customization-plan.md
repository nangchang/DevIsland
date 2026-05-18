# Notch Customization Plan

## Goal

Give users direct control over the notch and expanded window appearance while preserving the current default experience.

The default state must remain visually compatible with the existing app:

- Collapsed notch size: `260 x 32`
- Expanded window size: `692 x 300`
- Panel opacity: `100%`
- Backdrop shadow: enabled
- Notification auto-collapse: `5 seconds`
- Characters: current random left/right behavior

## Current Code Shape

- `NotchView.swift` renders both collapsed and expanded backgrounds with `NotchShape(...).fill(Color.black)`.
- `NotchWindowController.swift` owns the collapsed and expanded `NSPanel` instances. Both currently use fixed sizes and `hasShadow = false`.
- `SettingsStore.swift` persists app settings in `UserDefaults` through `AppSettings`.
- `SettingsWindow.swift` already has a Display tab with Notch and Notch characters sections.
- `AppState.swift` currently auto-collapses informational expanded notifications after a hard-coded `5.0` seconds.

## Settings

Add these settings to `AppSettings` and persist them through `SettingsStore`.

| Setting | Default | Range / Values | Applies To |
|---|---:|---|---|
| `notchPanelOpacity` | `1.0` | `0.4...1.0` | Collapsed notch and expanded window |
| `notchBackdropShadowEnabled` | `true` | `true / false` | Collapsed notch and expanded window |
| `collapsedNotchWidth` | `260` | `180...420` | Collapsed notch |
| `collapsedNotchHeight` | `32` | `24...56` | Collapsed notch |
| `expandedNotchWidth` | `692` | `560...1200` | Expanded window |
| `expandedNotchHeight` | `300` | `240...720` | Expanded window |
| `notchAutoCollapseDelay` | `5 seconds` | `off, 3, 5, 10, 30 seconds` | Expanded informational notifications only |
| `notchCharacterVerticalOffset` | `4` | `-8...12` | Collapsed notch characters |

Extend `NotchCharacterMode` with a hidden mode so each side character can be disabled independently.

## Display Settings UI

Add controls to Display > Notch:

- Panel opacity slider, displayed as a percentage. This setting applies to both the collapsed notch and expanded window.
- Backdrop shadow toggle. Use a downward-offset SwiftUI blur layer with bottom-only panel breathing room because native panel shadows can draw a visible top-edge line.
- Collapsed notch width slider.
- Collapsed notch height slider.
- Expanded window width slider.
- Expanded window height slider.
- Auto-collapse picker.
- Character vertical position slider.

Add hidden character support to Display > Notch characters by including a hidden mode in the existing left/right mode pickers.

## Rendering And Window Behavior

- Replace fixed `Color.black` with `Color.black.opacity(settings.notchPanelOpacity)` in `NotchView`.
- Replace fixed notch size constants with base sizes plus settings-derived size helpers.
- Ensure both collapsed and expanded panels use the same opacity setting through SwiftUI rendering.
- Keep native `NSPanel.hasShadow` disabled for both panels. Apply `notchBackdropShadowEnabled` as a downward-offset blur behind the notch shape, with extra panel height below the visual shape so the top edge stays clean.
- Update panel frames immediately when size or shadow settings change.
- Ensure `NotchHostingView.notchHitRect()` uses the same settings-derived size as rendering and window frames.
- Add a settings button to the expanded header that opens `AppWindowRouter.showSettings()`.
- Apply `notchCharacterVerticalOffset` to collapsed left/right character vertical alignment.
- Scale expansion and collapse durations with the configured expanded window size so large windows do not feel abrupt. Keep the base duration at the default size and cap the multiplier.

## Auto-Collapse Behavior

- Replace the hard-coded `5.0` notification timer in `AppState` with `notchAutoCollapseDelay`.
- Do not auto-collapse approval requests that have a response handler. Those continue to use the existing permission timeout.
- If auto-collapse is off, do not create the notification timer.
- If a new informational event arrives, cancel and recreate the timer using the latest setting.

## Test Plan

- Update `SettingsStoreTests` for:
  - Defaults.
  - Persist and reload.
  - Invalid persisted values falling back to defaults.
- Add or update app-state tests for auto-collapse delay when practical.
- Run:

```bash
./scripts/run-tests.sh
```

For compile verification without interrupting a live app:

```bash
./scripts/build_and_run.sh --no-kill --no-run
```
