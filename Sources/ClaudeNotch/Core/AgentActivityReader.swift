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

    var blocksTaskHandoff: Bool {
        self == .working || self == .thinking
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
                : state(for: claudeURL, parser: Self.claudeState),
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

    nonisolated static func claudeState(_ objects: [[String: Any]]) -> AgentActivityState {
        var state: AgentActivityState = .idle
        var reachedIdleBoundary = false
        for object in objects {
            if object["isSidechain"] as? Bool == true { continue }
            switch object["type"] as? String {
            case "last-prompt":
                state = .idle
                reachedIdleBoundary = true
            case "user":
                guard let message = object["message"] as? [String: Any] else { continue }
                if hasVisibleUserPrompt(message["content"]) {
                    state = .thinking
                    reachedIdleBoundary = false
                } else if !reachedIdleBoundary, hasToolResult(message["content"]) {
                    state = .thinking
                }
            case "assistant":
                guard !reachedIdleBoundary else { continue }
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

    private nonisolated static func hasVisibleUserPrompt(_ content: Any?) -> Bool {
        if let text = content as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { block in
            block["type"] as? String == "text"
                && !((block["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private nonisolated static func hasToolResult(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_result" }
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

/// 接力守卫：只看这个任务自己的记录，且只按「多久没写过」判断。
///
/// 不复用状态圆点那套判断，有两个原因。一是圆点取全机器最新的那个会话文件，
/// 别的会话（比如后台常驻的观察进程）在忙，会把这一行的按钮误伤成灰的。
/// 二是 `claudeState` 靠 `last-prompt` 认定一轮结束，而记录只读尾部 128 KB——
/// 一轮写满 128 KB 后标记滑出窗口，已经停下来的任务反而被判成工作中，按钮就此锁死。
/// 任务跑得越久越交不出去，正好是最该接力的时候。
///
/// 时间判据不受日志长度影响：真在干活的 agent 每次工具调用都会写记录。
enum HandoffActivityGuard {
    /// 记录安静多久就认定这一轮停了。
    ///
    /// 取小值，因为两种误判的代价差得很远：误判成「忙」按钮就是死的（正是这个 bug 本身），
    /// 误判成「闲」只是交接包里的进度稍微旧一点——接力不会打断原任务，写包也不碰它。
    /// 阈值再往上加会把「一轮刚结束、人正要接力」的那几十秒重新变成灰的。
    static let quietThreshold: TimeInterval = 20

    static func isBusy(lastWrite: Date?, now: Date) -> Bool {
        // 拿不到证据时放行：这个判断只用来禁用一个按钮，锁死的代价远大于偶尔放过。
        guard let lastWrite else { return false }
        return now.timeIntervalSince(lastWrite) < quietThreshold
    }

    static func isBusy(_ task: AgentTaskReference, now: Date = Date()) -> Bool {
        isBusy(lastWrite: lastWrite(of: task), now: now)
    }

    private static func lastWrite(of task: AgentTaskReference) -> Date? {
        guard let path = task.transcriptPath else { return nil }
        return (try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
