<#
.SYNOPSIS
    Drives traffic at podinfo so the RED dashboard shows something worth looking at.

.DESCRIPTION
    Opens its own port-forward, generates load, then tears the port-forward down.
    podinfo exposes endpoints built for manufacturing signal:

      /            steady baseline traffic
      /delay/N     sleeps N seconds  -> moves the latency quantiles
      /status/NNN  returns that code -> moves the error ratio
      /panic       crashes the process -> pod restart, KubePodCrashLooping

    Metrics land as http_requests_total{status} and the
    http_request_duration_seconds{method,path,status} histogram.

.EXAMPLE
    ./scripts/Generate-Load.ps1
    Baseline traffic for 120s.

.EXAMPLE
    ./scripts/Generate-Load.ps1 -Latency -Duration 180
    Baseline plus /delay/1 calls; watch p95 and p99 climb.

.EXAMPLE
    ./scripts/Generate-Load.ps1 -Errors
    Roughly 20% of requests return 500; watch the error-ratio panel go red.

.EXAMPLE
    ./scripts/Generate-Load.ps1 -Panic
    Kills one pod. Expect a restart and, after ~15m, KubePodCrashLooping.
#>
[CmdletBinding()]
param(
    [string]$Namespace   = 'demo',
    [string]$ServiceName = 'podinfo',
    [int]$Port           = 9898,
    [int]$Duration       = 120,
    [int]$Concurrency    = 8,
    [switch]$Latency,
    [switch]$Errors,
    [switch]$Panic
)

$ErrorActionPreference = 'Stop'
$BaseUrl = "http://localhost:$Port"

# ---------------------------------------------------------------------------
# Port-forward, owned by this script so it always gets cleaned up.
# ---------------------------------------------------------------------------
Write-Host "==> Port-forwarding svc/$ServiceName ($Namespace) to localhost:$Port" -ForegroundColor Cyan

$pf = Start-Process -FilePath 'kubectl' `
    -ArgumentList @('port-forward', "svc/$ServiceName", "${Port}:$Port", '-n', $Namespace) `
    -PassThru -WindowStyle Hidden

try {
    # Poll for readiness rather than sleeping a fixed guess.
    $ready = $false
    foreach ($attempt in 1..30) {
        Start-Sleep -Milliseconds 500
        if ($pf.HasExited) { throw "kubectl port-forward exited immediately. Is $ServiceName running in '$Namespace'?" }
        try {
            $r = Invoke-WebRequest -Uri "$BaseUrl/healthz" -TimeoutSec 2 -SkipHttpErrorCheck -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) { throw "podinfo did not become reachable on $BaseUrl" }
    Write-Host "    ready" -ForegroundColor DarkGray

    # -----------------------------------------------------------------------
    # -Panic is a one-shot action, not a load pattern.
    # -----------------------------------------------------------------------
    if ($Panic) {
        Write-Host "==> Sending /panic (expect the connection to drop - that is the point)" -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri "$BaseUrl/panic" -TimeoutSec 5 -SkipHttpErrorCheck | Out-Null
        } catch {
            Write-Host "    connection dropped as expected" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
        Write-Host ""
        kubectl get pods -n $Namespace
        Write-Host ""
        Write-Host "Watch the restart land on the 'Ready pods and restarts' panel." -ForegroundColor Green
        Write-Host "KubePodCrashLooping needs repeated crashes over ~15m to fire." -ForegroundColor DarkGray
        return
    }

    # -----------------------------------------------------------------------
    # Build the request mix.
    # -----------------------------------------------------------------------
    $paths = @('/')
    if ($Latency) {
        # Weighted so slow calls are a visible minority, which is what a real
        # latency regression looks like on a percentile chart.
        $paths += @('/delay/1', '/delay/1', '/delay/2')
    }
    if ($Errors) {
        $paths += @('/status/500', '/status/503')
    }

    $mix = ($paths | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    Write-Host "==> Load for ${Duration}s, concurrency $Concurrency" -ForegroundColor Cyan
    Write-Host "    mix: $mix" -ForegroundColor DarkGray

    $deadline = (Get-Date).AddSeconds($Duration)
    $sent     = 0
    $lastTick = Get-Date

    while ((Get-Date) -lt $deadline) {
        1..$Concurrency | ForEach-Object -Parallel {
            $p = Get-Random -InputObject $using:paths
            try {
                Invoke-WebRequest -Uri "$using:BaseUrl$p" -TimeoutSec 10 -SkipHttpErrorCheck | Out-Null
            } catch { }
        } -ThrottleLimit $Concurrency

        $sent += $Concurrency

        if (((Get-Date) - $lastTick).TotalSeconds -ge 10) {
            $remaining = [int]($deadline - (Get-Date)).TotalSeconds
            Write-Host "    $sent requests sent, ${remaining}s remaining" -ForegroundColor DarkGray
            $lastTick = Get-Date
        }
    }

    Write-Host ""
    Write-Host "Done - $sent requests sent." -ForegroundColor Green
    Write-Host "Open the 'podinfo / RED' dashboard in Grafana:" -ForegroundColor Green
    Write-Host "  ./scripts/Connect-Grafana.ps1"
    Write-Host ""
    Write-Host "Allow ~15-30s for the next scrape plus rate() window to fill in." -ForegroundColor DarkGray
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
        Write-Host "==> Port-forward closed" -ForegroundColor DarkGray
    }
}
