# Local development

Codebase machinery (layout, how the two apps stay in step, gotchas) is in [CLAUDE.md](CLAUDE.md). Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

You only need the OS you're changing — **or neither**: push a branch and CI builds both apps, runs the spec and commits fresh snapshots to your PR.

## macOS

### Prereqs

macOS 13 or later, with `xcode-select --install` (gives you `swiftc` — no Xcode app needed).

### Clone and run

```bash
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
bash mac/scripts/install.sh
```

The icon should appear in your menu bar within a couple of seconds. `install.sh` builds, bundles into `~/Applications/claude-limits.app`, installs a LaunchAgent so it autostarts on login, starts the new build, and renders snapshots into `build/snapshots/mac/`.

### Dev loop

```
edit Swift → bash mac/scripts/install.sh → check build/snapshots/mac/ (or your menu bar)
```

~5 seconds end-to-end on Apple Silicon. Useful side commands:

```bash
tail -f /tmp/claude-limits.log                  # stdout + stderr
defaults read claude-limits                     # current persisted settings
bash mac/scripts/snapshot.sh                    # re-render build/snapshots/mac/ from the fixture
bash mac/scripts/uninstall.sh                   # remove .app + LaunchAgent (settings + history kept)
```

### Dev install vs brew install

These don't coexist. `install.sh` writes the bundle to `~/Applications/`; `brew install --cask claude-limits` writes to `/Applications/`. Both register the `claude-limits://` URL scheme and the same LaunchAgent label, so running both produces double menubar icons. `install.sh` refuses to run if it detects the brew copy:

```bash
brew uninstall --cask claude-limits && bash mac/scripts/install.sh   # switch to dev
bash mac/scripts/uninstall.sh && brew install --cask claude-limits    # back to brew
bash mac/scripts/uninstall.sh --all                                   # wipe both
```

## Windows

### Prereqs

Windows 10 or 11 and the .NET SDK (build-time only — the app runs on the .NET Framework 4.8 that ships with Windows):

```powershell
winget install Microsoft.DotNet.SDK.10
```

### Clone and run

```powershell
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
powershell -ExecutionPolicy Bypass -File win\scripts\install.ps1
```

`install.ps1` builds `build\win\claude-limits.exe`, quits any running copy, installs to `%LOCALAPPDATA%\Programs\claude-limits\`, registers autostart (HKCU Run key) and the `claude-limits://` URL scheme, starts it, and renders snapshots into `build\snapshots\win\`. Look for the pill on the taskbar next to the tray; the tray icon starts in the `^` overflow.

### Dev loop

```
edit C# → powershell -File win\scripts\install.ps1 → check build\snapshots\win\
```

Useful side commands:

```powershell
Get-Content -Wait $env:TEMP\claude-limits.log                         # log
Get-Content $env:APPDATA\claude-limits\settings.json                  # persisted settings
powershell -File win\scripts\snapshot.ps1                             # re-render build\snapshots\win\ from the fixture
build\win\claude-limits.exe --fixture spec\fixtures\snapshot.json     # run the UI on fixture data, no polling
Start-Process claude-limits://flyout                                  # open the flyout from a script
powershell -File win\scripts\uninstall.ps1 [-Purge]                   # remove (-Purge also wipes settings + history)
```

## Spec tests

`spec/cases.json` pins the behaviour both apps share (countdowns, sparkline, burn-rate line, weekly rows, rollover, token parsing, version compare). Each app has a tiny runner that compiles its `core/` on its own:

```bash
# macOS
swiftc -o build/spec-mac mac/core/*.swift mac/tests/main.swift && build/spec-mac spec/cases.json
```

```powershell
# Windows
dotnet build win\tests\spec.csproj -c Release -o build\spec-win; build\spec-win\claude-limits-spec.exe spec\cases.json
```

Changing shared behaviour? Update the case first, then make both runners pass — CI runs both on every PR.

## Snapshots

`snapshots/mac/` and `snapshots/win/` hold menubar / dropdown / Settings in light + dark; open `snapshots/index.html` to view them side by side. They're rendered from `spec/fixtures/snapshot.json` with a pinned clock, so they're byte-identical run to run and only change when the UI does. CI re-renders both on every PR and commits any changes back to the branch — review them in the PR diff. Local runs write to `build/snapshots/` instead, so different fonts or PNG encoders on your machine never churn the committed images.

If you're not working with direct eyes on the menu bar (remote dev, Claude Code agent, the other OS), `snapshots/` is your verification step — not a post-hoc artifact.

## Wiring a token

Each app reads your Claude OAuth token from one of three sources, picked in Settings:

| Mode | macOS | Windows |
|---|---|---|
| Auto-detect *(default)* | Keychain (`Claude Code-credentials`), then `~/.claude/.credentials.json` and the paths under `~/Library/Application Support/Claude/` | `%CLAUDE_CONFIG_DIR%\.credentials.json`, `%USERPROFILE%\.claude\.credentials.json`, `%APPDATA%\Claude\…` |
| Custom file path | any file with the credentials JSON | same |
| Custom shell command | zsh login shell | PowerShell (e.g. `wsl cat ~/.claude/.credentials.json`) |

If `claude` is signed in on the machine, auto-detect picks it up. Otherwise run `claude` once and sign in.

## Releasing

Maintainer-only, from any OS with git, `gh` and PowerShell:

```powershell
# 1. Add a "## vX.Y.Z" section to CHANGELOG.md, merge to main
# 2. Ship
powershell -File scripts\release.ps1 X.Y.Z
```

CI builds both zips into a draft release; the script updates the Homebrew cask and tap, then publishes. Details in [CLAUDE.md](CLAUDE.md#ci-and-releasing).
