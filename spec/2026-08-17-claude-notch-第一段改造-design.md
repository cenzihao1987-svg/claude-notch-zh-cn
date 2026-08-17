# Claude Notch 第一段改造设计：刷新分级与前台跟随切换

日期：2026-08-17
状态：已实施（展开态一项待龟目视确认，见文末「验证结果」）
上游版本：`94839a4`（v0.3.2）

## 背景

`stevemcqueenz/claude-notch-tracker`（Claude Notch）是目前唯一同时覆盖 **Claude 桌面端**和 **Codex 桌面端**真实额度的刘海工具。已安装使用，基本符合预期，但有四个体验问题需要改造：

1. 界面无中文
2. 额度更新不够及时
3. 需要点击才能展开，期望 hover 展开
4. Claude / Codex 切换需手动点图标

（第五项「接入 DeepSeek / Kimi 等第三方 API 余额」已确认推迟到二期。）

本设计只覆盖 **第 2 和第 4 项**。这两项不触碰 UI 层，改动集中、可独立验证，用于先跑通「改代码 → 编译 → 打包 → 安装」的完整链路，再决定 UI 层（第 1、3 项）如何动。

## 目标

- 额度数字在用户关注时及时更新，同时不显著增加对非公开接口的请求量
- 前台切到哪个 AI 客户端，刘海就显示哪个的额度，无需手动点击
- 全程不破坏上游代码结构，保持后续合并上游更新的能力

## 非目标

- 不做中文化（二期）
- 不做 hover 展开（二期）
- 不接入第三方模型（二期）
- 不改动任何数据获取逻辑（`ClaudeAPIService`、`CodexUsageProvider` 保持原样）
  - 已发生的例外：2026-08-17 为修「用量恒为 100%」在 `ClaudeAPIService` 纯新增了 Desktop OAuth 数据源，见 `spec/2026-08-17-claude用量恒为100-修复-design.md`。本段改造不再动这两个文件
- 不改动 UI 布局与视觉

## 实测确认的前提

这些结论来自本机实测，不是文档推断：

| 项目 | 实测结果 |
|---|---|
| 构建工具链 | **不需要完整 Xcode**。Command Line Tools + Swift 6.2 编译通过，耗时 107 秒。README 中「需要 full Xcode toolchain」的说法在本机不成立 |
| 打包链路 | `scripts/make-app.sh` 存在且可用，产出 `dist/Claude Notch.app` |
| Claude.app bundle id | `com.anthropic.claudefordesktop` |
| ChatGPT.app bundle id | **`com.openai.codex`**（不是 `com.openai.chat`，按常识猜会猜错） |
| 独立 Codex.app | 不存在。Codex 内嵌于 `/Applications/ChatGPT.app/Contents/Resources/codex` |
| `codex` CLI | 不在 PATH 中。`CodexUsageProvider` 的候选路径第一条正是上述内嵌路径，数据源本来就通 |

## 设计一：刷新分级

### 现状

`Sources/ClaudeNotch/UI/AppModel.swift` 的 `start()` 中：

- 第 242 行：`limitsTimer`，60 秒轮询 Claude 额度
- 第 245 行：`codexTimer`，60 秒轮询 Codex 额度

### 问题

固定 60 秒。用户盯着看时嫌慢，但全天候压到 15 秒又是无谓的高频请求。

### 提速真正打到哪个接口（2026-08-17 修 100% bug 后更新）

原先以为被提速的是 `claude.ai/api/organizations/{org}/usage`（session cookie 调的非公开接口）。核实后不是：

- 本机 claude.ai 那条被 Cloudflare 挡回 403，`request()` 判为 `.rejected`，触发 **900 秒退避**。也就是无论 Timer 多快，claude.ai 都是每 15 分钟才撞一次，**提速影响不到它**
- 实际出数的是修 bug 时新增的 Desktop OAuth 分支，打 `api.anthropic.com/api/oauth/usage`。**被提速的是它**
- `ClaudeAPIService` 的 `sessionCache` / `desktopTokenCache` 缓存的是**凭据**不是 usage 结果，所以 Timer 提速等于请求提速，没有缓存兜底

结论：提速的对象从「cookie 调的非公开接口」变成了「官方 OAuth 端点、用官方 token 调用」，风险画像比原设计时低，15/45 秒的分级维持不变。

### 方案

