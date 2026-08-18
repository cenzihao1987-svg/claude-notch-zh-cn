# Codex 重置提醒实施计划

> **给执行者：** 本计划配合 `superpowers:subagent-driven-development` 或 `superpowers:executing-plans` 逐任务执行。每步是 `- [ ]` 复选框，做完打勾。
> **设计依据：** `spec/2026-08-18-Codex重置提醒-design.md`。视觉稿：根目录 `reset-tile-mockup.png`。

**目标：** 把 Codex 卡片里的「套餐」格子换成「重置」格子，按固定优先级在三种内容间切换，外部数据来自 codex-reset.com 的公开 JSON。

**架构：** 一个纯函数决定格子显示什么（`CodexResetTile.make`），一个 actor 负责取数与缓存（`CodexResetForecastService`），`CodexSnapshotMapper` 在组装 stats 时调用纯函数，`AppModel` 负责在恰当时机触发取数。取数与刷新完全解耦——外部站点慢或挂掉，刘海自己的数字一秒都不会被拖住。

**技术栈：** Swift 6 语言模式、SwiftPM、`actor` + `async/await`、`URLSession`、`JSONDecoder(.convertFromSnakeCase)`、`os.Logger`。

---

## 本机约束：`swift test` 跑不了

这台机器只有 Command Line Tools，没有 Xcode，缺 `Testing` 模块。实测：

```
$ swift test --list-tests
Tests/ClaudeNotchTests/BlockCalculatorTests.swift:1:8: error: no such module 'Testing'
error: fatalError
```

**8 个现有测试文件全部无法编译**，不是本次改动造成的。所以本计划**不用 TDD 循环**，用三层替代验证：

| 层 | 手段 | 覆盖什么 |
|---|---|---|
| 编译 | `swift build` | 类型、并发标注、签名兼容 |
| 数据 | `curl` + `python3` 对拍 | 字段名、字段值、JSON 结构 |
| 运行 | 打包实跑 + `log show` | 分支选择、渲染结果、请求时机 |

第三层靠新增的一条 `os.Logger` 记录「选了哪个状态、依据什么输入」，把「肉眼看界面猜」变成「读日志确认」。

**测试文件仍要改。** 现有 `CodexSnapshotMapperTests.swift:178` 断言里出现 `"plan"`，这次会删掉那个格子。虽然本机跑不了，但不能留一个语义已经错的断言给下一台有 Xcode 的机器。

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/ClaudeNotch/UI/CollapsedView.swift` | 改 1 行 | `Fmt.until` 不足 1 小时时不再输出「0小时40分」 |
| `Sources/ClaudeNotch/Model/CodexResetForecast.swift` | 新建 | 外部数据模型 + 三状态纯函数。不含网络、不含 UI |
| `Sources/ClaudeNotch/Core/CodexResetForecastService.swift` | 新建 | actor：取两个端点、缓存、6 小时节流、失败退避 |
| `Sources/ClaudeNotch/Core/CodexUsageProvider.swift` | 改 | 删「套餐」格子；`make` 加 `forecast` 参数；追加重置格子 |
| `Sources/ClaudeNotch/UI/IslandView.swift` | 改 2 处 | 排序数组 `"plan"` → `"reset"`；删掉变成死代码的 `case "plan"` |
| `Sources/ClaudeNotch/UI/AppModel.swift` | 改 | 持有 service；在 `fetchCodexUsage` 里接线 |
| `Tests/ClaudeNotchTests/CodexSnapshotMapperTests.swift` | 改 1 行 | 断言里 `"plan"` → `"reset"` |

拆成两个新文件的理由：纯函数没有依赖，将来这台机器装上 Xcode，`CodexResetTile.make` 可以直接写测试；取数逻辑混在里面就不行了。

---

## Task 1：修 `Fmt.until` 不足 1 小时的分支

重置格子的状态 1 条件是「≤3 小时」，必然会走到不足 1 小时的情况。现在的实现会输出「0小时40分」。

**文件：**
- 修改：`Sources/ClaudeNotch/UI/CollapsedView.swift:12-16`

- [ ] **Step 1：确认现状**

```bash
cd /Users/zp/claude-notch-zh-cn && sed -n '11,16p' Sources/ClaudeNotch/UI/CollapsedView.swift
```

预期输出：

```
    /// "1h 10m" (under a day) or "4d 17h" (a day or more).
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)天\(h)小时" : "\(h)小时\(String(format: "%02d", m))分"
    }
