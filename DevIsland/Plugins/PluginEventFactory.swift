import Foundation

struct PluginEventFactory: Sendable {
    private static let userHomeRegex = try! NSRegularExpression(pattern: #"/Users/[^/\s'"]+(?=/|\b)"#)
    private static let credentialRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*['"]?[^\s'"]+"#
    )
    private static let tokenPrefixRegex = try! NSRegularExpression(
        pattern: #"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[a-zA-Z]-[A-Za-z0-9-]{20,})\b"#
    )
    private static let heredocMarkerRegex = try! NSRegularExpression(
        pattern: #"<<-?\s*['"\\]?([A-Za-z_][A-Za-z0-9_]*)['"\\]?"#
    )

    func makeHookReceivedEvent(
        from hook: ParsedHookEvent,
        session: ActiveSession? = nil,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> PluginEvent {
        PluginEvent(
            id: id,
            kind: .hookReceived,
            timestamp: timestamp,
            session: session.map(snapshot(from:)),
            hook: PluginHookSummary(
                provider: providerName(for: hook.agentKind),
                eventType: HookEventNormalizer.normalizedName(hook.event),
                commandSummary: commandSummary(from: hook),
                cwd: hook.workspaceRoot,
                terminalApp: emptyToNil(hook.terminalApp),
                rawEvent: hook.event,
                toolName: emptyToNil(hook.toolName),
                notificationType: emptyToNil(hook.notificationType),
                message: emptyToNil(hook.displayMsg),
                payload: AnyJSON.object(from: redactPayload(hook.parsedJSON))
            ),
            action: nil,
            approval: nil,
            powerStatus: nil
        )
    }

    /// Builds a session-less lifecycle event (`app.started`, `plugin.started`).
    func makeLifecycleEvent(
        kind: PluginEventKind,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> PluginEvent {
        PluginEvent(
            id: id,
            kind: kind,
            timestamp: timestamp,
            session: nil,
            hook: nil,
            action: nil,
            approval: nil,
            powerStatus: nil
        )
    }

    func makeSessionEvent(
        kind: PluginEventKind,
        from session: ActiveSession,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> PluginEvent {
        PluginEvent(
            id: id,
            kind: kind,
            timestamp: timestamp,
            session: snapshot(from: session),
            hook: nil,
            action: nil,
            approval: nil,
            powerStatus: nil
        )
    }

    func makePowerStatusEvent(
        status: PluginPowerStatus,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> PluginEvent {
        PluginEvent(
            id: id,
            kind: .powerStatusChanged,
            timestamp: timestamp,
            session: nil,
            hook: nil,
            action: nil,
            approval: nil,
            powerStatus: status
        )
    }

    func snapshot(from session: ActiveSession) -> PluginSessionSnapshot {
        PluginSessionSnapshot(
            id: session.id,
            agentKind: providerName(for: session.agentKind),
            startTime: session.startTime,
            lastActiveAt: session.lastActiveAt,
            lastToolName: emptyToNil(session.lastToolName),
            lastEventName: emptyToNil(session.lastEventName).map(HookEventNormalizer.normalizedName),
            workspaceRoot: session.workspaceRoot
        )
    }

    func redactedEvent(from event: PluginEvent, permissions: Set<PluginPermission>) -> PluginEvent {
        let canReadHookSummaries = permissions.contains(.readHookSummaries)
        let canReadTerminalMetadata = permissions.contains(.readTerminalMetadata)
        let canReadSessionEvents = permissions.contains(.readSessionEvents)
        let metadata = canReadTerminalMetadata
            ? (cwd: event.hook?.cwd, terminalApp: event.hook?.terminalApp)
            : nil

        return PluginEvent(
            id: event.id,
            kind: event.kind,
            timestamp: event.timestamp,
            session: canReadSessionEvents
                ? redactedSession(event.session, canReadTerminalMetadata: canReadTerminalMetadata)
                : nil,
            hook: canReadHookSummaries ? event.hook.map { hook in
                PluginHookSummary(
                    provider: hook.provider,
                    eventType: hook.eventType,
                    commandSummary: hook.commandSummary,
                    cwd: metadata?.cwd,
                    terminalApp: metadata?.terminalApp,
                    rawEvent: hook.rawEvent,
                    toolName: hook.toolName,
                    notificationType: hook.notificationType,
                    message: hook.message,
                    payload: hook.payload
                )
            } : nil,
            action: event.action,
            approval: canReadHookSummaries ? event.approval : nil,
            powerStatus: permissions.contains(.controlPowerSleep) ? event.powerStatus : nil
        )
    }

    private func redactedSession(
        _ session: PluginSessionSnapshot?,
        canReadTerminalMetadata: Bool
    ) -> PluginSessionSnapshot? {
        guard let session else { return nil }
        guard !canReadTerminalMetadata else { return session }
        return PluginSessionSnapshot(
            id: session.id,
            agentKind: session.agentKind,
            startTime: session.startTime,
            lastActiveAt: session.lastActiveAt,
            lastToolName: session.lastToolName,
            lastEventName: session.lastEventName,
            workspaceRoot: nil
        )
    }

    private func commandSummary(from hook: ParsedHookEvent) -> String? {
        let candidates = [hook.displayToolName, hook.displayMsg]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let source = candidates.dropFirst().allSatisfy { $0 == candidates[0] }
            ? candidates[0]
            : candidates.joined(separator: ": ")
        return redactSensitiveText(source)
    }

    private func redactSensitiveText(_ text: String) -> String {
        var redacted = redactHeredocBodies(text)
        redacted = replace(Self.userHomeRegex, in: redacted, with: "~")
        redacted = replace(Self.credentialRegex, in: redacted, with: "$1=[redacted]")
        redacted = replace(Self.tokenPrefixRegex, in: redacted, with: "[redacted-token]")
        return redacted
    }

    private func redactSensitiveValue(_ value: Any, forKey key: String) -> Any {
        let lowerKey = key.lowercased()
        if lowerKey.contains("secret") || lowerKey.contains("token") || lowerKey.contains("password") || lowerKey.contains("api_key") {
            return "[redacted]"
        }

        if let stringValue = value as? String {
            return redactSensitiveText(stringValue)
        } else if let dictValue = value as? [String: Any] {
            return redactPayload(dictValue)
        } else if let arrayValue = value as? [Any] {
            return arrayValue.map { redactSensitiveValue($0, forKey: "") }
        }
        return value
    }

    private func redactPayload(_ payload: [String: Any]) -> [String: Any] {
        var redactedPayload: [String: Any] = [:]
        for (key, value) in payload {
            redactedPayload[key] = redactSensitiveValue(value, forKey: key)
        }
        return redactedPayload
    }

    private func redactHeredocBodies(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var output: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            output.append(line)

            if let marker = heredocMarker(in: line) {
                index += 1
                var didRedact = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == marker {
                        output.append(lines[index])
                        break
                    }
                    if !didRedact {
                        output.append("[redacted heredoc]")
                        didRedact = true
                    }
                    index += 1
                }
            }

            index += 1
        }

        return output.joined(separator: "\n")
    }

    private func heredocMarker(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Self.heredocMarkerRegex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let markerRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[markerRange])
    }

    private func replace(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private func providerName(for kind: BuddyKind) -> String {
        switch kind {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .gemini:
            return "gemini"
        case .antigravity:
            return "antigravity"
        case .island:
            return "unknown"
        }
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
