# Claude Notch 中文版

在 Mac 刘海区域显示 Claude 与 Codex 的额度、重置时间和近期活动。

这是基于 [stevemcqueenz/claude-notch-tracker](https://github.com/stevemcqueenz/claude-notch-tracker)
的简体中文分支，保留上游的 MIT 许可证与版权说明。

## 这一版的重点

- 简体中文界面；展开后将 Claude、Codex 的信息合并为单页。
- Claude 默认只读取 Claude Desktop 已缓存的官方额度响应，不自动访问钥匙串，减少密码弹窗。
  设置中可手动启用受限的 Claude Desktop 备用获取。
- Codex 通过官方本地 `codex app-server` 获取额度；数字和圆环表达剩余额度。
- 每个已连接屏幕都有独立的刘海，可分别展开；收起时会显示非空闲工作状态。
- 展开后的设置入口改为齿轮图标；提供 Codex 剩余额度桌面组件。

## 安装

从 [Releases](../../releases) 下载 DMG，打开后把 `Claude Notch.app` 拖入“应用程序”。

当前发布包为本机 ad-hoc 签名，尚未经过 Apple 公证。首次打开如被系统拦截，到
“系统设置 → 隐私与安全性”选择“仍要打开”。

## 从源码构建

需要 macOS 14+ 与完整 Xcode：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
swift build -c release
ALLOW_ADHOC=1 bash scripts/make-app.sh
```

`make-app.sh` 会清空并重新生成 `dist/`。没有 Developer ID 证书时，产物仅适合本机测试；
对外发布应使用稳定的 Apple Developer ID 签名并完成公证。

## 隐私与数据来源

- Claude：默认只读 Claude Desktop 的本地缓存；不复制登录凭证，也不读取浏览器或 Claude Code
  的凭证。备用获取只有在用户主动开启后才会读取 Claude Desktop 自身的授权信息。
- Codex：使用官方本地 `codex app-server`，不读取或上传提示词、账号邮箱和登录 token。

## 开源许可证与致谢

本项目按 [MIT License](LICENSE) 开源。感谢原作者及上游项目的设计、实现与资源。