```

- [ ] **Step 2：确认调用点只有一处**

```bash
cd /Users/zp/claude-notch-zh-cn && grep -rn "Fmt.until" Sources/ Tests/
```

预期输出：只有 `Sources/ClaudeNotch/UI/IslandView.swift:433`。若出现别的调用点，停下来重新评估影响面。

- [ ] **Step 3：改成三段式**

把 `Sources/ClaudeNotch/UI/CollapsedView.swift` 第 11-16 行替换为：

```swift
    /// "40分" / "1小时10分" / "4天17小时" —— 剩余时间。不足 1 小时时不写「0小时」，
    /// 因为重置格子会把这个字符串当主数值放大显示，「0小时40分」在那个位置很刺眼。
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(String(format: "%02d", m))分" }
        return "\(m)分"
    }
```

- [ ] **Step 4：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

- [ ] **Step 5：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/UI/CollapsedView.swift && git commit -m "fix: Fmt.until 不足 1 小时时不再输出「0小时」前缀"
```

---

## Task 2：新建 `CodexResetForecast.swift`（模型 + 三状态纯函数）

这是整个功能的大脑，不碰网络、不碰 UI。

**文件：**
- 新建：`Sources/ClaudeNotch/Model/CodexResetForecast.swift`

- [ ] **Step 1：确认目录与既有模型风格**

```bash
cd /Users/zp/claude-notch-zh-cn && ls Sources/ClaudeNotch/Model/
```

预期输出包含 `ProviderUsageSnapshot.swift`。`UsageStatMetric` 与 `UsageLimitMetric` 定义在其中，本文件直接用，不重复定义。

- [ ] **Step 2：写入完整文件**

创建 `Sources/ClaudeNotch/Model/CodexResetForecast.swift`，内容如下（全文，无省略）：

