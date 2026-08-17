# Claude 用量恒为 100% 的修复

日期：2026-08-17
状态：已实现，待实机验证
上游版本：`94839a4`（v0.3.2）

## 现象

刘海里 Claude 的用量数字长期停在 100%，不随实际使用变化。同一时刻账号真实用量是 **45%**（5 小时窗口）。

## 根因

三层叠加，缺一不可：

| 层 | 问题 | 证据 |
|---|---|---|
| 底层 | 本机 Claude Code 指向 `https://api.deepseek.com/anthropic`，本地 JSONL 日志记的是 **DeepSeek** 的消耗，不是 Claude 的 | `~/.claude/settings.json` 的 env |
| 中层 | 两条真实数据源都取不到数，`limits` 恒为 nil | claude.ai 接口被 Cloudflare 挡回 403（JS 挑战，URLSession 过不去）；`/api/oauth/usage` 走的 Keychain 项 `Claude Code-credentials` 里只有 `mcpOAuth`，没有 `claudeAiOauth` |
| 表层 | 于是回落到本地估算 `blockUsageEstimate`，而它在只有一个 5 小时块时恒等于 1.0 | 见下 |

表层这条是数字恒为 100% 的直接原因：

```
blockUsageEstimate = min(1, 当前块 tokens ÷ 历史最大块 tokens)
```

`AppModel` 只读最近 2 天的日志（`ClaudePaths.recentLogFiles(within: 2)`），最近用过 Claude Code 的人**只会有一个块**。一个块时，当前块就是最大块，比值恒为 1.0——不是测出来的 100%，是被除法构造出来的 100%。

用 Python 忠实复现（同样按 mtime 过滤 2 天）：68 个日志文件筛出 10 个 → 76 条事件 → 1 个块 → `min(1, 7,666,822 / 7,666,822) = 1.0000` → 100%。

> 说明：上一轮我扫了全部 68 个文件得到 10.3%，据此说这个假设「被证伪」，那是复现不忠实导致的假阴性。

## 修复

### A. 新增 Claude Desktop 的 OAuth 数据源

`Sources/ClaudeNotch/Core/ClaudeAPIService.swift`。**纯新增**，既有 cookie / Keychain 分支一行未改（经龟单独授权，见 CLAUDE.md 安全红线）。

Claude Desktop 把自己的 OAuth token 缓存在 `~/Library/Application Support/Claude/config.json` 的 `oauth:tokenCache` 字段，用 Chromium Safe Storage 那套加密（PBKDF2-HMAC-SHA1 / `saltysalt` / 1003 轮 / AES-128-CBC）。项目里已有的 `safeStorageKey` 和 `decrypt` 正好能解，不用新写密码学代码。

拿到 token 后打 `api.anthropic.com/api/oauth/usage`。**关键点：这个域名不设 Cloudflare 挑战**，所以 claude.ai 被 403 挡住时它照样通。

插在 CLI token 回退之前，顺序：cookie → **Desktop OAuth** → CLI token。加了独立的缓存与退避，失败不影响其他分支。

Python 端到端验证过：解密 → 取未过期 token → HTTP 200 → `five_hour=45.0`、`seven_day=5.0`。

### B. 样本不足时不给数字

`Sources/ClaudeNotch/Core/UsageStore.swift`、`Model/UsageSnapshot.swift`。

块数 < 2 时 `blockUsageEstimate` 返回 nil，刘海显示 `—`。

> 决策：宁可不显示，也不显示一个永远错的数。一个假的 100% 比一个诚实的「不知道」更有害——前者会让人以为额度用完了。

## 验证方式

1. `swift build` 通过 ✅
2. `ALLOW_ADHOC=1 bash scripts/make-app.sh` 打包通过 ✅
3. 运行 dist 版本，刘海 Claude 数字应为 **45% 附近**而非 100% ⏳ 受阻

第 3 步当前卡在环境问题：ad-hoc 签名的标识是 cdhash，每次重编译都变，钥匙串 ACL 失效，启动时弹授权框。**不点这个框，`SecItemCopyMatching` 会一直阻塞**（`sample` 抓栈已确认，卡在 Swift 并发线程池，主线程不受影响，UI 不冻结）。点一次「始终允许」后即可完成验证。

## 遗留问题

**面板里的 token 数、花费、会话列表同样不可信**：日志是 DeepSeek 的消耗，`PricingTable` 却按 Claude 的价格算。这次只修了百分比，没动这部分——它的正解是二期的「接入第三方模型」，按实际 provider 分别计价，改动范围远超本次修复。
