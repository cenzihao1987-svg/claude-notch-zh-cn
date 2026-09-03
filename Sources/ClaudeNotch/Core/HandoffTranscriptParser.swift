import Foundation

enum HandoffTranscriptParser {
    static func parse(data: Data, provider: UsageProviderID) -> HandoffTranscriptContext {
        let objects = data.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
        let context: HandoffTranscriptContext
        switch provider {
        case .claude: context = parseClaude(objects)
        case .codex: context = parseCodex(objects)
        case .workbuddy: context = parseWorkBuddy(objects)
        case .deepseek: context = .init()
        }
        return HandoffTranscriptContext(
            latestUserGoal: context.latestUserGoal.map(HandoffRedactor.sanitize),
            recentAgentProgress: context.recentAgentProgress.map(HandoffRedactor.sanitize),
            validationResults: context.validationResults.map(HandoffRedactor.sanitize)
        )
    }

    private static func parseClaude(_ objects: [[String: Any]]) -> HandoffTranscriptContext {
        var userMessages: [String] = []
        var agentMessages: [String] = []
        for object in objects {
            guard object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            let text = visibleText(from: message["content"], allowedTypes: ["text"])
            guard !text.isEmpty else { continue }
            if type == "user" {
                if !isInjectedInstruction(text) { userMessages.append(text) }
            } else {
                agentMessages.append(text)
            }
        }
        let progress = agentMessages.last.map { capped($0, at: 1_800) }
        return HandoffTranscriptContext(
            latestUserGoal: latestGoal(in: userMessages),
            recentAgentProgress: progress,
            validationResults: validationLines(in: progress)
        )
    }

    private static func parseCodex(_ objects: [[String: Any]]) -> HandoffTranscriptContext {
        var eventUserMessages: [String] = []
        var eventAgentMessages: [String] = []
        var fallbackAgentMessages: [String] = []

        for object in objects {
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }
            if object["type"] as? String == "event_msg" {
                if payloadType == "user_message", let message = payload["message"] as? String {
                    eventUserMessages.append(message)
                } else if payloadType == "agent_message",
                          let message = payload["message"] as? String {
                    eventAgentMessages.append(message)
                }
                continue
            }
            guard object["type"] as? String == "response_item", payloadType == "message",
                  let role = payload["role"] as? String else { continue }
            let allowed = Set(["output_text", "text"])
            let text = visibleText(from: payload["content"], allowedTypes: allowed)
            guard !text.isEmpty else { continue }
            if role == "assistant" { fallbackAgentMessages.append(text) }
        }

        let agents = eventAgentMessages.isEmpty ? fallbackAgentMessages : eventAgentMessages
        let progress = agents.last.map { capped($0, at: 1_800) }
        return HandoffTranscriptContext(
            latestUserGoal: latestGoal(in: eventUserMessages),
            recentAgentProgress: progress,
            validationResults: validationLines(in: progress)
        )
    }

    private static func parseWorkBuddy(_ objects: [[String: Any]]) -> HandoffTranscriptContext {
        var userMessages: [String] = []
        var agentMessages: [String] = []

        for object in objects {
            guard object["type"] as? String == "message",
                  let role = object["role"] as? String else { continue }
            let text: String
            switch role {
            case "user":
                let source = visibleText(from: object["content"], allowedTypes: ["input_text", "text"])
                // WorkBuddy wraps user prompts with a system reminder containing environment,
                // connectors and automation metadata. Only its explicit user-query is safe to
                // carry into another agent.
                text = embeddedUserQuery(in: source) ?? (isInjectedInstruction(source) ? "" : source)
                if !text.isEmpty { userMessages.append(text) }
            case "assistant":
                text = visibleText(from: object["content"], allowedTypes: ["output_text", "text"])
                if !text.isEmpty { agentMessages.append(text) }
            default:
                continue
            }
        }

        let progress = agentMessages.last.map { capped($0, at: 1_800) }
        return HandoffTranscriptContext(
            latestUserGoal: latestGoal(in: userMessages),
            recentAgentProgress: progress,
            validationResults: validationLines(in: progress)
        )
    }

    private static func visibleText(from value: Any?, allowedTypes: Set<String>) -> String {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let items = value as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            guard let type = item["type"] as? String, allowedTypes.contains(type),
                  let text = item["text"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func latestGoal(in messages: [String]) -> String? {
        let cleaned = messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let confirmations = Set(["好", "好的", "可以", "继续", "确认", "同意", "yes", "ok"])
        let substantive = cleaned.last { message in
            !confirmations.contains(message.lowercased()) && message.count >= 8
        }
        return (substantive ?? cleaned.last).map { capped($0, at: 1_800) }
    }

    private static func isInjectedInstruction(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<local-command-caveat>")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<environment_context>")
    }

    private static func embeddedUserQuery(in text: String) -> String? {
        guard let start = text.range(of: "<user_query>"),
              let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validationLines(in progress: String?) -> [String] {
        guard let progress else { return [] }
        let markers = ["测试", "构建", "验证", "打包", "通过", "失败", "test", "build",
                       "verify", "swift test", "git diff --check"]
        return progress.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in markers.contains { line.localizedCaseInsensitiveContains($0) } }
            .prefix(5)
            .map { capped($0, at: 360) }
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

enum HandoffRedactor {
    static func sanitize(_ input: String) -> String {
        var output = input
        let replacements: [(String, String, NSRegularExpression.Options)] = [
            (#"-----BEGIN[\s\S]{0,80}PRIVATE KEY-----[\s\S]*?-----END[\s\S]{0,80}PRIVATE KEY-----"#,
             "[私钥已脱敏]", [.caseInsensitive]),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [已脱敏]", []),
            (#"\b(?:sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{12,})\b"#,
             "[凭证已脱敏]", [.caseInsensitive]),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
             "[令牌已脱敏]", []),
            (#"(?i)\b([A-Za-z0-9_]*(?:api[_-]?key|token|cookie|authorization|password|secret)[A-Za-z0-9_]*)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
             "$1=[已脱敏]", []),
            (#"(?i)(?:^|[/\\])\.env(?:\.[A-Za-z0-9_-]+)?"#, "/[敏感配置文件]", []),
        ]
        for (pattern, replacement, options) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output, range: range, withTemplate: replacement
            )
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/")
        return components.contains { component in
            component == ".env" || component.hasPrefix(".env.")
                || component.contains("credential") || component.contains("private_key")
                || component.contains("private-key") || component == "auth.json"
                || component == "cookies" || component.hasPrefix("cookies.")
                || component == "token" || component.hasPrefix("token.")
                || component == "secrets" || component.hasPrefix("secrets.")
                || component == "id_rsa" || component == "id_ed25519"
                || component.hasSuffix(".pem") || component.hasSuffix(".p12")
        }
    }
}