保持单一 Timer，将间隔改为 15 秒，在回调内部按状态决定是否真正发起请求：

- **展开态**（`model.isExpanded == true`）：每次触发都刷新，即 15 秒
- **折叠态**：距上次成功刷新不足 45 秒则跳过
- **provider 因前台切换而变化时**：立即刷新一次（由设计二触发）

判断「距上次成功刷新」复用现有快照的时间戳（`ProviderUsageSnapshot` 已有该字段，`isStale(after:)` 正在使用）。

> **实施后已修正**（见文末事故一节）：数值改为 30 秒 tick / 90 秒折叠节流；claude 侧判断基准从「上次成功刷新」改为「上次发起请求」——用成功时刻做基准会在持续失败时每个 tick 都放行；节流位置从 Timer 回调下沉到 `fetchLimits`，因为展开与前台跟随也是取数入口。codex 侧仍按本节原样（读本地文件，不会被限流）。

### 为何不用重建 Timer 的方式

展开/折叠时销毁并重建 Timer 也能实现分级，但会引入 Timer 生命周期管理和竞态。单 Timer + 回调内判断的逻辑集中在一处，更易验证。

### 验证方式

1. 折叠状态下观察日志或网络请求，确认请求间隔约 90 秒
2. 展开面板后确认间隔缩短至 30 秒
3. 折叠后确认恢复约 90 秒
4. 连续运行 30 分钟，确认无 429 或鉴权失败
5. 失败退避：取数失败时确认间隔按 180 / 360 / 720 / 900 秒递增，且展开态不绕过

## 设计二：前台跟随切换

### 现状

`Sources/ClaudeNotch/System/AppMonitor.swift` 已具备的基础设施：

- 已通过 `NSWorkspace.shared.notificationCenter` 监听应用**启动**与**退出**通知
- 已维护 `claudeBundleIDs` 列表，并采用精确匹配（注释明确说明避免 `contains("claude")` 的误判）
- `AppModel.selectProvider(_:)` 已存在，切换时会自动触发对应 provider 的数据拉取

### 方案

新增对 `NSWorkspace.didActivateApplicationNotification` 的监听。收到通知后取前台应用 bundle id，按下表映射并切换：

| 前台应用 bundle id | 切换到 |
|---|---|
| `com.anthropic.claudefordesktop` | Claude |
| `com.openai.codex` | Codex |
| 其他任意应用 | **保持当前不变** |

映射表沿用 `AppMonitor` 现有的精确匹配风格，不使用模糊包含。

### 切换规则：纯跟随，手动只临时生效

- 前台切到 Claude 或 ChatGPT 时，自动切换到对应 provider
- 用户仍可点击左侧图标手动切换（`cycleProvider()` 保持不变）
- 手动切换的结果在下一次前台变化时被自动跟随覆盖

### 必须处理的细节：不污染手动选择的持久化

`selectProvider(_:)` 当前会执行：

```swift
UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
```

若自动切换直接调用它，每次前台变化都会覆写用户的手动选择记忆，与「手动只临时生效」的语义冲突，且产生无意义的磁盘写入。

方案：将方法签名改为 `selectProvider(_ provider: UsageProviderID, persist: Bool = true)`。自动切换传 `persist: false`，手动切换与菜单操作保持默认 `true`。默认值确保所有现有调用点无需修改。

### 避免重复切换

前台应用在同一个 App 内切换窗口也会触发激活通知。若映射结果与当前 `selectedProvider` 相同则直接返回，不重复拉取数据。

### 验证方式

1. 点击 Claude.app 使其到前台 → 刘海显示 Claude 额度
2. 点击 ChatGPT.app 使其到前台 → 刘海切换为 Codex 额度
3. 切到 Figma 或浏览器 → 刘海保持不变，不闪烁
4. 手动点击图标切到另一个 provider → 生效；随后激活 Claude.app → 自动切回 Claude
5. 重启应用 → 确认启动时的 provider 仍是手动选择过的那个（证明未被自动切换污染）
6. 在同一个 App 内切换窗口 → 确认不产生重复的数据请求

## 影响范围

| 文件 | 改动 |
|---|---|
| `Sources/ClaudeNotch/UI/AppModel.swift` | Timer 间隔与回调内的跳过判断；`selectProvider` 增加 `persist` 参数 |
| `Sources/ClaudeNotch/System/AppMonitor.swift` | 新增激活通知监听与 bundle id 映射 |

