import AppKit
import Foundation

actor HandoffCoordinator {
    private static let workQueue = DispatchQueue(label: "claude-notch-handoff", qos: .utility)

    func handoff(
        task: AgentTaskReference,
        to destination: HandoffDestination,
        awaitingConfirmation: Bool
    ) async -> HandoffResult {
        let preparation = await withCheckedContinuation { continuation in
            Self.workQueue.async {
                continuation.resume(returning: Self.prepare(
                    task: task,
                    destination: destination,
                    awaitingConfirmation: awaitingConfirmation
                ))
            }
        }
        guard case let .success(prepared) = preparation else {
            if case let .failure(reason) = preparation {
                return .failed(packetPath: nil, instruction: nil, reason: reason)
            }
            return .failed(packetPath: nil, instruction: nil, reason: "无法生成交接包")
        }

        switch destination {
        case .claudeDesktop:
            let opened = await MainActor.run {
                Self.openClaude(cwd: task.cwd, instruction: prepared.instruction)
            }
            if opened {
                return .opened(destination: .claudeDesktop, packetPath: prepared.packetPath,
                               instruction: prepared.instruction)
            }
            await MainActor.run {
                Self.copyToPasteboard(prepared.instruction)
                Self.openClaudeDesktop()
            }
            return .fallback(destination: .claudeDesktop, packetPath: prepared.packetPath,
                             instruction: prepared.instruction,
                             reason: "Claude 桌面端深链未打开，交接指令已复制")

        case .codex:
            let launch = await withCheckedContinuation { continuation in
                Self.workQueue.async {
                    continuation.resume(returning: CodexHandoffClient.start(
                        cwd: task.cwd,
                        workspaceRoots: task.workspaceRoots,
                        instruction: prepared.instruction
                    ))
                }
            }
            guard case let .success(threadID) = launch else {
                let reason: String
                if case let .failure(message) = launch { reason = message }
                else { reason = "Codex 任务未创建" }
                await MainActor.run {
                    Self.copyToPasteboard(prepared.instruction)
                    Self.openDirectory(task.cwd)
                }
                return .fallback(destination: .codex, packetPath: prepared.packetPath,
                                 instruction: prepared.instruction,
                                 reason: "\(reason)，交接指令已复制")
            }

            let opened = await MainActor.run { Self.openCodex(threadID: threadID) }
            if opened {
                return .opened(destination: .codex, packetPath: prepared.packetPath,
                               instruction: prepared.instruction)
            }
            await MainActor.run {
                Self.copyToPasteboard(prepared.instruction)
                Self.openDirectory(task.cwd)
            }
            return .fallback(destination: .codex, packetPath: prepared.packetPath,
                             instruction: prepared.instruction,
                             reason: "Codex 任务已创建但深链未打开，交接指令已复制")

        case .workBuddy:
            let appURL = await MainActor.run {
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.workbuddy.workbuddy"
                )
            }
            guard appURL != nil else {
                await MainActor.run { Self.copyToPasteboard(prepared.instruction) }
                return .fallback(destination: .workBuddy, packetPath: prepared.packetPath,
                                 instruction: prepared.instruction,
                                 reason: "未找到 WorkBuddy，交接指令已复制")
            }

            let opened = await MainActor.run {
                Self.openWorkBuddy(cwd: task.cwd, instruction: prepared.instruction)
            }
            if opened {
                return .opened(destination: .workBuddy, packetPath: prepared.packetPath,
                               instruction: prepared.instruction)
            }
            await MainActor.run {
                Self.copyToPasteboard(prepared.instruction)
                Self.openWorkBuddyDesktop()
            }
            return .fallback(destination: .workBuddy, packetPath: prepared.packetPath,
                             instruction: prepared.instruction,
                             reason: "WorkBuddy 深链未打开，交接指令已复制")
        }
    }

    private nonisolated static func prepare(
        task: AgentTaskReference,
        destination: HandoffDestination,
        awaitingConfirmation: Bool
    ) -> HandoffPreparationResult {
        let transcript = readTranscript(task)
            .map { HandoffTranscriptParser.parse(data: $0, provider: task.provider) }
            ?? HandoffTranscriptContext()
        let workspace = HandoffWorkspaceInspector.inspect(cwd: task.cwd)
        let roots = Array(Set(([task.cwd] + task.workspaceRoots).filter { !$0.isEmpty })).sorted()
        let packet = TaskHandoffPacketV1(
            version: 1,
            id: UUID().uuidString,
            createdAt: Date(),
            sourceAgent: sourceAgentName(task.provider),
            targetAgent: destination.agentName,
            taskTitle: HandoffRedactor.sanitize(task.title),
            sessionID: task.sessionID,
            cwd: task.cwd,
            workspaceRoots: roots,
            latestUserGoal: transcript.latestUserGoal,
            recentAgentProgress: transcript.recentAgentProgress,
            gitBranch: workspace.gitBranch,
            changedFiles: Array(workspace.changedFiles.prefix(500)),
            untrackedFiles: Array(workspace.untrackedFiles.prefix(500)),
            validationResults: transcript.validationResults,
            awaitingConfirmation: awaitingConfirmation,
            unansweredConfirmation: awaitingConfirmation ? transcript.recentAgentProgress : nil,
            transcriptPath: task.transcriptPath
        )
        do {
            let packetPath = try save(packet)
            let instruction = HandoffInstructionBuilder.make(
                packet: packet, packetPath: packetPath, destination: destination
            )
            return .success(PreparedHandoff(packetPath: packetPath, instruction: instruction))
        } catch {
            return .failure("交接包保存失败：\(error.localizedDescription)")
        }
    }

    private nonisolated static func readTranscript(_ task: AgentTaskReference) -> Data? {
        guard let path = task.transcriptPath else { return nil }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL]
        switch task.provider {
        case .claude:
            roots = [home.appendingPathComponent(".claude/projects")]
        case .codex:
            roots = [home.appendingPathComponent(".codex/sessions"),
                     home.appendingPathComponent(".codex/archived_sessions")]
        case .workbuddy:
            roots = [home.appendingPathComponent(".workbuddy/projects")]
        case .deepseek:
            roots = []
        }
        guard roots.map({ $0.standardizedFileURL.resolvingSymlinksInPath().path })
            .contains(where: { fileURL.path == $0 || fileURL.path.hasPrefix($0 + "/") }),
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            let maximumBytes: UInt64 = 2 * 1_024 * 1_024
            let size = try handle.seekToEnd()
            let start = size > maximumBytes ? size - maximumBytes : 0
            try handle.seek(toOffset: start)
            var data = try handle.readToEnd() ?? Data()
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
            return data
        } catch {
            return nil
        }
    }

    private nonisolated static func save(_ packet: TaskHandoffPacketV1) throws -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Notch/Handoffs",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "\(formatter.string(from: packet.createdAt))-\(packet.id).json"
        let url = directory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw HandoffCoordinatorError.packetAlreadyExists
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(packet).write(to: url, options: .atomic)
        return url.path
    }

    @MainActor private static func openClaude(cwd: String, instruction: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) != nil,
        let url = HandoffInstructionBuilder.claudeDesktopURL(
            cwd: cwd, instruction: instruction
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor private static func openClaudeDesktop() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @MainActor private static func openCodex(threadID: String) -> Bool {
        guard let url = URL(string: "codex://threads/\(threadID)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor private static func openWorkBuddy(cwd: String, instruction: String) -> Bool {
        guard let url = HandoffInstructionBuilder.workBuddyURL(
            cwd: cwd, instruction: instruction
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor private static func openWorkBuddyDesktop() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.workbuddy.workbuddy"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @MainActor private static func copyToPasteboard(_ instruction: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(instruction, forType: .string)
    }

    @MainActor private static func openDirectory(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private nonisolated static func sourceAgentName(_ provider: UsageProviderID) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .workbuddy: "WorkBuddy"
        case .deepseek: "DeepSeek"
        }
    }
}

private struct PreparedHandoff: Sendable {
    let packetPath: String
    let instruction: String
}

private enum HandoffPreparationResult: Sendable {
    case success(PreparedHandoff)
    case failure(String)
}

enum CodexHandoffLaunchResult: Sendable {
    case success(threadID: String)
    case failure(String)
}

enum HandoffInstructionBuilder {
    static let maximumCharacters = 5_000

    static func make(
        packet: TaskHandoffPacketV1,
        packetPath: String,
        destination: HandoffDestination
    ) -> String {
        let target = destination.agentName
        let changed = list(packet.changedFiles, empty: "无已识别的已修改文件")
        let untracked = list(packet.untrackedFiles, empty: "无已识别的未跟踪文件")
        let validations = list(packet.validationResults, empty: "未从可见进度中可靠提取")
        let roots = list(packet.workspaceRoots, empty: packet.cwd)
        let confirmation = packet.awaitingConfirmation
            ? (packet.unansweredConfirmation ?? "有，但未从可见记录中可靠提取；先确认是否仍需回答")
            : "无"
        let body = """
        你正在通过 Claude Notch 接手一个未完成任务。目标 Agent：\(target)。

        开始前必须：
        1. 读取工作目录内的 AGENTS.md、CLAUDE.md 等项目规则。
        2. 检查真实工作区、Git 状态和现有改动，区分用户与其他 Agent 的改动。
        3. 对照交接信息确认已经完成和尚未完成的部分，再继续执行。
        4. 不得重复已完成工作，不得覆盖或清理现有改动。
        5. 交接包信息不足时，才只读回查原会话；不要寻找隐藏推理或复制完整对话。

        任务：\(packet.taskTitle)
        来源：\(packet.sourceAgent)
        主工作目录：\(packet.cwd)
        工作目录范围：
        \(roots)

        最后一条有效用户目标：
        \(packet.latestUserGoal ?? "未从可见记录中可靠提取，请以项目现场和用户要求为准")

        最近可见进度：
        \(packet.recentAgentProgress ?? "未从可见记录中可靠提取，请重新检查工作区")

        Git 分支：\(packet.gitBranch ?? "非 Git 目录或未识别")
        已修改文件：
        \(changed)
        未跟踪文件：
        \(untracked)
        已报告的验证结果：
        \(validations)
        尚未回答的确认请求：\(confirmation)

        交接包：\(packetPath)
        原会话记录：\(packet.transcriptPath ?? "未提供")
        """
        let sanitized = HandoffRedactor.sanitize(body)
        let bounded: String
        if sanitized.count > maximumCharacters {
            let ending = """


            关键恢复信息：
            先读取项目规则并检查真实工作区。
            工作目录范围：
            \(capped(roots, at: 1_000))
            交接包：\(packetPath)
            请先检查真实工作区，再继续未完成任务。
            """
            let available = max(0, maximumCharacters - ending.count)
            bounded = String(sanitized.prefix(available)) + ending
        } else {
            bounded = sanitized
        }
        return bounded
    }

    private static func list(_ values: [String], empty: String) -> String {
        guard !values.isEmpty else { return "- \(empty)" }
        return values.prefix(80).map { "- \($0)" }.joined(separator: "\n")
    }

    static func claudeDesktopURL(cwd: String, instruction: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: instruction),
                                 URLQueryItem(name: "folder", value: cwd)]
        return components.url
    }

    static func workBuddyURL(cwd: String, instruction: String) -> URL? {
        var components = URLComponents()
        components.scheme = "workbuddy"
        components.host = "task"
        components.queryItems = [
            URLQueryItem(name: "action", value: "start"),
            URLQueryItem(name: "prompt", value: instruction),
            URLQueryItem(name: "cwd", value: cwd),
            URLQueryItem(name: "welcomeMode", value: "code"),
        ]
        return components.url
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }
}

