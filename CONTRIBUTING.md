# Contributing

PRs welcome. Keep them small, focused, and dependency-free.

## What's in scope

- Bug fixes — incorrect math, layout glitches, edge cases in API parsing, etc.
- Performance and battery improvements.
- Polish to the menu-bar / taskbar widget, the dropdown, the Settings window — on either platform.
- Better diagnostics or error UX.
- More token sources that fit the existing three-mode pattern.

## What's out of scope

- New dependencies (Swift packages, NuGet packages, frameworks). Every dependency is a liability for a single-binary app.
- Major UI rewrites without prior agreement. Open an issue to talk first.

## Not in focus right now (but open if you want to build it)

- **A Linux port.** Would sit alongside `macos/` and `windows/`, run `spec/cases.json`, and render the fixture in CI. Open an issue first so we can coordinate.
- **Telemetry or analytics.** Not needed at the current user base.

## Sending a pull request

1. Set up the local build for your OS — see [DEVELOPMENT.md](DEVELOPMENT.md). You don't need the other OS: CI builds and tests both.
2. Fork, branch off `main`, make your change. One PR per concern.
3. If you changed shared behaviour (formatting, burn rate, weekly rows, rollover, token parsing), update `spec/cases.json` and make both apps pass it — or say in the PR which side you couldn't change.
4. Push. CI builds both apps, runs the spec, and re-renders `snapshots/`. On branches in this repo it commits changed PNGs to your PR; on forks they're attached to the CI run as artifacts — drop them in the PR description if your change is visible.
5. Open the PR with a clear summary: what changed and why.

## Code conventions

Conventions live in [CLAUDE.md](CLAUDE.md). Things the build enforces:

- `macos/core/` must not import AppKit or Cocoa, and `windows/core/` must not reference WPF/WinForms — the build scripts grep for it and abort.
- No new dependencies: AppKit + Foundation on macOS; in-box .NET Framework 4.8 assemblies on Windows.
- `spec/cases.json` must pass on both apps.

## Reporting bugs

Open an issue at https://github.com/ibrarwtf/claude-limits/issues with:

- OS version (`sw_vers` on macOS, `winver` on Windows) — and Apple Silicon vs Intel on a Mac
- App version — visible in Settings
- Steps to reproduce
- Relevant lines from `/tmp/claude-limits.log` (macOS) or `%TEMP%\claude-limits.log` (Windows)

A screenshot of the widget / dropdown helps if it's a layout or rendering bug.
