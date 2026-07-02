# Security Review: DevIsland

## Scope

Repository-wide security scan of DevIsland macOS app, bridge scripts, approval proxy, update flow, and plugin resources.

- Scan mode: repository
- Target kind: git_revision
- Target ID: target_sha256_cb95413227831bef1a6181e4eff97ac7d92ebe310e9c648a32cd42d712caa8f1
- Revision: 4a949c4eebf094d466b08b8755f6adb14f1ebb59
- Inventory strategy: repository
- Included paths: .
- Excluded paths: none
- Runtime or test status: Static review with targeted multi-agent validation; no source changes were made.
- Artifacts reviewed: Swift app sources, Approval policy and persistence layer, Hook provider bridge scripts, Updater implementation, OpenPeon plugin resource handling, Markdown and HTML rendering paths
- Scan context: The app mediates CLI hook approvals for Claude, Codex, Gemini, and Antigravity, and performs local update installation from GitHub release assets.

Limitations and exclusions:
- Dynamic exploit execution was not performed; findings were validated by static control-flow and data-flow review.

### Scan Summary

| Field | Value |
| --- | --- |
| Reportable findings | 4 |
| Severity mix | high: 2, medium: 2 |
| Confidence mix | high: 4 |
| Coverage | complete |
| Validation mode | Codex Security repository scan |

Canonical artifacts: `scan-manifest.json`, `findings.json`, and `coverage.json`. This report is a deterministic projection of those files.

## Threat Model

Highest-risk boundaries are shell command approval decisions, provider response semantics, local hook environment inputs, update asset trust, IPC authorization, and file/resource loading.

### Assets

- User workstation command execution authority
- Persistent approval and deny rules
- Provider hook responses
- Installed DevIsland application bundle

### Trust Boundaries

- AI/provider tool request payloads into DevIsland approval logic
- Hook process environment into bridge metadata enrichment
- Remote GitHub release metadata and DMG assets into local app replacement
- Plugin and attachment paths into local file handling

### Attacker Capabilities

- Influence an AI agent prompt or repository contents to request commands
- Control hook environment variables in a local terminal session
- Compromise or replace update release assets in the distribution channel

### Security Objectives

- Deny rules must take precedence over convenience pass paths
- Auto-allow policy must not expand read/build prefixes into arbitrary shell execution
- Updater must install only authentic DevIsland bundles
- Bridge metadata collection must not execute attacker-controlled script fragments

### Assumptions

- Local malware with full user privileges is out of scope except where the app amplifies trust across update or approval boundaries.

## Findings

