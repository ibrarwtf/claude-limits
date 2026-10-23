# Changelog

`release.sh --publish` reads the section matching the version being shipped and feeds it to `gh release create --notes-file`. So write each section as user-facing release notes — what changed, why someone running `brew upgrade` would care.

## v0.3.1

- **Weekly limits are back on macOS.** Anthropic's usage API stopped filling the per-model weekly fields and now reports weekly usage in a new `limits` list; the Mac dropdown showed no weekly rows. Both apps now read the new list (the Windows app already did).
- First release built entirely by CI: one release carries both the Mac zip (for `brew upgrade`) and the Windows zip (for in-app update).
- Internals: repo split into `mac/` and `win/`, with shared behaviour tests in `spec/` that both apps must pass, and deterministic screenshots rendered from a fixture on every PR.

## v0.3.0

- **Windows app.** claude-limits now runs on Windows 10/11 as a ~140 KB exe with nothing to install (.NET Framework 4.8 ships with Windows). Download `claude-limits-windows-0.3.0.zip`, extract, run.
  - A pill on the taskbar next to the tray shows the same `18% ▆▇█ 4:32` line as the Mac menu bar (drag to move, hide in Settings, hides while a fullscreen app is running). Left-click refreshes, right-click opens the breakdown.
  - The tray icon shows the 5-hour % as a number — amber at 80%, red at 95% — with the reset countdown in its tooltip. Click it for the flyout.
  - Same polling, back-off, burn-rate projection, 80%/95% alerts (as Windows notifications) and token sources (auto-detect `%USERPROFILE%\.claude\.credentials.json`, custom file, or a PowerShell command, e.g. for WSL).
  - Follows Windows light/dark mode and accent colour, live. Starts at login via the per-user Run key.
  - "Update to vX.Y.Z" in Settings downloads the release zip, verifies its sha256, swaps the exe in place and relaunches.
- Weekly limits are read from the API's newer `limits` field when the `seven_day*` buckets come back empty (Windows app).

## v0.2.0

- **Update in place from Settings.** "Check for updates" now turns into "Update to vX.Y.Z" when a newer release exists; clicking it upgrades the app (via `brew upgrade --cask claude-limits`) and relaunches — no terminal needed. (Dev/self-built installs are pointed at the GitHub release instead.)
- **Burn-rate projection is now time-weighted.** The dropdown's `%/h` and "100% in X" projection previously averaged per-poll rates with equal weight, so a single ~5-min Anthropic update landing on one poll, or a laptop-sleep gap, could read many times too high and falsely warn you were about to cap. It now divides the window's net utilization change by its net elapsed time, ignoring sleep/relaunch gaps and window rollovers. A just-reset window shows "measuring…" instead of a false "idle".
- **Burn-rate sparkline** in the menu bar now reflects rate over time, so a sleep/relaunch gap no longer paints a misleading full-height spike next to an "idle" reset line.
- **Weekly-limit bars** light at least one block for any nonzero usage, so a small-but-real value no longer shows an empty bar next to a "1%"/"2%" label.
- **Window-reset detection** now keys off the API's authoritative `resets_at` advancing, not just a >5% usage drop, so resets from low utilization are caught.
- **Polling eased 120s → 180s** to match Anthropic's ~5-minute usage-update cadence: ~⅓ fewer API calls and less rate-limit exposure, with no loss of freshness (the reset countdown is derived locally).
- **Rate-limit & reliability hardening:** "Refresh now" now shares the menu-bar click's 5s click-storm cooldown, and Settings "Test fetch" now respects the rate-limit back-off window (a rate-limited test fetch is recorded in the back-off instead of silently resetting Anthropic's cooldown); the Settings token-reachability dot no longer fires an ungated probe on rapid reopen; shell token-source commands no longer spuriously time out on large output or leak a process when they hang; the refresh animation can't be cut short by a stale timer; 80%/95% notifications no longer re-fire when the API briefly drops `resets_at`.
- `release.sh`: re-shipping a tag now force-pushes it (a partial-failure re-run no longer aborts after pushing `main`), and the version argument is validated as semver.