```swift
import Foundation

/// codex-reset.com 提供的非敏感事实。每个字段都可选：接口随时可能少给一项，
/// 少一项只应该让格子少一行，不应该让整个格子消失。
struct CodexResetForecast: Equatable, Sendable {
    /// 距上次确认重置的天数，一位小数。来自 `/api/forecast` 的 `age_days`。
    var ageDays: Double?
    /// 近期几次重置的间隔中位数。来自 `/api/forecast` 的 `cadence.recent_median_days`。
    var recentMedianDays: Double?
    /// Tibo 原话被解析出的英文窗口措辞，例如 "within an hour"。
    var officialWindowLabel: String?
    /// 那个窗口的结束时刻。既用来判断预告是否过期，也用来算倒计时。
    var officialWindowEnd: Date?
}

/// 决定「重置」格子显示什么。
///
/// 固定优先级，不做「谁更早显示谁」：本地倒计时是确定的，Tibo 预告是可能的，
/// 两者不可比。规则可预测比规则最优更重要 —— 用户扫一眼就得知道自己在看什么。
enum CodexResetTile {
    /// 本地窗口进入这个区间就抢占格子。3 小时来自设计文档，不做成可调参数。
    private static let imminentThreshold: TimeInterval = 3 * 3_600

    /// 永远返回一个格子。没有任何数据时返回「重置 / —」，
    /// 这样六宫格始终是满的，不会因为断网塌成五个格子。
    static func make(
        limits: [UsageLimitMetric],
        forecast: CodexResetForecast?,
        now: Date
    ) -> UsageStatMetric {
        imminentLocalReset(limits, now: now)
            ?? announcedWindow(forecast, now: now)
            ?? cadenceFacts(forecast)
            ?? UsageStatMetric(id: "reset", label: "重置", value: "—", subtitle: nil)
    }

    // MARK: - 优先级 1：本地额度即将重置

    /// `now` 决定选哪个窗口；渲染出的字符串走 `Fmt.until`，和旁边额度格子的
    /// 「X 后重置」用同一个格式化器，两处数字必须长得一样。
    private static func imminentLocalReset(
        _ limits: [UsageLimitMetric],
        now: Date
    ) -> UsageStatMetric? {
        let candidates = limits.compactMap { metric -> (date: Date, label: String)? in
            guard let resets = metric.resetsAt else { return nil }
            let remaining = resets.timeIntervalSince(now)
            guard remaining > 0, remaining <= imminentThreshold else { return nil }
            return (resets, metric.label)
        }
        guard let soonest = candidates.min(by: { $0.date < $1.date }) else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "即将重置",
            value: Fmt.until(soonest.date),
            subtitle: windowName(soonest.label)
        )
    }

    /// "5-Hour" 或 "Codex · 5-Hour" -> "5 小时窗口"。
    /// 分隔逻辑与 CodexUsageProvider.durationOrder 一致：桶名在前，时长在后。
    ///
    /// 设计文档说这一行来自 `windowDurationMins`，但 UsageLimitMetric 只带格式化好的
    /// label，不带原始分钟数。label 本来就是 durationLabel(windowDurationMins) 的产物，
    /// 从它反解等价，且不用为了一个副行去改模型。
    private static func windowName(_ label: String) -> String {
        let duration = label.split(separator: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
        switch duration {
        case "5-Hour": return "5 小时窗口"
        case "Daily": return "每日窗口"
        case "7-Day": return "7 天窗口"
        case "Monthly": return "每月窗口"
        case "Annual": return "每年窗口"
        default:
            if duration.hasSuffix("-Hour"), let v = Int(duration.dropLast(5)) { return "\(v) 小时窗口" }
            if duration.hasSuffix("-Day"), let v = Int(duration.dropLast(4)) { return "\(v) 天窗口" }
            if duration.hasSuffix("-Min"), let v = Int(duration.dropLast(4)) { return "\(v) 分钟窗口" }
            return duration
        }
    }

    // MARK: - 优先级 2：Tibo 预告

    /// 过期判断放在渲染时再做一次（而不是只在取数时做）：缓存值可能已经躺了 6 小时，
    /// 那时窗口早就关了。宁可降级到优先级 3，也不能显示一个已经作废的预告。
    private static func announcedWindow(
        _ forecast: CodexResetForecast?,
        now: Date
    ) -> UsageStatMetric? {
        // 先解包整个 forecast 再取字段。写成 `forecast?.officialWindowLabel` 会得到
        // String??（对可选属性做可选链会多包一层），传不进 windowLabel。
        guard let forecast, let end = forecast.officialWindowEnd, end > now else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "Tibo 预告",
            value: windowLabel(forecast.officialWindowLabel),
            subtitle: "约 \(lead(end.timeIntervalSince(now))) 后"
        )
    }

    /// 只翻译见过的确切字符串，其余一律「有预告」。
    ///
    /// 不猜译：`in a bit` 译成「稍后」可能被读成「还早」，做出相反决策。
    /// 也不显示英文原文：`official hint — timing unspecified` 有 34 个字符，
    /// 格子只有 121pt 宽，必然溢出。「有预告」对任何 label 都成立，
    /// 真正可操作的时间在副行 —— 那是 `end_at` 算出来的，不经过任何文本理解。
    private static func windowLabel(_ raw: String?) -> String {
        switch raw {
        case "within an hour", "within the hour": return "1 小时内"
        case "within 30 minutes": return "30 分钟内"
        case "within a few hours": return "几小时内"
        case "later today": return "今天内"
        case "official hint — timing unspecified": return "时间未定"
        default: return "有预告"
        }
    }

    /// "40 分钟" / "2 小时 47 分" / "2 天"。
    /// 比 Fmt.until 粗：预告窗口可以横跨两天（"end of Monday"），也可以只剩几分钟，
    /// 一个格式化器同时照顾两端会很别扭，所以这里单独写一个。
    private static func lead(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { return "\(s / 86_400) 天" }
        if s >= 3_600 {
            let h = s / 3_600, m = (s % 3_600) / 60
            return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时"
        }
        return "\(max(1, s / 60)) 分钟"
    }

    // MARK: - 优先级 3：节奏事实

    /// 显示事实而非概率。接口给的 `rounded_24h: 30` 在它自己的 backtest 里
    /// 只比基线好 3%（brier 0.100 vs 0.103），基本是个常数，看一年也不会变。
    /// 「距上次 5.1 天 · 近期 2.3 天一轮」让用户自己判断「超期一倍了」。
    private static func cadenceFacts(_ forecast: CodexResetForecast?) -> UsageStatMetric? {
        // 同上，先解包 forecast，否则 subtitle 会是 String?? 而不是 String?。
        guard let forecast, let age = forecast.ageDays else { return nil }
        return UsageStatMetric(
            id: "reset",
            label: "距上次重置",
            value: String(format: "%.1f 天", age),
            subtitle: forecast.recentMedianDays.map { String(format: "近期 %.1f 天一轮", $0) }
        )
    }
}
```

