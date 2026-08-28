import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct HandoffTranscriptParserTests {
    @Test func claudeKeepsVisibleContextAndIgnoresThinkingAndTools() throws {
        let data = try jsonLines([
            [
                "type": "user",
                "message": ["content": "实现接力功能，token=visible-secret-value"],
                "isSidechain": false,
            ],
            [
                "type": "assistant",
                "message": ["content": [["type": "thinking", "thinking": "隐藏推理"]]],
                "isSidechain": false,
            ],
            [
                "type": "assistant",
                "message": ["content": [["type": "tool_use", "name": "Bash",
                                            "input": ["command": "cat .env"]]]],
                "isSidechain": false,
            ],
            [
                "type": "user",
                "message": ["content": [["type": "tool_result", "content": "原始工具输出"]]],
                "isSidechain": false,
            ],
            [
                "type": "assistant",
                "message": ["content": [["type": "text",
                                            "text": "核心实现完成。swift build 通过，尚未打包。"]]],
                "isSidechain": false,
            ],
            [
                "type": "assistant",
                "message": ["content": [["type": "text", "text": "子任务不应进入交接"]]],
                "isSidechain": true,
            ],
        ])

        let context = HandoffTranscriptParser.parse(data: data, provider: .claude)

        #expect(context.latestUserGoal == "实现接力功能，token=[已脱敏]")
        #expect(context.recentAgentProgress == "核心实现完成。swift build 通过，尚未打包。")
        #expect(context.validationResults == ["核心实现完成。swift build 通过，尚未打包。"])
        #expect(!String(describing: context).contains("隐藏推理"))
        #expect(!String(describing: context).contains("原始工具输出"))
    }

    @Test func codexUsesVisibleEventsAndIgnoresRawToolOutput() throws {
        let data = try jsonLines([
            ["type": "event_msg", "payload": [
                "type": "user_message", "message": "继续完成交接，Cookie=session-secret-value",
            ]],
            ["type": "response_item", "payload": [
                "type": "reasoning", "summary": [["text": "内部推理"]],
            ]],
            ["type": "response_item", "payload": [
                "type": "custom_tool_call_output", "output": "原始命令输出 sk-abcdefghijklmnop",
            ]],
            ["type": "event_msg", "payload": [
                "type": "agent_message", "message": "解析测试通过；release build 还没执行。",
            ]],
        ])

        let context = HandoffTranscriptParser.parse(data: data, provider: .codex)

        #expect(context.latestUserGoal == "继续完成交接，Cookie=[已脱敏]")
        #expect(context.recentAgentProgress == "解析测试通过；release build 还没执行。")
        #expect(!String(describing: context).contains("内部推理"))
        #expect(!String(describing: context).contains("原始命令输出"))
    }

    @Test func corruptedAndEmptyLinesDegradeToEmptyContext() {
        let context = HandoffTranscriptParser.parse(
            data: Data("not-json\n{}\n".utf8), provider: .codex
        )

        #expect(context == HandoffTranscriptContext())
    }

    @Test func redactorFiltersCommonSecretsAndSensitivePaths() {
        let text = "Authorization: Bearer abcdefghijklmnop /repo/.env.local ghp_abcdefghijklmnop"
        let redacted = HandoffRedactor.sanitize(text)

        #expect(!redacted.contains("abcdefghijklmnop"))
        #expect(!redacted.contains(".env.local"))
        #expect(HandoffRedactor.isSensitivePath("config/.env.production"))
        #expect(HandoffRedactor.isSensitivePath("keys/private-key.pem"))
        #expect(!HandoffRedactor.isSensitivePath("Sources/App.swift"))
    }

    private func jsonLines(_ objects: [[String: Any]]) throws -> Data {
        var data = Data()
        for object in objects {
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        return data
    }
}

@Suite struct HandoffInstructionBuilderTests {
    @Test func onlyActiveWorkBlocksHandoff() {
        #expect(AgentActivityState.working.blocksTaskHandoff)
        #expect(AgentActivityState.thinking.blocksTaskHandoff)
        #expect(!AgentActivityState.idle.blocksTaskHandoff)
        #expect(!AgentActivityState.awaitingConfirmation.blocksTaskHandoff)
    }

    @Test func instructionIsBoundedAndKeepsRecoveryRequirements() {
        let packet = TaskHandoffPacketV1(
            version: 1,
            id: "packet-1",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceAgent: "Codex",
            targetAgent: "Claude Desktop",
            taskTitle: String(repeating: "很长的任务目标", count: 1_000),
            sessionID: "thread-1",
            cwd: "/tmp/project",
            workspaceRoots: ["/tmp/project", "/tmp/shared"],
            latestUserGoal: String(repeating: "继续实现", count: 1_000),
            recentAgentProgress: String(repeating: "已完成一部分", count: 1_000),
            gitBranch: "codex/handoff",
            changedFiles: ["Sources/App.swift"],
            untrackedFiles: [],
            validationResults: ["swift build 通过"],
            awaitingConfirmation: false,
            unansweredConfirmation: nil,
            transcriptPath: "/tmp/session.jsonl"
        )

        let instruction = HandoffInstructionBuilder.make(
            packet: packet,
            packetPath: "/tmp/handoff.json",
            destination: .claude
        )

        #expect(instruction.count <= HandoffInstructionBuilder.maximumCharacters)
        #expect(instruction.contains("交接包：/tmp/handoff.json"))
        #expect(instruction.contains("/tmp/shared"))
        #expect(instruction.contains("先读取项目规则"))

        let url = HandoffInstructionBuilder.claudeDesktopURL(
            cwd: packet.cwd,
            instruction: instruction
        )
        #expect(url?.scheme == "claude")
        #expect(url?.host == "code")
        #expect(url?.path == "/new")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "q" })?.value == instruction)
        #expect(items?.first(where: { $0.name == "folder" })?.value == packet.cwd)
    }
}

@Suite struct HandoffActivityGuardTests {
    /// 2026-08-21 的回归测试：接力按钮长期是灰的，点不动。
    ///
    /// 原因是守卫复用了状态圆点那套判断——它取全机器最新的那个会话文件，
    /// 并靠 `last-prompt` 认定一轮结束，而记录只读尾部 128 KB。一轮任务写满
    /// 128 KB 后标记滑出窗口，已经停下来的任务反而被判成工作中，按钮就此锁死：
    /// 任务跑得越久越交不出去，正好是最该接力的时候。
    @Test func longRunningTranscriptStillHandsOffOnceQuiet() {
        let now = Date()

        // 尾窗里只剩工具调用、看不到 last-prompt —— 事件流「像」在工作。
        // 但记录已经十分钟没动，说明这一轮早就停了。
        #expect(!HandoffActivityGuard.isBusy(lastWrite: now.addingTimeInterval(-600), now: now))
    }

    @Test func liveTranscriptStillBlocksHandoff() {
        let now = Date()

        #expect(HandoffActivityGuard.isBusy(lastWrite: now.addingTimeInterval(-3), now: now))
        #expect(HandoffActivityGuard.isBusy(lastWrite: now, now: now))
    }

    /// 没有记录路径不该变成「永远不能接力」。取不到证据时放行，
    /// 因为这个判断只用来禁用一个按钮，锁死的代价远大于偶尔放过。
    @Test func missingTranscriptDoesNotBlockHandoff() {
        #expect(!HandoffActivityGuard.isBusy(lastWrite: nil, now: Date()))
    }

    /// 阈值必须短。一轮刚结束、人正要接力的那几十秒，按钮得是活的。
    /// 把它调大就是在悄悄把这个 bug 放回来——所以钉住上界。
    @Test func quietThresholdStaysShortEnoughToBeUsable() {
        #expect(HandoffActivityGuard.quietThreshold <= 30)
    }

    /// 守卫只认任务自己的记录：别的会话（比如后台常驻的 Claude 进程）在忙，
    /// 不该让这一行的按钮变灰。
    @Test func guardReadsTaskOwnTranscript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoff-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let quiet = dir.appendingPathComponent("quiet.jsonl")
        try Data("{\"type\":\"assistant\"}\n".utf8).write(to: quiet)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: quiet.path
        )

        let stopped = AgentTaskReference(provider: .claude, sessionID: "s1", title: "跑了很久的任务",
                                         cwd: "/tmp/project", transcriptPath: quiet.path)
        #expect(!HandoffActivityGuard.isBusy(stopped))

        let live = dir.appendingPathComponent("live.jsonl")
        try Data("{\"type\":\"assistant\"}\n".utf8).write(to: live)
        let running = AgentTaskReference(provider: .claude, sessionID: "s2", title: "正在跑的任务",
                                         cwd: "/tmp/project", transcriptPath: live.path)
        #expect(HandoffActivityGuard.isBusy(running))
    }
}