预计新增约 30 行，不新建文件，不引入依赖。

## 风险

- **接口频率**：展开态 15 秒提速的是 `api.anthropic.com/api/oauth/usage`（官方端点 + 官方 token），不是 claude.ai 的 cookie 接口——后者被 403 退避锁在 15 分钟一次。若观察到 429 或鉴权异常，退回 30 秒。这是可回退的单一常量。
  > **这条风险当天就命中了**：实测出现 429，已按此退回 30 秒并补上失败退避。但这条预判低估了两点——一是失败**不会**自动降频（服务层不设 backoff、本层用成功时刻做基准），限流会自我维持；二是「可回退的单一常量」不够，还需要退避机制。
- **激活通知频率**：`didActivateApplicationNotification` 在频繁切换应用时触发密集，靠「结果相同则返回」拦截，不会造成请求风暴。
  > **这条判断不完整**：「结果相同则返回」只拦住了重复通知，provider **真的**变化时会立刻取数——在 Claude 与 Codex 之间来回切窗口就是一串真实请求，频率远高于定时器。已把节流下沉到 `fetchLimits` 覆盖这条路径。
- **上游合并**：改动集中在两个文件的少量位置，上游 v0.3.2 后已近三周无提交，合并冲突风险低。

## 验证结果（2026-08-17 实跑）

靠新增的 `os.Logger`（subsystem `com.claudenotch.app`）实测，不是推演。

**下表是 15/45 那一版的实测记录**；因限流事故常量已回退到 30/90（见下节），机制结论仍然成立，只是数值按比例变成 30 秒 tick / 90 秒节流：

| 行为 | 证据 |
|---|---|
| tick 周期 = 15 秒 | 连续多条日志间隔精确 15.000 秒 |
| 折叠态 45 秒节流 | `codex, 57.444819s since last`（阈值 45 + 15 秒粒度 → 落在 45 或 60，符合） |
| 未选中 provider 不打日志 | 90 秒窗口：codex 0 条 / claude 6 条 |
| 前台跟随切换 | 同一进程内 provider 由 codex 自动切成 claude（Claude.app 激活时） |
| 手动选择不被自动切换污染 | 自动切换后 `defaults read` 仍为手动写入的值 |

最强的一段证据是同一个进程内两条线的行为差异：codex 侧 `fetchedAt` 有效，走节流分支得 57.4 秒；被前台跟随切到 claude 后 `fetchedAt` 为 nil，走「失败就重试」分支得 15 秒。**同一个判断的两个分支各自被实测覆盖**，不需要再造用例。

事后看，「失败就重试」这条分支恰恰是限流事故的根因——当时把它读成了功能（一直失败就该一直重试），没意识到它对服务端意味着什么。

**待龟目视确认**：展开态（展开瞬间立刻刷新 + 期间每 30 秒）需要点开面板，无法脚本化。「每个 tick 都刷」已由上表第一行证明；待确认的只是 `isExpanded` 状态本身与 `didSet` 的传递。注意 claude 侧现在展开态也受失败退避约束，若正处于退避窗口内，展开不会立刻取数——这是有意的。

### 实跑中修掉的一个缺陷

未选中的那个 provider 每 15 秒打一条「刷新了」，而 `fetch` 一进去就被 `guard selectedProvider` 挡掉——日志在记录不存在的刷新。计划里原本把这个空转当成无害取舍（「开销只是一次字典查询」），加了日志之后前提就变了：一条说谎的日志比没有日志更糟。两个 tick 都补上了 `guard !isPaused, selectedProvider == ...`。

## 事故：15 秒刷新把账号打到了限流（根因已确证）

**结论：Claude 侧取数失败的原因是 HTTP 429 `rate_limit_error`，诱因就是本次提速。** 刘海显示的「5 小时 20% / 周 —」不是取到的真数，是本地日志兜底值（本地日志算不出周额度所以是 `—`，且它把 DeepSeek 的消耗按 Claude 计价，本身就是错的）。真实值是 5 小时 26% / 周 14%。

### 一个必须记下来的推理错误

先前这一节写着「用假 token 探端点得 **401 而非 429** → 排除提速导致限流」，并据此把矛头指向 token scope。**这个推理是错的**：

