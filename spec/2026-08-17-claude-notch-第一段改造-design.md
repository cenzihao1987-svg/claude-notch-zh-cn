# Claude Notch 第一段改造设计：刷新分级与前台跟随切换

日期：2026-08-17
状态：待实施
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

固定 60 秒。用户盯着看时嫌慢，但全天候压到 15 秒又是无谓地高频请求 `claude.ai/api/organizations/{org}/usage` —— 这是用 session cookie 调的非公开接口，高频轮询存在触发限流甚至风控的风险。

### 方案

保持单一 Timer，将间隔改为 15 秒，在回调内部按状态决定是否真正发起请求：

- **展开态**（`model.isExpanded == true`）：每次触发都刷新，即 15 秒
- **折叠态**：距上次成功刷新不足 45 秒则跳过
- **provider 因前台切换而变化时**：立即刷新一次（由设计二触发）

判断「距上次成功刷新」复用现有快照的时间戳（`ProviderUsageSnapshot` 已有该字段，`isStale(after:)` 正在使用）。

### 为何不用重建 Timer 的方式

展开/折叠时销毁并重建 Timer 也能实现分级，但会引入 Timer 生命周期管理和竞态。单 Timer + 回调内判断的逻辑集中在一处，更易验证。

### 验证方式

1. 折叠状态下观察日志或网络请求，确认请求间隔约 45 秒
2. 展开面板后确认间隔缩短至 15 秒
3. 折叠后确认恢复约 45 秒
4. 连续运行 30 分钟，确认无 429 或鉴权失败

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

- **接口频率**：展开态 15 秒是对非公开接口的提速。若观察到 429 或鉴权异常，退回 30 秒。这是可回退的单一常量。
- **激活通知频率**：`didActivateApplicationNotification` 在频繁切换应用时触发密集，靠「结果相同则返回」拦截，不会造成请求风暴。
- **上游合并**：改动集中在两个文件的少量位置，上游 v0.3.2 后已近三周无提交，合并冲突风险低。

## 二期备忘

- **中文化**：采用标准 `Localizable.xcstrings` 跟随系统语言，而非硬替换英文串，以保留英文并降低上游合并冲突。可参考 `sk-ruban/notchi` 的实现（已含 zh-Hans / zh-Hant，150 条）。术语需与本机已有的 `/Users/zp/claude-desktop-zh-cn`（Claude Desktop 中文补丁）保持一致，避免同一台机器上两个工具对同一概念叫法不同。真正的工作量在排版而非翻译——中文字宽大于英文，刘海空间极窄，现有布局会被撑破。
- **hover 展开**：参考 `notchi` 的 `Core/NotchHitTestView.swift`，使用折叠态与展开态两个 `NSTrackingArea`（`.mouseEnteredAndExited` + `.activeAlways`），而非 SwiftUI 的 `.onHover`——后者在 non-activating panel 上可靠性存疑。
- **第三方 API 余额**：DeepSeek 与 Kimi 均提供余额查询接口，但返回的是金额而非百分比，需要独立于现有进度条的卡片形态，外加 API Key 输入界面与 Keychain 存储。工作量约等于第一、二段之和。
