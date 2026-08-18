# Codex 重置提醒设计：把「套餐」格子换成「重置」格子

日期：2026-08-18
状态：设计已确认，待实施
上游版本：`94839a4`（v0.3.2）

## 背景

OpenAI 会不定期给 Codex 用户额外重置额度，消息来源是 Codex 负责人 Tibo（Thibault Sottiaux，X 账号 `@thsottiaux`）的发帖。龟希望刘海能显示这类重置信息，用来判断「现在冲一波还是等重置」。

现有 Codex 卡片是 3 列 × 2 行六个格子，其中「套餐」格子显示的是 Plus / Pro 这类静态信息 —— 一次性信息，看一眼就够，长期占一个格子是浪费。用它来承载重置提醒。

## 目标

- Codex 卡片上有一个格子随时回答「下次重置是什么时候」
- 抓得到 Tibo 的明确预告，抓不到时也能给出有事实依据的判断
- 外部数据源失效时，体验退回到今天的水平，不出现错误信息

## 非目标

- **不做系统通知**。重置集中在北京时间早上 7–10 点，龟在睡觉，推送没有意义
- **不自己轮询 X**。见下方成本实测
- **不做本地额度跳变检测**。第三方已经在做核实（`reset_verification_status`），重做一遍只会做得更差
- 不加开关。默认启用，不做「关闭联网」选项
- 不改布局，不加特殊配色，格子样式与旁边保持一致

## 实测确认的前提

这些结论来自 2026-08-17 至 18 的实测，不是文档推断。

| 项目 | 实测结果 |
|---|---|
| X API 成本 | 2026 年 2 月起改按次计费，**读一条帖子 $0.005**，旧的 $200 Basic 档不对新用户开放。按 15 分钟轮询、每次 5 条算，约 **$72/月** |
| Tibo 预告覆盖率 | 39 次重置事件中只有 **10 次（26%）** 是预告，其余 74% 是「已经重置了」的事后通报 |
| 预告提前量 | 措辞是 `landing in the next hour or so` / `within the hour` / `over next 30 minutes`，**提前量 30–60 分钟**。唯一一次长提前量（`I'll do another performative reset on Monday`）被标为 `hinted` |
| 预告会放空炮 | 2026-08-13 那条公告的核实结果是 `reset_verification_status: rejected`、`observation_result: unchanged` —— Tibo 说要重置，实际额度没动 |
| 重置时间分布 | 统计窗口 UTC 23:00–02:00，即**北京时间次日 07:00–10:00** |
| 概率预测的信息量 | payload 自带 backtest：`brier: 0.1` vs `baseline_brier: 0.103`，`base_daily_rate: 0.294`。**只赢基线 3%**，报的「24h 内 30%」几乎等同于每天固定说 29.4% |
| 本地已有重置时间戳 | `CodexRateLimitsResponse.Window.resetsAt`（Unix 秒）已存在，`CodexUsageProvider` 已转成 `Date` 存进 `UsageLimitMetric.resetsAt` |
| 服务端缓存策略 | `cache-control: public, max-age=300, stale-while-revalidate=300`，Cloudflare 托管，`access-control-allow-origin: *`，无 `x-ratelimit` 头 |

## 设计一：数据来源

用 `codex-reset.com` 的公开 JSON 接口。该站每约 2 分钟检查一次 Tibo 的 X，把公告解析成结构化数据，并拿实际额度去核实公告是否落地。

| 端点 | 大小 | 取什么 |
|---|---|---|
| `https://codex-reset.com/api/forecast` | 1.5KB | `last_reset_at`、`age_days`、`cadence.recent_median_days` |
| `https://codex-reset.com/api/timeline` | 40KB | 每条 reset 事件的 `official_window` |
| `https://codex-reset.com/api/tibo/signals` | 12KB | **不用**。实测 16 条 item 里 0 条带 `official_window` |

请求是无参数、无鉴权、无 Cookie 的 GET，不携带任何可标识用户的信息。**不经过 Anthropic 或 OpenAI，不消耗也不影响任何额度。**

不自己从 timeline 算「距上次几天、近期节奏」的原因：timeline 里同一天会出现两条 reset 事件，还有 `hinted` 这种不算数的条目，去重规则第三方已经做好，重做一遍只会做错。

