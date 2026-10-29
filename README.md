<div align="center">

# Claude Notch 中文版

**额度监测与 Claude 环境守护，常驻你的 Mac 刘海。**

查看 Claude、Codex、WorkBuddy、DeepSeek 的额度与余额，掌握用量、消费趋势和重置时间。

v1.2.0 守护启动：首次三步开启防护；Claude 未从刘海启动时提醒，一键以防护重启。

[![Release](https://img.shields.io/github/v/release/cenzihao1987-svg/claude-notch-zh-cn?color=CC785C&label=版本)](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases/latest)
&nbsp; ![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
&nbsp; [![MIT License](https://img.shields.io/badge/许可证-MIT-blue)](LICENSE)

[English](README.en.md) · [下载安装包](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases/latest) · [v1.2.0 更新介绍](RELEASE_NOTES_v1.2.0.md)

</div>

## 守护启动，防护从刘海开始 · v1.2.0

![Claude Notch v1.2.0 未防护提醒：收起态、从 Dock 打开后的提醒及与网络问题同时出现，演示数据](docs/media/claude-notch-v1.2.0-guard-launch.png)

Claude 要从刘海启动，专属配置才会生效。没有防护时盾牌旁显示“未防护”；从 Dock 打开 Claude 时刘海自动展开一次，可一键以防护重启；与网络问题同时出现时并入同一个风险提醒，逐条处理。图片取自界面设计定稿，均为演示数据。

- **首次三步开启防护**：首次运行在刘海显示欢迎卡，确认专属环境、开机自动运行刘海，再从刘海启动 Claude。
- **未防护及时提醒**：Claude 不是从刘海按专属配置启动时，盾牌旁显示“未防护”，可一键以防护重启；确认后先检查网络，再正常退出并重启，不强制结束。
- **风险逐条处理**：打开 Clash Verge、重新检查、确认新出口、以防护重启，各项就地处理；悬停一行点 × 只忽略这一项，不清除风险记录。全部处理完转绿收起。
- **出口误报更少**：后台出口查询失败后 5 秒复测一次，连续两次失败才提示“无法确认”。
- **更省、更准**：图标只在任务运行时动画，空闲时占用明显下降；Claude 额度识别客户端各类用量请求，过久未更新时标注“x 分钟前更新”；恢复 Pro / Max 识别。

## 网络异常，刘海及时提醒 · v1.1.2

- **出口变化提醒**：包括同国换 IP，经间隔 5 秒复测后提醒；IPv4、IPv6 分别比较。
- **Clash 模式检查**：读取内核当前模式；非全局、未运行或无法核验时提示。
- **启动前确认**：从本工具启动、重启或任务接力前统一检查。异常时可取消，也可明确选择“仍然启动”；取消后停止后续操作。
- **自动复查与便捷处理**：运行中每 30 秒复查，网络切换和应用启动等事件触发即时检查。支持系统通知，通过网络图标打开当前使用的 VPN 工具。
- **历史与评分独立**：本机记录出口与风险变化；同国换 IP 提醒不增加跨区评分，忽略不清除风险历史。

## 常驻刘海，额度与守护随时可见

![Claude Notch v1.1.0 刘海守护入口，示例数据](docs/media/claude-notch-v1.1.0-notch.png)

额度与环境盾牌常驻刘海。点击盾牌，即可打开独立的 Claude 环境窗口。

## 多工具额度监测

收起时快速看额度，悬停展开查看用量、重置时间、趋势图与近期任务；不同工具展示各自支持的数据。

![Claude Notch Codex 额度与近七天套餐用量，复用既有截图](docs/media/claude-notch-v0.6.0-codex.png)

额度监测界面，复用既有版本截图。

| 工具 | 主要信息 |
| --- | --- |
| **Claude** | 5 小时、7 天额度及重置时间；按套餐显示适用信息，结合本地用量与近期任务。 |
| **Codex** | 剩余额度、可用积分、重置时间，近 7 天 Sol / Terra / Luna 套餐用量与近期任务。 |
| **WorkBuddy** | 剩余与已用积分、套餐、刷新或到期时间，以及近 7 天本机积分消耗。 |
| **DeepSeek** | 可用余额、充值与赠金余额，以及从下载的导出文件读取的近 7 天消费。 |

读取暂时失败或客户端尚未刷新时，已有额度保留并标明多久前更新；可点击失败提示旁的刷新图标重试。

## Claude 环境守护 · v1.1.0 新增

**给 Claude 一套独立专属环境，无需改变 Mac 的全局配置。**

在刘海查看环境封号风险，独立设置 Claude 的语言、地区和时区，并核对网页层实际读到的值。

![Claude Notch v1.1.0 环境配置与网页实测对照，示例数据](docs/media/claude-notch-v1.1.0-environment.png)

配置值、网页层实际值与出口所在地集中展示；窗口失去焦点后仍保留。图中为示例数据，50、10 为风险指数示例。

| 能力 | 帮你做什么 |
| --- | --- |
| **专属环境** | 为 Claude 独立设置语言、地区和时区，保持 Mac 全局配置与日常使用习惯。 |
| **实际核验** | 并排对照配置值与网页层实际值，结合 IP 所在国家和城市，发现配置未生效、时区与出口所在地不一致等风险。 |
| **风险可见** | 对比当前系统与专属配置的风险指数，查看本地特征、出口所在地及客户端核验信息。 |
| **便捷调整** | 选择地区后联动推荐时区，记住按地区手动修改的选择，应用配置并启动 Claude。 |

## 三步开始

![Claude Notch v1.2.0 首次运行欢迎卡，演示数据](docs/media/claude-notch-v1.2.0-welcome.png)

首次运行时，刘海会显示欢迎卡：

1. **专属环境**：按出口 IP 推荐 Claude 的语言、地区和时区，可修改。
2. **开机自动运行刘海**：刘海不在运行时，无法为 Claude 提供防护。
3. **从刘海启动 Claude**：启动前先检查网络；以后也从这里启动。

之后要调整配置，在 Claude 页点击刘海中的环境盾牌；启动后查看“网页层实际值”是否一致。已有实例需要应用新配置时，按提示以防护重启。

网页层核验需要先完成与当前 Claude 版本匹配的客户端适配，保留原版备份并本地重签；详见下方“使用与兼容说明”。

## 任务接力与日常体验

- **任务接力**：在支持的近期任务间交接可见上下文；来源任务工作中或思考中时不允许接力。
- **失败重试**：连接失败提示旁增加刷新图标，点击即可重试，加载期间防止重复点击。
- **日常体验**：悬停展开、中文 / English 切换、多显示器显示与独立设置窗口。

<details>
<summary><strong>原有功能截图与演示</strong></summary>

![Claude Notch v1.1.2 完整刘海展开界面及底部网络异常提示，全部为演示数据](docs/media/claude-notch-v1.1.2-network-warning.png)

v1.1.2 网络异常 tips：额度、近七天图表和近期任务下方显示异常提示，图中额度、任务名和 IP 均为演示数据。

![Claude Notch 从近期任务发起接力，复用既有截图](docs/media/claude-notch-v0.6.0-handoff.png)

悬停近期任务，选择接力目标，继续处理任务。

![Claude Notch 原有额度查看与刘海交互演示](docs/media/claude-notch-v0.4.0-demo.gif)

复用原有演示 GIF 展示额度查看与刘海交互；录制于历史版本，新增环境守护见上方新版截图。

</details>

## 获取

适用于 **macOS 14 及以上的 Apple Silicon Mac**。从 [GitHub Releases](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases/latest) 下载 `ClaudeNotch-v<版本>.dmg`，打开后把 Claude Notch 拖入“应用程序”。

安装包未经 Apple 公证，首次打开会提示无法验证开发者：前往“系统设置 → 隐私与安全性”，在页面下方点“仍要打开”。之后按上方“三步开始”从刘海启动 Claude；从 Dock 直接打开的 Claude 不会应用专属配置。

<details>
<summary><strong>使用与兼容说明</strong></summary>

### 从源码构建

需要 Git 与支持 Swift 6 的完整 Xcode。以下命令生成本机自签名构建，脚本会重新生成仓库内的 `dist/`：

```bash
git clone https://github.com/cenzihao1987-svg/claude-notch-zh-cn.git
cd claude-notch-zh-cn
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ALLOW_ADHOC=1 bash scripts/make-app.sh
```

构建后将 `dist/Claude Notch.app` 放入“应用程序”。本机自签名构建没有 Apple 公证，首次打开按 macOS 的安全提示操作。

### 专属启动与网页核验

- 专属配置默认关闭，仅用于从本工具启动的 Claude，不修改 macOS 全局语言、地区、时区或输入法。
- 网页层核验及地区适配需要修改 Claude 的本地副本。先完整备份原版，确认客户端版本，再使用仓库中的适配脚本生成暂存副本，完成本地重签与替换；脚本不会自动覆盖已安装的 Claude。
- 当前已验证的客户端适配版本为 **Claude Desktop 2.37337.1**。其他版本需先检查适配；升级后模块可能需要重新安装或调整，不能直接套用旧版本。
- 未适配、未启动、读数过期或读取失败时，界面保留待核验状态；网页实际值来自运行中的页面，不用配置值补齐。
- 关闭专属配置后可选择正常重启 Claude，恢复系统配置；拒绝退出或退出超时不会强制结束进程。
- 网络继续由你的 VPN 管理。本工具不切换节点、不修改代理，也不接管流量。

### 守护启动与网络预警

- 欢迎卡可选择“稍后”。之后从 Dock 等外部入口打开 Claude 时，刘海显示“未防护”，每个实例提醒一次；以防护重启前需确认，Claude 会正常退出，进行中的任务可能中断，拒绝退出或超时不会强制结束。
- 风险提醒逐条处理：悬停 × 只忽略当前项，不清除风险记录与评分，忽略不算已处理。
- 后台出口查询超时 12 秒，失败后 5 秒复测一次，连续两次失败才提示“无法确认”；启动前检查仍为单次查询，异常或未知时默认取消。
- Claude运行时，同国或跨国的公网IP变化经复测后提醒；Clash Verge为规则、直连、未运行或无法核验时也会提醒。全局模式读取内核实时状态，不用TUN开关或保存的配置代替。
- 从本工具启动、重启及任务接力前统一检查，异常或未知时默认取消，也可明确选择“仍然启动”。取消后不再执行备用启动或复制交接指令；外部启动只能在发现运行后提醒。
- 刘海自动展开，并发送macOS通知；首次需要允许通知。通知不可用不影响刘海内的提示。后台每30秒自动复查；预警保留“忽略”“关闭”，右上角网络图标可打开正在使用的VPN工具，多客户端可选择。
- 同国换IP提醒不增加跨区评分，忽略不清除历史风险。关闭后台网络检测时不继续后台查询，启动前会提示出口未核验。
- 详情及验证范围见 [v1.2.0 设计记录](spec/2026-10-29-v1.2.0-release-design.md) 与 [v1.1.2 设计记录](spec/2026-10-18-network-warning-release-design.md)。

</details>

<details>
<summary><strong>数据与隐私</strong></summary>

- 环境采集仅包含语言、语言列表、Locale、时区及核验所需的实例标记，不读取聊天、账号、Cookie 或网页存储。适配前保留原版客户端备份。
- 可选出口参照向 `api.country.is` 查询国家、城市等信息，服务可见请求公网 IP，不收到账号信息。它反映本工具的请求出口，VPN 分流时可能与 Claude 的实际出口不同；可在“核验信息”中关闭。
- Claude 额度默认只读桌面客户端缓存。手动开启“Claude 备用获取”后，才使用 Claude Desktop 的授权信息；首次可能出现钥匙串授权，所得解密密钥以仅当前用户可读写的权限保存在本机应用数据目录。
- 识别 Pro / Max 时，若客户端缓存没有组织资料，只读取 `~/.claude.json` 中登录账户的组织类型，不读取凭据。
- Codex 额度使用官方本地 `codex app-server`；套餐用量来自官方只读接口。凭据与原始响应不写日志。
- WorkBuddy 兼容新版加密登录格式，仅在内存中读取当前访问令牌以查询额度，不主动续期；每日积分来自本机记录，不读取浏览器 Cookie。
- DeepSeek 余额使用本机配置的授权信息，消费图读取用户下载的导出文件。
- 只有手动触发任务接力时，才提取可见任务上下文；隐藏推理、工具调用与输出及识别出的凭据等敏感内容不进入交接包。

</details>

## 开源与致谢

基于 [stevemcqueenz/claude-notch-tracker](https://github.com/stevemcqueenz/claude-notch-tracker) 继续开发，保留上游版权与 [MIT License](LICENSE)。感谢原作者 **Stanislav Kulik** 及所有上游贡献者。

环境守护图标采用 [iconfont 的 Lucide 图标库](https://www.iconfont.cn/collections/detail?cid=54062)，随项目保留 Lucide ISC 与相关 Feather MIT 许可。
