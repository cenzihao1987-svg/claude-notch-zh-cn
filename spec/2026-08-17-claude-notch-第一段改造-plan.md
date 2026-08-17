# Claude Notch 第一段改造实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让额度数字在用户关注时 15 秒一刷、不看时 45 秒一刷，并让刘海自动跟随前台的 AI 客户端切换 provider。

**Architecture:** 两处都不新建文件。刷新分级把两个 60 秒 Timer 改成 15 秒 tick + 回调内判断「距上次成功刷新多久」，时间戳复用各自已有的 `fetchedAt`。前台跟随在 `AppMonitor` 新增 `didActivateApplicationNotification` 监听，按 bundle id 精确映射后回调给 `AppModel`，走一个新增 `persist:` 参数的 `selectProvider`，自动切换不写 UserDefaults。

**Tech Stack:** Swift 6.2 / SwiftUI / AppKit / Swift Package Manager，macOS 15+。

对应设计文档：`spec/2026-08-17-claude-notch-第一段改造-design.md`

---

## 执行前必读：本项目不能用标准 TDD

`swift test` 在本机**跑不了**：测试用 swift-testing 写，`Testing` 模块只随完整 Xcode 分发，Command Line Tools 没有，报 `no such module 'Testing'`。这是环境限制，不是能绕过的配置问题。

因此本计划的每个任务用**「改前先确认当前行为 → 改 → 实跑确认新行为」**替代「红-绿-重构」，验证手段是实跑 app 读日志，不是断言。这是刻意的偏离，不是遗漏。

配套的一个前提：现有代码**没有任何日志**，`nettop` 也观测不到进程的网络时序。也就是说**不加日志就无法验证刷新间隔是否真的变了**。所以 Task 1 会加一条 `os.Logger`，并作为正式代码保留——理由见 Task 1 步骤 1。

查日志时有两个坑，都实际踩过：

1. **zsh 下必须用 `/usr/bin/log`**。`log` 是 shell 内建命令，直接写 `log show ...` 会报 `too many arguments`，加了 `2>/dev/null` 就变成静默返回 0 行——看起来像"日志系统里没有记录"，其实命令压根没执行。
2. **日志级别必须用 `notice`，不能用 `debug`**。debug 级别默认不被记录，`log show --debug` 只能显示已记录的、不会追溯启用，结果同样是 0 行。

---

## 文件结构

| 文件 | 职责 | 本次改动 |
|---|---|---|
| `Sources/ClaudeNotch/UI/AppModel.swift` | 全局可观察状态与定时调度 | Timer 间隔改 15 秒；新增 tick 判断、展开即刷新、`selectProvider` 的 `persist` 参数、一条刷新日志 |
| `Sources/ClaudeNotch/System/AppMonitor.swift` | NSWorkspace 事件监听 | 新增前台激活监听与 bundle id → provider 映射 |
| `Sources/ClaudeNotch/App.swift` | 组装与接线 | `monitor.start` 接上新回调 |

> 设计文档「影响范围」只列了前两个文件，漏了 `App.swift`——回调必须在那里接线才生效。以本表为准。

**不改**：`ClaudeAPIService.swift`、`CodexUsageProvider.swift`（CLAUDE.md 安全红线），以及任何 UI 布局与视觉。

---

## 设计文档的两处修正

执行时以下面为准，设计文档里的原话已过时：

1. **时间戳来源**。设计文档说「复用 `ProviderUsageSnapshot` 的时间戳」——那是 Codex 侧的类型。Claude 侧走的是 `ClaudeLimits`，两者都有 `fetchedAt`，但取法不同：
   - Claude：`limits?.fetchedAt`（`ClaudeLimits.fetchedAt: Date`，非可选，`AppModel.swift:72` 已有 `lastFetch` 计算属性）
   - Codex：`codexSnapshot.fetchedAt`（`ProviderUsageSnapshot.fetchedAt: Date?`，可选）
2. **提速打到哪个接口**。不是 claude.ai——那条被 Cloudflare 403 判为 `.rejected` 后锁进 900 秒退避，Timer 再快也影响不到它。真正被提速的是 `api.anthropic.com/api/oauth/usage`。详见设计文档已更新的同名小节。

---

## Task 1: 刷新分级

**Files:**
- Modify: `Sources/ClaudeNotch/UI/AppModel.swift`（`start()` 的 Timer、新增私有方法、`isExpanded` 加 `didSet`）

- [ ] **Step 1: 加刷新日志，先让行为可观测**

没有这条日志，后面所有步骤都无法验证。它作为正式代码保留，不是临时诊断——这个 app 的核心职责就是定时取数，而出问题时（例如刚修掉的「用量恒为 100%」）零可观测性，只能靠 `sample` 抓栈猜。日志只记 provider 名与距上次刷新的秒数，**不含 token、cookie、账号信息**，符合 CLAUDE.md 的红线。

