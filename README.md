# claude-limits

[![Latest release](https://img.shields.io/github/v/release/ibrarwtf/claude-limits?label=brew%20cask&color=d97757)](https://github.com/ibrarwtf/claude-limits/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Your Anthropic usage at a glance, in the macOS menu bar or the Windows taskbar.

```
┌─────────────────────────────────────┐
│ ...   18% ▆▇█▇▆▆▅▅▄▃ 4:32   ...     │  ← always visible
└─────────────────────────────────────┘
            │       │       │
            │       │       └── time until your 5-hour quota resets
            │       └────────── recent burn rate (newest on right)
            └────────────────── how much of the window you've used
```

Right-click for the full breakdown. Left-click to refresh.

## Install

### macOS

```bash
brew tap ibrarwtf/lab
brew install --cask claude-limits
```

That's it. The Settings window opens on first launch — pick how to read your Claude OAuth token (auto-detect works for most installs) and you're done.

To upgrade later: `brew upgrade --cask claude-limits`
To remove: `brew uninstall --cask --zap claude-limits`

### Windows 10 / 11

Download `claude-limits-windows-X.Y.Z.zip` from the [latest Windows release](https://github.com/ibrarwtf/claude-limits/releases), extract `claude-limits.exe` into a folder you'll keep (e.g. `%LOCALAPPDATA%\Programs\claude-limits`), and run it. Nothing to install — it runs on the .NET Framework 4.8 that ships with Windows. The exe is unsigned, so SmartScreen asks once: **More info → Run anyway**.

Settings opens on first launch and turns on "Open at login". Updates install in place from Settings → **Update to vX.Y.Z**.

On Windows the menu-bar line becomes a small **pill on the taskbar** next to the tray (drag it anywhere; hide it in Settings), plus a **tray icon showing the 5-hour %** — amber at 80%, red at 95%. New tray icons start in the `^` overflow; drag it onto the taskbar, or turn it on under *Settings → Personalization → Taskbar → Other system tray icons*. Click the tray icon or right-click the pill for the full breakdown; left-click the pill to refresh.

## What you get

- Live percentage, burn-rate sparkline, and reset countdown in the menu bar
- Right-click dropdown with weekly limits, pay-as-you-go credits, refresh, settings
- Hide any part you don't want via Settings (or the whole widget — runs silently in the background)
- Plays a slot-machine wave animation when you click to refresh
- Polls every 120 s, honours rate limits, never burns extra requests

## Token sources

Auto-detect works if Claude is installed normally on this machine (macOS Keychain or `~/.claude/.credentials.json`; on Windows `%USERPROFILE%\.claude\.credentials.json`). For other setups (Docker, SSH, custom path), Settings has two more modes:

| Mode | When to use |
|---|---|
| **Auto-detect** *(default)* | Standard Claude install |
| **Custom file path** | Token file lives in a non-standard location |
| **Custom shell command** | Claude runs in Docker, on a remote box over SSH, in WSL (`wsl cat ~/.claude/.credentials.json`), etc. — anything that prints credentials JSON to stdout. zsh on macOS, PowerShell on Windows |

## Local-only by design

- Usage polling only calls `https://api.anthropic.com/api/oauth/usage`; the optional update checker also calls GitHub Releases.
- No telemetry, no analytics, no third-party libraries
- All data stays local: on macOS settings in UserDefaults and history in `~/Library/Application Support/claude-limits/`; on Windows both in `%APPDATA%\claude-limits\`
- Single binary: ~415 KB Swift on macOS, ~140 KB C# exe on Windows

## Building from source

```bash
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
bash scripts/install.sh
```

Requires macOS 13+ and Xcode Command Line Tools. On Windows:

```powershell
winget install Microsoft.DotNet.SDK.10   # build-time only
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

Full local-dev guide in [DEVELOPMENT.md](DEVELOPMENT.md).

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for scope and conventions, [CLAUDE.md](CLAUDE.md) for codebase notes.

## License

MIT. See [LICENSE](LICENSE).
