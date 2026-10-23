# Working on this codebase

Notes for Claude Code (and humans poking under the hood). User-facing install/usage is in [README.md](README.md); local-dev setup is in [DEVELOPMENT.md](DEVELOPMENT.md); contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

Shows your Claude usage in the macOS menu bar and the Windows taskbar. **Two native apps, one spec**: a Swift/AppKit app in `mac/` and a C#/WPF app (.NET Framework 4.8, ships with Windows) in `win/`. No code is shared — the Swift runtime isn't on Windows — but behaviour is: both run the same test cases in `spec/` and render the same fixture in CI. Usage polling calls `https://api.anthropic.com/api/oauth/usage`; update checks call GitHub Releases.

## Layout

```
mac/                          win/
  core/   Foundation only       core/   no WPF/WinForms
  app/    AppKit                ui/     WPF + WinForms NotifyIcon
  tests/  spec runner (Swift)   tests/  spec runner (C#)
  scripts/ build install        scripts/ build install
           uninstall snapshot            uninstall snapshot
  homebrew/  cask               claude-limits.csproj, app.manifest
  launchd/   LaunchAgent

spec/          cases.json (behaviour tests) + fixtures/snapshot.json
snapshots/     mac/ + win/ PNGs, index.html viewer — written by CI
scripts/       release.ps1 — ships both apps
assets/        AppIcon.icns / AppIcon.ico
VERSION, CHANGELOG.md, .github/workflows/{ci,release}.yml
```

Files pair up by name — `mac/core/Format.swift` ↔ `win/core/Format.cs`, `mac/app/AppDelegate.swift` ↔ `win/ui/TrayApp.cs` — and method names match, so a change on one side is easy to find on the other.

```
core (both)   API      usage call            Models   response shapes + weeklyRows
              Token    credential sources    Settings persisted prefs
              History  samples + sparkline   Format   countdowns, reset/burn line
              Updates  GitHub release check  Errors   AppError + copy
              Fixture  pinned Clock + --fixture mode
win/core only Json (DataContract helpers), Platform (data dir, Run key, URL
              scheme, theme registry), SelfUpdate (zip → swap exe), Log
```

`mac/scripts/build.sh` greps `mac/core/` for AppKit and `win/scripts/build.ps1` greps `win/core/` for `System.Windows`; either aborts the build. That boundary is what lets the spec runners compile core on its own. Don't add protocols/abstractions to enforce it; the grep is the gate.

## Keeping the two apps in step

- **Behaviour lives in core and is pinned by `spec/cases.json`.** Countdown/relative-time formatting, version compare, token extraction, the sparkline, the reset/burn-rate line, weekly rows (including the `limits` fallback) and window-rollover detection. Change the behaviour → change the case → make both runners pass. CI fails if either side disagrees.
- **UI-side logic** (polling cadence, back-off, click cooldowns, threshold alerts, animations) lives in `AppDelegate.swift` / `TrayApp.cs`. Mirror changes by hand; keep method names aligned.
- **You don't need a Mac to change the Mac app.** Push a branch: CI compiles it, runs the spec, renders `snapshots/mac/` from the fixture and commits the PNGs back to the PR. Review the images in the diff. Same for Windows from a Mac.

Deliberate platform differences: no Keychain on Windows (Claude Code writes a plain file there); PowerShell instead of zsh for the shell token source; Windows adds the taskbar pill, the number-in-tray-icon and in-place self-update (Mac updates via brew).

## Fixture mode

Both apps accept `--fixture <file> [--snapshot-all <dir>]`. The fixture (`spec/fixtures/snapshot.json`) supplies an API response, usage history and a pinned `now`. In fixture mode the apps don't hit the network, use throwaway in-memory settings, don't touch history on disk, format times in UTC/en-US, and (Windows) use fonts and accent present on every image. With `--snapshot-all` they render menubar/dropdown/settings in light + dark and exit. That's what makes snapshots byte-identical run to run — CI only commits PNGs when the UI actually changed.

