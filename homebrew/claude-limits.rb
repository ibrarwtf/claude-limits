cask "claude-limits" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/ibrarwtf/claude-limits/releases/download/v#{version}/claude-limits-#{version}.zip"
  name "claude-limits"
  desc "Native macOS menu-bar app showing your Anthropic usage at a glance"
  homepage "https://github.com/ibrarwtf/claude-limits"

  app "claude-limits.app"

  postflight do
    # Strip Gatekeeper's quarantine flag — we're ad-hoc signed, not notarized,
    # so without this users would see "unidentified developer" on first launch.
    # Standard pattern in homebrew-cask for indie macOS apps.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine",
                          "#{appdir}/claude-limits.app"]

    # Launch the app immediately so first-run logic kicks in: writes the
    # LaunchAgent plist (autostart on next login) + opens the Settings window
    # so the user picks a token source straight away.
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/claude-limits.app"]
  end

  uninstall quit:      "claude-limits",
            launchctl: "claude-limits"

  zap trash: [
    "~/Library/LaunchAgents/claude-limits.plist",
    "~/Library/Preferences/claude-limits.plist",
    "~/Library/Application Support/claude-limits",
  ]
end
