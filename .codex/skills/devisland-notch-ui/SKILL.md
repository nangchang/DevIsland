---
name: devisland-notch-ui
description: Change DevIsland notch UI, expanded panel, notification auto-collapse, session list display, character settings, Markdown rendering, modal presentation, or NSPanel/window behavior. Use for NotchView, NotchWindowController, NotchComponents, MarkdownView, Settings UI, and related AppState UI state.
---

# DevIsland Notch UI

Use this for notch and panel-facing UI changes. Read `docs/agent/ui-customization.md`; read `docs/agent/stability-standards.md` if timers, focus, or async work are involved.

## UI State Rules

Approval requests do not auto-collapse. Informational notifications may auto-collapse according to settings. New events should reset the notification timer predictably.

Do not let UI changes alter approval queue order or provider decisions. Visual state must reflect `AppState`, not become a second source of truth.

Plugin UI contributions render through `PluginContributionRenderer` with cached contributions — do not bypass the cache. Keep per-second-changing elements (timeAgo text, plugin badges) in child views that do not observe the parent, or open context menus will flicker (see `SessionRowTimeAgo`, `SessionRowPluginBadges`).

## Window And Modal Rules

DevIsland is an `LSUIElement` app with notch-style `NSPanel` behavior. When changing windows, panels, sheets, or modal alerts:

- Keep notch hit testing and click-through behavior intentional.
- Avoid blocking modal alerts behind the notch panel.
- Prefer existing helpers such as modal presentation utilities when present.
- Verify expanded and collapsed window sizing after settings changes.

## Settings

When adding UI settings:

- Add storage in `SettingsStore` / `AppSettings`.
- Add focused `SettingsStoreTests` coverage.
- Update `docs/agent/ui-customization.md` when defaults, ranges, or behavior change.
- Keep setting ranges aligned with documented values.

## Markdown And Message Rendering

For agent message rendering, preserve security constraints:

- Do not load remote images unexpectedly.
- Do not open links without user intent.
- Preserve whitespace and scalar hook message formatting.
- Keep diff rendering legible and avoid crashes on malformed headings or patches.

## Verification

Run focused tests where available, then:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

For visual behavior that tests cannot cover, describe the manual scenario to verify.