在 `Sources/ClaudeNotch/UI/AppModel.swift` 文件顶部的 `import SwiftUI` 之后加一行：

```swift
import OSLog
```

在 `final class AppModel {` 的第一个属性 `private(set) var snapshot` 之前插入：

```swift
    /// 刷新节奏的可观测性。查看方式见文首「查日志时有两个坑」。
    private static let log = Logger(subsystem: "com.claudenotch.app", category: "refresh")
```

- [ ] **Step 2: 加分级判断与两个 tick 方法**

在 `AppModel` 中 `func fetchLimits(force: Bool = false)` 的正上方插入：

```swift
    /// 展开态每个 tick 都刷；折叠态至少隔 collapsedInterval 秒才刷一次。
    private static let refreshTick: TimeInterval = 15
    private static let collapsedInterval: TimeInterval = 45

    /// 从未成功取过数时返回 true——一直失败就该一直重试，不该被节流锁住。
    private func shouldRefresh(since lastFetch: Date?) -> Bool {
        if isExpanded { return true }
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) >= Self.collapsedInterval
    }

    private func tickLimits() {
        let last = limits?.fetchedAt
        guard shouldRefresh(since: last) else { return }
        Self.log.notice("refresh claude, \(last.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public)s since last")
        fetchLimits()
    }

    private func tickCodexUsage() {
        let last = codexSnapshot.fetchedAt
        guard shouldRefresh(since: last) else { return }
        Self.log.notice("refresh codex, \(last.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public)s since last")
        fetchCodexUsage()
    }
```

- [ ] **Step 3: 把两个 Timer 接到 tick 上**

在 `start()` 中，把这两段：

```swift
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchLimits() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchCodexUsage() }
        }
```

改成：

```swift
        limitsTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLimits() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCodexUsage() }
        }
```

`start()` 末尾原有的 `fetchLimits()` / `fetchCodexUsage()` 首次调用**保持不动**——启动时就该立刻取一次，不走节流。

- [ ] **Step 4: 编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build
```

Expected: `Build complete!`。若报 `cannot find 'Logger'`，是 Step 1 的 `import OSLog` 漏了。

- [ ] **Step 5: 提交**

```bash
cd /Users/zp/claude-notch-zh-cn
git add Sources/ClaudeNotch/UI/AppModel.swift
git commit -m "feat: 刷新分级，展开态 15 秒、折叠态 45 秒"
```

- [ ] **Step 6: 补上「展开即刷新」**

不补的话分级的价值掉一半：折叠态刚好在第 44 秒展开，用户看到的是 44 秒前的旧数，还要再等 15 秒才更新——而他展开就是为了看最新的。

先把 `selectProvider` 里那段 switch 提成可复用方法。在 `func selectProvider` 正上方插入：

```swift
    /// 立刻拉取当前 provider（不 force，不清缓存、不重读 Keychain）。
    private func refreshSelectedProvider() {
        switch selectedProvider {
        case .claude: fetchLimits()
        case .codex: fetchCodexUsage()
        }
    }
```

此时 `selectProvider` 里那段 switch **先原样留着**，Task 2 Step 1 会把它替换成对这个新方法的调用。中间状态有一处重复，是刻意的——让两个任务各自可独立提交。

然后把 `AppModel.swift:13` 的：

```swift
    var isExpanded = false
```

改成：

```swift
    var isExpanded = false {
        didSet {
            guard isExpanded, oldValue == false else { return }
            refreshSelectedProvider()
        }
    }
```

> `@Observable` 宏与 `didSet` 能否共存已实测：单独编译验证过，didSet 正常触发，重复赋同值时被 `oldValue` 判断挡住。不用担心宏会吞掉 observer。

- [ ] **Step 7: 编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build
```

Expected: `Build complete!`

- [ ] **Step 8: 打包并实跑验证分级**

```bash
cd /Users/zp/claude-notch-zh-cn
pkill -f "Claude Notch.app/Contents/MacOS/ClaudeNotch"
ALLOW_ADHOC=1 bash scripts/make-app.sh && open "dist/Claude Notch.app"
```

⚠️ ad-hoc 签名每次编译都换 cdhash，启动后**会弹钥匙串授权框，必须点「始终允许」**，否则取数逻辑一直阻塞在 `SecItemCopyMatching`，日志里一条 refresh 都不会有（表现为数字不动但不报错）。

点掉授权框后，开一个终端跑 3 分钟：

```bash
/usr/bin/log stream --predicate 'subsystem == "com.claudenotch.app"'
```

