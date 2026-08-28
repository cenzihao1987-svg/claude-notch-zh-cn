# Codex 重置提醒设计：把「套餐」格子换成「重置」格子

日期：2026-08-18

## 2026-08-24 信源迁移（覆盖下文旧接口约定）

Tibo 信号改用 `https://codex-resets.com/`。网站明确称其为免费公开 API，OpenAPI
`security` 为空；匿名请求 `GET /api/v1/status` 返回 200，不需要 API Key、Cookie 或登录。
接口会返回 429 和 `Retry-After`，应用仍需节制请求，不能把“免费”理解成无限调用。

- 唯一接口：`https://codex-resets.com/api/v1/status`，当前响应约 0.7KB。
- `data.stats.days_since_last` 映射为距上次重置天数。
- `data.stats.avg_interval_days` 映射为平均重置间隔，文案不得继续写“近期中位数”。
- `data.active_watch` 是站点的 AI 分类预测，不是 OpenAI 官方承诺。有效时卡片显示
  “Tibo 信号”和概率；不得写成“确定重置”。点击卡片到网站查看原文和完整上下文。
- `active_watch.expires_at` 只用于判断观察信号是否仍有效，不得表达成“约 X 后重置”。
- 数据每 15 分钟最多请求一次；失败后保留上一份好数据并继续退避。仅查看 Codex 卡片时
  请求，桌面小组件后台刷新不触发第三方 API。
- 整张 `reset` 卡片可点击，打开 `https://codex-resets.com/`；其他额度、Token 卡片不受影响。
- 旧域名 `codex-reset.com` 的 `/api/forecast` 和 `/api/timeline` 不再调用。

验证必须覆盖：匿名接口实测、固定 JSON 解码、无 active watch、过期 watch、概率缺失、
网络失败保留缓存、整卡链接目标、完整测试、release 构建和真实安装版本。
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
| 3 | 其余时候 | 距上次重置 | `4.5 天` | `近期 2.3 天一轮` |

三个状态的值长度接近（`2 小时 47 分` / `1 小时内` / `4.5 天`），与旁边格子「92%」「1.2M」「无限」的短值风格一致。

> 状态 3 初稿是 label「可能重置」+ 值「距上次 4.5 天」，做出视觉稿后发现值几乎占满 121pt 格宽，在网格里显得字特别多。根因是把描述塞进了值里，与其他格子「label 说明 + 短值」的结构不一致。改为把描述挪回 label。视觉稿见根目录 `reset-tile-mockup.png`。

各字段的确切来源：

- **状态 1 的值** = 距 `resetsAt` 的剩余时间，用现有的 `Fmt.until`。多个窗口同时满足条件时，取 `resetsAt` 最早的那一个
  - `Fmt.until` 在不足 1 小时时会输出「0小时40分」。状态 1 的条件是 ≤3 小时，必然会走到这一段，所以顺带把这个分支修掉（输出「40分」）。全项目只有额度格子的「X 后重置」一处调用它，那一处同样受益
- **状态 1 的副行** = 该窗口的 `windowDurationMins` 经现有 `durationLabel` 转成的中文名（「5 小时窗口」「7 天窗口」）
- **状态 2 的值** = `official_window.label` 经下方中文映射
- **状态 2 的副行** = 距 `official_window.end_at` 的剩余时间。多条事件同时未过期时，取 `end_at` 最早的那一条
- **状态 3 的值** = `forecast.age_days`，一位小数，加「天」
- **状态 3 的副行** = `forecast.cadence.recent_median_days`，一位小数，格式为「近期 X 天一轮」

### 状态 3 为什么显示天数而不是概率

`/api/forecast` 提供 `rounded_24h: 30`、`rounded_48h: 50` 两个概率，但同一份 payload 的 backtest 显示模型只比基线好 3%，`base_daily_rate` 就是 0.294 —— 那个「30%」几乎是个常数，看一年也不会变多少。

`age_days: 4.5` 和 `cadence.recent_median_days: 2.3` 是事实。「距上次 4.5 天 · 近期 2.3 天一轮」让用户自己得出「已经超期一倍，快了」的判断，比一个恒定的百分比有用。

### 英文标签的处理

`official_window.label` 是 Tibo 原文的英文摘要。把 timeline 全部 47 条事件扫一遍，带 `official_window` 的共 10 条，label 只有 6 种取值：

| 原值 | 出现次数 | 显示 |
|---|---|---|
| `within an hour` | 4 | 1 小时内 |
| `within 30 minutes` | 2 | 30 分钟内 |
| `within a few hours` | 1 | 几小时内 |
| `later today` | 1 | 今天内 |
| `official hint — timing unspecified` | 1 | 时间未定 |
| `end of Monday` | 1 | 有预告 |

**未命中映射的值一律显示「有预告」，不猜译、也不显示英文原文。** 两条理由：

1. 猜译会翻车。`in a bit` 译成「稍后」可能被读成「还早」，做出相反决策
2. 英文原文塞不进格子。`official hint — timing unspecified` 有 34 个字符，格子宽 121pt，必然溢出

「有预告」对任何 label 都成立，不含猜测成分；而真正可操作的时间信息在副行——它由 `end_at` 这个机器字段算出，不经过任何文本理解。`end of Monday` 的副行会显示「约 2 天后」，信息没丢。

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
- `Sources/ClaudeNotch/UI/IslandView.swift:495` — 把标签映射里的 `"plan": "套餐"` **整行删掉**，不要换成 `"reset": "重置"`。重置格子的 label 随状态变（即将重置 / Tibo 预告 / 距上次重置），在这里写死一个「重置」会把三个状态全盖掉。该 switch 末尾的 `default: metric.label` 会把 mapper 产出的中文标签原样放行
- `Sources/ClaudeNotch/UI/AppModel.swift` — 持有 service，在 `fetchCodexUsage` 中带上 forecast 数据

复用现有 `tile()` 渲染，三行结构（label / 值 / 副行）与旁边格子完全一致。**不加特殊配色。**

> 行号基于 2026-08-18 的工作区状态。该工作区有 13 个已修改、7 个未跟踪文件（桌面小组件功能）尚未提交，实施前需确认行号仍然准确。

## 验证方式

本机 Command Line Tools 缺少 `Testing` 模块，`swift test` 无法运行（影响全部 8 个既有测试文件，非本次引入）。按项目既定规则，以实跑验证替代。

1. `swift build` 编译通过
2. 断网启动，确认格子显示 `—` 而非崩溃或错误数字
3. 联网后切到 Codex 卡片，确认状态 3 显示的天数与 `/api/forecast` 的 `age_days` 一致
4. 用 `os.Logger` 确认：切到 Claude 卡片时不发外部请求；6 小时内重复切换 Codex 只拉一次
5. 状态 1 需等 5 小时窗口进入 3 小时内实际观察
6. 状态 2 无法等 Tibo 真的发预告（26% 覆盖率、窗口只有 30–60 分钟）。改为临时去掉过期判断，让 timeline 里 10 条历史预告被选中，跑通「映射 → 格式化 → 渲染」三段，看到后立即还原

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
