# claude-limits

[![Latest release](https://img.shields.io/github/v/release/ibrarwtf/claude-limits?label=release&color=d97757)](https://github.com/ibrarwtf/claude-limits/releases/latest)
[![CI](https://github.com/ibrarwtf/claude-limits/actions/workflows/ci.yml/badge.svg)](https://github.com/ibrarwtf/claude-limits/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Your Claude usage at a glance — in the **macOS menu bar** or the **Windows taskbar**.

```
┌─────────────────────────────────────┐
│ ...   18% ▆▇█▇▆▆▅▅▄▃ 4:32   ...     │  ← always visible
└─────────────────────────────────────┘
            │       │       │
            │       │       └── time until your 5-hour quota resets
            │       └────────── recent burn rate (newest on right)
            └────────────────── how much of the window you've used
```

Click for the full breakdown: weekly limits, pay-as-you-go credits, and whether your current pace will cap you before the window resets. [Screenshots →](snapshots/)

## Install

### macOS 13+

```bash
brew tap ibrarwtf/lab
brew install --cask claude-limits
```

Settings opens on first launch — auto-detect finds your Claude login for most installs. Upgrade with `brew upgrade --cask claude-limits` (or Settings → **Update**); remove with `brew uninstall --cask --zap claude-limits`.

Right-click the menu-bar item for the breakdown, left-click to refresh.

### Windows 10 / 11

Download `claude-limits-windows-X.Y.Z.zip` from the [latest release](https://github.com/ibrarwtf/claude-limits/releases/latest), extract `claude-limits.exe` into a folder you'll keep (e.g. `%LOCALAPPDATA%\Programs\claude-limits`), and run it. Nothing else to install — it runs on the .NET Framework that ships with Windows. The exe is unsigned, so SmartScreen asks once: **More info → Run anyway**.

Settings opens on first launch and turns on "Open at login". Updates install in place from Settings → **Update**.

The menu-bar line becomes a **pill on the taskbar** next to the tray (drag it anywhere, or hide it in Settings), plus a **tray icon showing the 5-hour %** — amber at 80%, red at 95%. New tray icons start in the `^` overflow; drag it onto the taskbar, or switch it on under *Settings → Personalization → Taskbar → Other system tray icons*. Click the tray icon or right-click the pill for the breakdown; left-click the pill to refresh.

## What you get

- Live percentage, burn-rate sparkline, and reset countdown, always visible
- A breakdown with weekly limits, pay-as-you-go credits, and a pace projection ("40%/h over safe 19%/h · 100% in 1h 10m")
- Notifications when the 5-hour window crosses 80% and 95%
- Hide any part you don't want (or the whole widget — it keeps running in the background)
- Follows light/dark mode
- Polls every 3 minutes (Anthropic only recomputes usage every ~5), honours rate limits, never burns extra requests

## Token sources

Auto-detect works if Claude Code is signed in on this machine (macOS Keychain or `~/.claude/.credentials.json`; on Windows `%USERPROFILE%\.claude\.credentials.json`). For other setups, Settings has two more modes:

| Mode | When to use |
|---|---|
| **Auto-detect** *(default)* | Standard Claude Code install |
| **Custom file path** | Credentials file lives somewhere else |
| **Custom shell command** | Claude runs in Docker, WSL (`wsl cat ~/.claude/.credentials.json`), on a remote box over SSH — anything that prints the credentials JSON to stdout. zsh on macOS, PowerShell on Windows |

## Local-only by design

- Usage polling only calls `https://api.anthropic.com/api/oauth/usage`; the update checker also calls GitHub Releases.
- No telemetry, no analytics, no third-party libraries.
- Everything stays on your machine: settings + history in `~/Library/Application Support/claude-limits/` and UserDefaults on macOS, `%APPDATA%\claude-limits\` on Windows.
- One small binary per platform: ~415 KB Swift app on macOS, ~145 KB exe on Windows.

## Building from source

```bash
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
bash macos/scripts/install.sh                                     # macOS (Xcode Command Line Tools)
powershell -ExecutionPolicy Bypass -File windows\scripts\install.ps1  # Windows (.NET SDK, build-time only)
```

Full local-dev guide in [DEVELOPMENT.md](DEVELOPMENT.md).

## Contributing

PRs welcome — CI builds, tests and screenshots both apps, so you can change either platform from either OS. See [CONTRIBUTING.md](CONTRIBUTING.md), and [CLAUDE.md](CLAUDE.md) for codebase notes.

## License

MIT. See [LICENSE](LICENSE).
