<#
.SYNOPSIS
    Deploys podinfo (the demo workload) and its Grafana dashboard.

.DESCRIPTION
    Must run AFTER Deploy-Monitoring.ps1. ServiceMonitor is a CRD owned by
    kube-prometheus-stack, so installing podinfo first fails with:
      no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"

    No change to the monitoring release is needed for Prometheus to discover
    podinfo. The stack sets serviceMonitorSelectorNilUsesHelmValues=false, which
    makes its ServiceMonitor selector match every namespace, so the new
    ServiceMonitor is picked up within one scrape interval.

    The RED dashboard is shipped as a ConfigMap labelled grafana_dashboard=1 in
    the same namespace; the Grafana sidecar imports it automatically because the
    stack sets sidecar.dashboards.searchNamespace=ALL.

.EXAMPLE
    ./scripts/Deploy-Podinfo.ps1
#>
[CmdletBinding()]
param(
    [string]$Namespace   = 'demo',
    [string]$ReleaseName = 'podinfo',
    [string]$Timeout     = '5m',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ChartDir    = Join-Path $RepoRoot 'helm/podinfo'
$ValuesFile  = Join-Path $ChartDir 'values.yaml'
$VersionFile = Join-Path $ChartDir 'VERSION'
$Dashboard   = Join-Path $RepoRoot 'dashboards/podinfo-red.json'

foreach ($f in @($ValuesFile, $VersionFile, $Dashboard)) {
    if (-not (Test-Path $f)) { throw "Missing required file: $f" }
}

$ChartVersion = (Get-Content $VersionFile -Raw).Trim()

# Fail with a useful message instead of a raw Helm error if the stack is absent.
kubectl get crd servicemonitors.monitoring.coreos.com *> $null
if ($LASTEXITCODE -ne 0) {
    throw "ServiceMonitor CRD not found. Run ./scripts/Deploy-Monitoring.ps1 first."
}

Write-Host "==> podinfo $ChartVersion -> namespace '$Namespace'" -ForegroundColor Cyan

helm repo add podinfo https://stefanprodan.github.io/podinfo --force-update | Out-Null
helm repo update podinfo | Out-Null

$helmArgs = @(
    'upgrade', $ReleaseName, 'podinfo/podinfo',
    '--install',
    '--version', $ChartVersion,
    '--namespace', $Namespace,
    '--create-namespace',
    '--values', $ValuesFile,
    '--wait',
    '--timeout', $Timeout,
    '--rollback-on-failure'
)
# Helm 4 deprecates bare --dry-run in favour of an explicit strategy.
if ($DryRun) { $helmArgs += '--dry-run=client' }

helm @helmArgs
if ($LASTEXITCODE -ne 0) { throw "podinfo install failed." }

if ($DryRun) { return }

# ---------------------------------------------------------------------------
# Dashboard ConfigMap. Built with --dry-run=client | apply so it is idempotent
# and picks up edits to the JSON on every re-run.
# ---------------------------------------------------------------------------
Write-Host "==> Applying RED dashboard ConfigMap" -ForegroundColor Cyan
kubectl create configmap podinfo-red-dashboard `
    --namespace $Namespace `
    --from-file=podinfo-red.json=$Dashboard `
    --dry-run=client -o yaml |
    kubectl label --local -f - grafana_dashboard=1 -o yaml |
    kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Dashboard ConfigMap apply failed." }

Write-Host ""
kubectl get pods -n $Namespace
Write-Host ""
Write-Host "==> ServiceMonitor" -ForegroundColor Cyan
kubectl get servicemonitor -n $Namespace

Write-Host ""
Write-Host "Verify discovery (no stack redeploy required):" -ForegroundColor Green
Write-Host "  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
Write-Host "  then open http://localhost:9090/targets and look for job 'podinfo'"
Write-Host ""
Write-Host "Then generate some signal:" -ForegroundColor Green
Write-Host "  ./scripts/Generate-Load.ps1 -Latency"
