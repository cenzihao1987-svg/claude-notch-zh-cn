# Codex 桌面小组件设计

## 目标

参考用户提供的横向黑色卡片，新增 macOS WidgetKit 中号桌面小组件，展示 Codex 7 天额度的剩余百分比、分段进度、重置日期与剩余天数。

## 成功标准

1. 无 Apple 开发者证书的本地构建也能直接在桌面显示中号尺寸组件，并可拖动位置、从刘海右键菜单显示或隐藏。
2. 大数字与进度条都表达“剩余”：100% 时满格，随使用顺时针/从左到右减少。
3. 主应用仍通过现有 `CodexUsageProvider` / Codex app-server 获取数据，不复制登录态、不读取 token、不新增网络接口。
4. 小组件显示最近一次有效的 7 天额度；暂时取数失败时不覆盖正确旧值，并标出更新时间。
5. 简体中文、深色卡片、蓝青色强调，布局与参考图保持一致的视觉层级。

## 数据与安全

- 现有主应用将 `7-Day` 指标从“已用”转换为“剩余”，只把剩余比例、重置时间、抓取时间写入 App Group 的 UserDefaults suite。
- 小组件扩展只读上述三个非敏感字段，不运行 Codex CLI、不访问账号凭据。
- 当前本机没有 Apple 代码签名证书；macOS `chronod` 会拒绝缓存 ad-hoc 签名的第三方 WidgetKit 扩展。因此默认交付使用桌面图标层的原生 AppKit 面板，数据始终只在主应用进程内流转。
- 代码仍保留可选 WidgetKit 扩展：以后有 Apple 签名身份且已注册 App Group 时，可用 `EMBED_WIDGETKIT=1` 打包；扩展启用 App Sandbox，并只通过 `group.com.claudenotch.app` 读取上述快照。
- 主应用启动时会为小组件拉取一次 Codex 数据；之后在应用存活期间每 15 分钟维护一次。刘海选中 Codex 时仍沿用现有较快刷新节奏。
- 无有效数据时显示占位态，不用 0% 冒充真实额度。

## 视觉规格

- 尺寸：macOS `.systemMedium`，关闭系统默认内边距，由卡片自行留白。
- 背景：近黑色，右侧带极弱蓝青光晕；使用系统圆角裁切。
- 左侧：Codex 图标与名称、`7 天额度`、24 段进度条、重置日期、剩余天数或更新时间。
- 右侧：大号剩余百分比，蓝青渐变；低于 40% 转橙，低于 20% 转高对比红。
- 图标：优先打包本机 ChatGPT/Codex 官方资源 `icon-codex-dark-color.png`，缺失时回退项目已有 Codex 图标。

## 工程结构

- `CodexWidgetShared`：非敏感快照、共享卡片视图。
- `DesktopWidgetWindow`：默认交付的桌面层原生窗口，可拖动并跨桌面显示，不需要 Apple 开发者证书。
- `CodexQuotaWidget`：有正式 Apple 签名时可选的 WidgetKit timeline provider。
- `CodexWidgetRender`：只用于输出静态图，和参考图并排做设计验收。
- `ClaudeNotch`：在既有 Codex 拉取成功后写共享快照并通知 WidgetKit 刷新。

## 验证方式

1. `swift build` 编译主应用、小组件扩展和验收渲染器。
2. 运行渲染器输出 72% 示例图，与参考图同屏比较并记录到根目录 `design-qa.md`。
3. 启动本地测试 app，在桌面实际检查组件可见、可拖动、普通窗口能覆盖它。
4. 验证真实 Codex 7 天剩余额度进入桌面组件；当前实测为剩余 40%。
5. 不运行 `swift test`：本机 Command Line Tools 缺少 `Testing` 模块，按项目规则以实跑验证替代。
