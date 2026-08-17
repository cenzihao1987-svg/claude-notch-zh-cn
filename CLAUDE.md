# Claude Notch 改造项目规则

## 项目定位

本项目是 `stevemcqueenz/claude-notch-tracker`（MIT）的本地改造版，用于在 MacBook 刘海中实时查看 **Claude 桌面端**与 **Codex 桌面端**的额度。

改造目标按段推进，当前处于第一段。各段范围见 `spec/`。

## 上游关系

- `upstream` remote 指向原仓库，保留追踪能力
- **改动必须克制**：只动必须动的位置，不顺手重构、不调整格式、不优化无关代码。每一处改动都要能追溯到明确需求
- 目标是上游更新时仍能合并。任何大范围重写都会牺牲这个能力，动手前先确认值得

## 构建与验证

```bash
swift build                            # 编译，约 60–110 秒
ALLOW_ADHOC=1 bash scripts/make-app.sh # 打包 dist/Claude Notch.app
```

**不需要完整 Xcode**即可编译。Command Line Tools + Swift 6.2 已验证可 `swift build`，README 中相反的说法在本机不成立。

但 **`swift test` 在本机跑不了**：测试用 swift-testing 写，`Testing` 模块只随完整 Xcode 分发，Command Line Tools 没有，报 `no such module 'Testing'`。这是环境限制，不是代码问题——验证只能靠实跑 app。

`make-app.sh` 默认要求 Developer ID 证书，本机没有，必须带 `ALLOW_ADHOC=1` 走 ad-hoc 签名。**代价**：ad-hoc 签名的标识是 cdhash，每次重新编译都变，钥匙串 ACL 随之失效，于是每次启动新构建都会弹一次钥匙串授权框，**不点它 `ClaudeAPIService` 就一直阻塞在 `SecItemCopyMatching`，取不到任何额度**（表现为界面停在旧值或 `—`，不报错）。跑验证前先确认这个框已被处理。

改完必须跑验证，不要只改不验。每项改动的验证方式写在对应设计文档的「验证方式」小节，逐条实测。

## 目录约定

- `spec/`：设计文档，命名 `YYYY-MM-DD-主题-design.md`。**不放 `docs/`**——上游 `.gitignore` 忽略 `docs/superpowers/`，且 `docs/` 在上游用于 GitHub Pages
- `Sources/ClaudeNotch/Core/`、`Model/`：数据层，**第一段不动**
- `Sources/ClaudeNotch/UI/`、`System/`：展示与系统集成层，改造集中在此
- 不新建目录、不移动既有文件

## 安全红线

- **不改动数据获取逻辑**（`ClaudeAPIService`、`CodexUsageProvider`）。这两处涉及 cookie、Keychain 与官方接口，改错的后果是账号异常而不只是功能失效
  - 唯一例外经龟逐次授权，且只能**纯新增**：2026-08-17 为修 100% bug 新增了 Claude Desktop OAuth 数据源，既有 cookie/Keychain 分支一行未动。再要动这两个文件，仍需单独授权
- token、cookie、API Key 不进日志、不进 commit、不进诊断信息
- 提高轮询频率前先评估风控风险。`claude.ai/api/organizations/{org}/usage` 是用 session cookie 调用的非公开接口

## 安装

打包后手动替换 `/Applications/Claude Notch.app`。自行构建的版本无 Apple 公证，首次打开需在「系统设置 → 隐私与安全性」放行。