## v0.1.10

- `install.sh` now refuses if a brew-installed copy exists at `/Applications/claude-limits.app` — prevents the dual-bundle conflict (double menubar icons, URL-scheme race) that bit anyone running both dev install and brew install.
- `uninstall.sh` adds an `--all` flag that also runs `brew uninstall --cask claude-limits`. Default behavior is unchanged (dev cleanup only) and the script now states explicitly what was removed and what was kept.
- `DEVELOPMENT.md` documents the dev-install ↔ brew-install workflow.
- Internals: removed dead `writeFrames()` and `progressBar(_:)` — the former wrote `frames.txt` for an old screen-cropping flow that no longer exists; the latter was a text-bar utility replaced by `TabularRowView`'s drawn bars long ago.

## v0.1.9

- Sparkline and burn-rate / reset projection now skip error-sentinel samples — no more fake spikes in the menubar after a stretch of failed polls.
- Settings opening no longer burns an extra usage-API call when recent app state is already cached (or when the next poll is rate-limited). Fresh fetch only when there's nothing to reuse.
- Removed the deprecated `NSColor.selectedMenuItemColor` usage — clean build, no warnings.
- Docs fixed: usage polling calls Anthropic; the optional update checker also calls GitHub Releases. Previous wording undersold the second call.

## v0.1.8

- Settings: the credentials.json glyph dot now also pulses **red** when the token is verified unreachable (previously it stayed gray). Three states: gray = unprobed, green-pulse = connected, red-pulse = disconnected.
- Internals: snapshot URL handler retries up to 2s waiting for `statusItem` initialization. Fixes menubar capture failing on cold-launch via URL scheme (the previous race window was ~100ms).
- `release.sh --publish` now ends by uninstalling the dev build and `brew reinstall`-ing the freshly published cask, so the maintainer Mac always runs the actual shipped artifact post-release (not the dev bundle at `~/Applications`).

## v0.1.7

- Settings footer: "made by ibr" is now centred, lowercase, and styled as a blue underlined link to the maintainer's GitHub.
- Settings: the dot on the credentials.json glyph pulses slow green when the token is verified reachable, gray otherwise. Updates on Settings open and after the Test fetch button.
- Dropdown: removed the "Update available" hint line. The same hint still appears in Settings (Check for updates) — keeping the menubar dropdown clean.
- Internals: the footer link is now rendered as an NSButton instead of an NSTextField-with-selectable-attributedString, so it paints correctly in offscreen snapshots (the previous trick used NSTextView under the hood, which doesn't honour cacheDisplay).

## v0.1.6

- "Made by ibr" footer in Settings is now a clickable link to the project's GitHub.
- **Internals (no user-visible change):**
  - Snapshot capture extracted from `AppDelegate.swift` into its own `Snapshot.swift` (1,279 → 1,095 lines in AppDelegate).
  - Single `VERSION` file now drives the build — no more hardcoded version string in `build.sh`'s Info.plist heredoc.
  - `install.sh` auto-runs `snapshot.sh` after a successful install, so the dev loop is one command (the working tree's `snapshots/` always reflects the just-built UI).
  - `install.sh` legacy bundle/plist cleanup trimmed — old naming schemes from before v0.1.0 are no longer handled.
  - `release.sh` gains a `--publish` mode that does the tag, push, GitHub Release upload, and homebrew-tap commit in one go (with an identity check that refuses to commit the tap as a non-personal email).
  - README gets a release-version badge.

## v0.1.5

Burn-rate fix, threshold notifications, source split (`src/core/` + `src/mac/`).

## v0.1.4

Clamp status item width to "all three on" max — prevents jumpy menubar width when widgets toggle.

## v0.1.3

Diagnostic logging + better authFailed UX.

## v0.1.2

Drop dishonest `0m` at window reset.

## v0.1.1

Auto-detect macOS Keychain credentials.

## v0.1.0

Initial release.