private enum HandoffCoordinatorError: LocalizedError {
    case packetAlreadyExists

    var errorDescription: String? { "交接记录已存在，未覆盖旧记录" }
}

enum CodexHandoffClient {
    /// 建一个新线程、把交接指令作为用户消息送进去，然后立刻断开。
    ///
    /// 不能挂着连接等这一轮跑完。Codex 的线程是独占的：只要还有客户端连着，
    /// 人在 GUI 里打开它就会被挡回「已在另一个应用中打开」。而且这一轮是无头跑的——
    /// 没有界面能批准命令，它一要批准就永远停在那儿，连接永远不释放，还每次泄漏一个进程。
    ///
    /// `turn/start` 一应答就可以走。指令是靠 `finish()` 那次干净退出落进会话文件的——
    /// app-server 收到 EOF 后会把这一轮标记成中断、把用户消息写完再退。
    /// 所以这里不需要等任何确认信号，等反而要多花五秒看它启动一堆 MCP 服务。
    /// 人打开线程就看得见指令，接着说话就能继续。真正干活的是接手的那个 Codex，不是这里。
    static func start(cwd: String, workspaceRoots: [String], instruction: String)
        -> CodexHandoffLaunchResult {
        var connection: CodexHandoffConnection?
        defer { connection?.finish() }
        do {
            let activeConnection = try CodexHandoffConnection()
            connection = activeConnection
            let roots = Array(Set(([cwd] + workspaceRoots).filter { !$0.isEmpty })).sorted()
            try activeConnection.sendRequest(id: 1, method: "initialize", params: [
                "clientInfo": [
                    "name": "claude-notch-handoff",
                    "title": "Claude Notch Handoff",
                    "version": AppInfo.version,
                ],
                "capabilities": ["experimentalApi": true],
            ])
            _ = try activeConnection.wait(for: 1, timeout: 8)
            try activeConnection.sendNotification(method: "initialized", params: [:])
            try activeConnection.sendRequest(id: 2, method: "thread/start", params: [
                "cwd": cwd,
                "runtimeWorkspaceRoots": roots,
            ])
            let threadData = try activeConnection.wait(for: 2, timeout: 12)
            let response = try JSONDecoder().decode(CodexThreadStartResponse.self, from: threadData)
            try activeConnection.sendRequest(id: 3, method: "turn/start", params: [
                "threadId": response.thread.id,
                "input": [["type": "text", "text": instruction]],
                "runtimeWorkspaceRoots": roots,
            ])
            _ = try activeConnection.wait(for: 3, timeout: 12)
            return .success(threadID: response.thread.id)
        } catch {
            return .failure("Codex 启动失败：\(error.localizedDescription)")
        }
    }
}

