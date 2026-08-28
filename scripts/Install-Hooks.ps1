<#
.SYNOPSIS
    Points git at the committed hooks in .githooks and reports scanner status.

.DESCRIPTION
    Git does not version .git/hooks, so hooks committed to a repo do nothing
    until core.hooksPath is set. This is a per-clone setting, so anyone cloning
    this repo needs to run it once - which is exactly why the hooks live in a
    tracked directory rather than being copied into .git/hooks by hand.

    Installs:
      pre-commit  gitleaks over staged changes, plus an identifier review and a
                  dangerous-filename block. Fast enough for every commit.
      pre-push    trufflehog --results=verified over full history. Slower, and
                  answers the question that matters at publish time: is any of
                  this actually live.

.EXAMPLE
    ./scripts/Install-Hooks.ps1

.EXAMPLE
    ./scripts/Install-Hooks.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $RepoRoot
try {
    if ($Uninstall) {
        git config --unset core.hooksPath 2>$null
        Write-Host "Hooks disabled (core.hooksPath unset)." -ForegroundColor Yellow
        return
    }

    $hooksDir = Join-Path $RepoRoot '.githooks'
    if (-not (Test-Path $hooksDir)) { throw "Missing hooks directory: $hooksDir" }

    git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) { throw "Failed to set core.hooksPath." }
    Write-Host "==> core.hooksPath = .githooks" -ForegroundColor Cyan

    # Git for Windows runs hooks through sh, but the executable bit still needs
    # recording in the index or they are skipped silently on Linux and macOS.
    # update-index only works on files git already tracks, so skip the ones that
    # are not staged yet rather than failing the whole install.
    foreach ($h in 'pre-commit', 'pre-push') {
        git ls-files --error-unmatch ".githooks/$h" *> $null
        if ($LASTEXITCODE -eq 0) {
            git update-index --chmod=+x ".githooks/$h" *> $null
        }
    }
    $global:LASTEXITCODE = 0

    Write-Host "`n==> Installed hooks" -ForegroundColor Cyan
    Get-ChildItem $hooksDir -File | ForEach-Object { "  $($_.Name)" }

    # -----------------------------------------------------------------------
    # Report scanner availability honestly. A hook whose tool is missing warns
    # loudly rather than passing quietly, but it is better to find out here.
    # -----------------------------------------------------------------------
    Write-Host "`n==> Scanner status" -ForegroundColor Cyan
    $tools = [ordered]@{
        'gitleaks'   = 'pre-commit  - pattern and entropy matching on staged changes'
        'trufflehog' = 'pre-push    - API-verified live credential detection'
    }
    $missing = @()
    foreach ($t in $tools.Keys) {
        $cmd = Get-Command $t -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = (& $t --version 2>&1 | Select-Object -First 1) -replace '^\s+|\s+$', ''
            Write-Host ("  {0,-11} {1,-46} {2}" -f $t, $tools[$t], $ver) -ForegroundColor Green
        } else {
            $missing += $t
            Write-Host ("  {0,-11} {1,-46} NOT INSTALLED" -f $t, $tools[$t]) -ForegroundColor Yellow
        }
    }

    if ($missing -contains 'gitleaks') {
        Write-Host "`n  Install gitleaks:   winget install Gitleaks.Gitleaks" -ForegroundColor Yellow
    }
    if ($missing -contains 'trufflehog') {
        Write-Host "  Install trufflehog: not in winget; download the release binary from" -ForegroundColor Yellow
        Write-Host "                      https://github.com/trufflesecurity/trufflehog/releases" -ForegroundColor Yellow
    }

    Write-Host "`nHooks are active for this clone. Never bypass them with --no-verify:" -ForegroundColor DarkGray
    Write-Host "if a finding is real, rotate the credential - removing it from the diff" -ForegroundColor DarkGray
    Write-Host "does not undo the exposure." -ForegroundColor DarkGray
}
finally { Pop-Location }
