# Local development

Codebase machinery (file roles, build steps, gotchas) is in [CLAUDE.md](CLAUDE.md). Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Prereqs

A Mac on macOS 13 or later, with `xcode-select --install` (gives you `swiftc` — no Xcode app needed). For the Windows build, see [Windows](#windows) below.

## Clone and run

```bash
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
bash scripts/install.sh
```

The icon should appear in your menu bar within a couple of seconds. `install.sh` builds, bundles into `~/Applications/claude-limits.app`, installs a LaunchAgent so it autostarts on login, and starts the new build.

## Dev loop

```
edit Swift → bash scripts/install.sh → look at your menu bar
```

~5 seconds end-to-end on Apple Silicon. Useful side commands:

```bash
tail -f /tmp/claude-limits.log         # stdout + stderr
defaults read claude-limits            # current persisted settings
bash scripts/uninstall.sh              # remove .app + LaunchAgent (settings + history kept)
```

## Wiring a token

The app reads your Claude OAuth token from one of three sources, picked in the Settings window (right-click the menu bar icon):

| Mode | Where it reads from |
|---|---|
| Auto-detect *(default)* | macOS Keychain (`Claude Code-credentials`), then `~/.claude/.credentials.json` and the other known credential paths under `~/Library/Application Support/Claude/`. |
| Custom file path | A path you supply that contains the credentials JSON. |
| Custom shell command | A shell command whose stdout is the credentials JSON — useful for Docker, SSH, etc. |

If `claude` is signed in on this Mac, auto-detect picks it up. Otherwise run `claude` once and sign in.

## Snapshots

```bash
bash scripts/snapshot.sh --auto-all
open snapshots/index.html
```

The app captures its own views via `cacheDisplay` (no Screen Recording grant needed) and overwrites the six PNGs in `snapshots/mac/` in place (Windows: `snapshots/windows/`). After any change that affects rendering: rerun and commit the updated PNGs so reviewers — and anyone else cloning the repo — see the UI without having to build it. See [CLAUDE.md](CLAUDE.md) for the snapshot mechanism.

If you're not working with direct eyes on the menu bar (remote dev, Claude Code agent, CI), `snapshots/` is your verification step — not a post-hoc artifact. Build, snapshot, look at the PNGs, iterate.

## Dev install vs brew install

These don't coexist. `bash scripts/install.sh` writes the bundle to `~/Applications/`; `brew install --cask claude-limits` writes to `/Applications/`. Both register the `claude-limits://` URL scheme and the same LaunchAgent label, so running both produces double menubar icons and races snapshot capture.

`install.sh` refuses to run if it detects the brew copy at `/Applications/`. Use one of:

```bash
# Switch to dev workflow
brew uninstall --cask claude-limits
bash scripts/install.sh

# Switch back to brew (running the actually-shipped artifact)
bash scripts/uninstall.sh                       # remove dev install
brew install --cask claude-limits               # or: brew upgrade

# Wipe everything in one shot
bash scripts/uninstall.sh --all                 # dev + brew cask
```

`release.sh --publish` runs the second flow automatically post-ship — the maintainer Mac always ends up running the actual brew-installed release after a publish.

## Windows

### Prereqs

Windows 10 or 11 and the .NET SDK (build-time only — the app itself runs on the .NET Framework 4.8 that ships with Windows):

```powershell
winget install Microsoft.DotNet.SDK.10
```

### Clone and run

```powershell
git clone https://github.com/ibrarwtf/claude-limits
cd claude-limits
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

`install.ps1` builds `build\win\claude-limits.exe`, quits any running copy, installs to `%LOCALAPPDATA%\Programs\claude-limits\`, registers autostart (HKCU Run key) and the `claude-limits://` URL scheme, starts it, and refreshes `snapshots\windows\`. Look for the pill on the taskbar next to the tray. The tray icon starts in the `^` overflow; drag it onto the taskbar.

### Dev loop

```
edit C# → powershell -File scripts\install.ps1 → check snapshots\windows\
```

Useful side commands:

```powershell
Get-Content -Wait $env:TEMP\claude-limits.log                   # log
Get-Content $env:APPDATA\claude-limits\settings.json            # persisted settings
Start-Process claude-limits://flyout                             # open the flyout from a script
powershell -File scripts\snapshot.ps1 --auto-all                 # re-capture PNGs
powershell -File scripts\uninstall.ps1 [-Purge]                  # remove (−Purge also wipes settings + history)
```

## Releasing

Maintainer-only. See [CLAUDE.md](CLAUDE.md).
