<div align="center">

# Claude Notch — Simplified Chinese Edition

**See live Claude and Codex quotas in your Mac notch—and safely hand tasks between them.**

[![Release](https://img.shields.io/github/v/release/cenzihao1987-svg/claude-notch-zh-cn?color=CC785C&label=download)](https://github.com/cenzihao1987-svg/claude-notch-zh-cn/releases/latest)
&nbsp; ![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
&nbsp; [![MIT License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

This is a Simplified Chinese edition built on
[stevemcqueenz/claude-notch-tracker](https://github.com/stevemcqueenz/claude-notch-tracker).
It retains the upstream MIT license and attribution.

[中文说明](README.md)

## Core capability: visible-context handoff between Claude and Codex

Claude Notch does more than track quotas. Hover over a recent task in the expanded notch to
**hand it to Claude** or **hand it to Codex**, so the other agent can continue the work.

- **Two-way handoff:** Send a Codex task to a Claude Desktop Code session, or a Claude Code session to Codex.
- **Verifiable working context:** Carry over the visible goal, progress, working directory, workspace roots, Git branch/change summary, and remaining work.
- **No hidden-context transfer:** Reasoning, tool calls and outputs, tokens, cookies, private keys, `.env` files, and other secrets are excluded.
- **Concurrent-edit protection:** Handoff is disabled while the source task is working or thinking; it is available only after the task stops, becomes idle, or awaits confirmation.
- **Recoverable fallback:** If the destination app or deep link fails, the handoff packet remains available and the instructions are copied for manual continuation.

## Latest UI

![Claude Notch: Codex single-page quota view, 7-day chart, and recent tasks](docs/media/claude-notch-v0.4.0.png)

![Claude Notch: 18-second interaction demo](docs/media/claude-notch-v0.4.0-demo.gif)

## Highlights

- Two-way visible-context handoff between Claude and Codex, so work can continue across agents.
- Chinese / English UI switching with a one-page expanded layout for both Claude and Codex.
- Hover to expand, smooth expand/collapse movement, and a settings gear at the right edge.
- Independent notch windows on every display, with compact activity indicators while collapsed.
- Claude reads the official Claude Desktop usage cache by default and does not automatically access Keychain data, reducing repeated password prompts.
- Claude Pro hides inapplicable Fable and credit information; Max keeps the applicable capabilities.
- Codex numbers and ring both represent **remaining quota**, with 7-day quota, reset time, recent tasks, and a desktop widget.
- The Codex reset tile combines local reset timing with third-party parsed Tibo announcement signals; it does not read X directly.

## Install

Download the DMG from [Releases](../../releases), open it, and drag `Claude Notch.app` to Applications.

The current release is ad-hoc signed and not Apple-notarized. If macOS blocks the first launch,
open “System Settings → Privacy & Security” and choose “Open Anyway”.

## Data and Privacy

- Claude reads only the local Claude Desktop cache by default. It does not read browser or Claude Code credentials. Claude Desktop credential fallback is available only when the user enables it in Settings.
- Codex uses the official local `codex app-server`; prompts, account emails, and login tokens are neither read nor uploaded.
- Reset reminders request only anonymous public JSON from `codex-reset.com`; that service parses Tibo’s X announcements.

## License and Credits

Released under the [MIT License](LICENSE). Special thanks to **Stanislav Kulik**, creator of the original repository, for the design, implementation, and open-source contribution, and to all upstream contributors.
