<div align="center">

# Claude Notch — Simplified Chinese Edition

**Quota monitoring and Claude Environment Guard, right in your Mac’s notch.**

Track quota and balances for Claude, Codex, WorkBuddy and DeepSeek, with usage trends and reset times.

New in v1.1.2: exit-IP warnings and a network check before launching, restarting or handing a task to Claude.

[![Release](https://img.shields.io/github/v/release/cenzihao1987-svg/claude-notch-zh-cn?color=CC785C&label=version)](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases/latest)
&nbsp; ![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
&nbsp; [![MIT License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[中文](README.md) · [Source releases](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases) · [v1.1.2 overview](RELEASE_NOTES_v1.1.2.md)

</div>

## Network warnings in the expanded notch · v1.1.2

![Full expanded Claude Notch dashboard with network warning tips; all values are demonstration data](docs/media/claude-notch-v1.1.2-network-warning.png)

The warning sits below quota, the weekly chart and recent tasks. The network-tool icon is to the left of history; the only action buttons are Ignore and Close. Quota values, task names and IP addresses in this image are synthetic.

- Detect exit-IP changes, including same-country changes, with a five-second repeat sample and separate IPv4/IPv6 baselines.
- Read Clash Verge’s live core mode; warn when it is not global, not running or cannot be verified.
- Check before launching, restarting or handing a task to Claude. Cancellation stops the remaining actions.
- Recheck every 30 seconds while Claude runs and on network or application events. Show notch warnings and macOS notifications; open the current VPN client from the network icon.
- Keep local route history separate from risk scoring: same-country IP changes do not add geographic risk points, and dismissing a warning does not erase risk history.

## Quota and environment status at a glance

![Claude Notch v1.1.0 environment shield in the notch, sample data](docs/media/claude-notch-v1.1.0-notch.png)

Quota and the environment shield stay in the notch. Click the shield to open the standalone Claude environment window.

## Multi-tool quota monitoring

Check quota while collapsed; hover to expand for usage, reset times, charts and recent tasks. Each tool displays the information its data sources support.

![Claude Notch Codex quota and seven-day plan usage, existing screenshot](docs/media/claude-notch-v0.6.0-codex.png)

The quota dashboard, reusing an existing version screenshot.

| Tool | Main information |
| --- | --- |
| **Claude** | Five-hour and seven-day quotas and reset times, with applicable plan details, local usage and recent tasks. |
| **Codex** | Remaining quota, available credits, reset timing, seven-day Sol / Terra / Luna plan usage and recent tasks. |
| **WorkBuddy** | Remaining and used credits, plan and refresh or expiry time, plus seven-day local credit consumption. |
| **DeepSeek** | Available, topped-up and granted balances, plus seven-day spend read from a downloaded export. |

Temporary read failures retain previous valid quota with a clear stale indication. Click the refresh icon beside a warning to retry.

## Claude Environment Guard · new in v1.1.0

**Give Claude its own environment, without changing your Mac’s global settings.**

Check environment-related account risk in your notch, configure Claude’s language, region and timezone, and compare them with what its web layer actually reads.

![Claude Notch v1.1.0 configured environment beside observed web values, sample data](docs/media/claude-notch-v1.1.0-environment.png)

Compare saved settings, observed web values and the IP location in one place. The window stays open when it loses focus. Screenshots use sample data; 50 and 10 are example risk index values.

| Capability | What it does |
| --- | --- |
| **Dedicated environment** | Set Claude’s language, region and timezone independently, keeping your global Mac settings and everyday habits. |
| **Observed values** | Compare settings with the web layer’s actual values. Use the IP country and city alongside them to spot unapplied settings or a timezone inconsistent with the route location. |
| **Visible risk** | Compare the system risk index with the launch-profile estimate, with local signals, route location and client verification details. |
| **Easy adjustments** | Get a suggested timezone when choosing a region, remember manual timezone choices per region, and launch Claude with the saved profile. |

## Get started in three steps

1. **Open the guard:** select Claude and click the environment shield in the notch.
2. **Choose a profile:** enable the dedicated profile and select the app language, region and process timezone.
3. **Launch and verify:** apply the profile, launch Claude and compare the observed web values. Follow the normal-restart prompt when applying changes to a running instance.

Web-layer verification requires a compatible local client adaptation, a complete original backup and local signing. See “Usage and compatibility” below.

## Task handoff and everyday use

- **Task handoff:** transfer visible context for supported recent tasks; handoff is disabled while the source is working or thinking.
- **Retry on failure:** click the refresh icon beside a connection warning; the loading indicator prevents duplicate requests.
- **Everyday use:** hover to expand, Chinese / English switching, multiple displays and a standalone settings window.

<details>
<summary><strong>Existing feature screenshots and demo</strong></summary>

![Claude Notch handing off a recent task, existing screenshot](docs/media/claude-notch-v0.6.0-handoff.png)

Hover over a recent task and choose a destination to continue the work.

![Claude Notch original quota and notch interaction demo](docs/media/claude-notch-v0.4.0-demo.gif)

The original GIF demonstrates quota viewing and notch interaction. It was recorded on an earlier version; the new environment guard is shown in the screenshots above.

</details>

## Get the source

Requires **macOS 14 or later**. [GitHub Releases](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases) provides published source archives. No DMG or application ZIP for installation on other Macs is offered at this stage.

<details>
<summary><strong>Usage and compatibility</strong></summary>

### Build from source

Requires Git and a full Xcode installation supporting Swift 6. This creates a locally signed build and regenerates the repository’s `dist/` directory:

```bash
git clone https://github.com/cenzihao1987-svg/claude-notch-zh-cn.git
cd claude-notch-zh-cn
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ALLOW_ADHOC=1 bash scripts/make-app.sh
```

Move `dist/Claude Notch.app` to Applications. Local builds are not notarized; follow macOS security prompts on first launch. Public application packages will require Developer ID signing and notarization.

### Launch profiles and web verification

- Profiles default to off and apply only to Claude launched through this tool. Global macOS language, region, timezone and input-method settings stay unchanged.
- Web verification and region adaptation require a modified local Claude copy. Keep a complete original backup, check the client version, then use the repository’s adaptation script to stage a copy for local signing and replacement. The script does not overwrite the installed client.
- The currently verified adaptation targets **Claude Desktop 2.37337.1**. Other versions need inspection first; client updates may require reinstalling or adapting the module.
- An unadapted client, a stopped instance, stale observations or read failures remain unverified. Saved settings are never substituted for observed web values.
- Turning the profile off offers a normal restart with system settings. A refused or timed-out quit never forces the process to terminate.
- Your VPN continues to manage networking. The tool does not switch nodes, change proxies or take over traffic.

</details>

<details>
<summary><strong>Data and privacy</strong></summary>

- The environment collector reads only language, language list, Locale, timezone and instance-verification markers. It does not read chats, accounts, cookies or web storage. Keep the original client backup before adaptation.
- Optional country and city checks use `api.country.is`. The service sees the request’s public IP but receives no account data. This is the tool’s route reference; VPN routing may give Claude a different route. Disable the check under Verification.
- Claude quota reads the desktop client’s cache by default. Desktop credentials are used only after enabling the fallback in Settings. The first read may request Keychain permission; the resulting decryption key is stored in the local app data directory with owner-only permissions.
- Codex quota uses the official local `codex app-server`; plan usage comes from an official read-only endpoint. Credentials and raw responses are not logged.
- WorkBuddy supports the newer encrypted login format, using only the current access token in memory for quota requests, without renewing it. Daily credits come from local records, without browser cookies.
- DeepSeek balance uses locally configured credentials, while the spend chart reads the user’s downloaded export.
- Visible task context is extracted only when handoff is triggered manually. Hidden reasoning, tool calls and outputs, and detected credentials are excluded from handoff packets.

</details>

## License and credits

Built on [stevemcqueenz/claude-notch-tracker](https://github.com/stevemcqueenz/claude-notch-tracker), retaining the upstream copyright and [MIT License](LICENSE). Thanks to **Stanislav Kulik** and all upstream contributors.

Environment icons use the [Lucide collection on iconfont](https://www.iconfont.cn/collections/detail?cid=54062). The Lucide ISC and applicable Feather MIT notices remain included.
