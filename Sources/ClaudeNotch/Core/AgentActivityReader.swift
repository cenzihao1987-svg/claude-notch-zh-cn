import Foundation

enum AgentActivityState: String, Sendable {
    case idle
    case working
    case thinking
    case awaitingConfirmation

    var label: String {
        switch self {
        case .idle: "空闲"
        case .working: "工作中"
        case .thinking: "思考中"
        case .awaitingConfirmation: "待确认"
        }
    }
}

/// Reads only the tail of the newest local Claude/Codex event files. Conversation content is
/// ignored; only event kinds and tool names influence the status dot.
actor AgentActivityReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeURL: URL?
    private var claudeAuditURL: URL?
    private var codexURL: URL?
    private var lastDiscovery = Date.distantPast
    private let activeFreshness: TimeInterval = 10 * 60

    func read() -> [UsageProviderID: AgentActivityState] {
        if Date().timeIntervalSince(lastDiscovery) >= 5 {
            discoverLatestFiles()
            lastDiscovery = Date()
        }
        let useAudit = Self.mtime(claudeAuditURL) >= Self.mtime(claudeURL)
        return [
            .claude: useAudit
                ? state(for: claudeAuditURL, parser: claudeAuditState)
                : state(for: claudeURL, parser: claudeState),
            .codex: state(for: codexURL, parser: codexState),
        ]
    }

    private func state(
        for url: URL?,
        parser: ([[String: Any]]) -> AgentActivityState
    ) -> AgentActivityState {
        guard let url else { return .idle }
        let state = parser(tailObjects(url))
        if state == .awaitingConfirmation { return state }
        guard Date().timeIntervalSince(Self.mtime(url)) <= activeFreshness else { return .idle }
        return state
    }

    private func discoverLatestFiles() {
        claudeURL = latest(ClaudePaths.recentLogFiles(within: 2)) ?? claudeURL
        let auditRoot = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions"
        )
        claudeAuditURL = latestFile(named: "audit.jsonl", under: auditRoot) ?? claudeAuditURL

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        if let year = parts.year, let month = parts.month, let day = parts.day {
            let folder = home.appendingPathComponent(
                String(format: ".codex/sessions/%04d/%02d/%02d", year, month, day)
            )
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            ))?.filter { $0.pathExtension == "jsonl" } ?? []
            codexURL = latest(files) ?? codexURL
        }
    }

    private func latest(_ files: [URL]) -> URL? {
        files.max { Self.mtime($0) < Self.mtime($1) }
    }

    private func latestFile(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var result: URL?
        for case let url as URL in enumerator where url.lastPathComponent == name {
            if result == nil || Self.mtime(url) > Self.mtime(result) { result = url }
        }
        return result
    }

    private func tailObjects(_ url: URL) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 131_072 ? size - 131_072 : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return [] }
        var data = handle.readDataToEndOfFile()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return data.split(separator: 0x0A).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    private func codexState(_ objects: [[String: Any]]) -> AgentActivityState {
        var state: AgentActivityState = .idle
        for object in objects {
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }
            if object["type"] as? String == "event_msg" {
                switch payloadType {
                case "task_started", "agent_reasoning": state = .thinking
                case "agent_message": state = .working
                case "task_complete": state = .idle
                default: break
                }
            } else if object["type"] as? String == "response_item" {
                switch payloadType {
                case "reasoning": state = .thinking
                case "custom_tool_call":
                    state = payload["name"] as? String == "request_user_input"
                        ? .awaitingConfirmation : .working
                case "custom_tool_call_output": state = .thinking
                default: break
                }
            }
        }
        return state
    }

    private func claudeState(_ objects: [[String: Any]]) -> AgentActivityState {
        var state: AgentActivityState = .idle
        for object in objects {
            switch object["type"] as? String {
            case "last-prompt":
                state = .idle
            case "user":
                state = .thinking
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                let types = Set(content.compactMap { $0["type"] as? String })
                if types.contains("tool_use") {
                    state = .working
                } else if types.contains("thinking") {
                    state = .thinking
                } else if types.contains("text") {
                    state = .working
                }
            default:
                break
            }
        }
        return state
    }

    private func claudeAuditState(_ objects: [[String: Any]]) -> AgentActivityState {
        var state: AgentActivityState = .idle
        for object in objects {
            switch (object["type"] as? String, object["subtype"] as? String) {
            case ("system", "permission_request"):
                state = .awaitingConfirmation
            case ("system", "permission_response"):
                state = .thinking
            case ("system", "status"):
                if let status = object["status"] as? String, !status.isEmpty {
                    state = .thinking
                }
            case ("user", _):
                state = .thinking
            case ("assistant", _):
                guard let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                let types = Set(content.compactMap { $0["type"] as? String })
                if types.contains("tool_use") {
                    state = .working
                } else if types.contains("thinking") {
                    state = .thinking
                } else if types.contains("text") {
                    state = .working
                }
            case ("result", _):
                state = .idle
            default:
                break
            }
        }
        return state
    }

    private static func mtime(_ url: URL?) -> Date {
        guard let url else { return .distantPast }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