Without `--snapshot-all` the Windows app shows its tray icon + pill with the fixture data and no polling — handy for eyeballing a UI change.

## Scripts

| Script | Does |
|---|---|
| `mac/scripts/build.sh` | Compile + bundle into `~/Applications/claude-limits.app`, icon from `assets/AppIcon.icns`, ad-hoc codesign. |
| `mac/scripts/install.sh` | `build.sh`, then (re)loads the LaunchAgent; refuses if a brew copy exists in `/Applications`. Refreshes snapshots. |
| `mac/scripts/uninstall.sh` | Stops the LaunchAgent, removes the bundle (`--all` also removes the brew cask). Keeps settings + history. |
| `mac/scripts/snapshot.sh` | Runs the built app with `--fixture … --snapshot-all` → `build/snapshots/mac` (`snapshots/mac` under CI). |
| `win/scripts/build.ps1` | Boundary grep, `dotnet build` → `build\win\claude-limits.exe`. |
| `win/scripts/install.ps1` | Builds, quits the running copy, installs to `%LOCALAPPDATA%\Programs\claude-limits\`, registers HKCU Run + `claude-limits://`, starts it, refreshes snapshots. |
| `win/scripts/uninstall.ps1` | Quits, removes exe + Run key + URL scheme. Keeps `%APPDATA%\claude-limits\` unless `-Purge`. |
| `win/scripts/snapshot.ps1` | Runs the built exe with `--fixture … --snapshot-all` → `build\snapshots\win` (`snapshots\win` under CI). |
| `scripts/release.ps1` | Maintainer-only, any OS with git + gh + PowerShell. See *CI and releasing*. |

Run `.ps1` scripts with `powershell -ExecutionPolicy Bypass -File <path>`. They must stay **UTF-8 with BOM**: Windows PowerShell 5.1 reads BOM-less files as ANSI, and the UTF-8 bytes of `—` contain a byte it treats as a closing quote. `.gitattributes` pins `.sh`/`.swift` to LF and `.ps1` to CRLF.

## Daily loop

```
mac:  edit Swift → bash mac/scripts/install.sh → check build/snapshots/mac/   (log: /tmp/claude-limits.log)
win:  edit C#    → powershell -File win\scripts\install.ps1 → check build\snapshots\win\   (log: %TEMP%\claude-limits.log)
spec: edit spec/cases.json → run both runners (see DEVELOPMENT.md) — or let CI do it
other OS: push a branch → CI builds, tests, commits snapshots → review the PNG diff
```

`snapshots/` is the verification surface when you can't (or shouldn't have to) physically look at the menu bar — agentic workflows, remote pairs, CI. Don't insert a "look at the screen" step in your loop unless the change genuinely isn't UI-visible. Local runs render into `build/snapshots/`; only CI writes the committed `snapshots/` (font/encoder differences between machines would otherwise churn the PNGs). Each capture overwrites in place; git is the history. The live apps also still answer `claude-limits://snapshot/<kind>?dest=<dir>` to capture real (non-fixture) state, and Windows answers `claude-limits://flyout` to open the flyout from a script.

## CI and releasing

