# Changelog

`release.sh --publish` reads the section matching the version being shipped and feeds it to `gh release create --notes-file`. So write each section as user-facing release notes — what changed, why someone running `brew upgrade` would care.

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