关键字段结构（以 2026-08-13 那条为例）：

```json
{
  "official_window": {
    "label": "within an hour",
    "start_at": "2026-08-13T01:01:37.000Z",
    "end_at":   "2026-08-13T02:01:37.000Z"
  }
}
```

这是 Tibo 原文「1 小时内落地」被解析后的结构化结果。有了它，状态 2 的判定不需要碰任何英文文本。

## 设计二：三状态格子

格子标签固定为「重置」，内容按**固定优先级**三选一。优先级不随时间比较——规则可预测优先。

| 优先级 | 条件 | label | 值 | 副行 |
|---|---|---|---|---|
| 1 | 本地任一窗口 `resetsAt` 距现在 ≤ 3 小时 | 即将重置 | `2 小时 47 分` | `5 小时窗口` |
| 2 | timeline 中存在 `official_window.end_at` 尚未过期的事件 | Tibo 预告 | `1 小时内` | `约 40 分钟后` |
| 3 | 其余时候 | 可能重置 | `距上次 4.5 天` | `近期 2.3 天一轮` |

各字段的确切来源：

- **状态 1 的值** = 距 `resetsAt` 的剩余时间，用现有的 `Fmt.until`。多个窗口同时满足条件时，取 `resetsAt` 最早的那一个
- **状态 1 的副行** = 该窗口的 `windowDurationMins` 经现有 `durationLabel` 转成的中文名（「5 小时窗口」「7 天窗口」）
- **状态 2 的值** = `official_window.label` 经下方中文映射
- **状态 2 的副行** = 距 `official_window.end_at` 的剩余时间。多条事件同时未过期时，取 `end_at` 最早的那一条
- **状态 3 的值** = `forecast.age_days`，一位小数
- **状态 3 的副行** = `forecast.cadence.recent_median_days`，一位小数

### 状态 3 为什么显示天数而不是概率

`/api/forecast` 提供 `rounded_24h: 30`、`rounded_48h: 50` 两个概率，但同一份 payload 的 backtest 显示模型只比基线好 3%，`base_daily_rate` 就是 0.294 —— 那个「30%」几乎是个常数，看一年也不会变多少。

`age_days: 4.5` 和 `cadence.recent_median_days: 2.3` 是事实。「距上次 4.5 天 · 近期 2.3 天一轮」让用户自己得出「已经超期一倍，快了」的判断，比一个恒定的百分比有用。

### 英文标签的处理

`official_window.label` 是 Tibo 原文的英文摘要。已观察到的值做中文映射：

| 原值 | 显示 |
|---|---|
| `within an hour` | 1 小时内 |
| `within the hour` | 1 小时内 |
| `next 30 minutes` | 30 分钟内 |
| `next few hours` | 几小时内 |

**未观察到的值直接显示英文原文，不猜译。** 原因：猜错方向比看到英文更糟。用户看到 `in a bit` 至少知道是「快了」；若被译成「稍后」，可能理解成「还早」，做出相反决策。

## 设计三：更新时机与降级

### 更新时机

- 数据超过 **6 小时**未更新时，在下一次 Codex 刷新中顺带拉取
- **仅当 `selectedProvider == .codex` 时才发请求**。看 Claude 时一个外部请求都不发
- 桌面小组件那条每 15 分钟的后台 `fetchCodexUsage(includeWhenInactive: true)` **不触发** forecast 拉取 —— 小组件只显示 7 天额度剩余，不显示重置提醒

选 6 小时而不是 24 小时：重置集中在北京时间早上 7–10 点，6 小时间隔保证起床时看到的数据不会是昨天下午的。按最坏情况每天 4 次 × 42KB ≈ 168KB/天。服务端自己声明 `max-age=300`，每天 4 次远在容忍度内。

### 降级

| 情况 | 行为 |
|---|---|
| 网络失败 | 保留上次成功的数据继续显示，不清空 |
| JSON 解码失败 | 同上。所有字段声明为可选，任何字段缺失都不导致整体解码失败 |
| 从未成功过 | 状态 2、3 不可用，格子只在状态 1 条件成立时有内容，其余显示 `—` |

