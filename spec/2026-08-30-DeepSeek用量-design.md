# DeepSeek 用量 Tab

## 目标

在展开刘海的 Claude、Codex 之后增加 DeepSeek Tab，展示 DeepSeek API 的当前账户余额。

## 数据边界

- 只读 `~/.config/config.json` 的 `responsesUpstream` 配置。
- 只接受 `status=active`、`serviceType=openai`、HTTPS 主机为 `api.deepseek.com` 的条目。
- API Key 仅在内存中用于 `GET https://api.deepseek.com/user/balance`，不写日志、不保存、不读取网页 Cookie。
- 官方接口只提供余额与可用状态；不估算 Token、日用量或会话。
- 不提供手动上传或选择入口。应用只读扫描 `~/Downloads` 根目录的 `cost-*.csv`，以及一层 `usage_data_*` 官方导出文件夹中的 `cost-*.csv`，选择修改时间最新的一份；不递归读取其他下载内容，也不误读只有 Token/单价明细的 `amount-*.csv`。
- 应用只解析日期、消费金额、币种和可选交易类别，忽略充值、赠金和退款；不保存原始 CSV、API Key 或请求记录。
- 柱状图只展示导入 CSV 中的最近 7 个本地日历日消费金额。不同币种不能混合成一张图，导入文件含多币种时明确提示用户拆分后再导入。

## 界面

- Tab 顺序固定为 Claude、Codex、DeepSeek。
- DeepSeek 顶部直接显示优先人民币、否则美元的可用余额，不显示百分比或圆环。
- 展开态左侧固定展示总余额、充值余额、赠金余额和 API 状态四张卡片；右侧展示最近 7 天消费金额柱状图。未导入 CSV 时显示明确的导入提示；不显示近期任务或接力。
- 同时存在人民币与美元时并列展示，不做汇率换算。

## 刷新与降级

- 自动读取只在本地时间 09:00 后和 21:00 后各进行一次；应用在该时段启动时补一次，重启也不会重复。自动读取会更新余额，并重新扫描“下载”中的最新 DeepSeek 导出。
- 选择 Tab 和展开刘海不会触发 DeepSeek 请求；点击“立即刷新”时才额外主动更新一次余额并扫描最新导出。
- 失败时保留最后一次成功余额并标记过期；无历史结果时显示配置、鉴权、余额、限流、服务或网络状态。
- DeepSeek 不接入前台自动跟随、工作状态或桌面小组件。

## 验证方式

- 脱敏样本覆盖配置匹配、余额映射、双币种、零余额、异常状态和官方请求地址。
- CSV 样本覆盖中英文列名、引号金额、充值排除、缺少日期/金额列、多币种和早晚刷新时段。
- 完整 Xcode 执行 `swift test`、release build、`git diff --check` 与 ad-hoc 打包。
- 安装测试版后，实际检查 DeepSeek Tab、余额卡片、无百分比环及 Claude/Codex 布局不变。