- [ ] **Step 3：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

若报 `cannot find 'Fmt' in scope`：`Fmt` 定义在 `Sources/ClaudeNotch/UI/CollapsedView.swift`，与本文件同属 `ClaudeNotch` target，不需要 import，检查是不是拼写问题。

- [ ] **Step 4：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/Model/CodexResetForecast.swift && git commit -m "feat: 新增 Codex 重置格子的数据模型与三状态决策函数"
```

---

## Task 3：新建 `CodexResetForecastService.swift`（取数 + 缓存 + 节流）

**文件：**
- 新建：`Sources/ClaudeNotch/Core/CodexResetForecastService.swift`

- [ ] **Step 1：先对拍接口，确认字段还在**

```bash
curl -s --max-time 20 https://codex-reset.com/api/forecast | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('age_days =', d.get('age_days'))
print('recent_median_days =', (d.get('cadence') or {}).get('recent_median_days'))
"
```

预期输出形如：

```
age_days = 5.1
recent_median_days = 2.3
```

```bash
curl -s --max-time 25 https://codex-reset.com/api/timeline | python3 -c "
import json,sys
d=json.load(sys.stdin)
w=[e['official_window'] for e in d['events'] if e.get('official_window')]
print('events:', len(d['events']), '| with official_window:', len(w))
print('sample:', json.dumps(w[0], ensure_ascii=False))
"
```

预期输出形如：

```
events: 47 | with official_window: 10
sample: {"label": "within an hour", "start_at": "2026-08-13T01:01:37.000Z", "end_at": "2026-08-13T02:01:37.000Z"}
```

**若任一字段消失，停下来告诉龟**，不要改代码去适配一个还没看懂的新结构。

- [ ] **Step 2：写入完整文件**

创建 `Sources/ClaudeNotch/Core/CodexResetForecastService.swift`，内容如下（全文，无省略）：

```swift
import Foundation
import os

