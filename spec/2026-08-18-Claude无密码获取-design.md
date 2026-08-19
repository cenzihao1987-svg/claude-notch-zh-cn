# Claude 无密码获取

## 目标

默认只读取 Claude Desktop 已缓存的官方额度数据，启动、自动刷新和手动刷新均不访问钥匙串，避免连续出现系统密码弹窗。

## 行为边界

- 默认关闭“Claude 备用获取”，现有用户升级后也保持关闭。
- 缓存存在时正常展示额度；缓存缺失或已跨过重置时间时显示“等待 Claude 客户端更新…”，不自动尝试浏览器或 Claude Code 凭证。
- 设置菜单保留“Claude 备用获取（可能要求密码）”开关，只有用户主动开启后才允许访问钥匙串。
- 备用获取只允许 Claude Desktop 自身的 Cookies / OAuth 数据，不再遍历 Chrome、Edge、Brave、Arc、Firefox、Zen 或 Claude Code。
- 关闭备用获取后，后续刷新立即回到无密码模式；已展示的最后一次有效额度可以保留，等待 Desktop 缓存覆盖。

## 安全

- Claude Desktop 缓存继续只读，不修改缓存文件，不记录 token、Cookie、组织 ID 或钥匙串内容。
- 备用模式只在显式开关开启时调用现有 `ClaudeAPIService`，并限制为 Claude Desktop 单一来源。
- 本次修改已获得龟对 Claude 数据获取策略的明确授权。

## 验证方式

1. 默认设置下启动应用，额度缓存不可用时不调用钥匙串路径，界面显示等待提示。
2. 手动刷新在默认设置下仍只重新扫描本地缓存。
3. 开启备用获取后最多只访问 `Claude Safe Storage`，不会访问 Chrome、Edge 或 Claude Code 凭证。
4. 关闭备用获取后再次刷新不访问钥匙串。
5. 调试与发布构建通过，更新测试版并完成签名校验。
