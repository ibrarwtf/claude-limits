# Working on this codebase

Notes for Claude Code (and humans poking under the hood). User-facing install/usage is in [README.md](README.md); local-dev setup is in [DEVELOPMENT.md](DEVELOPMENT.md); contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

Shows your Claude usage in the macOS menu bar and the Windows taskbar. **One logic, two native shells**: everything the apps *decide* is written once in Prolog (`logic/core.pl`) and compiled to Swift and C#; everything they *do* — drawing, networking, files, timers — is native Swift/AppKit in `macos/` and C#/WPF (.NET Framework 4.8, ships with Windows) in `windows/`. Usage polling calls `https://api.anthropic.com/api/oauth/usage`; update checks call GitHub Releases. The logic layer is explained in [logic/README.md](logic/README.md).

## Layout

```
logic/         core.pl (the logic) · plc.pl (compiler) · oracle.pl (spec) · lang.pl
spec/          cases.json (behaviour tests) + fixtures/snapshot.json

macos/                          windows/
  core/   Foundation only       core/   no WPF/WinForms
          Logic.swift ◄─ generated ─► Logic.cs
  app/    AppKit                ui/     WPF + WinForms NotifyIcon
  tests/  main.swift ◄─ generated ─► Spec.cs
  scripts/ build install        scripts/ build install
           uninstall snapshot            uninstall snapshot
  homebrew/  cask               claude-limits.csproj, app.manifest
  launchd/   LaunchAgent

snapshots/     macos/ + windows/ PNGs, index.html viewer — written by CI
scripts/       release.ps1 (ships both apps), metrics.ps1 (line counts)
assets/        AppIcon.icns / AppIcon.ico
VERSION, CHANGELOG.md, .github/workflows/{ci,release}.yml
```

