# claude-limits

Your Anthropic usage at a glance, in the macOS menu bar.

```
┌─────────────────────────────────────┐
│ ...   18% ▆▇█▇▆▆▅▅▄▃ 4:32   ...    │  ← always visible
└─────────────────────────────────────┘
            │       │       │
            │       │       └── time until your 5-hour quota resets
            │       └────────── recent burn rate (newest on right)
            └────────────────── how much of the window you've used
```

Right-click for the full breakdown. Left-click to refresh.

## Install

```bash
brew tap ibrarwtf/lab
brew install --cask claude-limits
```

That's it. The Settings window opens on first launch — pick how to read your Claude OAuth token (auto-detect works for most installs) and you're done.

To upgrade later: `brew upgrade --cask claude-limits`
To remove: `brew uninstall --cask --zap claude-limits`

## What you get

- Live percentage, burn-rate sparkline, and reset countdown in the menu bar
- Right-click dropdown with weekly limits, pay-as-you-go credits, refresh, settings
- Hide any part you don't want via Settings (or the whole widget — runs silently in the background)
- Plays a slot-machine wave animation when you click to refresh
- Polls every 120 s, honours rate limits, never burns extra requests

## Token sources

Auto-detect works if Claude is installed normally on this Mac. For other setups (Docker, SSH, custom path), Settings has two more modes:

| Mode | When to use |
|---|---|
| **Auto-detect** *(default)* | Standard Claude install |
| **Custom file path** | Token file lives in a non-standard location |
| **Custom shell command** | Claude runs in Docker, on a remote box over SSH, etc. — anything that prints credentials JSON to stdout |

## Local-only by design

- One network call: `https://api.anthropic.com/api/oauth/usage`. Nothing else.
- No telemetry, no analytics, no third-party libraries
- All data on your Mac: settings in UserDefaults, history in `~/Library/Application Support/claude-limits/`
- Single ~415 KB Swift binary
- Source is one file you can read in an evening (`src/main.swift`)

## Building from source

```bash
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
bash scripts/install.sh
```

Requires macOS 13+ and Xcode Command Line Tools.

## License

MIT. See [LICENSE](LICENSE).
