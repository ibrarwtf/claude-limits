# Working on this codebase

Notes for Claude Code (and humans poking under the hood). User-facing install/usage is in [README.md](README.md); local-dev setup is in [DEVELOPMENT.md](DEVELOPMENT.md); contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

A macOS menu-bar app (and a Windows tray app) that shows your Anthropic API usage. Single binary per platform, no dependencies: Swift + AppKit on macOS, C# + WPF on .NET Framework 4.8 on Windows. Usage polling calls `https://api.anthropic.com/api/oauth/usage`; update checks call GitHub Releases.

## How the parts fit together

```
src/core/   Foundation only — no AppKit. Headless logic, could be reused
            for a CLI or another platform.

   API.swift         usage call to /api/oauth/usage
   Models.swift      response shapes (Codable)
   Token.swift       keychain → known credential paths fall-through;
                     plus custom file-path / shell-command modes
   Settings.swift    UserDefaults wrapper (token source, which widgets show)
   History.swift     burn-rate samples on disk under
                     ~/Library/Application Support/claude-limits/
   Format.swift      "4h 32m" / "18%" formatting
   Updates.swift     GitHub Releases poll for newer version
   Errors.swift      AppError enum

src/mac/    AppKit.

   main.swift            entry point — sets up NSApplication
   AppDelegate.swift     status item, menu, dropdown, refresh tick,
                         animations, snapshot URL handler
   SettingsWindow.swift  Settings UI
```

`scripts/build.sh` greps `src/core/*.swift` for `import AppKit|Cocoa` and aborts the build if found — boundary-as-build-error so the headless layer stays headless. Don't introduce protocols/abstractions to enforce this; the grep is the gate.

### Windows (`src/win/`)

A C# port, not shared code — the Swift runtime isn't on Windows (shipping it costs ~40 MB), while .NET Framework 4.8 is on every Windows 10/11 box, so the exe is ~140 KB with nothing to install. Built with `dotnet build` (SDK is build-time only).

```
src/win/core/   No WPF/WinForms. scripts/build.ps1 greps for System.Windows
                and aborts — same gate as build.sh.

   Api.cs  Models.cs  Token.cs  Settings.cs  History.cs
   Format.cs  Updates.cs  Errors.cs         ← one-to-one with src/core/*.swift
   Json.cs         DataContractJsonSerializer helpers (no System.Text.Json on 4.8)
   Platform.cs     data dir, version, HKCU Run key (autostart), URL scheme
   SelfUpdate.cs   download release zip → rename running exe to .old → swap
   Log.cs          %TEMP%\claude-limits.log (NSLog stand-in)

src/win/ui/     WPF + a WinForms NotifyIcon (both in-box).

   Program.cs        entry: single-instance mutex + named pipe that forwards
                     claude-limits:// URLs from a second launch
   TrayApp.cs        AppDelegate port: state, timers, polling, animations
   PillWindow.cs     floating taskbar capsule (the menu-bar text)
   PillView.cs       MenuBarTitle + the capsule's visual (shared)
   FlyoutWindow.cs   the dropdown (FlyoutView rows are shared with snapshots)
   SettingsWindow.cs Settings UI
   TrayIcon.cs       draws the % number into the tray icon
   Theme.cs, Styles.xaml  light/dark brushes + control templates
   Snapshot.cs       offscreen RenderTargetBitmap → snapshots/windows/
```

**Keeping the two in sync.** Polling cadence, back-off, burn-rate math, rollover detection, threshold alerts and error copy are duplicated. A behaviour change in `src/core/*.swift` or `AppDelegate.swift` should land in the same-named C# file (`AppDelegate.swift` ↔ `TrayApp.cs`); method names match so they're greppable. Platform-only differences are deliberate: no Keychain on Windows (Claude Code writes a plain file there), PowerShell instead of zsh for the shell token source, and the Windows build reads weekly usage from the API's newer `limits` array when `seven_day*` is null.

## What each script does

| Script | Does |
|---|---|
| `build.sh` | Compile + bundle into `~/Applications/claude-limits.app`. Pre-baked icon from `assets/AppIcon.icns`. Codesigns ad-hoc. |
| `install.sh` | Runs `build.sh`, then loads the LaunchAgent so the app starts (and restarts on login). Tears down legacy bundles from prior naming schemes. |
| `uninstall.sh` | Stops the LaunchAgent, removes the bundle. Preserves settings + history. |
| `snapshot.sh` | Triggers the running app via `claude-limits://snapshot/<kind>`; the app captures its own views (`NSView.cacheDisplay`, no Screen Recording grant) and writes PNGs into `snapshots/`. |
| `release.sh` | Maintainer-only. Bumps `Info.plist` version, builds, zips, sha256, patches `homebrew/claude-limits.rb` in-place. |
| `build.ps1` | Windows: boundary grep, then `dotnet build` → `build\win\claude-limits.exe`. |
| `install.ps1` | Windows: builds, quits the running copy, installs to `%LOCALAPPDATA%\Programs\claude-limits\`, registers the HKCU Run key + `claude-limits://`, starts it, refreshes snapshots. |
| `uninstall.ps1` | Windows: quits, removes exe + Run key + URL scheme. Keeps `%APPDATA%\claude-limits\` unless `-Purge`. |
| `snapshot.ps1` | Windows: `claude-limits://snapshot/<kind>`; writes `snapshots/windows/*.png`. |
| `release.ps1` | Maintainer-only. Bumps `VERSION`, builds, zips `claude-limits-windows-X.Y.Z.zip`. `-Publish` tags, pushes, and uploads to the tag's GitHub release — creating it with `--latest=false` if no Mac release exists, so the Mac app (which reads `/releases/latest` and upgrades via brew) isn't offered a version its cask lacks. The Windows app scans the release list for the newest Windows zip. |