`core.pl` holds: the error enum and its copy, every tuning constant, the persisted-settings table, the API / release / credentials / fixture JSON models, countdowns, the burn-rate and reset line, the sparkline, refresh/error animation frames, window rollover, the polling / back-off / click / credentials-dot policies (including a back-off still running at launch and the refresh animation's minimum), once-per-window threshold alerts, the menu-bar title parts, **the dropdown's rows**, the Settings token-source hint, the Windows tray glyph, tooltip and flyout placement, update selection, token parsing and the order token sources are tried, and command-line flag lookup. The apps call the generated functions (`camelCase` in Swift, `PascalCase` in C# via `using static ClaudeLimits.Logic;`) and keep only platform code: `API`/`Api`, `Token` (Keychain / files / shell), `History` and `Settings` storage, `Fixture` loading, `SelfUpdate`, and the UI.

`macos/scripts/build.sh` greps `macos/core/` for AppKit and `windows/scripts/build.ps1` greps `windows/core/` for `System.Windows`; either aborts the build. That boundary is what lets the generated test suites compile core on its own. Don't add protocols/abstractions to enforce it; the grep is the gate.

## Changing behaviour

- **Logic changes go in `logic/core.pl`**, then `swipl logic/plc.pl && swipl logic/oracle.pl` regenerates `Logic.swift`, `Logic.cs` and both test suites and checks `spec/cases.json` in Prolog. Commit the regenerated files; CI fails if they're stale. Install SWI-Prolog with `winget install SWI-Prolog.SWI-Prolog` / `brew install swi-prolog`.
- **Spec cases live in `spec/cases.json`**: Prolog evaluates every one, then emits literal checks for both apps. Add a case when you change a rule — usually a `calls` entry (`fn`, JSON `args` typed by the signature, `expect`). `oracle.pl` also prints how many `core.pl` clauses the spec runs.
- **The compiler supports a deterministic subset** (first matching clause wins, bodies are bindings ending in an if-then-else tree, optionals narrow when tested). If `plc.pl` rejects something it names the goal — rewrite it in the subset rather than special-casing the compiler.
- **Native code that remains in both apps** (`AppDelegate.swift` ↔ `TrayApp.cs`, the Settings windows, the API clients) still pairs up by name; mirror changes by hand.
- **You don't need a Mac to change the Mac app.** Push a branch: CI compiles it, runs the generated spec, renders `snapshots/macos/` from the fixture and commits PNGs back to the PR only if the UI changed.

Deliberate platform differences: no Keychain on Windows (Claude Code writes a plain file there); PowerShell instead of zsh for the shell token source; Windows adds the taskbar pill, the number-in-tray-icon and in-place self-update (Mac updates via brew).

## Fixture mode

Both apps accept `--fixture <file> [--snapshot-all <dir>]`. The fixture (`spec/fixtures/snapshot.json`) supplies an API response, usage history and a pinned `now`. In fixture mode the apps don't hit the network, use throwaway in-memory settings, don't touch history on disk, format times in UTC/en-US, and (Windows) use fonts and accent present on every image. With `--snapshot-all` they render menubar/dropdown/settings in light + dark and exit. That's what makes snapshots byte-identical run to run — CI only commits PNGs when the UI actually changed.

Without `--snapshot-all` the Windows app shows its tray icon + pill with the fixture data and no polling — handy for eyeballing a UI change.

## Scripts

| Script | Does |
|---|---|
| `macos/scripts/build.sh` | Compile + bundle into `~/Applications/claude-limits.app`, icon from `assets/AppIcon.icns`, ad-hoc codesign. |
| `macos/scripts/install.sh` | `build.sh`, then (re)loads the LaunchAgent; refuses if a brew copy exists in `/Applications`. Refreshes snapshots. |
| `macos/scripts/uninstall.sh` | Stops the LaunchAgent, removes the bundle (`--all` also removes the brew cask). Keeps settings + history. |
| `macos/scripts/snapshot.sh` | Runs the built app with `--fixture … --snapshot-all` → `build/snapshots/macos` (`snapshots/macos` under CI). |
| `windows/scripts/build.ps1` | Boundary grep, `dotnet build` → `build\windows\claude-limits.exe`. |
| `windows/scripts/install.ps1` | Builds, quits the running copy, installs to `%LOCALAPPDATA%\Programs\claude-limits\`, registers HKCU Run + `claude-limits://`, starts it, refreshes snapshots. |
| `windows/scripts/uninstall.ps1` | Quits, removes exe + Run key + URL scheme. Keeps `%APPDATA%\claude-limits\` unless `-Purge`. |
| `windows/scripts/snapshot.ps1` | Runs the built exe with `--fixture … --snapshot-all` → `build\snapshots\windows` (`snapshots\windows` under CI). |
| `scripts/release.ps1` | Maintainer-only, any OS with git + gh + PowerShell. See *CI and releasing*. |
| `scripts/metrics.ps1` | Hand-written lines per language (generated files excluded), Prolog share, Windows exe size. |

Run `.ps1` scripts with `powershell -ExecutionPolicy Bypass -File <path>`. They must stay **UTF-8 with BOM**: Windows PowerShell 5.1 reads BOM-less files as ANSI, and the UTF-8 bytes of `—` contain a byte it treats as a closing quote. `.gitattributes` pins `.sh`/`.swift` to LF and `.ps1` to CRLF.

## Daily loop

```
macos:   edit Swift → bash macos/scripts/install.sh → check build/snapshots/macos/   (log: /tmp/claude-limits.log)
windows: edit C#    → powershell -File windows\scripts\install.ps1 → check build\snapshots\windows\   (log: %TEMP%\claude-limits.log)
spec:    edit spec/cases.json → run both runners (see DEVELOPMENT.md) — or let CI do it
other OS: push a branch → CI builds, tests, commits snapshots → review the PNG diff
```

`snapshots/` is the verification surface when you can't (or shouldn't have to) physically look at the menu bar — agentic workflows, remote pairs, CI. Don't insert a "look at the screen" step in your loop unless the change genuinely isn't UI-visible. Local runs render into `build/snapshots/`; only CI writes the committed `snapshots/` (font/encoder differences between machines would otherwise churn the PNGs). Each capture overwrites in place; git is the history. The live apps also still answer `claude-limits://snapshot/<kind>?dest=<dir>` to capture real (non-fixture) state, and Windows answers `claude-limits://flyout` to open the flyout from a script.

## CI and releasing

- `.github/workflows/ci.yml` — on every PR and push to `main`: a `logic` job runs the spec in SWI-Prolog and fails if any generated file is stale; Windows + macOS jobs build, run their generated spec suites and render snapshots. On same-repo PRs a final job commits changed PNGs back to the branch (GITHUB_TOKEN pushes don't retrigger CI). The macOS runner has a non-Retina display, so Mac PNGs come out @1x.
- `.github/workflows/release.yml` — on a `v*` tag: builds both zips (`claude-limits-macos-X.Y.Z.zip` for the cask, `claude-limits-windows-X.Y.Z.zip`) into a **draft** release, notes from the CHANGELOG section.
- `scripts/release.ps1 X.Y.Z` — checks clean/synced `main` + a `## vX.Y.Z` CHANGELOG section, bumps `VERSION`, tags, pushes, waits for the draft, writes the Mac zip's sha256 into `macos/homebrew/claude-limits.rb` and the tap clone (`..\homebrew-lab`, or `TAP_DIR`), then publishes the draft as latest. Draft-first means neither app is offered a release before brew can install it.
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
- No new dependencies: AppKit + Foundation on macOS; in-box .NET Framework 4.8 assemblies on Windows (no NuGet packages). SWI-Prolog is a dev/CI tool only — the apps never need it.
- Direct platform APIs over wrappers/protocols. The codebase is small enough that boilerplate beats indirection.
- Keep the `core/` boundaries clean. Anything UI-shaped goes in `macos/app/` or `windows/ui/`.
- Match existing naming and structure — and the other platform's naming — rather than introducing a new style.

## Versioning

Pre-1.0:
- `0.x.0 → 0.y.0` — visible feature change
- `0.x.y → 0.x.z` — bug fix or polish

One version for both apps, from the `VERSION` file: `macos/scripts/build.sh` bakes it into Info.plist, `windows/claude-limits.csproj` into the exe. Only `scripts/release.ps1` bumps it. Maintainer-only; forks land changes via PRs to `main`.
