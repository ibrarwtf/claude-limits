# Working on this codebase

Notes for Claude Code (and humans poking under the hood). User-facing install/usage is in [README.md](README.md); local-dev setup is in [DEVELOPMENT.md](DEVELOPMENT.md); contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

A macOS menu-bar app that shows your Anthropic API usage. Single Swift binary, no dependencies. Usage polling calls `https://api.anthropic.com/api/oauth/usage`; update checks call GitHub Releases.

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

## What each script does

| Script | Does |
|---|---|
| `build.sh` | Compile + bundle into `~/Applications/claude-limits.app`. Pre-baked icon from `assets/AppIcon.icns`. Codesigns ad-hoc. |
| `install.sh` | Runs `build.sh`, then loads the LaunchAgent so the app starts (and restarts on login). Tears down legacy bundles from prior naming schemes. |
| `uninstall.sh` | Stops the LaunchAgent, removes the bundle. Preserves settings + history. |
| `snapshot.sh` | Triggers the running app via `claude-limits://snapshot/<kind>`; the app captures its own views (`NSView.cacheDisplay`, no Screen Recording grant) and writes PNGs into `snapshots/`. |
| `release.sh` | Maintainer-only. Bumps `Info.plist` version, builds, zips, sha256, patches `homebrew/claude-limits.rb` in-place. |

## Daily loop

For UI-visible changes:

```
edit Swift → bash scripts/install.sh → bash scripts/snapshot.sh --auto-all → check snapshots/
```

For non-visual changes (logic, refactors, plumbing):

```
edit Swift → bash scripts/install.sh → tail -f /tmp/claude-limits.log
```

`snapshots/` is the verification surface when you can't (or shouldn't have to) physically look at the menu bar — agentic workflows, remote pairs, CI. Don't insert a "look at the screen" step in your loop unless the change genuinely isn't UI-visible.

~5s end-to-end on Apple Silicon. Logs at `/tmp/claude-limits.log`. Persisted settings: `defaults read claude-limits`. Bundle: `~/Applications/claude-limits.app`.

## Snapshots in the repo

`snapshots/index.html` shows the current menu bar / dropdown / Settings in light + dark, sourced from six tracked PNGs (`{menubar,dropdown,settings}-{light,dark}.png`). After any change that affects rendering, run `bash scripts/snapshot.sh --auto-all` and commit the updated PNGs so anyone reading the repo can see what they're working with without building.

Each capture overwrites in place — no timestamped variants, no `latest-` prefix. Git is the history. The app handles `claude-limits://snapshot/<menubar|dropdown|settings>?dest=<dir>` itself; `snapshot.sh` just opens the URL and polls the destination file's mtime.

## macOS gotchas worth knowing

- LSUIElement apps don't show windows reliably at `applicationDidFinishLaunching`. Defer to the next runloop tick with `DispatchQueue.main.async { ... }`.
- `cacheDisplay`'s offscreen graphics context ignores `NSAppearance.performAsCurrentDrawingAppearance`. For dark/light-aware rendering use direct drawing inside the perform block, not `cacheDisplay`.
- `NSMenu` reserves ~22pt on the left of every item for the state-icon column. Setting `NSMenuItem.view` bypasses that — that's how the dropdown gets flush-left text.
- Anthropic's usage endpoint updates on its own ~5-minute cadence even though we poll every 2 minutes; expect runs of identical-utilization samples and don't treat them as "no activity".

## Code style

- Comments explain WHY, not WHAT. Add them only when the reasoning is non-obvious — an AppKit gotcha, a threading constraint, an API quirk.
- No new dependencies. AppKit + Foundation only.
- Direct AppKit over wrappers/protocols. The codebase is small enough that boilerplate beats indirection.
- Keep the `core/` boundary clean. Anything UI-shaped goes in `mac/`.
- Match existing naming and structure rather than introducing a new style.

## Versioning

Pre-1.0:
- `0.x.0 → 0.y.0` — visible feature change
- `0.x.y → 0.x.z` — bug fix or polish

Single source of version: `scripts/build.sh` Info.plist heredoc (`CFBundleShortVersionString`). `scripts/release.sh` overrides via `PlistBuddy` and patches `homebrew/claude-limits.rb` in-place. Maintainer-only; forks land changes via PRs to `main`.
