# Ship a release of both apps. Maintainer-only; runs on any machine with git,
# gh and PowerShell — no Mac needed (CI builds the Mac app).
#
#   powershell -File scripts\release.ps1 0.3.1
#
# 1. Checks you're on a clean, up-to-date main with a "## v<VERSION>" section
#    in CHANGELOG.md (it becomes the release notes).
# 2. Bumps VERSION, commits "v<VERSION>", tags, pushes.
# 3. Waits for .github/workflows/release.yml to build both zips into a DRAFT
#    release.
# 4. Points macos/homebrew/claude-limits.rb at the Mac zip (version + sha256),
#    commits + pushes it, and copies it into the tap clone (TAP_DIR, default
#    ..\homebrew-lab next to this repo; cloned if missing).
# 5. Publishes the draft as the latest release. Only now do the Mac app (via
#    brew) and the Windows app (via self-update) see the new version.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "version must be semver like 0.3.1 (got '$Version')" }
$Tag = "v$Version"
$Root = Split-Path -Parent $PSScriptRoot
$Repo = 'ibrarwtf/claude-limits'
$TapDir = if ($env:TAP_DIR) { $env:TAP_DIR } else { Join-Path (Split-Path -Parent $Root) 'homebrew-lab' }
$Cask = Join-Path $Root 'macos\homebrew\claude-limits.rb'

# Native tools write progress to stderr; under Stop, PowerShell 5.1 would turn
# that into a terminating error. Check exit codes explicitly instead.
function Run([string]$exe) {
    $ErrorActionPreference = 'Continue'
    & $exe @args
    if ($LASTEXITCODE -ne 0) { throw "$exe $($args -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-RepoGit { Run git -C $Root @args }

function Assert-PersonalIdentity([string]$dir) {
    $email = git -C $dir config user.email
    if ($email -notlike '*ibrarwtf*' -and $email -notlike '*@users.noreply.github.com') {
        throw "$dir commits as <$email> — set: git -C `"$dir`" config user.email ibrarwtf@users.noreply.github.com"
    }
}

# ── 1. Preflight ─────────────────────────────────────────────────────────────
Assert-PersonalIdentity $Root
if ((git -C $Root rev-parse --abbrev-ref HEAD) -ne 'main') { throw 'release from main' }
if (git -C $Root status --porcelain) { throw 'working tree not clean' }
Invoke-RepoGit fetch -q origin main
if ((git -C $Root rev-parse HEAD) -ne (git -C $Root rev-parse origin/main)) { throw 'main is not in sync with origin/main' }
if (-not (Select-String -Path (Join-Path $Root 'CHANGELOG.md') -Pattern "^## $([regex]::Escape($Tag))$" -Quiet)) {
    throw "CHANGELOG.md has no '## $Tag' section — write the release notes first"
}

# ── 2. Bump, tag, push ───────────────────────────────────────────────────────
[IO.File]::WriteAllText((Join-Path $Root 'VERSION'), "$Version`n")
Invoke-RepoGit add VERSION
Invoke-RepoGit commit -q -m $Tag
Invoke-RepoGit tag -f $Tag
Invoke-RepoGit push -q origin main
Invoke-RepoGit push -q --force origin $Tag
Write-Host "→ Pushed $Tag; waiting for the Release workflow…"

# ── 3. Wait for CI to build the draft ────────────────────────────────────────
$runId = $null
for ($i = 0; $i -lt 60 -and -not $runId; $i++) {
    Start-Sleep -Seconds 5
    $runId = gh run list --repo $Repo --workflow release.yml --branch $Tag --limit 1 --json databaseId --jq '.[0].databaseId'
}
if (-not $runId) { throw "Release workflow didn't start for $Tag" }
Run gh run watch $runId --repo $Repo --exit-status --interval 15

# ── 4. Homebrew cask ─────────────────────────────────────────────────────────
$tmp = Join-Path ([IO.Path]::GetTempPath()) "claude-limits-release-$Version"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Run gh release download $Tag --repo $Repo --pattern "claude-limits-macos-$Version.zip" --dir $tmp
$sha = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp "claude-limits-macos-$Version.zip")).Hash.ToLower()
Write-Host "→ Mac zip sha256: $sha"

$c = [IO.File]::ReadAllText($Cask)
$c = $c -replace '(?m)^  version ".*"', "  version `"$Version`"" -replace '(?m)^  sha256 ".*"', "  sha256 `"$sha`""
[IO.File]::WriteAllText($Cask, $c)
Invoke-RepoGit add $Cask
Invoke-RepoGit commit -q -m "claude-limits $Version cask"
Invoke-RepoGit push -q origin main

if (-not (Test-Path (Join-Path $TapDir '.git'))) { Run gh repo clone ibrarwtf/homebrew-lab $TapDir }
Assert-PersonalIdentity $TapDir
Run git -C $TapDir pull -q --ff-only
Copy-Item $Cask (Join-Path $TapDir 'Casks\claude-limits.rb') -Force
Run git -C $TapDir add Casks/claude-limits.rb
git -C $TapDir diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Run git -C $TapDir commit -q -m "claude-limits $Version"
    Run git -C $TapDir push -q
} else {
    Write-Host '  (tap already up to date)'
}

# ── 5. Publish ───────────────────────────────────────────────────────────────
Run gh release edit $Tag --repo $Repo --draft=false --latest
Remove-Item -Recurse -Force $tmp

Write-Host ''
Write-Host "✓ Published $Tag."
Write-Host "  Release: https://github.com/$Repo/releases/tag/$Tag"
Write-Host '  Mac:     brew upgrade --cask claude-limits (or Settings → Update)'
Write-Host '  Windows: Settings → Update'