/// 读 codex-reset.com 的公开接口。不带任何凭据，取的就是那个网站自己渲染用的匿名 JSON。
/// 两个端点合计约 42KB，一天最多拉 4 次。
actor CodexResetForecastService {
    private static let log = Logger(subsystem: "com.claudenotch.app", category: "reset")

    /// Tibo 的预告提前量是 30–60 分钟，重置集中在 UTC 的一个 3 小时窗口里，
    /// 这里没有任何东西会在几小时内变化。6 小时把请求量压到一天 4 次以内。
    private static let staleAfter: TimeInterval = 6 * 3_600
    /// 失败后的重试间隔。没有它，断网时展开态每 30 秒就会重试一次。
    private static let retryAfterFailure: TimeInterval = 15 * 60

    private var cached: CodexResetForecast?
    /// 上次**成功**的时刻，驱动 6 小时新鲜度判断。
    private var succeededAt: Date?
    /// 上次**尝试**的时刻（成功失败都记），驱动失败退避。
    private var attemptedAt: Date?

    /// 已有的值，不碰网络。
    func current() -> CodexResetForecast? { cached }

    /// 数据过期就拉一次。
    /// - Returns: 缓存值是否真的变了。调用方据此决定要不要重画一次界面；
    ///            返回 false 时不重画，避免「拉取 → 重画 → 又拉取」的死循环。
    @discardableResult
    func refreshIfStale(now: Date = Date()) async -> Bool {
        if let succeededAt, now.timeIntervalSince(succeededAt) < Self.staleAfter { return false }
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < Self.retryAfterFailure { return false }
        attemptedAt = now

        guard let fresh = await Self.load() else {
            // 断网或对方改了结构：继续供应上一份好数据，等下一轮再试。
            // 绝不把一个正在正常显示的格子清空。
            Self.log.notice("reset forecast fetch failed, keeping cached value")
            return false
        }

        succeededAt = now
        guard fresh != cached else { return false }
        cached = fresh
        // 单行字符串：os.Logger 的 OSLogMessage 对多行字面量支持不稳，不要拆行。
        Self.log.notice("reset forecast updated: age=\(fresh.ageDays ?? -1, privacy: .public)d window=\(fresh.officialWindowLabel ?? "none", privacy: .public)")
        return true
    }

    // MARK: - 取数

    private static func load() async -> CodexResetForecast? {
        async let forecastTask = get(ForecastPayload.self, "https://codex-reset.com/api/forecast")
        async let timelineTask = get(TimelinePayload.self, "https://codex-reset.com/api/timeline")
        let (forecast, timeline) = await (forecastTask, timelineTask)

        // 只要有一半拿到就算成功：forecast 挂了还能显示预告，timeline 挂了还能显示节奏。
        guard forecast != nil || timeline != nil else { return nil }

        var result = CodexResetForecast(
            ageDays: forecast?.ageDays,
            recentMedianDays: forecast?.cadence?.recentMedianDays,
            officialWindowLabel: nil,
            officialWindowEnd: nil
        )
        // 这里必须用 if let 而不是 `window?.label`：label 本身是 String?，
        // 再走一层可选链就成了 String??，赋不进 officialWindowLabel。
        if let window = timeline.flatMap(liveWindow) {
            result.officialWindowLabel = window.label
            result.officialWindowEnd = window.end
        }
        return result
    }

    /// 尚未关闭的预告里，结束最早的那一条。
    private static func liveWindow(_ timeline: TimelinePayload) -> (label: String?, end: Date)? {
        let now = Date()
        return timeline.events
            .compactMap { event -> (label: String?, end: Date)? in
                guard let window = event.officialWindow,
                      let raw = window.endAt,
                      let end = parseISO(raw),
                      end > now
                else { return nil }
                return (window.label, end)
            }
            .min { $0.end < $1.end }
    }

    private static func get<T: Decodable>(_ type: T.Type, _ urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeNotch", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    /// end_at 形如 "2026-08-13T02:01:37.000Z"，少数早期记录没有小数秒。
    /// 双 formatter 的写法与 ClaudeDesktopUsageCache 里的一致。
    private static func parseISO(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: - JSON 结构
    // 只声明用得到的字段。多余的键 JSONDecoder 默认忽略，对方加字段不会把我们打挂。

    private struct ForecastPayload: Decodable {
        struct Cadence: Decodable {
            let recentMedianDays: Double?
        }
        let ageDays: Double?
        let cadence: Cadence?
    }

    private struct TimelinePayload: Decodable {
        struct Event: Decodable {
            struct Window: Decodable {
                let label: String?
                let endAt: String?
            }
            let officialWindow: Window?
        }
        let events: [Event]
    }
}
```

- [ ] **Step 3：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

Swift 6 严格并发下若报 `ISO8601DateFormatter` 相关的 Sendable 错误，说明 formatter 被写成了 `static let`——必须在函数内部局部创建，不要提到类型作用域。

- [ ] **Step 4：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/Core/CodexResetForecastService.swift && git commit -m "feat: 新增 codex-reset.com 取数 actor，带 6 小时节流与失败退避"
```

---

## Task 4：`CodexSnapshotMapper` 换格子

**文件：**
- 修改：`Sources/ClaudeNotch/Core/CodexUsageProvider.swift:10-17`（`fetch` 加参数）
- 修改：`Sources/ClaudeNotch/Core/CodexUsageProvider.swift:19-48`（`snapshot` 透传）
- 修改：`Sources/ClaudeNotch/Core/CodexUsageProvider.swift:118-125`（`make` 加参数）
- 修改：`Sources/ClaudeNotch/Core/CodexUsageProvider.swift:154-156`（换格子）

- [ ] **Step 1：`fetch` 接收 forecast**

把 `Sources/ClaudeNotch/Core/CodexUsageProvider.swift` 第 10-17 行替换为：

```swift
    func fetch(forecast: CodexResetForecast? = nil) async -> ProviderUsageSnapshot {
        let transport = transport
        return await withCheckedContinuation { continuation in
            Self.transportQueue.async {
                continuation.resume(returning: Self.snapshot(using: transport, forecast: forecast))
            }
        }
    }
```

`CodexResetForecast` 是 `Sendable` 的结构体，可以安全跨进 `transportQueue` 的闭包。

- [ ] **Step 2：`snapshot` 透传**

把第 19 行的签名：

```swift
    private static func snapshot(using transport: CodexAppServerTransport) -> ProviderUsageSnapshot {
```

改为：

```swift
    private static func snapshot(
        using transport: CodexAppServerTransport,
        forecast: CodexResetForecast?
    ) -> ProviderUsageSnapshot {
```

并把第 37-44 行的 `CodexSnapshotMapper.make(...)` 调用改为：

```swift
            return CodexSnapshotMapper.make(
                account: account,
                rateLimits: rateLimits,
                usage: usage,
                threads: threads,
                errors: errors,
                forecast: forecast,
                now: Date()
            )
```

- [ ] **Step 3：`make` 加参数**

把第 118-125 行的签名替换为：

```swift
    static func make(
        account: CodexAccountResponse?,
        rateLimits: CodexRateLimitsResponse?,
        usage: CodexAccountUsageResponse?,
        threads: CodexThreadListResponse?,
        errors: [Int: String] = [:],
        forecast: CodexResetForecast? = nil,
        now: Date
    ) -> ProviderUsageSnapshot {
```

`= nil` 是必须的：`CodexSnapshotMapperTests.swift` 有 5 处调用不传这个参数，没有默认值那个 target 会编译失败。

- [ ] **Step 4：换掉「套餐」格子**

把第 154-156 行：

```swift
        if let planName {
            stats.append(.init(id: "plan", label: "plan", value: planName, subtitle: nil))
        }
```

替换为：

```swift
        // 「套餐」是一次性信息（看一眼就知道自己是 Plus），这个位置换成会变的重置提醒。
        // 永远 append，没有数据时是「重置 / —」，六宫格不会因为断网塌成五格。
        stats.append(CodexResetTile.make(limits: limits, forecast: forecast, now: now))
```

第 201 行的 `planName: planName` **保留不动**——它是 `ProviderUsageSnapshot` 的字段，删了会改变模型。

> 顺带一提，不要动：`ProviderUsageSnapshot.planName` 目前只有 Claude 那条路径在读（`AppModel.swift:227`），Codex 写进去的这个值实际没有消费者。这是本次改动之前就存在的情况，不在本次范围内。

- [ ] **Step 5：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

- [ ] **Step 6：修测试里已经失效的断言**

`Tests/ClaudeNotchTests/CodexSnapshotMapperTests.swift:178` 现在是：

```swift
        #expect(ids.firstIndex(of: "peak-day")! > ids.firstIndex(of: "plan")!)
```

改为：

```swift
        #expect(ids.firstIndex(of: "peak-day")! > ids.firstIndex(of: "reset")!)
```

新顺序是 `tokens-today, credits, tokens-yesterday, reset, tokens-lifetime, peak-day, longest-task`，断言依然成立。这台机器跑不了 `swift test`，改它是为了不给下一台有 Xcode 的机器留坑。

- [ ] **Step 7：确认没有别的地方还在发 `id: "plan"`**

```bash
cd /Users/zp/claude-notch-zh-cn && grep -rn 'id: "plan"' Sources/ Tests/
```

预期输出：**空**。

- [ ] **Step 8：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/Core/CodexUsageProvider.swift Tests/ClaudeNotchTests/CodexSnapshotMapperTests.swift && git commit -m "feat: Codex 卡片用重置格子取代套餐格子"
```

---

## Task 5：`IslandView` 换位置、删死代码

**文件：**
- 修改：`Sources/ClaudeNotch/UI/IslandView.swift:324`
- 修改：`Sources/ClaudeNotch/UI/IslandView.swift:505`

- [ ] **Step 1：改排序数组**

把第 324 行：

```swift
        for id in ["credits", "plan", "tokens-lifetime"] {
```

改为：

```swift
        for id in ["credits", "reset", "tokens-lifetime"] {
```

这个数组决定展开态六宫格里显示哪几个格子、按什么顺序。重置格子接管的就是「套餐」原来占的第 5 格。

- [ ] **Step 2：删掉变成死代码的那一行**

把 `localizedStatLabel` 里的第 505 行整行删除：

```swift
        case "plan": "套餐"
```

删除后 `localizedStatLabel` 应为：

```swift
    private func localizedStatLabel(_ metric: UsageStatMetric) -> String {
        switch metric.id {
        case "tokens-today": "今日 Token · 账号"
        case "tokens-yesterday": "昨日 Token · 账号"
        case "credits": "可用额度"
        case "tokens-lifetime": "Token · 累计"
        case "peak-day": "单日峰值"
        case "longest-task": "最长任务"
        default: metric.label
        }
    }
```

**注意：不要顺手改成 `case "reset": "重置"`。** 重置格子的 label 随状态变（即将重置 / Tibo 预告 / 距上次重置），在这里写死一个「重置」会把三个状态的标签全盖成同一个，整个功能就废了。末尾的 `default: metric.label` 会把 `CodexResetTile` 产出的中文标签原样放行。

值也一样不用管——`localizedStatValue` 只对 `longest-task` 做转换，其余直接返回 `metric.value`。

- [ ] **Step 3：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

- [ ] **Step 4：确认「套餐」两字在代码里彻底没了**

```bash
cd /Users/zp/claude-notch-zh-cn && grep -rn "套餐" Sources/
```

预期输出：**空**。

- [ ] **Step 5：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/UI/IslandView.swift && git commit -m "feat: 展开态六宫格第 5 格改显示重置信息"
```

---

## Task 6：`AppModel` 接线

关键约束：外部站点慢或挂掉，**不能拖住刘海自己的数字**。所以取数是「发出去就不管」，值落到 actor 缓存里，下一次刷新自然带上；真拉到新值时主动再画一次。

**文件：**
- 修改：`Sources/ClaudeNotch/UI/AppModel.swift:69` 附近（加属性）
- 修改：`Sources/ClaudeNotch/UI/AppModel.swift:484-491`（接线）

- [ ] **Step 1：加属性**

在 `Sources/ClaudeNotch/UI/AppModel.swift` 第 69 行

```swift
    private let codexProvider = CodexUsageProvider()
```

下面新增一行：

```swift
    private let resetForecastService = CodexResetForecastService()
```

- [ ] **Step 2：改 `fetchCodexUsage`**

把第 484-491 行整个函数替换为：

```swift
    func fetchCodexUsage(includeWhenInactive: Bool = false) {
        guard !isPaused, includeWhenInactive || selectedProvider == .codex else { return }

        // 只在真正在看 Codex 卡片时才碰外部站点。桌面小组件那条每 15 分钟的后台刷新
        // （includeWhenInactive: true）只需要 7 天额度，不该为它发第三方请求。
        if selectedProvider == .codex {
            // 发出去就不管：codex-reset.com 慢 15 秒，也不该让刘海的数字晚 15 秒。
            // 拉到的值落进 actor 缓存，下面这次刷新用的是上一份。真拿到新值时
            // refreshIfStale 返回 true，再触发一次刷新把新值画上去。
            Task { [resetForecastService] in
                if await resetForecastService.refreshIfStale() { self.fetchCodexUsage() }
            }
        }

        Task { [codexProvider, resetForecastService] in
            let forecast = await resetForecastService.current()
            let snapshot = await codexProvider.fetch(forecast: forecast)
            self.codexSnapshot = snapshot
            self.updateCodexWidget(from: snapshot)
        }
    }
```

递归最深两层：第二次调用时 6 小时新鲜度检查命中，`refreshIfStale` 返回 `false`，停住。

- [ ] **Step 3：编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3
```

预期输出末行：`Build complete!`

- [ ] **Step 4：提交**

```bash
cd /Users/zp/claude-notch-zh-cn && git add Sources/ClaudeNotch/UI/AppModel.swift && git commit -m "feat: 在 Codex 刷新流程里接入重置数据，取数不阻塞界面"
```

---

## Task 7：打包实跑验证

这是替代 `swift test` 的那一层。**每一项都要真看到，不能靠推断。**

**文件：** 不改代码（第 5 步的临时改动会在第 6 步还原）

- [ ] **Step 1：打包**

```bash
cd /Users/zp/claude-notch-zh-cn && ALLOW_ADHOC=1 bash scripts/make-app.sh 2>&1 | tail -5
```

预期：脚本正常结束并产出 .app。若中途弹出 `SecurityAgent` 钥匙串授权框，那是 ad-hoc 重签名导致 ACL 失效的已知现象，点允许即可。

- [ ] **Step 2：启动，看状态 3**

启动打包好的 app，点开刘海切到 Codex 卡片。

预期：第 5 格 label 是「距上次重置」，值形如「5.1 天」，副行形如「近期 2.3 天一轮」。

对拍——这两个数必须和接口当场返回的一致：

```bash
curl -s --max-time 20 https://codex-reset.com/api/forecast | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('界面应显示: %.1f 天 / 近期 %.1f 天一轮' % (d['age_days'], d['cadence']['recent_median_days']))
"
```

- [ ] **Step 3：读日志确认取数发生过**

```bash
/usr/bin/log show --predicate 'subsystem == "com.claudenotch.app" AND category == "reset"' --last 10m --info
```

预期：一条 `reset forecast updated: age=5.1d window=none`。

注意用 `/usr/bin/log` 全路径——zsh 有个内建的 `log` 会把它挡掉。

- [ ] **Step 4：确认看 Claude 时不发外部请求**

把刘海切到 Claude 卡片，等 3 分钟，再看日志：

```bash
/usr/bin/log show --predicate 'subsystem == "com.claudenotch.app" AND category == "reset"' --last 3m --info
```

预期：**没有新增记录**。切回 Codex 卡片，再切走再切回来，日志也不该增加——6 小时节流生效。

- [ ] **Step 5：临时验证状态 2 的渲染路径**

状态 2 没法等——历史上只有 26% 的重置带预告，窗口只有 30–60 分钟。用历史数据把渲染路径跑通：

在 `Sources/ClaudeNotch/Core/CodexResetForecastService.swift` 的 `liveWindow` 里，把

```swift
                      let end = parseISO(raw),
                      end > now
```

**临时**改成

```swift
                      let end = parseISO(raw)
```

（即去掉过期判断，让最早的历史预告被选中），同时把 `announcedWindow` 里的

```swift
        guard let end = forecast?.officialWindowEnd, end > now else { return nil }
```

**临时**改成

```swift
        guard let end = forecast?.officialWindowEnd else { return nil }
```

然后：

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3 && ALLOW_ADHOC=1 bash scripts/make-app.sh 2>&1 | tail -3
```

重启 app，预期第 5 格变成：label「Tibo 预告」，值「1 小时内」或「30 分钟内」，副行「约 X 后」。

**看到就够了，说明映射表、格式化、渲染三段都通。**

- [ ] **Step 6：还原临时改动**

```bash
cd /Users/zp/claude-notch-zh-cn && git checkout Sources/ClaudeNotch/Core/CodexResetForecastService.swift && git status --short
```

预期：`git status --short` 里不再出现这个文件。

```bash
cd /Users/zp/claude-notch-zh-cn && swift build 2>&1 | tail -3 && ALLOW_ADHOC=1 bash scripts/make-app.sh 2>&1 | tail -3
```

重启 app，第 5 格应该回到「距上次重置」。

- [ ] **Step 7：状态 1 —— 等一个真窗口进入 3 小时**

看展开态里 5 小时窗口那个格子的「X 后重置」。等它跌破 3 小时（每轮 5 小时窗口里必然有 3 小时满足），预期第 5 格自动变成：label「即将重置」，值与额度格子里那个倒计时**完全一致**，副行「5 小时窗口」。

这一步可能要等几十分钟到几小时。**这是唯一必须等待的验证项**，做完前面 6 步就可以先交给龟看。

- [ ] **Step 8：断网降级**

关掉 Wi-Fi，重启 app（缓存清空，且拉不到数据）。

预期：第 5 格显示「重置 / —」，不显示错误、不显示 0、其余五个格子照常（Codex app-server 是本地进程，不走网络）。

- [ ] **Step 9：截图存档**

把三种状态的截图放进根目录，命名 `reset-tile-state1.png` / `reset-tile-state2.png` / `reset-tile-state3.png`，和 `reset-tile-mockup.png` 对比确认字号、间距、留白与设计稿一致。

- [ ] **Step 10：提交验证结果**

```bash
cd /Users/zp/claude-notch-zh-cn && git add reset-tile-state*.png && git commit -m "docs: 重置格子三状态实跑截图"
```

---

## 验收清单

全部打勾才算完成：

- [ ] 展开 Codex 卡片，第 5 格不再是「套餐 / Plus」
- [ ] 状态 3 的两个数字与 `/api/forecast` 当场返回的一致
- [ ] 状态 2 的渲染路径已用历史数据验证过，且临时改动已还原
- [ ] 状态 1 的倒计时与旁边额度格子的「X 后重置」完全一致
- [ ] 断网时显示「—」，不是 0、不是错误、不是塌成五格
- [ ] 看 Claude 卡片时 `category == "reset"` 日志零新增
- [ ] 6 小时内反复切换 Codex 卡片，只拉取一次
- [ ] `grep -rn "套餐" Sources/` 输出为空
- [ ] `grep -rn 'id: "plan"' Sources/ Tests/` 输出为空
- [ ] `swift build` 通过
