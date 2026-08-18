# Codex 桌面小组件 Design QA

## 验收输入

- 参考图：`/tmp/codex-remote-attachments/01a00f04-1f2b-7300-a2bc-a81d871c3a9c/9F2F0454-9DD6-4F34-BA23-6C40B045F68E/1-照片-1.jpg`
- 72% 实现稿：`/Users/zp/claude-notch-zh-cn/codex-widget-preview.png`
- 真实数据实机截图：`/Users/zp/claude-notch-zh-cn/codex-widget-live.png`
- 同屏对比：`/Users/zp/claude-notch-zh-cn/codex-widget-comparison.png`
- 参考原图：1280 × 960；卡片区域按相同比例裁切后，与实现稿统一到 728 × 340 对比。
- 组件实际尺寸：364 × 170 pt；对比稿按 2x 输出为 728 × 340 px。

## 状态

- 视觉对齐状态：剩余 72%，24 段进度条，8 月 24 日重置，还剩 7 天。
- 边界状态：剩余 100% 已验证，三位数字完整显示，24 段全部点亮。
- 警示状态：剩余 15% 已验证，数字、日期和进度条切换为高对比红色。
- 实机状态：Codex app-server 返回剩余 35%，8 月 20 日重置；组件已按真实数据更新。

## 同屏检查

- 信息层级一致：图标与 Codex 名称在左上，额度标题和分段条在左侧，大百分比在右侧，重置与剩余天数位于左下。
- 对齐与留白通过：进度条宽度、百分比占比、卡片圆角和四周内边距与参考图接近，无贴边、裁切或重叠。
- 字体通过：使用系统字体，数字具备参考图的大号粗体层级；100% 时自动缩放，不截断。
- 颜色通过：充足额度使用蓝青渐变，40% 以下橙色，20% 以下高对比红色；暗色背景上的文字对比清晰。
- 本地化通过：`Weekly quota`、`Resets`、`days remaining` 已替换为简体中文。
- 唯一有意差异：参考图使用旧式 OpenAI 结形图标，实现使用本机 ChatGPT 内置的当前 Codex 官方图标，避免仿制品牌资产。

## 功能检查

- `swift build` 与 release build 通过；只有项目原有 `LogParser` Sendable 警告。
- 实机窗口层级为桌面图标层上方、普通应用窗口下方；组件可随所有桌面显示，不遮挡正常应用窗口。
- 默认显示，可拖动；位置持久化；刘海右键菜单可显示或隐藏。
- 主应用启动即获取 Codex，未选中 Codex 时每 15 分钟维护一次；失败不会覆盖最后一次有效额度。
- 数据仍来自既有 `CodexUsageProvider` / Codex app-server；没有新增 token、Cookie 或非官方网络调用。
- ad-hoc 本地构建默认使用原生桌面窗口；可选 WidgetKit 扩展只在具备 Apple 签名与 App Group 时打包，避免交付一个会被 macOS 拒绝的假入口。

## 修正记录

1. 首版百分比横向空间不足，72% 被截断；缩短左栏并把数字改为统一缩放的组合文本。
2. 放大百分比并收窄进度区，使视觉比例匹配参考；重新同屏比较通过。
3. 验证 100% 与 15% 两个边界状态，确认无截断且警示色清晰。
4. WidgetKit ad-hoc 扩展被 `chronod` 拒绝后，改为无需开发者证书的桌面层原生窗口，并完成真实额度实机验收。

final result: passed
