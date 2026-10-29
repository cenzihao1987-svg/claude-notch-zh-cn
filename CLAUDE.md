# Claude Notch 改造项目规则

## 项目定位

本项目是 `stevemcqueenz/claude-notch-tracker`（MIT）的本地改造版，用于在 MacBook 刘海中实时查看 **Claude 桌面端**与 **Codex 桌面端**的额度。

改造目标按段推进，当前处于第一段。各段范围见 `spec/`。

## 环境守护目标与宗旨

**Claude 环境守护的首要目标：在保留中国用户 macOS 日常使用习惯的前提下，尽可能降低 Claude 账号被封禁的风险。**

后续需求判断、检测项选择、实现和界面表达均遵循以下原则：

- **以实际防护价值为先。** Anthropic 的完整风控规则不公开，不把获得完整规则、证明某项一定导致封号或计算精确封号概率作为推进防护的前提。缺少公开证据，不等于没有风险。
- **审慎处理中文相关信号。** 中文语言、简繁体偏好、客户端持久化语言配置、系统与进程的地区和时区、网页层语言与 Locale 等，均纳入检查和防护评估。对合理疑虑，在已授权范围内优先评估并提供可控、可逆的处理方案，不仅停留在“尚无证据”的解释。
- **保留日常习惯，控制改动范围。** 优先采用 Claude 专属配置和应用级隔离，不改用户的 macOS 全局语言、地区、时区或输入法；网络继续由用户的 VPN 管理。保留用户选择、手动覆盖、配置记忆和必要备份，避免防护措施本身引入更大风险。
- **形成检测、优化、实际核验的闭环。** 不只检查设定或启动参数，还要核对当前实例真正读到的值；发现配置不一致或守护缺口时，优先补齐处理能力。区分已确认事实与预防性判断，不把未知结果标为已通过，也不作绝对安全承诺。
- **界面突出守护与操作。** 主要展示当前风险、守护状态、网页层实际值、可优化项及一键操作。不新增或反复突出“不能保证不封号”等免责声明，不让此类提示占据主要视觉层级；读取失败、配置未生效等具体状态仍须清楚反馈。

本节确立产品目标与后续判断原则；具体能力和工程约束以对应 `spec/` 为准，既有授权与隐私边界继续适用。

## 上游关系

- `upstream` remote 指向原仓库，保留追踪能力
- **改动必须克制**：只动必须动的位置，不顺手重构、不调整格式、不优化无关代码。每一处改动都要能追溯到明确需求
- 目标是上游更新时仍能合并。任何大范围重写都会牺牲这个能力，动手前先确认值得

## 构建与验证

```bash
swift build                            # 编译，约 60–110 秒
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/make-app.sh
```

**不需要完整 Xcode**即可编译。Command Line Tools + Swift 6.2 已验证可 `swift build`，README 中相反的说法在本机不成立。

`swift test` 需要本机已安装的完整 Xcode；只选用 Command Line Tools 会报 `no such module 'Testing'`。

本机已有 `Claude Notch Local` 自签名证书，`make-app.sh` 会自动使用它，让每次重建的签名身份保持稳定，公开安装包也用它签名。没有 Developer ID 时安装包未经 Apple 公证，用户首次打开需在「系统设置 → 隐私与安全性」点「仍要打开」，发布说明必须写明。不要用钥匙串里的 `Apple Development` 证书签名：它会把账号邮箱写进签名，且同样无法通过 Gatekeeper。

改完必须跑验证，不要只改不验。每项改动的验证方式写在对应设计文档的「验证方式」小节，逐条实测。

## 发布 GitHub Release（硬性要求）

**每个 Release 必须附带安装包 `ClaudeNotch-v<版本>.dmg`；只有源码归档和效果图不算发布完成。**（2026-10-29 龟要求；v1.1.2 曾漏传。）