最坏情况等价于「只有本地倒计时」，与今天的体验持平，不会更差。

## 代码落点

改动集中，不触碰数据获取与鉴权逻辑。

**新增：**

- `Sources/ClaudeNotch/Core/CodexResetForecastService.swift` — 拉取两个端点、解码、内存缓存与 6 小时节流
- `Sources/ClaudeNotch/Model/CodexResetForecast.swift` — 数据模型 + 三状态判定纯函数

三状态判定写成纯函数（输入：本地 limits、forecast 数据、当前时间；输出：label / 值 / 副行），不依赖任何全局状态，便于将来补测试。

**修改：**

- `Sources/ClaudeNotch/Core/CodexUsageProvider.swift:154` — 删掉 `plan` stat tile，改为生成 `reset` stat tile
- `Sources/ClaudeNotch/UI/IslandView.swift:314` — 格子顺序数组里 `"plan"` 换成 `"reset"`
- `Sources/ClaudeNotch/UI/IslandView.swift:495` — 标签映射 `"plan": "套餐"` 换成 `"reset": "重置"`
- `Sources/ClaudeNotch/UI/AppModel.swift` — 持有 service，在 `fetchCodexUsage` 中带上 forecast 数据

复用现有 `tile()` 渲染，三行结构（label / 值 / 副行）与旁边格子完全一致。**不加特殊配色。**

> 行号基于 2026-08-18 的工作区状态。该工作区有 13 个已修改、7 个未跟踪文件（桌面小组件功能）尚未提交，实施前需确认行号仍然准确。

## 验证方式

本机 Command Line Tools 缺少 `Testing` 模块，`swift test` 无法运行（影响全部 5 个既有测试文件，非本次引入）。按项目既定规则，以实跑验证替代。

1. `swift build` 编译通过
2. 断网启动，确认格子显示 `—` 而非崩溃或错误数字
3. 联网后切到 Codex 卡片，确认状态 3 显示的天数与 `/api/forecast` 的 `age_days` 一致
4. 用 `os.Logger` 确认：切到 Claude 卡片时不发外部请求；6 小时内重复切换 Codex 只拉一次
5. 状态 1 需等 5 小时窗口进入 3 小时内实际观察
6. 状态 2 只能等 Tibo 下次发预告时观察，无法主动触发。**在此之前状态 2 视为未验证**

## 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 第三方改 schema | 状态 2、3 失效 | 字段全可选，解码失败只影响这个格子；decoder 集中在一个文件，坏了只改一处 |
| 第三方停服或转收费 | 同上 | 同上。最坏退回状态 1 |
| 状态 2 长期无法验证 | 预告功能可能一直是坏的却没人发现 | 实施时用 `official_window` 已过期的历史数据构造一次手工验证，确认渲染路径通 |
| 状态 1 占据格子时间较长 | 5 小时窗口每周期有 3 小时满足条件（60% 时间），与左侧格子的重置副行信息重复 | 已知并接受。龟的判断是格子本来就该回答「下次什么时候重置」，重复可接受 |

## 被否决的方案

**自己调 X API。** $72/月，且凭据要落在客户端、限流自己扛。价格不是唯一问题——一个刘海挂件直连 X API 本身架构就不对。

**只订阅 `/feed.xml`（Atom）。** 格式比私有 JSON 稳定，但拿不到结构化的时间窗和核实结果，要自己从英文里抠语义。等于把第三方最有价值的工作重做一遍且做得更差。

**纯本地不联网。** 零依赖，但「监测 Tibo」这个原始诉求直接落空，只剩本地倒计时。

**状态 1 加「额度快见底」双条件。** 设计过程中提出过：只在剩余低于阈值且 3 小时内重置时才占用格子，避免 60% 时间被占。龟否决：「有那么复杂吗？把套餐这个 div 用来做重置提醒就好了」。**否决是对的** —— 双条件引入一个需要调参的阈值，换来的只是格子内容切换更频繁，不构成收益。记录在此以免日后重新提出。

**按「谁更早」比较状态 1 与状态 2。** 设计过程中建议过用「哪个重置来得更早显示哪个」替代固定优先级。龟选择固定优先级。固定规则可预测，且省掉「确定的时间与可能的时间怎么比较」这个边界问题。
