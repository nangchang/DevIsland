import Foundation

struct PluginEventFactory: Sendable {
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
                terminalApp: emptyToNil(hook.terminalApp)
            ),
            action: nil,
            approval: nil
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
            approval: nil
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
            session: canReadSessionEvents ? event.session : nil,
            hook: canReadHookSummaries ? event.hook.map { hook in
                PluginHookSummary(
                    provider: hook.provider,
                    eventType: hook.eventType,
                    commandSummary: hook.commandSummary,
                    cwd: metadata?.cwd,
                    terminalApp: metadata?.terminalApp
                )
            } : nil,
            action: event.action,
            approval: canReadHookSummaries ? event.approval : nil
        )
    }

    private func commandSummary(from hook: ParsedHookEvent) -> String? {
        let candidates = [hook.displayToolName, hook.displayMsg]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let source = candidates.dropFirst().contains(candidates[0])
            ? candidates[0]
            : candidates.joined(separator: ": ")
        return redactSensitiveText(source)
    }

    private func redactSensitiveText(_ text: String) -> String {
        var redacted = redactHeredocBodies(text)
        redacted = replace(pattern: #"/Users/[^/\s'"]+(?=/|\b)"#, in: redacted, with: "~")
        redacted = replace(
            pattern: #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*['"]?[^\s'"]+"#,
            in: redacted,
            with: "$1=[redacted]"
        )
        redacted = replace(pattern: #"\b[A-Za-z0-9_=-]{32,}\b"#, in: redacted, with: "[redacted-token]")
        return redacted
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
                        if didRedact {
                            output.append(lines[index])
                        }
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
        guard let range = line.range(of: "<<") else { return nil }
        let rawMarker = line[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard rawMarker.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return rawMarker
    }

    private func replace(pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private func providerName(for kind: BuddyKind) -> String {
        switch kind {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .gemini:
            return "gemini"
        case .island:
            return "unknown"
        }
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
