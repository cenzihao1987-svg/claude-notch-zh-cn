# Codex、Claude 与 WorkBuddy 上下文接力

日期：2026-08-20

## 目标

在展开态的近期任务中，由用户手动把一个已经停止的 Codex 任务交给 Claude 桌面端中的 Code 会话或
WorkBuddy，或把一个已经停止的 Claude Code 会话交给 Codex 或 WorkBuddy。WorkBuddy 仍只作为
交接目标，不实现 WorkBuddy 向其他 Agent 的反向接力；其独立的用量与近期任务只读展示见
`2026-08-30-WorkBuddy用量-design.md`。接力
恢复的是可验证的任务现场，不复制模型
未公开的内部思考，也不把刘海工具改造成自动编排多个 Agent 的中枢。

## 交接数据

每次接力生成一个独立的 `TaskHandoffPacketV1` JSON 文件，保存到：

`~/Library/Application Support/Claude Notch/Handoffs/`

记录不覆盖旧文件，也不由应用自动删除。交接包只包含：

- 来源 Agent、任务标题、会话 ID、主工作目录、额外工作目录和原会话记录位置。
- 最后一条可见的有效用户目标、最近一条可见的 Agent 进度说明。
- 当前 Git 分支、已修改文件、未跟踪文件。
- 来源任务是否仍有未回答的确认请求。

验证结果只在 Agent 的可见进度说明明确提到时保留，不复制命令的原始输出。目标 Agent
必须重新检查真实工作区，不能把交接包中的状态当作最终事实。

## 隐私与安全边界

- 只读取来源任务自己的本地 JSONL 记录，并限制读取文件尾部 2 MB。
- Claude 仅接受 `~/.claude/projects/` 下的记录；Codex 仅接受
  `~/.codex/sessions/` 与 `~/.codex/archived_sessions/` 下的记录。
- 只提取正常用户文本和正常 Agent 文本；忽略 reasoning、thinking、tool use、tool result、
  原始工具输出、sidechain 和 meta 消息。
- 保存和启动前再次脱敏：过滤 `.env` 路径、Token、Cookie、Authorization、私钥和常见
  凭证格式。交接功能不读取 Keychain，不读取浏览器 Cookie，不改额度轮询逻辑。
- 来源 Agent 处于工作中或思考中时禁用接力，防止两个 Agent 同时修改文件。待确认或空闲
  状态可以由用户手动接力。

## 启动流程

### Codex → Claude 桌面端

生成不超过 5,000 字符的交接指令，通过 Claude Desktop 官方
`claude://code/new?q=...&folder=...` 深链，在 Claude 桌面端新建 Code 会话、带入来源
工作目录并预填指令。Claude 会要求用户确认目录；用户检查指令后按 Enter 开始。不得调用
`claude-cli://` 或启动终端 CLI。若系统无法打开深链，保留交接包、复制指令到剪贴板并打开
Claude 桌面端；不能静默显示成功。

### Claude Code → Codex

通过本机 `codex app-server` 的 `thread/start` 创建任务，再用 `turn/start` 提交交接指令，
设置来源工作目录和额外工作目录。成功后打开 `codex://threads/<threadId>`。若创建任务、提交
指令或深链打开失败，保留交接包、复制指令到剪贴板并用 Codex 打开来源工作目录；失败必须
在界面上有明确反馈。

### Codex / Claude Code → WorkBuddy

通过本机 WorkBuddy 桌面端的
`workbuddy://task?action=start&prompt=...&cwd=...&welcomeMode=code` 深链，传入不超过
5,000 字符的交接指令和来源任务的主工作目录。深链只预填任务，用户检查后按 Enter
开始；不自动发送，不指定模型、Skill、连接器或权限模式。额外工作目录仍写入交接指令，但
不通过深链自动授权。

启动前用 `com.workbuddy.workbuddy` 检查应用。未安装时保留交接包、复制指令并显示
“未找到 WorkBuddy，交接指令已复制”。深链未打开时复制指令并尝试直接打开 WorkBuddy，
显示降级原因。不使用 WorkBuddy 本地数据库、`conversations.get/fork` 或其他未公开执行接口。

目标 Agent 的首条指令固定要求：先读取项目规则，检查工作区和现有改动，确认已完成与未完成
部分，再继续执行；不得重复已完成工作，不得覆盖用户或其他 Agent 的现有改动。

## 界面

- 展开态“近期任务”每行悬停时出现“接力文字 + 右侧图标”的胶囊菜单按钮，
  不使用只有图标、依赖悬停提示才能理解的入口。
- 按钮内容固定为左侧“接力”、右侧接力图标。Codex 行的菜单显示“交给 Claude”和
  “交给 WorkBuddy”；Claude 行显示“交给 Codex”和“交给 WorkBuddy”。Codex 侧的 Claude
  目标仍指 Claude 桌面端中的 Code 会话。
- Claude 与 Codex 均只显示“近期任务”；Claude 不再提供“活跃会话/累计 · 高频项目”切换，
  避免累计项目因没有唯一会话记录而无法出现接力按钮。
- 工作中或思考中时按钮禁用，并提示“先停止当前任务再接力”。
- Claude 出现 `last-prompt` 结束标记后追加的工具结果、附件和标题元数据不得重新把会话
  判为工作中；只有新的真实用户消息才重新进入思考状态。
- 生成中显示进度；Claude/Codex 成功显示“已交给 …”，WorkBuddy 成功显示
  “已打开 WorkBuddy，请检查后发送”；降级时显示指令已复制；失败显示原因。
- 累计高频项目没有唯一会话记录，不显示接力按钮。
- 不根据额度比例或剩余时间自动提醒，不自动触发接力。
- 悬停出现或收起接力按钮时，任务行和整个任务列表的高度、上下位置必须保持不变；按钮只替换该行右侧的信息区域。

## 内部接口

- `AgentTaskReference`：来源、会话 ID、标题、目录和记录位置。接力来源仍只有 Claude/Codex。
- `HandoffDestination`：Claude Desktop、Codex 和 WorkBuddy 三种内部交接目标。
- `TaskHandoffPacketV1`：统一、可版本化的交接包。
- `HandoffResult`：目标已打开、只生成并复制交接指令、失败。
- `HandoffCoordinator.handoff(task:to:awaitingConfirmation:)`：提取、脱敏、保存和启动的唯一入口。

额度展示只把近期任务映射为 `AgentTaskReference`，不承担交接实现。

## 验证方式

1. 固定脱敏样本：Claude、Codex 均只提取可见用户/Agent 文本，忽略思考和工具输出。
2. 固定脱敏样本：Token、Cookie、私钥、`.env` 路径被替换或排除。
3. 异常样本：损坏记录、空会话、非 Git 目录和无记录路径仍能生成最小交接包。
4. 启动降级：Claude 桌面端未安装、app-server 失败、WorkBuddy 未安装或深链失效时，
   交接包仍存在且指令进入剪贴板。
5. 临时仓库手动完成 Claude/Codex 双向接力及两种来源到 WorkBuddy 的接力，核对目标、待办、
   修改文件和工作目录，并确认 WorkBuddy 只预填、不自动发送。
6. 工作中/思考中的来源任务不能接力，原会话记录和项目文件的内容及修改时间不被改变。
7. 执行 `swift test`、release build、`git diff --check`、ad-hoc 打包和真实界面检查；当前
   工具链缺少 `Testing` 模块时单独记录，不用构建通过替代单测结论。
8. 在有两条近期任务的列表上反复移入、移出、打开和关闭接力菜单，确认任务标题、列表顶部和底部均没有上下位移。
