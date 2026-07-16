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

## Session Center And Fleet Radar

The menu item formerly named Session History opens **Session Center**, a cached standard
`NSWindow` with three tabs in this order:

1. **Fleet** (default): active parent sessions as attention-ranked cards, with sub-agents nested
   under their parent.
2. **Sessions**: the existing live/closed session table, search, favorites, and Quick Launch
   actions.
3. **Insights**: the existing durable session and approval summaries.

Fleet's larger adaptive grid and detailed Git inspection stay in the standard window. The normal
expanded notch session list may also render a compact cached summary on each Fleet group root:
branch or detached HEAD, clean/changed count, unmerged state, overlap risk, and stale evidence. The
approval/notification compact session list does not show these summaries.

The normal expanded **Agent Sessions** section header includes a direct Session Center button. It
collapses the regular notch before routing through the existing cached Session Center controller,
so repeated opens reuse the same window and its view models. The button is not rendered in the
approval/notification compact screen and does not change approval ownership or queue behavior.

Each presentation owns a `FleetRadarViewModel` that turns active sessions into scan descriptors,
while both share the `GitContextService` actor. The service performs bounded, read-only Git commands
and caches snapshots off the main thread. Session Center refreshes when its window appears, sessions
or labels change, or the user explicitly chooses Refresh. The notch view model refreshes only while
the normal expanded session content is visible and cancels presentation-owned work when that content
disappears. Fleet performs no network access, Git writes, background polling, or Git work on the main
thread or hook response path.

Closing Session Center marks its cached view as hidden and cancels presentation-owned Fleet refresh
work. Session/label changes while hidden do not start scans. Reopening the cached controller advances
the presentation generation and refreshes current session and Git state without reconstructing the
Sessions or Insights view models. The cached `NSWindow` title and all tab/card strings follow live
English/Korean language changes.

Fleet does not mutate `AppState` approval ownership, queue order, provider responses, notification
timers, or notch expansion. Informational notification auto-collapse remains governed by
`notchAutoCollapseDelay`; approval requests still never auto-collapse.

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
| `notchCompactLeadingSelection` | Region selection | `Compact Appearance` | `hidden` or registered provider | Exclusive provider for the compact Island's left region. |
| `notchCompactCenterSelection` | Region selection | `Compact Appearance` | `hidden` or registered provider | Exclusive provider for the compact Island's center region. |
| `notchCompactTrailingSelection` | Region selection | `Compact Appearance` | `hidden` or registered provider | Exclusive provider for the compact Island's right region. |

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
- Compact left/center/right content comes from one user-selected built-in provider per region. The default `CompactAppearancePlugin` owns the configured buddies and center text.
- The Host keeps the compact chrome and unread/pending dot. Plugins return cached declarative content only; they never render during the SwiftUI body pass.
- A transient provider failure keeps the last valid region cache. Disabling, safemode, expiration, or selecting `hidden` leaves the region empty rather than selecting an implicit fallback.

### Auto-Collapse Logic
- Managed in `AppState` using a `notificationTimer`.
- Informational events (starts, task completions, notifications) trigger the timer.
- Approval requests (`hasResponseHandler`) **do not** auto-collapse; they rely on the permission timeout.
- New events reset the timer if one is already running.

### Buddy Management
- `MascotState` handles the randomization logic for side buddies.
- Vertical offset is applied during collapsed rendering to allow centering buddies within custom-height Islands.

### Session Metadata
- Session labels, descriptions, and history favorites are stored by session ID in `AppState` via `UserDefaults`.
- Favorites are a Session History window filter and marker; they do not pin or reorder active sessions in the Island.
- The Session History window shows both live and closed sessions, with a status column distinguishing current work from ended sessions.
- Active session rows keep descriptions out of the main row layout and expose them as hover help text.