Expected（刘海保持折叠）：`refresh claude` 每 45–60 秒一条。因为 tick 是 15 秒、阈值是 45 秒，实际落点是 45 或 60 秒，不会更密。

- [ ] **Step 9: 验证展开态**

保持 `log stream` 开着，点开刘海面板并停留 1 分钟。

Expected：展开瞬间立刻一条 `refresh`（Step 6 的效果），随后每 15 秒一条。折叠后恢复到 45–60 秒一条。

- [ ] **Step 10: 挂 30 分钟看有没有被限流**

保持展开态挂 30 分钟，然后确认刘海数字仍然正常、不是 `—`。

Expected：数字正常。若变成 `—` 或长时间不更新，说明 `api.anthropic.com` 开始拒绝——把 Step 2 的 `refreshTick` 改成 30、`collapsedInterval` 改成 90，重新走 Step 4/5/8。这是可回退的两个常量。

---

## Task 2: 前台跟随切换

**Files:**
- Modify: `Sources/ClaudeNotch/System/AppMonitor.swift`（新增激活监听与映射）
- Modify: `Sources/ClaudeNotch/UI/AppModel.swift`（`selectProvider` 加 `persist` 参数）
- Modify: `Sources/ClaudeNotch/App.swift:28`（接线）

- [ ] **Step 1: 给 selectProvider 加 persist 参数**

自动切换若直接调现有的 `selectProvider`，每次前台变化都会覆写用户手动选择的记忆，与「手动只临时生效」冲突，还产生无谓的磁盘写。

把 `Sources/ClaudeNotch/UI/AppModel.swift` 的：

```swift
    func selectProvider(_ provider: UsageProviderID) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
        switch provider {
        case .claude: fetchLimits()
        case .codex: fetchCodexUsage()
        }
    }
```

改成：

```swift
    /// `persist: false` 用于前台跟随的自动切换——只临时生效，不覆盖用户手动选择的记忆。
    func selectProvider(_ provider: UsageProviderID, persist: Bool = true) {
        // 先持久化再判重：自动跟随可能已把 selectedProvider 切成了用户想固定的那个，
        // 此时菜单里再点它一次必须能写进记忆，否则重启会跳回另一个。
        if persist { UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider") }
        guard provider != selectedProvider else { return }   // 同 App 内换窗口也会触发激活通知
        selectedProvider = provider
        refreshSelectedProvider()
    }
```

> 顺序不能反。把 `guard` 写在持久化之前会漏掉这个场景：自动跟随已切到 Codex → 用户在右键菜单点 Codex 想固定它 → `provider == selectedProvider` 被 guard 挡掉 → UserDefaults 没写 → 重启跳回 Claude。

默认值 `true` 保证 `cycleProvider()` 与菜单等现有调用点一行都不用改。`refreshSelectedProvider()` 是 Task 1 Step 6 建的。

- [ ] **Step 2: 编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build
```

Expected: `Build complete!`。若报找不到 `refreshSelectedProvider`，说明 Task 1 Step 6 没做，回去补。

- [ ] **Step 3: AppMonitor 新增前台映射**

在 `Sources/ClaudeNotch/System/AppMonitor.swift` 的 `private let claudeBundleIDs = [...]` 下面加：

```swift
    private let codexBundleIDs = ["com.openai.codex"]
    private var onFrontmostProvider: ((UsageProviderID) -> Void)?
```

> `com.openai.codex` 是 ChatGPT.app 的真实 bundle id，本机实测确认。按常识猜 `com.openai.chat` 会猜错。

把 `start` 的签名从：

```swift
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
```

改成：

```swift
    func start(onChange: @escaping () -> Void,
               onFrontmostProvider: @escaping (UsageProviderID) -> Void = { _ in }) {
        self.onChange = onChange
        self.onFrontmostProvider = onFrontmostProvider
```

在 `start` 内部、现有那个 `for name in [...didLaunch..., ...didTerminate...]` 循环之后插入：

```swift
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor in self?.reportFrontmost(id) }
        }
```

最后，在 `private func updateClaude()` 正上方加：

```swift
    /// 前台切到 Claude 或 ChatGPT 时报告对应 provider；切到别的应用**不报告**，保持当前不变。
    private func reportFrontmost(_ bundleID: String?) {
        guard let bundleID else { return }
        if claudeBundleIDs.contains(bundleID) {
            onFrontmostProvider?(.claude)
        } else if codexBundleIDs.contains(bundleID) {
            onFrontmostProvider?(.codex)
        }
    }
```

沿用文件里既有的精确匹配风格，不用 `contains("claude")` 这种模糊判断——原注释已说明它会误判其它第三方用量工具。

- [ ] **Step 4: 编译**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build
```