- **401 在鉴权阶段就返回了，根本走不到限流检查。** 用无效凭证去探限流，无论是否限流都只会得到 401。
- **限流按账号/token 计，不按 IP 计。** 换一个 token 去探，探的不是同一个额度。

用**真 token** 走同一端点（`/tmp/diag_token.py`，只读、不打印 token 值）立刻得到 `HTTP 429 {"type":"rate_limit_error"}`。同时确认 token 本身完好：4 个 tokenCache 条目全部未过期、108 字符，429 恰恰证明它通过了鉴权。**token scope 的怀疑方向完全错误。**

教训：证伪一个假设时，必须确认探针走的是同一条判定路径。

### 死锁链条

429 不是单次失败，是自我维持的循环，两层缺陷叠加：

1. `usageWithCLIToken` 非 200 一律返回 nil，不区分 429，**且不设 backoff**（上游缺陷：backoff 只在读 token 失败时设，请求失败不设）
2. 本 fork 的 `shouldRefresh` 用**上次成功时刻**（`limits?.fetchedAt`）做节流。取数一直失败 → 该时刻一直不变 → 每个 tick 都放行 → 又是 429

于是：429 → 无 backoff → 15 秒后重试 → 429。而 `if isExpanded { return true }` 让展开态无条件放行，展开着刘海就是无限重试。

### 已采取的修复

数据层在 CLAUDE.md 红线内（`ClaudeAPIService.swift` 未动），修复全部落在 `AppModel`：

| 改动 | 内容 |
|---|---|
| 间隔回退 | `refreshTick` 15 → **30**，`collapsedInterval` 45 → **90** |
| 节流基准 | 从「上次成功时刻」改为**上次发起时刻**（`claudeAttemptedAt`）——这才是死锁的根 |
| 失败退避 | 连续失败翻倍：90 → 180 → 360 → 720 → 上限 **900** 秒（与服务层 backoff 同量级） |
| 退避不可绕过 | 展开态失败时也退避，不再无条件放行 |
| 节流下沉 | 从 `tickLimits` 移到 `fetchLimits`——定时器只是三个入口之一，**展开与前台跟随切换也会立刻取数，切窗口比 tick 频繁得多，只拦定时器等于没拦**。这条是前台跟随功能自带的新风险，先前漏了 |
| 穿透口 | 只有菜单「立即刷新」（`force: true`）能穿透节流与退避 |

还补掉一个实跑中暴露的缺陷：**取数可能无限期挂住**。钥匙串授权框不点，`SecItemCopyMatching` 就一直等，而 `claudeAttemptedAt` 已经记下了发起时刻，于是每 90 秒堆一个 Task——用户一点「允许」，积压的请求会一次性全部发出，正好又撞限流。加了 `claudeInFlight` 标记：上一次没回来就不发。这个判断放在 `force` 之前，因为 `force` 该穿透的是节流**策略**，不是「物理上已有一个请求在飞」。

### 修复后的实测

| 版本 | 机制 | 145 秒内发起取数 |
|---|---|---|
| 事故版 | 15/45，用成功时刻做基准 | 约 10 次 |
| 进程 51156 | 30/90，用发起时刻做基准 | **2 次**（15:45:17 / 15:46:47 / 15:48:17，间隔精确 90.000 秒） |
| 进程 52877 | 再加 in-flight | **1 次**（15:50:02 之后 145 秒无新条目，已跨过 90 秒窗口） |

第二行是死锁修复的直接证据：两个版本都处在「持续失败」状态，事故版 15 秒一次，新版 90 秒一次。第三行证明挂起期间不再积压。

### 失败退避的实测，以及它抓出的第二个 bug

龟点掉授权框后拿到这段日志：

```
16:04:32.844  claude failed 1x, next in 180s
16:04:36.365  claude, 623s since last, 1 fails      ← 只隔 3.5 秒
16:04:36.707  claude failed 2x, next in 360s
```

失败计数与翻倍退避都对，但第二次发起**只隔了 3.5 秒就绕过了 180 秒退避**。原因：`claudeAttemptedAt` 记的是**发起**时刻（15:54:13），而这次请求挂在授权框上 623 秒才返回，退避窗口在请求还没回来时就被消耗光了。623 ≥ 180，于是判断通过。

退避的语义是「失败后等多久再试」，基准必须是失败时刻。已在失败分支里补 `claudeAttemptedAt = Date()`。

