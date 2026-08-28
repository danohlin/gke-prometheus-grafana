<#
.SYNOPSIS
    Opens the Hubble UI service map, deploying it first if it is not present.

.DESCRIPTION
    Hubble gives the live topology view that Grafana cannot: an eBPF-derived map
    of flows actually observed between pods and services, plus NetworkPolicy
    verdicts. It works because the cluster runs Cilium by virtue of Dataplane V2
    (datapath_provider = ADVANCED_DATAPATH in terraform/cluster.tf).

    GKE provisions ONLY hubble-relay when
    advanced_datapath_observability_config.enable_relay is true. There is no
    managed hubble-ui, so this script applies manifests/hubble-ui.yaml on first
    run and then port-forwards it.

    Use -Cli for the terminal equivalent, which needs nothing deployed at all.

.EXAMPLE
    ./scripts/Connect-Hubble.ps1
    Deploys the UI if needed, then opens http://localhost:16100

.EXAMPLE
    ./scripts/Connect-Hubble.ps1 -Cli
    Prints relay status and streams live flows in the terminal.

.EXAMPLE
    ./scripts/Connect-Hubble.ps1 -Cli -Namespace demo
    Streams only flows involving the demo namespace.
#>
[CmdletBinding()]
param(
    [int]$Port       = 16100,
    [string]$Namespace,
    [switch]$Cli,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$HubbleNs = 'gke-managed-dpv2-observability'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $RepoRoot 'manifests/hubble-ui.yaml'

# ---------------------------------------------------------------------------
# The namespace only exists once flow observability is enabled. Fail with the
# fix rather than a bare NotFound.
# ---------------------------------------------------------------------------
kubectl get namespace $HubbleNs *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Namespace '$HubbleNs' not found. Flow observability is off - set enable_hubble_relay = true in terraform.tfvars and re-apply."
}

# ---------------------------------------------------------------------------
# CLI mode: nothing to deploy, the relay pod carries a hubble-cli container
# with TLS already wired up.
# ---------------------------------------------------------------------------
if ($Cli) {
    Write-Host "==> Relay status" -ForegroundColor Cyan
    kubectl exec -n $HubbleNs deployment/hubble-relay -c hubble-cli -- hubble status
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "NOT_SERVING is normal for a few minutes after enabling: turning on flow" -ForegroundColor Yellow
        Write-Host "observability recreates the anetd pods, and the relay retries them every 30s." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "==> Live flows (Ctrl+C to stop)" -ForegroundColor Cyan
    # NOT $args - that is a PowerShell automatic variable and assigning to it
    # is asking for trouble even where it happens to work.
    $hubbleArgs = @('observe', '--follow')
    if ($Namespace) { $hubbleArgs += @('--namespace', $Namespace) }
    kubectl exec -n $HubbleNs deployment/hubble-relay -c hubble-cli -- hubble @hubbleArgs
    return
}

# ---------------------------------------------------------------------------
# UI mode: deploy on first run, then port-forward.
# ---------------------------------------------------------------------------
kubectl -n $HubbleNs get deploy hubble-ui *> $null
if ($LASTEXITCODE -ne 0) {
    if (-not (Test-Path $Manifest)) { throw "Missing manifest: $Manifest" }
    Write-Host "==> hubble-ui not deployed; applying $Manifest" -ForegroundColor Cyan
    kubectl apply -f $Manifest
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply the Hubble UI manifest." }
    kubectl -n $HubbleNs rollout status deploy/hubble-ui --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw "hubble-ui did not become ready." }
}

Write-Host "==> Port-forwarding svc/hubble-ui to localhost:$Port" -ForegroundColor Cyan
$pf = Start-Process -FilePath 'kubectl' `
    -ArgumentList @('port-forward', 'svc/hubble-ui', "${Port}:80", '-n', $HubbleNs) `
    -PassThru -WindowStyle Hidden

try {
    $ready = $false
    foreach ($i in 1..40) {
        Start-Sleep -Milliseconds 700
        if ($pf.HasExited) { throw "kubectl port-forward exited. Is port $Port already in use?" }
        try {
            $r = Invoke-WebRequest "http://localhost:$Port/" -TimeoutSec 3 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) { throw "Hubble UI did not respond on http://localhost:$Port" }

    Write-Host ""
    Write-Host "  Hubble UI   http://localhost:$Port" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Pick a namespace top-left - the map is built from observed flows," -ForegroundColor DarkGray
    Write-Host "  so a service with no recent traffic will not appear. Generate some:" -ForegroundColor DarkGray
    Write-Host "    ./scripts/Generate-Load.ps1 -Latency" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Ctrl+C to stop." -ForegroundColor Yellow

    if (-not $NoBrowser) { Start-Process "http://localhost:$Port" }

    while ($true) {
        Start-Sleep -Seconds 1
        if ($pf.HasExited) { throw "Port-forward exited unexpectedly." }
    }
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "==> Port-forward closed" -ForegroundColor DarkGray
}