@Suite(.serialized) struct CodexHandoffDisconnectTests {
    /// 2026-08-21 的回归测试：交接按钮点得动、也有反应，但 Codex 那边报
    /// 「已在另一个应用中打开／请先在那边关闭会话，才能在这里继续」。
    ///
    /// 原因是这条路径把 app-server 连接挂着不放，要等这一轮跑完才断。Codex 的线程是独占的：
    /// 只要还有客户端连着，GUI 打开它就会被挡在门外。而这一轮是无头跑的——
    /// 它一要批准命令就永远停在那儿，`turn/completed` 永远不来，连接就永远不释放，
    /// 每交接一次还泄漏一个 app-server 进程（实测泄漏两个，白烧掉 25 万 token）。
    ///
    /// 正确做法是送完指令立刻断开。指令不会因此丢：app-server 收到 EOF 后
    /// 会把这一轮标记成中断、把用户消息写完再退——真机连跑三次都在，每次 0.25 秒。
    ///
    /// 这个测试拿一个假 app-server 钉住两件事：
    /// 一是 start 会返回，不等这一轮跑完（假服务端故意永远不发 turn/completed）；
    /// 二是假服务端确实读到了 EOF 才收工——说明是关掉 stdin 等它自己退干净的。
    /// 改回 SIGTERM 硬杀这里就会红，而那正是会把刚送进去的用户消息截在半路的写法。
    @Test func startDisconnectsOnceInstructionLands() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.appendingPathComponent("saw-eof")
        let script = dir.appendingPathComponent("fake-codex")
        try fakeAppServer(marker: marker).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        setenv("CODEX_NOTCH_BINARY", script.path, 1)
        defer { unsetenv("CODEX_NOTCH_BINARY") }

