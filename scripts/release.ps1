# Build, package, and publish a Windows release.
#
# Usage:
#   powershell -File scripts\release.ps1 0.3.0             # build zip, print next steps
#   powershell -File scripts\release.ps1 0.3.0 -Publish    # also: tag, push, GitHub release
#
# What -Publish does that the default doesn't:
#   - git tag v<VERSION> + push tag and main
#   - uploads claude-limits-windows-<VERSION>.zip to the GitHub release for
#     that tag — onto the existing release if release.sh already made one on a
#     Mac, otherwise creates it with --latest=false (see below)
#   - uses release notes from the matching section of CHANGELOG.md if present
#
# Why --latest=false for Windows-only releases: the Mac app's update check reads
# /releases/latest and upgrades via `brew upgrade`. A release with no Mac zip
# (and no cask bump) would show Mac users an update brew can't install. The
# Windows app reads the full release list instead, so it still finds it.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    Write-Error "first argument must be a semver version like 0.3.0 (got '$Version')."
    exit 2
}

$Root = Split-Path -Parent $PSScriptRoot
$Name = 'claude-limits'
$DistDir = Join-Path $Root 'dist'
$ZipName = "$Name-windows-$Version.zip"
$ZipPath = Join-Path $DistDir $ZipName
New-Item -ItemType Directory -Force $DistDir | Out-Null

# ── 1. Bump VERSION file (single source of truth) ────────────────────────────
[IO.File]::WriteAllText((Join-Path $Root 'VERSION'), "$Version`n")
Write-Host "→ VERSION → $Version"

# ── 2. Build (the csproj reads VERSION → bakes it into the exe) ──────────────
& (Join-Path $PSScriptRoot 'build.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── 3. Zip the exe ───────────────────────────────────────────────────────────
Write-Host "→ Zipping → $ZipPath"
if (Test-Path $ZipPath) { Remove-Item $ZipPath }
Compress-Archive -Path (Join-Path $Root "build\win\$Name.exe") -DestinationPath $ZipPath

# ── 4. SHA256 ────────────────────────────────────────────────────────────────
$Sha = (Get-FileHash -Algorithm SHA256 $ZipPath).Hash.ToLower()
$Size = (Get-Item $ZipPath).Length
Write-Host "→ SHA256: $Sha"
Write-Host "→ Size:   $Size bytes"

# ── 5. Resolve release notes (CHANGELOG.md section if present) ───────────────
$NotesFile = [IO.Path]::GetTempFileName()
$notes = @()
$changelog = Join-Path $Root 'CHANGELOG.md'
if (Test-Path $changelog) {
    # Pull the section under "## v<VERSION>" up to (but not including) the next "## " header.
    $found = $false
    foreach ($line in Get-Content $changelog -Encoding UTF8) {
        if ($line -eq "## v$Version") { $found = $true; continue }
        if ($found -and $line -match '^## ') { break }
        if ($found) { $notes += $line }
    }
}
if (-not ($notes -join '').Trim()) { $notes = @("Release $Version") }
[IO.File]::WriteAllLines($NotesFile, $notes, (New-Object Text.UTF8Encoding $false))

# ── 6. Either print next-steps or run them under -Publish ────────────────────
if (-not $Publish) {
    Write-Host @"

Release artifact ready (NOT published — re-run with -Publish to ship).

   File:    $ZipPath
   SHA256:  $Sha

To publish:
  powershell -File scripts\release.ps1 $Version -Publish

"@
    Remove-Item $NotesFile
    exit 0
}

Write-Host ''
Write-Host '→ -Publish: checking git identity'
$email = git -C $Root config user.email
if ($email -notlike '*ibrarwtf*' -and $email -notlike '*@users.noreply.github.com') {
    Write-Error "repo is committing as <$email> — looks like a work identity. Run: git config user.email ibrarwtf@users.noreply.github.com"
    exit 4
}

Write-Host '→ -Publish: tagging + pushing source repo'
git -C $Root add -A
# Allow re-running after a partial failure: skip commit if nothing staged.
git -C $Root diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git -C $Root commit -m "v$Version" }
git -C $Root tag -f "v$Version"
git -C $Root push origin main
# Force-push the tag: `git tag -f` may have moved it (re-ship of the same version).
git -C $Root push --force origin "v$Version"

Write-Host ''
Write-Host '→ -Publish: GitHub release'
# Probe with Stop relaxed: PowerShell 5.1 turns a redirected native stderr
# line ("release not found") into a terminating error under Stop.
$ErrorActionPreference = 'Continue'
gh release view "v$Version" --repo ibrarwtf/claude-limits *> $null
$releaseExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($releaseExists) {
    # Release exists (made by release.sh on a Mac) — add/replace the Windows asset.
    gh release upload "v$Version" $ZipPath --clobber --repo ibrarwtf/claude-limits
} else {
    gh release create "v$Version" $ZipPath --title "v$Version" --notes-file $NotesFile --latest=false --repo ibrarwtf/claude-limits
}
if ($LASTEXITCODE -ne 0) { Remove-Item $NotesFile; exit $LASTEXITCODE }
Remove-Item $NotesFile

Write-Host ''
Write-Host "✓ Published v$Version (Windows)."
Write-Host "  Release: https://github.com/ibrarwtf/claude-limits/releases/tag/v$Version"
Write-Host "  Installed copies pick it up via Settings → Check for updates."