1. 从 tag 指向的提交导出干净源码再构建，不用带未提交改动的工作区：`git archive <提交> | tar -x -C <临时目录>`，在其中运行上面的 `make-app.sh`。
2. `bash scripts/make-dmg.sh "<临时目录>/dist/Claude Notch.app"` 生成 DMG；脚本会校验签名，并挂载 DMG 复核其中的应用。
3. 发布时带上 DMG：`gh release create <tag> <dmg> …`，补传用 `gh release upload <tag> <dmg>`。
4. 发布说明写明：下载 DMG → 拖入「应用程序」→ 首次打开的放行步骤；当前构建只支持 Apple Silicon（arm64）；附 DMG 的 SHA-256；安装后从刘海启动 Claude 才会应用专属配置。
5. 发布后核验：`gh release view <tag> --repo cenzihao1987-svg/claude-notch-zh-cn --json assets` 必须列出该 `.dmg`，下载回来比对 SHA-256，结果写进对应的 `spec/…-publish-validation.json`。
6. 公开发布本身仍需龟确认（全局红线）；确认的是「发不发」，不是「带不带安装包」。

## 目录约定

- `spec/`：设计文档 `YYYY-MM-DD-主题-design.md`，实施计划 `YYYY-MM-DD-主题-plan.md`。**都不放 `docs/`**——上游 `.gitignore` 忽略 `docs/superpowers/`，写进去会被静默丢弃；且 `docs/` 在上游用于 GitHub Pages
- `Sources/ClaudeNotch/Core/`、`Model/`：数据层，**第一段不动**
- `Sources/ClaudeNotch/UI/`、`System/`：展示与系统集成层，改造集中在此
- 不新建无归属的目录、不移动既有文件。

2026-08-17 新增的 `ClaudeDesktopUsageCache` 是一个只读本地数据源：读取 Claude Desktop
已经缓存的官方 `/usage` 响应，不自行发请求。它可以新增在 `Core/`，但不得改变缓存内容、
不得把缓存原文或组织 ID 写入日志，也不得替代下面对网络数据源的逐次授权要求。

## 安全红线

- **不改动数据获取逻辑**（`ClaudeAPIService`、`CodexUsageProvider`）。这两处涉及 cookie、Keychain 与官方接口，改错的后果是账号异常而不只是功能失效
  - 唯一例外经龟逐次授权，且只能**纯新增**：2026-08-17 为修 100% bug 新增了 Claude Desktop OAuth 数据源，既有 cookie/Keychain 分支一行未动。再要动这两个文件，仍需单独授权
- token、cookie、API Key 不进日志、不进 commit、不进诊断信息
- 提高轮询频率前先评估风控风险。`claude.ai/api/organizations/{org}/usage` 是用 session cookie 调用的非公开接口
- Claude Desktop 的 `Cache/Cache_Data` 只允许只读；最多读取 1 MiB 的候选响应，解压程序只认
  `/opt/homebrew/bin/zstd` 或 `/usr/local/bin/zstd`，不从可被注入的任意路径执行程序

## 2026-10-14 环境守护扩展授权

龟已确认环境守护方案与效果图，并授权实现。此功能可在 `Core/`、`Model/` 新增独立检测、判断和启动模块，
并让现有任务接力复用专属启动器；不改变 `ClaudeAPIService`、`CodexUsageProvider` 和任何凭据获取逻辑。
环境状态只在 Claude 页显示，以状态和去重后的待处理项数表达，不估算封号概率。
系统语言、地区、时区、输入法及 VPN 均不修改。语言、地区和时区仅通过新实例启动参数传入。
公开版功能与工程约束见 `spec/2026-10-15-claude-environment-guard-release-design.md`；本机调试与备份记录不随源码发布。

## 安装

打包后手动替换 `/Applications/Claude Notch.app`。自行构建的版本无 Apple 公证，首次打开需在「系统设置 → 隐私与安全性」放行。

## 2026-10-14 Chromium 网页层守护授权

龟已明确同意备份后修改 Claude 客户端，接受本地重签和升级后重新适配。仅加入只读网页环境采集模块；
不移除官方调试限制，不开放调试端口，不读取聊天、账号、Cookie、Token 或网页存储。
采集由专属启动的一次性会话标记启用，普通启动不采集；对比结果复用现有核验信息入口。
保留完整原版备份和 ASAR 完整性校验。手动界面验收交给龟，不再代为操作 Claude 做手动验收。