        let result = CodexHandoffClient.start(
            cwd: dir.path, workspaceRoots: [dir.path], instruction: "接着把这个任务干完"
        )

        guard case let .success(threadID) = result else {
            Issue.record("start 应当成功，实际拿到 \(result)")
            return
        }
        #expect(threadID == "fake-thread")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 假的 `codex app-server --stdio`：认三个方法，然后就闭嘴——
    /// 模拟真实情况里这一轮卡在等命令批准、`turn/completed` 永远不来。
    private func fakeAppServer(marker: URL) -> String {
        """
        #!/usr/bin/env python3
        import json, sys

        def write(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        while True:
            line = sys.stdin.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method, rid = msg.get("method"), msg.get("id")
            if method == "initialize":
                write({"jsonrpc": "2.0", "id": rid, "result": {}})
            elif method == "thread/start":
                write({"jsonrpc": "2.0", "id": rid,
                       "result": {"thread": {"id": "fake-thread"}}})
            elif method == "turn/start":
                write({"jsonrpc": "2.0", "id": rid,
                       "result": {"turn": {"id": "fake-turn"}}})

        open(r"\(marker.path)", "w").write("eof")
        """
    }
}

@Suite struct AgentActivityReaderTests {
    @Test func claudeMetadataAfterLastPromptStaysIdle() {
        let state = AgentActivityReader.claudeState([
            ["type": "assistant", "message": ["content": [["type": "tool_use"]]]],
            ["type": "last-prompt"],
            ["type": "custom-title"],
            ["type": "user", "message": ["content": [["type": "tool_result"]]]],
            ["type": "attachment"],
        ])

        #expect(state == .idle)
    }

    @Test func newVisibleClaudePromptLeavesIdleBoundary() {
        let state = AgentActivityReader.claudeState([
            ["type": "last-prompt"],
            ["type": "user", "message": ["content": "继续完成任务"]],
        ])

        #expect(state == .thinking)
    }
}