private struct CodexThreadStartResponse: Decodable {
    struct Thread: Decodable { let id: String }
    let thread: Thread
}

private final class CodexHandoffConnection: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let collector = HandoffRPCCollector()
    private let finishLock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var finished = false

    init() throws {
        process.executableURL = try Self.findExecutable()
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [collector] handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { [collector, exited] _ in
            collector.markProcessExited()
            exited.signal()
        }
        try process.run()
    }

    func sendRequest(id: Int, method: String, params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func sendNotification(method: String, params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func wait(for id: Int, timeout: TimeInterval) throws -> Data {
        try collector.wait(for: id, timeout: timeout)
    }

    /// 关掉 stdin 让 app-server 自己退，不直接 SIGTERM。
    ///
    /// 它退出前还要把这一轮标记成中断、把会话文件写完。从中间打断有可能把刚送进去的
    /// 用户消息截在半路——而那正是这次交接要送的全部内容。
    /// 期间还得继续读它的输出，管道写满了它就卡在那儿退不掉。等超了再动手。
    func finish() {
        finishLock.lock()
        guard !finished else { finishLock.unlock(); return }
        finished = true
        finishLock.unlock()
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 6) == .timedOut, process.isRunning {
            process.terminate()
        }
        output.fileHandleForReading.readabilityHandler = nil
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private static func findExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["CODEX_NOTCH_BINARY"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexHandoffError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

private final class HandoffRPCCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var results: [Int: Data] = [:]
    private var errors: [Int: String] = [:]
    private var completedIDs = Set<Int>()
    private var processExited = false

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            processExited = true
            condition.broadcast()
            return
        }
        buffer.append(data)
        guard buffer.count <= 8 * 1_024 * 1_024 else {
            processExited = true
            condition.broadcast()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    func markProcessExited() {
        condition.lock()
        processExited = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for id: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !completedIDs.contains(id), !processExited {
            if !condition.wait(until: deadline) { break }
        }
        if let error = errors[id] { throw CodexHandoffError.server(error) }
        guard let result = results[id] else {
            throw processExited ? CodexHandoffError.transport : CodexHandoffError.timeout
        }
        return result
    }

    private func consume(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }
        if let result = object["result"] {
            results[id] = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        } else if let error = object["error"] as? [String: Any] {
            errors[id] = error["message"] as? String ?? "未知 app-server 错误"
        }
        completedIDs.insert(id)
        condition.broadcast()
    }
}

private enum CodexHandoffError: LocalizedError {
    case executableNotFound
    case timeout
    case transport
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Codex"
        case .timeout: "Codex 本地接口响应超时"
        case .transport: "Codex 本地接口已断开"
        case let .server(message): message
        }
    }
}
