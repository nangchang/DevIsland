---
name: devisland-markdown-rendering
description: Change DevIsland MarkdownView, agent message rendering, hook message formatting, diff rendering, attachment loading, heading handling, link/image safety, or tool output presentation. Use for MarkdownView, ToolMessageFormatter, Notch UI message displays, and related rendering tests.
---

# DevIsland Markdown Rendering

Use this for message rendering and diff display changes. Pair with `devisland-notch-ui` when the rendered content appears in the notch or expanded panel.

## Start

Read `AGENTS.md` and inspect existing behavior in:

- `DevIsland/UI/MarkdownView.swift`
- `DevIsland/Provider/ToolMessageFormatter.swift`
- `DevIsland/UI/NotchView.swift`
- `DevIsland/UI/NotchComponents.swift`
- `DevIslandTests/ToolMessageFormatterTests.swift`

Check recent tests before changing parsing or formatting.

## Rendering Rules

Preserve scalar hook message formatting. Do not flatten whitespace-only edits or meaningful line breaks.

For diff rendering:

- Preserve whitespace-only changes.
- Keep edit/replace labels visually distinct.
- Guard empty or malformed patches.
- Avoid crashes on invalid heading levels or malformed Markdown.

For security:

- Do not load remote images unexpectedly.
- Do not open links without explicit user intent.
- Treat command output and tool responses as untrusted display content.

## UI Fit

Rendered text must fit in compact panels and session lists. Avoid hero-scale type inside notch surfaces. Keep headings smaller and predictable inside compact UI.

If changing font size, weight, or spacing, verify readability in both collapsed/expanded contexts and session lists.

## Tests And Checks

Use focused tests for formatter behavior:

- `ToolMessageFormatterTests`
- Any `MarkdownView` or message rendering tests present in the repo

Run:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

For visual-only changes, describe the manual rendering cases to inspect.
