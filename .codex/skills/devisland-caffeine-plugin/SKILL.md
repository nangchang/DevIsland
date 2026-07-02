---
name: devisland-caffeine-plugin
description: Change DevIsland Caffeine sleep-prevention behavior, AC/battery/SSID policy, session idle timeout, power.preventIdleSleep plugin effects, Caffeine settings UI, or related tests/docs. Use for DevIsland/Plugins/BuiltIn/Caffeine files, CaffeineSettings, SettingsStore Caffeine values, AppState runtime wiring, and Caffeine tests.
---

# DevIsland Caffeine Plugin

Use this for Caffeine work. Read `docs/agent/caffeine.md`, `docs/agent/stability-standards.md`, and the plugin architecture docs if the change touches plugin host/effect boundaries.

## Boundaries

Caffeine is a built-in system plugin. Keep policy and system side effects separated:

- `CaffeinePlugin` owns the enable, timeout, SSID, AC power, and battery decision policy.
- `CaffeineCoordinator` combines host signals, schedules session timeout, applies plugin effects, and reports effect results.
- `SleepAssertion`, `PowerSourceMonitor`, `WifiSSIDMonitor`, and `LocationPermissionRequester` stay host-owned.
- The plugin must not directly call IOKit, CoreWLAN, Location APIs, AppleScript, or create sleep assertions.

Plugin enablement and safemode are host guards. They do not replace `SettingsStore.caffeineEnabled`, and disabling/safemode must release any held assertion.

## Policy Rules

Preserve the documented conditions unless intentionally changing behavior:

- Master setting enabled.
- Optional session idle timeout not expired.
- Current Wi-Fi not in the excluded SSID list.
- AC power connected.
- Battery not in low-battery state.

Low-battery hysteresis enters at 20% or below and exits at 23% or above. Macs without a battery skip that condition.

Session idle timeout is optional, defaults off, accepts 1...120 minutes, and uses the latest active-session activity or coordinator start time as the baseline.

## Runtime And UI

Inspect these files before editing the matching area:

- `DevIsland/Plugins/BuiltIn/Caffeine/CaffeinePlugin.swift`
- `DevIsland/Plugins/BuiltIn/Caffeine/CaffeineCoordinator.swift`
- `DevIsland/Plugins/BuiltIn/Caffeine/PowerSourceMonitor.swift`
- `DevIsland/Plugins/BuiltIn/Caffeine/WifiSSIDMonitor.swift`
- `DevIsland/Plugins/BuiltIn/Caffeine/SleepAssertion.swift`
- `DevIsland/Settings/CaffeineSettings.swift`
- `DevIsland/Settings/SettingsStore.swift`
- `DevIsland/Core/AppState.swift`

Wi-Fi scanning and power monitoring must not block hook or approval processing. Assertion acquisition is idempotent; shutdown releases the assertion and cancels timers/subscriptions.

## Tests

Use or update:

- `CaffeinePluginTests`
- `SettingsStoreTests`
- Focused coordinator or monitor tests when timeout scheduling or signal handling becomes deterministic enough to test.

Run `./scripts/run-tests.sh` before handoff.