| Finding | Severity | Confidence |
| --- | --- | --- |
| [Seeded commandPrefix allow rules match shell commands with unsafe suffixes](#finding-1) | high | high |
| [Updater installs downloaded DMG without verifying the replacement app signature](#finding-2) | high | high |
| [Focused-terminal pass bypasses persistent deny policy evaluation](#finding-3) | medium | high |
| [CMUX_WORKSPACE_ID is interpolated into shell bridge AppleScript without escaping](#finding-4) | medium | high |

### Confidence Scale

| Label | Meaning |
| --- | --- |
| high | Direct evidence supports the finding with no material unresolved blocker. |
| medium | Evidence supports a plausible issue, but material runtime or reachability proof remains. |
| low | Evidence is incomplete and the item is retained only for explicit follow-up. |

<a id="finding-1"></a>

### [1] Seeded commandPrefix allow rules match shell commands with unsafe suffixes

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | high |
| Confidence rationale | The matching logic, seeded persistent allow rules, and lack of shell token boundary checks are directly visible in source. |
| Category | Command approval bypass |
| CWE | CWE-78, CWE-693 |
| Affected lines | DevIsland/Approval/ApprovalPolicyEngine.swift:63-66, DevIsland/Approval/SQLiteApprovalStore.swift:817-854 |

#### Summary

Persistent allow rules for Bash and shell use raw command.hasPrefix matching, so commands that begin with a seeded safe prefix can append shell metacharacters or extra tokens and still bypass manual approval.

#### Root Cause

The authorization predicate treats a shell command prefix as sufficient proof of safety without parsing shell syntax or enforcing token boundaries.

**Raw command prefix match** — `DevIsland/Approval/ApprovalPolicyEngine.swift:63-66`

commandPrefix allows a rule when the raw command string starts with the rule pattern.

```swift
        case .commandPrefix:
            guard rule.toolName == toolName,
                  let command = toolInput?["command"] as? String else { return false }
            return command.hasPrefix(rule.pattern)
```

**Persistent seeded shell allow rules** — `DevIsland/Approval/SQLiteApprovalStore.swift:817-854`

The migration installs broad persistent allow prefixes for Bash and shell, including gh, xcodebuild, xcodegen, bash scripts, and screencapture.

```swift
    private func migrateToVersion4() throws {
        let seed: [(id: String, toolName: String, pattern: String)] = [
            // Bash variants
            ("A1B2C3D4-0001-0000-0000-000000000001", "Bash", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000002", "Bash", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000003", "Bash", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000004", "Bash", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000005", "Bash", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000006", "Bash", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000007", "Bash", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000008", "Bash", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000009", "Bash", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000000A", "Bash", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000000B", "Bash", "screencapture /tmp/"),
            // shell variants (Codex uses 'shell' as tool_name)
            ("A1B2C3D4-0001-0000-0000-000000000011", "shell", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000012", "shell", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000013", "shell", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000014", "shell", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000015", "shell", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000016", "shell", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000017", "shell", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000018", "shell", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000019", "shell", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000001A", "shell", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000001B", "shell", "screencapture /tmp/"),
        ]
        for entry in seed {
            try execute(
                """
                INSERT OR IGNORE INTO rules
                    (id, provider, tool_name, match_kind, pattern, action, scope,
                     risk_floor, workspace_root, created_at, expires_at, enabled)
                VALUES (?, 'any', ?, 'commandPrefix', ?, 'allow', 'persistent',
                        NULL, NULL, 0, NULL, 1)
                """,
                [entry.id, entry.toolName, entry.pattern]
            )
```

#### Validation

Validated by tracing policy evaluation from seeded commandPrefix rows to ApprovalPolicyEngine.matches; there is no rejection of separators, pipes, subshells, or suffix tokens.

**Raw command prefix match** — `DevIsland/Approval/ApprovalPolicyEngine.swift:63-66`

commandPrefix allows a rule when the raw command string starts with the rule pattern.

```swift
        case .commandPrefix:
            guard rule.toolName == toolName,
                  let command = toolInput?["command"] as? String else { return false }
            return command.hasPrefix(rule.pattern)
```

**Persistent seeded shell allow rules** — `DevIsland/Approval/SQLiteApprovalStore.swift:817-854`

The migration installs broad persistent allow prefixes for Bash and shell, including gh, xcodebuild, xcodegen, bash scripts, and screencapture.

```swift
    private func migrateToVersion4() throws {
        let seed: [(id: String, toolName: String, pattern: String)] = [
            // Bash variants
            ("A1B2C3D4-0001-0000-0000-000000000001", "Bash", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000002", "Bash", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000003", "Bash", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000004", "Bash", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000005", "Bash", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000006", "Bash", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000007", "Bash", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000008", "Bash", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000009", "Bash", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000000A", "Bash", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000000B", "Bash", "screencapture /tmp/"),
            // shell variants (Codex uses 'shell' as tool_name)
            ("A1B2C3D4-0001-0000-0000-000000000011", "shell", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000012", "shell", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000013", "shell", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000014", "shell", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000015", "shell", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000016", "shell", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000017", "shell", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000018", "shell", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000019", "shell", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000001A", "shell", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000001B", "shell", "screencapture /tmp/"),
        ]
        for entry in seed {
            try execute(
                """
                INSERT OR IGNORE INTO rules
                    (id, provider, tool_name, match_kind, pattern, action, scope,
                     risk_floor, workspace_root, created_at, expires_at, enabled)
                VALUES (?, 'any', ?, 'commandPrefix', ?, 'allow', 'persistent',
                        NULL, NULL, 0, NULL, 1)
                """,
                [entry.id, entry.toolName, entry.pattern]
            )
```

#### Dataflow

The canonical finding records the affected path at DevIsland/Approval/ApprovalPolicyEngine.swift:63-66, DevIsland/Approval/SQLiteApprovalStore.swift:817-854, but no expanded source-to-sink narrative was recorded.

**Raw command prefix match** — `DevIsland/Approval/ApprovalPolicyEngine.swift:63-66`

commandPrefix allows a rule when the raw command string starts with the rule pattern.

```swift
        case .commandPrefix:
            guard rule.toolName == toolName,
                  let command = toolInput?["command"] as? String else { return false }
            return command.hasPrefix(rule.pattern)
```

**Persistent seeded shell allow rules** — `DevIsland/Approval/SQLiteApprovalStore.swift:817-854`

The migration installs broad persistent allow prefixes for Bash and shell, including gh, xcodebuild, xcodegen, bash scripts, and screencapture.

```swift
    private func migrateToVersion4() throws {
        let seed: [(id: String, toolName: String, pattern: String)] = [
            // Bash variants
            ("A1B2C3D4-0001-0000-0000-000000000001", "Bash", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000002", "Bash", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000003", "Bash", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000004", "Bash", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000005", "Bash", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000006", "Bash", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000007", "Bash", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000008", "Bash", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000009", "Bash", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000000A", "Bash", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000000B", "Bash", "screencapture /tmp/"),
            // shell variants (Codex uses 'shell' as tool_name)
            ("A1B2C3D4-0001-0000-0000-000000000011", "shell", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000012", "shell", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000013", "shell", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000014", "shell", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000015", "shell", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000016", "shell", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000017", "shell", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000018", "shell", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000019", "shell", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000001A", "shell", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000001B", "shell", "screencapture /tmp/"),
        ]
        for entry in seed {
            try execute(
                """
                INSERT OR IGNORE INTO rules
                    (id, provider, tool_name, match_kind, pattern, action, scope,
                     risk_floor, workspace_root, created_at, expires_at, enabled)
                VALUES (?, 'any', ?, 'commandPrefix', ?, 'allow', 'persistent',
                        NULL, NULL, 0, NULL, 1)
                """,
                [entry.id, entry.toolName, entry.pattern]
            )
```

#### Reachability

Reachability was not recorded beyond the canonical finding summary and affected locations.

#### Severity

**High** — A malicious prompt or repository instruction can turn trusted read/build prefixes into arbitrary local command execution through the originating CLI approval path.

Additional runtime or deployment evidence could raise or lower this severity.

#### Remediation

Parse shell commands into an argv-level policy or require exact token-boundary matches for allowed subcommands. Reject shell control operators and unsafe suffixes for commandPrefix allow rules, and add regression tests for appended semicolons, pipes, command substitution, and extra subcommands.

Tests:
- A command beginning with gh pr view followed by a semicolon and another command must not auto-allow.
- Seeded allow commands with only permitted arguments should still pass.
- User-created commandPrefix allow rules should use the same safe boundary behavior.

<a id="finding-2"></a>

### [2] Updater installs downloaded DMG without verifying the replacement app signature

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | high |
| Confidence rationale | The download, mount, app selection, quarantine removal, and replacement steps are visible with no intervening signature verification calls. |
| Category | Insecure update |
| CWE | CWE-494, CWE-345 |
| Affected lines | DevIsland/Utility/UpdateChecker.swift:146-150, DevIsland/Utility/UpdateChecker.swift:232-242, DevIsland/Utility/UpdateChecker.swift:280-312 |

#### Summary

The updater chooses a GitHub release DMG, mounts it with hdiutil -noverify, accepts the first .app, strips quarantine from the staged bundle, and replaces the installed app without verifying bundle ID, Team ID, code signature, or notarization.

#### Root Cause

The update trust decision is bound to GitHub asset selection and HTTP status rather than cryptographic verification of the staged application bundle.

**First DMG release asset is trusted** — `DevIsland/Utility/UpdateChecker.swift:146-150`

The stable update path selects the first DMG asset from release metadata.

```swift
        guard let asset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
              let urlStr = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlStr) else {
            throw UpdateError.noAsset
        }
```

**Downloaded URL is installed** — `DevIsland/Utility/UpdateChecker.swift:232-242`

The downloaded temporary file is passed directly into installFromDMG.

```swift
            let (tempURL, downloadResponse) = try await URLSession.shared.download(from: downloadURL)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (downloadResponse as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpError(code)
            }

            updateStatusText = L10n.shared.updateInstalling
            downloadProgress = 0.5
            let destURL = try await Task.detached(priority: .userInitiated) {
                try UpdateChecker.installFromDMG(downloaded: tempURL)
            }.value
```

**DMG app is copied and installed without signature checks** — `DevIsland/Utility/UpdateChecker.swift:280-312`

The installer disables DMG verification, chooses the first app, removes quarantine, and replaces the app without codesign or notarization validation.

```swift
        let mountCode = shell("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint.path,
            "-quiet"
        ])
        guard mountCode == 0 else { throw UpdateError.mountFailed(mountCode) }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appSrc = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let appsDir = fm.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let bundleURL = Bundle.main.bundleURL.standardized
        let destURL: URL
        if bundleURL.path.hasPrefix(appsDir.standardized.path + "/") {
            destURL = bundleURL
        } else {
            destURL = appsDir.appendingPathComponent(appSrc.lastPathComponent)
        }

        // 스테이징 경로에 먼저 복사한 뒤 원자적으로 교체 → 복사 실패 시 기존 앱 보존
        let stagingURL = tmpDir.appendingPathComponent("DevIsland-staging-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: appSrc, to: stagingURL)
        shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagingURL.path])

        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(destURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: destURL)
        }
```

#### Validation

Validated by searching the update path for Security.framework, codesign, spctl, SecStaticCode, Team ID, bundle ID, and notarization checks before replacement; none are present in the install path.

**Downloaded URL is installed** — `DevIsland/Utility/UpdateChecker.swift:232-242`

The downloaded temporary file is passed directly into installFromDMG.

```swift
            let (tempURL, downloadResponse) = try await URLSession.shared.download(from: downloadURL)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (downloadResponse as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpError(code)
            }

            updateStatusText = L10n.shared.updateInstalling
            downloadProgress = 0.5
            let destURL = try await Task.detached(priority: .userInitiated) {
                try UpdateChecker.installFromDMG(downloaded: tempURL)
            }.value
```

**DMG app is copied and installed without signature checks** — `DevIsland/Utility/UpdateChecker.swift:280-312`

The installer disables DMG verification, chooses the first app, removes quarantine, and replaces the app without codesign or notarization validation.

```swift
        let mountCode = shell("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint.path,
            "-quiet"
        ])
        guard mountCode == 0 else { throw UpdateError.mountFailed(mountCode) }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appSrc = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let appsDir = fm.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let bundleURL = Bundle.main.bundleURL.standardized
        let destURL: URL
        if bundleURL.path.hasPrefix(appsDir.standardized.path + "/") {
            destURL = bundleURL
        } else {
            destURL = appsDir.appendingPathComponent(appSrc.lastPathComponent)
        }

        // 스테이징 경로에 먼저 복사한 뒤 원자적으로 교체 → 복사 실패 시 기존 앱 보존
        let stagingURL = tmpDir.appendingPathComponent("DevIsland-staging-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: appSrc, to: stagingURL)
        shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagingURL.path])

        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(destURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: destURL)
        }
```

#### Dataflow

The canonical finding records the affected path at DevIsland/Utility/UpdateChecker.swift:146-150, DevIsland/Utility/UpdateChecker.swift:232-242, DevIsland/Utility/UpdateChecker.swift:280-312, but no expanded source-to-sink narrative was recorded.

**First DMG release asset is trusted** — `DevIsland/Utility/UpdateChecker.swift:146-150`

The stable update path selects the first DMG asset from release metadata.

```swift
        guard let asset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
              let urlStr = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlStr) else {
            throw UpdateError.noAsset
        }
```

**Downloaded URL is installed** — `DevIsland/Utility/UpdateChecker.swift:232-242`

The downloaded temporary file is passed directly into installFromDMG.

```swift
            let (tempURL, downloadResponse) = try await URLSession.shared.download(from: downloadURL)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (downloadResponse as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpError(code)
            }

            updateStatusText = L10n.shared.updateInstalling
            downloadProgress = 0.5
            let destURL = try await Task.detached(priority: .userInitiated) {
                try UpdateChecker.installFromDMG(downloaded: tempURL)
            }.value
```

**DMG app is copied and installed without signature checks** — `DevIsland/Utility/UpdateChecker.swift:280-312`

The installer disables DMG verification, chooses the first app, removes quarantine, and replaces the app without codesign or notarization validation.

```swift
        let mountCode = shell("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint.path,
            "-quiet"
        ])
        guard mountCode == 0 else { throw UpdateError.mountFailed(mountCode) }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appSrc = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let appsDir = fm.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let bundleURL = Bundle.main.bundleURL.standardized
        let destURL: URL
        if bundleURL.path.hasPrefix(appsDir.standardized.path + "/") {
            destURL = bundleURL
        } else {
            destURL = appsDir.appendingPathComponent(appSrc.lastPathComponent)
        }

        // 스테이징 경로에 먼저 복사한 뒤 원자적으로 교체 → 복사 실패 시 기존 앱 보존
        let stagingURL = tmpDir.appendingPathComponent("DevIsland-staging-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: appSrc, to: stagingURL)
        shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagingURL.path])

        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(destURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: destURL)
        }
```

#### Reachability

Reachability was not recorded beyond the canonical finding summary and affected locations.

#### Severity

**High** — A compromised release asset or update channel can replace the local app with attacker-controlled code that runs with the user’s privileges.

Additional runtime or deployment evidence could raise or lower this severity.

#### Remediation

Verify the staged .app before removing quarantine or replacing the current app. Enforce expected bundle identifier, Team ID or designated requirement, valid code signature, hardened runtime, and notarization status using Security.framework or codesign/spctl, and fail closed on mismatch.

Tests:
- A DMG containing an unsigned .app must be rejected before replacement.
- A signed app with the wrong Team ID or bundle ID must be rejected.
- A valid DevIsland-signed and notarized update should still install successfully.

<a id="finding-3"></a>

### [3] Focused-terminal pass bypasses persistent deny policy evaluation

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | The frontmost pass branch is ordered before policyDecision and the pass response is directly visible in source. |
| Category | Authorization policy bypass |
| CWE | CWE-863, CWE-693 |
| Affected lines | DevIsland/Core/AppState.swift:899-926, DevIsland/Core/AppState.swift:1339-1349, DevIsland/Provider/GeminiHookHandler.swift:6-8 |

#### Summary

The request evaluation hierarchy sends pass when the terminal is frontmost before checking persistent policy, so a matching deny rule can be skipped by the focused-terminal convenience path.

#### Root Cause

A UX convenience path has higher precedence than durable authorization policy, so explicit denies are not fail-closed.

**Terminal focus pass precedes persistent policy** — `DevIsland/Core/AppState.swift:899-926`

The focused-terminal branch returns before persistent policyDecision executes.

```swift
        // MARK: Phase 4: Evaluation Hierarchy
        // 우선순위: 터미널 포커스 pass → 영속 정책 → 휘발성 자동 승인 → 수동 승인 큐잉.
        isTerminalFrontmostAsync(
            appName: h.terminal.app,
            tty: h.terminal.tty,
            windowId: h.terminal.windowId,
            tabIndex: h.terminal.tabIndex,
            tmuxPane: h.terminal.tmuxPane,
            tmuxSocket: h.terminal.tmuxSocket,
            tmuxClient: h.terminal.tmuxClient
        ) { [weak self] isFrontmost in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(h.sessionId.prefix(8))")
                self.passRequestToFocusedTerminal(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
                return
            }

            // 2. Persistent Policy Check: Check SQLite for durable rules (Exact, Glob, Regex).
            if let policyDecision = self.policyDecision(
```

**Focused path emits pass** — `DevIsland/Core/AppState.swift:1339-1349`

The automatic response records action prompt with reason terminal focused and sends a pass payload.

```swift
        respondWithReplay(
            "{\"response\": \"pass\"}",
            responseHandler: request.responseHandler,
            hookEventId: hookEventId,
            agentKind: h.agentKind,
            sessionId: h.sessionId,
            toolName: replayToolName,
            workspaceRoot: h.workspaceRoot,
            action: .prompt,
            source: .automatic,
            reason: "terminal focused"
```

#### Validation

Validated by tracing AppState evaluation order and pass output. Sibling pass paths in queued and focus helpers should be rechecked under the same policy-ordering rule.

**Terminal focus pass precedes persistent policy** — `DevIsland/Core/AppState.swift:899-926`

The focused-terminal branch returns before persistent policyDecision executes.

```swift
        // MARK: Phase 4: Evaluation Hierarchy
        // 우선순위: 터미널 포커스 pass → 영속 정책 → 휘발성 자동 승인 → 수동 승인 큐잉.
        isTerminalFrontmostAsync(
            appName: h.terminal.app,
            tty: h.terminal.tty,
            windowId: h.terminal.windowId,
            tabIndex: h.terminal.tabIndex,
            tmuxPane: h.terminal.tmuxPane,
            tmuxSocket: h.terminal.tmuxSocket,
            tmuxClient: h.terminal.tmuxClient
        ) { [weak self] isFrontmost in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(h.sessionId.prefix(8))")
                self.passRequestToFocusedTerminal(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
                return
            }

            // 2. Persistent Policy Check: Check SQLite for durable rules (Exact, Glob, Regex).
            if let policyDecision = self.policyDecision(
```

**Focused path emits pass** — `DevIsland/Core/AppState.swift:1339-1349`

The automatic response records action prompt with reason terminal focused and sends a pass payload.

```swift
        respondWithReplay(
            "{\"response\": \"pass\"}",
            responseHandler: request.responseHandler,
            hookEventId: hookEventId,
            agentKind: h.agentKind,
            sessionId: h.sessionId,
            toolName: replayToolName,
            workspaceRoot: h.workspaceRoot,
            action: .prompt,
            source: .automatic,
            reason: "terminal focused"
```

**Gemini pass returns empty output** — `DevIsland/Provider/GeminiHookHandler.swift:6-8`

For Gemini, pass produces an empty response instead of a deny payload, relying on provider mode semantics.

```swift
    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }
        return GeminiPromptPolicy.beforeToolOutput(allow: context.allow, denialMessage: context.denialMessage)
```

#### Dataflow

The canonical finding records the affected path at DevIsland/Core/AppState.swift:899-926, DevIsland/Core/AppState.swift:1339-1349, DevIsland/Provider/GeminiHookHandler.swift:6-8, but no expanded source-to-sink narrative was recorded.

**Terminal focus pass precedes persistent policy** — `DevIsland/Core/AppState.swift:899-926`

The focused-terminal branch returns before persistent policyDecision executes.

```swift
        // MARK: Phase 4: Evaluation Hierarchy
        // 우선순위: 터미널 포커스 pass → 영속 정책 → 휘발성 자동 승인 → 수동 승인 큐잉.
        isTerminalFrontmostAsync(
            appName: h.terminal.app,
            tty: h.terminal.tty,
            windowId: h.terminal.windowId,
            tabIndex: h.terminal.tabIndex,
            tmuxPane: h.terminal.tmuxPane,
            tmuxSocket: h.terminal.tmuxSocket,
            tmuxClient: h.terminal.tmuxClient
        ) { [weak self] isFrontmost in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(h.sessionId.prefix(8))")
                self.passRequestToFocusedTerminal(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
                return
            }

            // 2. Persistent Policy Check: Check SQLite for durable rules (Exact, Glob, Regex).
            if let policyDecision = self.policyDecision(
```

**Focused path emits pass** — `DevIsland/Core/AppState.swift:1339-1349`

The automatic response records action prompt with reason terminal focused and sends a pass payload.

```swift
        respondWithReplay(
            "{\"response\": \"pass\"}",
            responseHandler: request.responseHandler,
            hookEventId: hookEventId,
            agentKind: h.agentKind,
            sessionId: h.sessionId,
            toolName: replayToolName,
            workspaceRoot: h.workspaceRoot,
            action: .prompt,
            source: .automatic,
            reason: "terminal focused"
```

**Gemini pass returns empty output** — `DevIsland/Provider/GeminiHookHandler.swift:6-8`

For Gemini, pass produces an empty response instead of a deny payload, relying on provider mode semantics.

```swift
    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }
        return GeminiPromptPolicy.beforeToolOutput(allow: context.allow, denialMessage: context.denialMessage)
```

#### Reachability

Reachability was not recorded beyond the canonical finding summary and affected locations.

#### Severity

**Medium** — The bypass weakens explicit deny policy and can become execution-impacting for providers or modes where pass means allow or no provider-side prompt appears.

Additional runtime or deployment evidence could raise or lower this severity.

#### Remediation

Evaluate persistent and session deny rules before every focused-terminal pass path. Only delegate to provider prompts when no deny matches, and add provider-specific tests for Gemini, Antigravity, Codex, and Claude pass semantics.

Tests:
- A matching persistent deny must win even when the terminal is frontmost.
- Queued requests that become frontmost must re-run deny policy before pass.
- Provider output tests should assert deny is not converted to pass in auto-approve modes.

<a id="finding-4"></a>

### [4] CMUX_WORKSPACE_ID is interpolated into shell bridge AppleScript without escaping

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | The unescaped variable interpolation occurs directly inside the osascript heredoc and is gated only by environment presence and cmux state. |
| Category | AppleScript injection |
| CWE | CWE-94, CWE-78 |
| Affected lines | scripts/devisland-bridge.sh:295-312 |

#### Summary

The shell bridge embeds CMUX_WORKSPACE_ID directly inside an unquoted AppleScript heredoc, allowing a crafted environment value to break out of the string literal and execute attacker-chosen AppleScript when cmux detection runs.

#### Root Cause

Shell variable expansion is used to construct AppleScript source code rather than passing untrusted values as argv or escaping them as AppleScript string literals.

**Environment value interpolated into AppleScript string** — `scripts/devisland-bridge.sh:295-312`

Because the heredoc delimiter is unquoted, the shell expands CMUX_WORKSPACE_ID before osascript parses the AppleScript source.

```bash
detect_cmux() {
  [ -n "$CURRENT_TTY" ] || return 1
  { [ -n "$CMUX_WORKSPACE_ID" ] || [ -n "$CMUX_SURFACE_ID" ]; } || return 1
  osascript -e 'return (application "cmux" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="cmux"
  if [ -n "$CMUX_WORKSPACE_ID" ]; then
    TERM_TITLE=$(osascript 2>/dev/null << ASEOF
tell application "cmux"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      if (id of aTab as text) is "$CMUX_WORKSPACE_ID" then
        return name of aTab
      end if
    end repeat
  end repeat
  return ""
end tell
ASEOF
```

#### Validation

Validated by reviewing detect_cmux: the variable is required only to be non-empty, then embedded in a quoted AppleScript comparison with no escaping helper.

**Environment value interpolated into AppleScript string** — `scripts/devisland-bridge.sh:295-312`

Because the heredoc delimiter is unquoted, the shell expands CMUX_WORKSPACE_ID before osascript parses the AppleScript source.

```bash
detect_cmux() {
  [ -n "$CURRENT_TTY" ] || return 1
  { [ -n "$CMUX_WORKSPACE_ID" ] || [ -n "$CMUX_SURFACE_ID" ]; } || return 1
  osascript -e 'return (application "cmux" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="cmux"
  if [ -n "$CMUX_WORKSPACE_ID" ]; then
    TERM_TITLE=$(osascript 2>/dev/null << ASEOF
tell application "cmux"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      if (id of aTab as text) is "$CMUX_WORKSPACE_ID" then
        return name of aTab
      end if
    end repeat
  end repeat
  return ""
end tell
ASEOF
```

#### Dataflow

The canonical finding records the affected path at scripts/devisland-bridge.sh:295-312, but no expanded source-to-sink narrative was recorded.

**Environment value interpolated into AppleScript string** — `scripts/devisland-bridge.sh:295-312`

Because the heredoc delimiter is unquoted, the shell expands CMUX_WORKSPACE_ID before osascript parses the AppleScript source.

```bash
detect_cmux() {
  [ -n "$CURRENT_TTY" ] || return 1
  { [ -n "$CMUX_WORKSPACE_ID" ] || [ -n "$CMUX_SURFACE_ID" ]; } || return 1
  osascript -e 'return (application "cmux" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="cmux"
  if [ -n "$CMUX_WORKSPACE_ID" ]; then
    TERM_TITLE=$(osascript 2>/dev/null << ASEOF
tell application "cmux"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      if (id of aTab as text) is "$CMUX_WORKSPACE_ID" then
        return name of aTab
      end if
    end repeat
  end repeat
  return ""
end tell
ASEOF
```

#### Reachability

Reachability was not recorded beyond the canonical finding summary and affected locations.

#### Severity

**Medium** — Exploitation requires local control over hook environment variables and cmux to be running, but successful injection can execute local commands through AppleScript.

Additional runtime or deployment evidence could raise or lower this severity.

#### Remediation

Pass CMUX_WORKSPACE_ID to osascript through argv using on run argv, or apply strict AppleScript string literal escaping before interpolation. Prefer a quoted heredoc for static script text and explicit argument binding for all environment data.

Tests:
- A CMUX_WORKSPACE_ID containing a quote and AppleScript syntax must be treated as inert data.
- Normal cmux tab title detection should still work with expected IDs.
- Shellcheck or unit coverage should guard future osascript heredocs from direct environment interpolation.

## Reviewed Surfaces

| Surface | Risk Area | Outcome | Notes |
| --- | --- | --- | --- |
| Approval policy engine and persisted rules | authorization | Reported | Reviewed policy matching, deny precedence, seeded rules, queue pass paths, and provider response effects. Evidence: artifacts/02_discovery/work_ledger.jsonl, artifacts/05_findings/DEVSEC-001/validation_report.md, artifacts/05_findings/DEVSEC-002/validation_report.md |
| GitHub release updater and DMG installation | supply-chain | Reported | Reviewed release metadata selection, download, mounting, quarantine, and replacement. Evidence: artifacts/05_findings/DEVSEC-003/validation_report.md, artifacts/05_findings/DEVSEC-003/attack_path_analysis_report.md |
| Hook bridge shell and Python scripts | local command execution | Reported | Reviewed provider bridge script parsing, IPC forwarding, and terminal metadata enrichment. Evidence: artifacts/02_discovery/finding_discovery_report.md, artifacts/05_findings/DEVSEC-004/validation_report.md |
| IPC framing, token checks, SQLite persistence, and replay logs | local IPC | No issue found | Loopback token and framed IPC behavior did not produce a reportable finding in this pass. Evidence: artifacts/03_coverage/repository_coverage_ledger.md |
| Markdown, HTML rendering, attachments, and plugin resource loading | file and UI rendering | No issue found | Reviewed markdown attachment handling, HTML CSP/navigation restrictions, OpenPeon path validation, and scoped resource broker behavior. Evidence: artifacts/03_coverage/repository_coverage_ledger.md |