Expected: `Build complete!`。若报 `cannot find type 'UsageProviderID' in scope`，在文件顶部 `import AppKit` 下加 `import Foundation` 不解决问题——该类型在同一 module 内，检查拼写。

- [ ] **Step 5: 在 App.swift 接线**

没有这一步前面全都不生效。把 `Sources/ClaudeNotch/App.swift:28` 的：

```swift
        monitor.start { [weak self] in self?.sync() }   // fires on display / Claude changes
```

改成：

```swift
        monitor.start(onChange: { [weak self] in self?.sync() },   // display / Claude changes
                      onFrontmostProvider: { [weak self] provider in
                          self?.model.selectProvider(provider, persist: false)
                      })
```

- [ ] **Step 6: 编译并打包**

```bash
cd /Users/zp/claude-notch-zh-cn && swift build && pkill -f "Claude Notch.app/Contents/MacOS/ClaudeNotch"; ALLOW_ADHOC=1 bash scripts/make-app.sh && open "dist/Claude Notch.app"
```

Expected: `Build complete!` 与 `✓ Done`。同样记得点掉钥匙串授权框。

- [ ] **Step 7: 实机验证跟随切换**

依次做，每步看刘海：

1. 点 Claude.app 到前台 → 刘海显示 Claude 额度
2. 点 ChatGPT.app 到前台 → 刘海切成 Codex 额度
3. 切到 Figma 或浏览器 → 刘海**保持不变、不闪烁**
4. 手动点刘海左侧图标切到另一个 provider → 立即生效；再激活 Claude.app → 自动切回 Claude
5. 在同一个 App 内换窗口（如 Claude.app 开两个窗口来回点）→ `log stream` 里**不应**出现额外的 refresh（`selectProvider` 的 guard 拦住了）

- [ ] **Step 8: 验证手动选择没被自动切换污染**

```bash
cd /Users/zp/claude-notch-zh-cn
# 手动把刘海切到 Codex，然后激活 Claude.app 让它自动切回 Claude，再读：
defaults read com.claudenotch.app selectedProvider
```

Expected: `codex`——记住的是**手动**那次，自动切换没写进去。若读到 `claude`，说明 Step 1 的 `persist` 没接对，或 Step 5 漏传 `persist: false`。

然后重启 app，确认启动后显示的是 Codex。

- [ ] **Step 9: 提交**

```bash
cd /Users/zp/claude-notch-zh-cn
git add Sources/ClaudeNotch/System/AppMonitor.swift Sources/ClaudeNotch/UI/AppModel.swift Sources/ClaudeNotch/App.swift
git commit -m "feat: 前台跟随切换 provider，手动选择只临时生效"
```

---

## Task 3: 回归确认

改的是全局调度与 provider 选择，容易碰坏不相干的地方。

- [ ] **Step 1: 过一遍没动过的功能**

逐项点：菜单的「Refresh now」「Pause」、点图标切 provider、切换头像、面板里的会话列表与周图表、全屏时隐藏（若开着）。

Expected：行为与改动前一致。重点看 **Pause**——`togglePause()` 里调的是 `fetchLimits()` 而不是 tick，恢复时应当立刻刷新一次，不被 45 秒节流挡住。

- [ ] **Step 2: 确认 Claude 数字仍然正确**

刘海显示的 Claude 百分比应与刚修完 bug 时一致（当时实测 five_hour 约 45%），不是 100%、也不是 `—`。

- [ ] **Step 3: 更新设计文档状态**

把 `spec/2026-08-17-claude-notch-第一段改造-design.md` 顶部的 `状态：待实施` 改成 `状态：已实施`。

- [ ] **Step 4: 提交**

```bash
cd /Users/zp/claude-notch-zh-cn
git add spec/2026-08-17-claude-notch-第一段改造-design.md
git commit -m "docs: 第一段改造已实施"
```

---

## 已知会留下的行为

不是 bug，是这次范围内接受的取舍，别当问题去修：

- **未选中的那个 provider 的 Timer 每 15 秒空转一次**：`tickLimits` 会走到 `fetchLimits()`，被里面 `guard selectedProvider == .claude` 挡掉。开销是一次字典查询，不值得为它加第二层判断。
- **取数一直失败时会每 15 秒重试一次**：`shouldRefresh` 在 `fetchedAt` 为 nil 时返回 true 是刻意的——失败就该重试。真正的节流在 `ClaudeAPIService` 的 900 秒 backoff 里，那层不动。
- **面板里的 token 数 / 花费 / 会话列表仍然不准**：本机日志记的是 DeepSeek 的消耗却按 Claude 计价，这次不修，属于二期「接入第三方模型」的范围。
