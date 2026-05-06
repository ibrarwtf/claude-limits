# Contributing

PRs welcome. Keep them small, focused, and dependency-free.

## What's in scope

- Bug fixes — incorrect math, layout glitches, edge cases in API parsing, etc.
- Performance and battery improvements.
- Polish to the menu-bar widget, the dropdown, the Settings window.
- Better diagnostics or error UX.
- More token sources that fit the existing three-mode pattern.

## What's out of scope

- New dependencies (Swift packages, frameworks). Every dependency is a liability for a single-binary app.
- Major UI rewrites without prior agreement. Open an issue to talk first.

## Not in focus right now (but open if you want to build it)

- **Cross-platform ports.** `src/core/` is Foundation-only on purpose. If you want to add a `win/` (or `linux/`, etc.) sibling alongside `src/mac/` that reuses the same core, go for it — open an issue first so we can coordinate the layout.
- **Telemetry or analytics.** Not needed at the current user base. Reconsider later if it ever becomes hard to debug what's happening for users.

## Sending a pull request

1. Set up the local build — see [DEVELOPMENT.md](DEVELOPMENT.md).
2. Fork, branch off `main`, make your change. One PR per concern.
3. Verify it visually in your menu bar (`bash scripts/install.sh`). There is no automated test suite.
4. If your change affects rendering, attach a before/after screenshot. `bash scripts/snapshot.sh --auto-all` produces PNGs you can drop into the PR.
5. Open the PR with a clear summary: what changed and why.

## Code conventions

Conventions live in [CLAUDE.md](CLAUDE.md). Two things the build itself enforces:

- `src/core/` must not import AppKit or Cocoa — `scripts/build.sh` greps for it and aborts.
- No new dependencies. AppKit + Foundation only.

## Reporting bugs

Open an issue at https://github.com/ibrarwtf/claude-limits/issues with:

- macOS version (`sw_vers`)
- Mac model — Apple Silicon vs Intel
- App version — visible in Settings (right-click the menu bar icon)
- Steps to reproduce
- Relevant lines from `tail /tmp/claude-limits.log`

A screenshot of the menu bar / dropdown helps if it's a layout or rendering bug.
