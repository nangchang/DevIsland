# Caffeine Implementation

Caffeine is a built-in system plugin that prevents display and system idle sleep while the Mac is connected to AC power. It is not tied to whether a session currently exists. Session activity affects the feature only when the optional session idle timeout is enabled.

## Runtime Behavior

Caffeine holds the sleep assertion only when every applicable condition permits it:

1. The Caffeine master setting is enabled.
2. The optional session idle timeout has not expired.
3. The current Wi-Fi is not in the excluded SSID list.
4. The Mac is connected to AC power.
5. The battery is not in the low-battery state.

The first failing condition releases the assertion and becomes the status reason shown in the menu.

Low-battery handling uses hysteresis:

- Enter low-battery state at 20% or below.
- Leave low-battery state at 23% or above.
- A Mac without a battery reports no battery level and skips this condition.

If the current SSID is unavailable, the excluded-SSID condition cannot match and the remaining conditions still apply.

## Session Idle Timeout

Session idle timeout is optional and disabled by default. When enabled, Caffeine releases the assertion after the configured number of minutes without session activity.

- Activity time is the latest lastActiveAt value among active sessions.
- When all sessions end, the last known activity time remains the timeout baseline.
- If no session activity has been observed since startup, the coordinator start time is the baseline.
- New activity clears the timed-out state and schedules a new deadline.
- Disabling the setting clears the timed-out state immediately.

The Settings UI accepts 1 through 120 minutes and defaults to 5 minutes.

## Architecture

Policy and system side effects are intentionally separated:

| Component | Responsibility |
|---|---|
| CaffeinePlugin | Sole owner of the enable, timeout, SSID, AC power, and battery decision policy. Produces power.preventIdleSleep effects and menu contributions. |
| CaffeineCoordinator | Combines host signals into PluginPowerStatus, schedules the session timeout, applies plugin effects, and reports effect results. It does not decide policy. |
| PowerSourceMonitor | Reads AC power and battery level through IOKit and preserves the last valid state on transient failures. |
| WifiSSIDMonitor | Tracks the connected SSID through CoreWLAN and provides asynchronous nearby-network scans. |
| SleepAssertion | Owns one idempotent IOPM assertion and releases it on shutdown or deinitialization. |
| AppWiring | Owns the monitors and connects settings, session activity, PluginHost, and the coordinator at AppState init. |

The assertion type is kIOPMAssertionTypePreventUserIdleDisplaySleep with the name DevIsland.Caffeine. Preventing display idle sleep also prevents system idle sleep.

## Settings

Settings are persisted by SettingsStore.

| Setting | Default | Meaning |
|---|---:|---|
| caffeineEnabled | false | Master feature switch. |
| caffeineExcludedSSIDs | empty | Connected SSIDs that force Caffeine off. |
| caffeineSessionTimeoutEnabled | false | Whether session inactivity can force Caffeine off. |
| caffeineSessionTimeoutMinutes | 5 | Session inactivity deadline in minutes. |

Plugin enablement and safemode are additional host guards. They do not replace the persisted Caffeine master setting.

## UI

- The Features settings pane shows live AC power, battery, SSID, and assertion state.
- The pane owns the master switch, session timeout controls, and excluded Wi-Fi list.
- Nearby Wi-Fi scanning requires Location permission on modern macOS. Manual SSID entry remains available when scanning fails.
- The menu-bar plugin contribution shows the current reason and a toggle.
- The app status icon reflects whether the assertion is currently held.

Caffeine does not add a separate menu-bar item or expose a global keyboard shortcut.

## Lifecycle and Failure Handling

- Power and Wi-Fi monitors start during AppState setup (AppWiring.wireCaffeine).
- Assertion acquisition is idempotent.
- App shutdown cancels the timeout, removes subscriptions, and releases the assertion.
- IOKit acquisition failures are returned to the plugin as effect results and displayed as a failure status.
- Wi-Fi scanning runs off the main thread; hook and approval processing do not depend on Caffeine.

## Key Files

| File | Responsibility |
|---|---|
| DevIsland/Plugins/BuiltIn/Caffeine/CaffeinePlugin.swift | Policy and menu contribution |
| DevIsland/Plugins/BuiltIn/Caffeine/CaffeineCoordinator.swift | Signal/effect adapter and session timeout |
| DevIsland/Plugins/BuiltIn/Caffeine/PowerSourceMonitor.swift | AC and battery monitoring |
| DevIsland/Plugins/BuiltIn/Caffeine/WifiSSIDMonitor.swift | SSID tracking and scanning |
| DevIsland/Plugins/BuiltIn/Caffeine/SleepAssertion.swift | IOPM assertion ownership |
| DevIsland/Settings/CaffeineSettings.swift | Settings UI |
| DevIsland/Settings/SettingsStore.swift | Persistence and defaults |
| DevIsland/Core/AppWiring.swift | Runtime wiring |

## Verification

Policy behavior is covered by CaffeinePluginTests and persistence defaults by SettingsStoreTests. Changes to timeout scheduling should add deterministic coordinator tests because the current coordinator uses Date and Timer directly.
