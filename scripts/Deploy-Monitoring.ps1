<#
.SYNOPSIS
    Installs or upgrades the kube-prometheus-stack release.

.DESCRIPTION
    Ordering here is deliberate:

      1. Add/update the chart repo.
      2. Apply the chart's CRDs with server-side apply.
      3. helm upgrade --install with --skip-crds.

    Step 2 exists because Helm installs CRDs on FIRST INSTALL ONLY and never
    upgrades them. Worse, these CRDs total ~4.4MB with the largest single file
    at ~814KB, so a client-side `kubectl apply` blows the 262144-byte
    last-applied-configuration annotation limit outright. Server-side apply is
    the documented path and is what makes this script idempotent across
    upgrades rather than working once and failing on the second run.

    CRDs are taken from the pulled chart at the pinned version, so they can
    never drift from the release being installed.

.EXAMPLE
    ./scripts/Deploy-Monitoring.ps1
#>
[CmdletBinding()]
param(
    [string]$Namespace   = 'monitoring',
    [string]$ReleaseName = 'kube-prometheus-stack',
    [string]$Timeout     = '15m',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ChartDir   = Join-Path $RepoRoot 'helm/kube-prometheus-stack'
$ValuesFile = Join-Path $ChartDir 'values.yaml'
$VersionFile = Join-Path $ChartDir 'VERSION'

foreach ($f in @($ValuesFile, $VersionFile)) {
    if (-not (Test-Path $f)) { throw "Missing required file: $f" }
}

$ChartVersion = (Get-Content $VersionFile -Raw).Trim()
$RepoName     = 'prometheus-community'
$RepoUrl      = 'https://prometheus-community.github.io/helm-charts'
$Chart        = "$RepoName/kube-prometheus-stack"

Write-Host "==> kube-prometheus-stack $ChartVersion -> namespace '$Namespace'" -ForegroundColor Cyan

# --- Helm 4 check -----------------------------------------------------------
# Helm 4 renamed --atomic to --rollback-on-failure. This script uses the Helm 4
# spelling, so fail loudly on Helm 3 rather than emitting a confusing flag error.
$helmVersion = (helm version --short) -replace '^v', ''
if ($helmVersion -notmatch '^4\.') {
    throw "Helm 4 required (found $helmVersion). Helm 3 is EOL in November 2026 and does not accept --rollback-on-failure."
}

# --- 1. Repo ---------------------------------------------------------------
Write-Host "==> Adding/updating chart repo" -ForegroundColor Cyan
helm repo add $RepoName $RepoUrl --force-update | Out-Null
helm repo update $RepoName | Out-Null

# --- 2. CRDs via server-side apply ------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kps-crds-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    Write-Host "==> Pulling chart $ChartVersion to extract CRDs" -ForegroundColor Cyan
    helm pull $Chart --version $ChartVersion --untar --untardir $tmp
    if ($LASTEXITCODE -ne 0) { throw "helm pull failed." }

    $crdDir = Join-Path $tmp 'kube-prometheus-stack/charts/crds/crds'
    if (-not (Test-Path $crdDir)) { throw "CRD directory not found at $crdDir - chart layout may have changed." }

    $crdCount = (Get-ChildItem $crdDir -Filter '*.yaml').Count
    Write-Host "==> Server-side applying $crdCount CRDs" -ForegroundColor Cyan

    if (-not $DryRun) {
        kubectl apply --server-side --force-conflicts -f $crdDir
        if ($LASTEXITCODE -ne 0) { throw "CRD apply failed." }

        # The operator's webhook rejects CRs before the CRDs are Established.
        Write-Host "==> Waiting for CRDs to become Established" -ForegroundColor Cyan
        kubectl wait --for=condition=Established --timeout=120s `
            crd/prometheuses.monitoring.coreos.com `
            crd/servicemonitors.monitoring.coreos.com `
            crd/prometheusrules.monitoring.coreos.com `
            crd/alertmanagers.monitoring.coreos.com
        if ($LASTEXITCODE -ne 0) { throw "CRDs did not reach Established." }
    }

    # --- 3. Release ---------------------------------------------------------
    $helmArgs = @(
        'upgrade', $ReleaseName, $Chart,
        '--install',
        '--version', $ChartVersion,
        '--namespace', $Namespace,
        '--create-namespace',
        '--values', $ValuesFile,
        # CRDs were applied above; let Helm not fight server-side apply for them.
        '--skip-crds',
        '--wait',
        '--timeout', $Timeout,
        # Helm 4 name for what used to be --atomic.
        '--rollback-on-failure'
    )
    # Helm 4 deprecates bare --dry-run in favour of an explicit strategy.
    if ($DryRun) { $helmArgs += '--dry-run=client' }

    Write-Host "==> helm $($helmArgs -join ' ')" -ForegroundColor Cyan
    helm @helmArgs
    if ($LASTEXITCODE -ne 0) { throw "helm upgrade --install failed." }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($DryRun) { return }

Write-Host ""
Write-Host "==> Release status" -ForegroundColor Cyan
kubectl get pods -n $Namespace
Write-Host ""
kubectl get pvc -n $Namespace

Write-Host ""
Write-Host "Next:" -ForegroundColor Green
Write-Host "  ./scripts/Connect-Grafana.ps1        # Grafana on http://localhost:3000"
Write-Host "  ./scripts/Deploy-Podinfo.ps1         # add the demo workload"
Write-Host ""
Write-Host "If pods are stuck in ImagePullBackOff, Cloud NAT is the cause - the" -ForegroundColor DarkGray
Write-Host "nodes are private and these images come from quay.io / ghcr.io." -ForegroundColor DarkGray
