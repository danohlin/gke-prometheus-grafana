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
    http_request_duration_seconds{method,path,status} histogram. podinfo
    normalizes the path label to route names, so /delay/1 appears as `delay`.

    COMPATIBILITY: runs on both Windows PowerShell 5.1 and PowerShell 7+.
    It deliberately uses .NET HttpClient rather than Invoke-WebRequest, because
    -SkipHttpErrorCheck and ForEach-Object -Parallel are PowerShell 7 only. As a
    bonus, HttpClient does not treat 5xx as an exception, which is exactly what
    -Errors mode needs.

.EXAMPLE
    ./Generate-Load.ps1
    Baseline traffic for 120s.

.EXAMPLE
    ./Generate-Load.ps1 -Latency -Duration 180
    Baseline plus /delay calls; watch p95 and p99 climb.

.EXAMPLE
    ./Generate-Load.ps1 -Errors
    A large share of requests return 500/503; watch the error-ratio panel go red.

.EXAMPLE
    ./Generate-Load.ps1 -Panic
    Kills one pod. Expect a restart and, after repeated crashes, KubePodCrashLooping.
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

# System.Net.Http is a separate assembly on .NET Framework (5.1) but built in on
# .NET (7+), where Add-Type would fail.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Add-Type -AssemblyName System.Net.Http
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl not found on PATH."
}

# Surface a real failure early instead of blaming it on readiness later.
$svc = kubectl get svc $ServiceName -n $Namespace --ignore-not-found 2>&1
if (-not $svc) {
    throw "svc/$ServiceName not found in namespace '$Namespace'. Run ./Deploy-Podinfo.ps1 first."
}

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(15)

Write-Host "==> Port-forwarding svc/$ServiceName ($Namespace) to localhost:$Port" -ForegroundColor Cyan

$pf = Start-Process -FilePath 'kubectl' `
    -ArgumentList @('port-forward', "svc/$ServiceName", "${Port}:$Port", '-n', $Namespace) `
    -PassThru -WindowStyle Hidden

try {
    # -----------------------------------------------------------------------
    # Readiness. Records the last failure so a genuine problem is reported
    # rather than swallowed into a generic "not reachable".
    # -----------------------------------------------------------------------
    $ready    = $false
    $lastErr  = $null
    foreach ($attempt in 1..30) {
        Start-Sleep -Milliseconds 500
        if ($pf.HasExited) {
            throw "kubectl port-forward exited immediately (code $($pf.ExitCode)). Is port $Port already in use?"
        }
        try {
            $resp = $client.GetAsync("$BaseUrl/healthz").GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            $resp.Dispose()
            if ($code -eq 200) { $ready = $true; break }
            $lastErr = "HTTP $code from /healthz"
        } catch {
            $lastErr = $_.Exception.GetBaseException().Message
        }
    }
    if (-not $ready) {
        throw "podinfo did not become reachable on $BaseUrl after 15s. Last error: $lastErr"
    }
    Write-Host "    ready" -ForegroundColor DarkGray

    # -----------------------------------------------------------------------
    # -Panic is a one-shot action, not a load pattern.
    # -----------------------------------------------------------------------
    if ($Panic) {
        Write-Host "==> Sending /panic (expect the connection to drop - that is the point)" -ForegroundColor Yellow
        try {
            $r = $client.GetAsync("$BaseUrl/panic").GetAwaiter().GetResult()
            $r.Dispose()
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
    # Request mix.
    # -----------------------------------------------------------------------
    $paths = @('/')
    if ($Latency) {
        # Slow calls stay a visible minority, which is what a real latency
        # regression looks like on a percentile chart.
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
    $failed   = 0
    $byStatus = @{}
    $lastTick = Get-Date
    $rand     = New-Object System.Random

    while ((Get-Date) -lt $deadline) {
        # Fire a batch concurrently via tasks - portable across 5.1 and 7,
        # unlike ForEach-Object -Parallel.
        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        for ($i = 0; $i -lt $Concurrency; $i++) {
            $p = $paths[$rand.Next(0, $paths.Count)]
            $tasks.Add($client.GetAsync("$BaseUrl$p"))
        }

        [void][System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), 20000)

        foreach ($t in $tasks) {
            if ($t.Status -eq 'RanToCompletion') {
                $code = [int]$t.Result.StatusCode
                if ($byStatus.ContainsKey($code)) { $byStatus[$code]++ } else { $byStatus[$code] = 1 }
                $t.Result.Dispose()
                $sent++
            } else {
                $failed++
            }
        }

        if (((Get-Date) - $lastTick).TotalSeconds -ge 10) {
            $remaining = [int]((New-TimeSpan -Start (Get-Date) -End $deadline).TotalSeconds)
            Write-Host "    $sent requests sent, ${remaining}s remaining" -ForegroundColor DarkGray
            $lastTick = Get-Date
        }
    }

    Write-Host ""
    Write-Host "Done - $sent requests completed." -ForegroundColor Green
    foreach ($k in ($byStatus.Keys | Sort-Object)) {
        Write-Host ("    HTTP {0}  {1,6}" -f $k, $byStatus[$k]) -ForegroundColor DarkGray
    }
    if ($failed -gt 0) {
        Write-Host "    $failed request(s) did not complete (timeout or connection reset)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Open the 'podinfo / RED' dashboard in Grafana:" -ForegroundColor Green
    Write-Host "  ./Connect-Grafana.ps1"
    Write-Host ""
    Write-Host "Allow ~15-30s for the next scrape plus the rate() window to fill in." -ForegroundColor DarkGray
}
finally {
    if ($client) { $client.Dispose() }
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
        Write-Host "==> Port-forward closed" -ForegroundColor DarkGray
    }
}
