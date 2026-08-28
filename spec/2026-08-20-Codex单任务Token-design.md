# Codex 单任务 Token 展示

日期：2026-08-20

## 目标

在 Codex「近期任务」列表右侧显示每个任务自身消耗的 Token，例如 `126K`，替代只有更新时间、无法比较任务消耗的现状。

## 数据口径

- 优先通过本机官方 `codex app-server` 取数，不读取 Codex 登录 token，不解析任务提示词。
- 先用 `thread/list` 获取近期任务，再对最终保留的 3 个任务调用 `account/usage/read`，参数为对应的 `threadId`。
- 展示接口 `threadUsage.groups[].totalTokens` 的合计。`cachedInputTokens` 已属于输入明细，不再重复相加。
- 当前账号若未开放任务计费路由、官方结果为 `null`，只读取 app-server 返回的任务
  `path` 对应 JSONL 尾部，并仅解析最新 `token_count.total_token_usage.total_tokens`。
- 官方将该字段定义为 estimated usage，因此只用于任务间消耗比较，不作为精确账单。

## 交互与降级

- 复用现有任务行的右侧 Token 样式，不新增组件、开关或加载动画。
- 某个任务没有 billing route、接口不支持或查询超时时，该任务继续显示最后更新时间。
- 单任务查询是可选增强；失败不得影响额度圆环、账户用量、图表和任务名称。

## 性能与安全

- 每轮最多增加 3 个本地 app-server 请求，并在同一进程中并发发送。
- 可选请求采用独立短超时，不延长核心额度查询的失败链路。
- 本地回退只允许访问 `~/.codex/sessions` 与 `~/.codex/archived_sessions`，最多读取文件
  尾部 2 MB，不解析、保存或展示提示词与回复内容。
- 不记录 thread ID、任务名称、提示词、账号信息或原始响应。

## 验证方式

1. 单元测试：多个 usage group 的 `totalTokens` 正确合计并映射到对应任务。
2. 单元测试：缺少 task usage 时 `tokens` 保持 `nil`，原更新时间降级不变。
3. 真实协议测试：显式开启集成测试后，近期任务能取得大于 0 的 Token（账号和任务支持时）。
4. 完整 Xcode 下运行 `swift test`、release build 与 `git diff --check`。
5. 打包本地测试应用，目视确认任务名称不被挤压、右侧数字格式与现有字号一致。