- `.github/workflows/ci.yml` — on every PR and push to `main`: Windows + macOS jobs build, run the spec, render snapshots. On same-repo PRs a final job commits changed PNGs back to the branch (GITHUB_TOKEN pushes don't retrigger CI). The macOS runner has a non-Retina display, so Mac PNGs come out @1x.
- `.github/workflows/release.yml` — on a `v*` tag: builds both zips (`claude-limits-X.Y.Z.zip` for the cask, `claude-limits-windows-X.Y.Z.zip`) into a **draft** release, notes from the CHANGELOG section.
- `scripts/release.ps1 X.Y.Z` — checks clean/synced `main` + a `## vX.Y.Z` CHANGELOG section, bumps `VERSION`, tags, pushes, waits for the draft, writes the Mac zip's sha256 into `mac/homebrew/claude-limits.rb` and the tap clone (`..\homebrew-lab`, or `TAP_DIR`), then publishes the draft as latest. Draft-first means neither app is offered a release before brew can install it.
- The Mac app reads `/releases/latest` and updates via `brew upgrade`; the Windows app scans the release list for the newest release with a Windows zip and swaps its exe in place (sha256-checked against GitHub's asset digest).

## macOS gotchas worth knowing

- LSUIElement apps don't show windows reliably at `applicationDidFinishLaunching`. Defer to the next runloop tick with `DispatchQueue.main.async { ... }`.
- `cacheDisplay`'s offscreen graphics context ignores `NSAppearance.performAsCurrentDrawingAppearance`. For dark/light-aware rendering use direct drawing inside the perform block, not `cacheDisplay`.
- `NSMenu` reserves ~22pt on the left of every item for the state-icon column. Setting `NSMenuItem.view` bypasses that — that's how the dropdown gets flush-left text.
- ICU's `en_US` short time format uses a narrow no-break space before AM/PM; fixture mode uses `en_US_POSIX` + an explicit `h:mm a` so strings match the spec.

## Windows gotchas worth knowing

- The notification area only fits a small square icon, so the menu-bar line lives in `PillWindow` (a topmost tool window over the taskbar). The taskbar is topmost too and re-raises when clicked, so the pill re-asserts `HWND_TOPMOST` every second, and hides while `SHQueryUserNotificationState` reports a fullscreen app.
- `NotifyIcon.Text` throws past 63 characters on .NET Framework — truncate tooltips.
- Windows lets you rename a running exe but not overwrite it; `SelfUpdate` relies on that. The relaunched copy waits on the single-instance mutex (`--after-update`) while the old one exits.
- WPF's mouse events hit-test the real cursor, so synthetic `PostMessage` clicks don't trigger handlers — use the `claude-limits://` URLs to drive the app from scripts.
- `HttpClient` sends no User-Agent by default and GitHub's API rejects those requests, so `Api.cs` sets one.
- Two theme axes: the tray, pill and flyout follow the *Windows* mode (`SystemUsesLightTheme`), Settings follows the *app* mode (`AppsUseLightTheme`), matching Windows' own surfaces.
- `Settings.Shared` / `UsageHistory.Shared` are `Lazy<>` so fixture mode can switch off disk access before their first use.

## Shared API notes

- Anthropic's usage endpoint updates on its own ~5-minute cadence even though we poll every 3 minutes; expect runs of identical-utilization samples and don't treat them as "no activity".
- Since late 2026 the endpoint returns `seven_day*` as null and reports weekly usage in a `limits` array (`group: "weekly"`, optional `scope.model.display_name`). `weeklyRows` reads the legacy buckets first and falls back to `limits`.

## Code style

- Comments explain WHY, not WHAT. Add them only when the reasoning is non-obvious — a platform gotcha, a threading constraint, an API quirk.
- No new dependencies: AppKit + Foundation on macOS; in-box .NET Framework 4.8 assemblies on Windows (no NuGet packages).
- Direct platform APIs over wrappers/protocols. The codebase is small enough that boilerplate beats indirection.
- Keep the `core/` boundaries clean. Anything UI-shaped goes in `mac/app/` or `win/ui/`.
- Match existing naming and structure — and the other platform's naming — rather than introducing a new style.

## Versioning

Pre-1.0:
- `0.x.0 → 0.y.0` — visible feature change
- `0.x.y → 0.x.z` — bug fix or polish

One version for both apps, from the `VERSION` file: `mac/scripts/build.sh` bakes it into Info.plist, `win/claude-limits.csproj` into the exe. Only `scripts/release.ps1` bumps it. Maintainer-only; forks land changes via PRs to `main`.