Run the `.ps1` scripts with `powershell -ExecutionPolicy Bypass -File scripts\<name>.ps1`. They must stay **UTF-8 with BOM**: Windows PowerShell 5.1 reads BOM-less files as ANSI, and the UTF-8 bytes of `—` contain a byte it treats as a closing quote.

## Daily loop

For UI-visible changes:

```
edit Swift → bash scripts/install.sh → bash scripts/snapshot.sh --auto-all → check snapshots/mac/
```

For non-visual changes (logic, refactors, plumbing):

```
edit Swift → bash scripts/install.sh → tail -f /tmp/claude-limits.log
```

On Windows:

```
edit C# → powershell -File scripts\install.ps1 → check snapshots\windows\   (logs: %TEMP%\claude-limits.log)
```

`claude-limits://flyout` opens the flyout from a script, so its placement can be checked without clicking.

`snapshots/` is the verification surface when you can't (or shouldn't have to) physically look at the menu bar — agentic workflows, remote pairs, CI. Don't insert a "look at the screen" step in your loop unless the change genuinely isn't UI-visible.

~5s end-to-end on Apple Silicon. Logs at `/tmp/claude-limits.log`. Persisted settings: `defaults read claude-limits`. Bundle: `~/Applications/claude-limits.app`.

## Snapshots in the repo

`snapshots/index.html` shows the current menu bar / dropdown / Settings in light + dark, sourced from tracked PNGs in `snapshots/mac/` and `snapshots/windows/` (`{menubar,dropdown,settings}-{light,dark}.png` each). After any change that affects rendering, run `bash scripts/snapshot.sh --auto-all` and commit the updated PNGs so anyone reading the repo can see what they're working with without building.

Each capture overwrites in place — no timestamped variants, no `latest-` prefix. Git is the history. The app handles `claude-limits://snapshot/<menubar|dropdown|settings>?dest=<dir>` itself; `snapshot.sh` just opens the URL and polls the destination file's mtime.

## macOS gotchas worth knowing

- LSUIElement apps don't show windows reliably at `applicationDidFinishLaunching`. Defer to the next runloop tick with `DispatchQueue.main.async { ... }`.
- `cacheDisplay`'s offscreen graphics context ignores `NSAppearance.performAsCurrentDrawingAppearance`. For dark/light-aware rendering use direct drawing inside the perform block, not `cacheDisplay`.
- `NSMenu` reserves ~22pt on the left of every item for the state-icon column. Setting `NSMenuItem.view` bypasses that — that's how the dropdown gets flush-left text.
- Anthropic's usage endpoint updates on its own ~5-minute cadence even though we poll every 2 minutes; expect runs of identical-utilization samples and don't treat them as "no activity".

## Windows gotchas worth knowing

- The notification area only fits a small square icon, so the menu-bar line lives in `PillWindow` (a topmost tool window over the taskbar). The taskbar is topmost too and re-raises when clicked, so the pill re-asserts `HWND_TOPMOST` every second, and hides while `SHQueryUserNotificationState` reports a fullscreen app.
- `NotifyIcon.Text` throws past 63 characters on .NET Framework — truncate tooltips.
- Windows lets you rename a running exe but not overwrite it; `SelfUpdate` relies on that. The relaunched copy waits on the single-instance mutex (`--after-update`) while the old one exits.
- WPF's mouse events hit-test the real cursor, so synthetic `PostMessage` clicks don't trigger handlers — use the `claude-limits://` URLs to drive the app from scripts.
- `HttpClient` sends no User-Agent by default and GitHub's API rejects those requests, so `Api.cs` sets one.
- Two theme axes: the tray, pill and flyout follow the *Windows* mode (`SystemUsesLightTheme`), Settings follows the *app* mode (`AppsUseLightTheme`), matching Windows' own surfaces.

## Code style

- Comments explain WHY, not WHAT. Add them only when the reasoning is non-obvious — an AppKit gotcha, a threading constraint, an API quirk.
- No new dependencies. AppKit + Foundation only on macOS; .NET Framework 4.8 in-box assemblies only on Windows (no NuGet packages).
- Direct AppKit over wrappers/protocols. The codebase is small enough that boilerplate beats indirection.
- Keep the `core/` boundary clean. Anything UI-shaped goes in `mac/`.
- Match existing naming and structure rather than introducing a new style.

## Versioning

Pre-1.0:
- `0.x.0 → 0.y.0` — visible feature change
- `0.x.y → 0.x.z` — bug fix or polish

Single source of version: the `VERSION` file — `scripts/build.sh` bakes it into Info.plist (`CFBundleShortVersionString`), `src/win/claude-limits.csproj` reads it into the exe's assembly version. `scripts/release.sh` overrides via `PlistBuddy` and patches `homebrew/claude-limits.rb` in-place. Maintainer-only; forks land changes via PRs to `main`.