这个 bug 只在「单次请求耗时超过退避窗口」时暴露——正常 15 秒超时下退避照常生效，只少算 15 秒。是钥匙串无限期阻塞造出了这个极端条件。**纯推理不会发现它，实跑才会。**

`623s since last` 这条同时旁证了 in-flight 有效：那 623 秒里定时器触发了 7 次，只有 1 次真的发起。

**注意**：该修复提交后**没有重启 app**。限流期间重启会把 `claudeFailures` 归零、退避从 90 秒重新开始，等于增加请求、延长恢复；而当前进程已爬到 360 秒档位。dist 里跑的版本因此比 HEAD 少这一个修复，下次打包时自然带上。要立刻看数据可用菜单「立即刷新」——`force: true` 穿透节流与退避。

退避阶梯实测（同一进程 53872，全程限流中，30 秒 tick 粒度所以实际间隔略大于阈值）：

| 失败次数 | 日志 | 实际间隔 |
|---|---|---|
| 1 | `failed 1x, next in 180s` | 被上面那个 bug 绕过，只隔 3.5 秒 |
| 2 | `failed 2x, next in 360s` | 16:04:36 → 16:10:43 = **366 秒** |
| 3 | `failed 3x, next in 720s` | 16:10:43 → 16:23:13 = **749 秒** |
| 4 | `failed 4x, next in 900s` | 日志值本身就是证据：90×2⁴=1440 被 `min()` 压到 900，没有失控 |

从 90 秒爬到 15 分钟一次，用了 4 次失败、约 19 分钟。既没有卡死在高频，也没有退避到永不重试。

### 一个连带的行为变化

节流下沉到 `fetchLimits` 后，`togglePause()` 恢复时那句 `fetchLimits()` 也受节流约束了——原先是无条件立刻取数。

暂停 10 秒后恢复不会立刻刷新（10 秒前刚取过，本就没必要），暂停几分钟后恢复会刷新。正处在失败退避窗口时也不刷。这个变化是对的，但不在原设计里，记一笔以免后来者当成 bug。菜单「立即刷新」仍然无条件穿透。

`Tests/ClaudeNotchTests/RefreshBackoffTests.swift` 钉住了上述不变量。**注意：本机只装了 CommandLineTools，没有 Xcode.app，`swift-testing` 模块缺失，全套测试（含原有 5 个文件）都跑不起来**，该文件目前是未执行的资产。

**ad-hoc 签名的连带成本**：每次重新打包 cdhash 就变，macOS 视为另一个程序，钥匙串「始终允许」失效，授权框重来一次（上游 issue #6 已知）。所以每改一次代码就要重点一次框。要根治得有 Developer ID 签名。

### 待限流解除后确认

限流解除后应能看到 5 小时 26% / 周 14%。若仍取不到，下一个怀疑点是分支顺序：`fetch(force:)` 里 cookie 路径（第 79 行）排在能用的 OAuth 路径（第 100 行）之前，且 cookie 路径要读 Chromium Safe Storage 钥匙串——ad-hoc 签名每次重建都让 ACL 失效，会弹授权框并**无限阻塞** `SecItemCopyMatching`。

## 二期备忘

- **中文化**：采用标准 `Localizable.xcstrings` 跟随系统语言，而非硬替换英文串，以保留英文并降低上游合并冲突。可参考 `sk-ruban/notchi` 的实现（已含 zh-Hans / zh-Hant，150 条）。术语需与本机已有的 `/Users/zp/claude-desktop-zh-cn`（Claude Desktop 中文补丁）保持一致，避免同一台机器上两个工具对同一概念叫法不同。真正的工作量在排版而非翻译——中文字宽大于英文，刘海空间极窄，现有布局会被撑破。
- **hover 展开**：参考 `notchi` 的 `Core/NotchHitTestView.swift`，使用折叠态与展开态两个 `NSTrackingArea`（`.mouseEnteredAndExited` + `.activeAlways`），而非 SwiftUI 的 `.onHover`——后者在 non-activating panel 上可靠性存疑。
- **第三方 API 余额**：DeepSeek 与 Kimi 均提供余额查询接口，但返回的是金额而非百分比，需要独立于现有进度条的卡片形态，外加 API Key 输入界面与 Keychain 存储。工作量约等于第一、二段之和。
