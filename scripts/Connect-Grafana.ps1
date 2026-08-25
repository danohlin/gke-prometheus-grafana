<#
.SYNOPSIS
    Port-forwards Grafana (and optionally Prometheus / Alertmanager) to localhost.

.DESCRIPTION
    Grafana is deployed with service.type=ClusterIP and no Ingress, so this is
    the only way in. Nothing is exposed publicly and there is no certificate to
    manage.

.EXAMPLE
    ./scripts/Connect-Grafana.ps1
    Grafana on http://localhost:3000

.EXAMPLE
    ./scripts/Connect-Grafana.ps1 -All
    Grafana 3000, Prometheus 9090, Alertmanager 9093, all at once.

.EXAMPLE
    ./scripts/Connect-Grafana.ps1 -Prometheus
    Prometheus only, on http://localhost:9090
#>
[CmdletBinding()]
param(
    [string]$Namespace   = 'monitoring',
    [string]$ReleaseName = 'kube-prometheus-stack',
    [switch]$Prometheus,
    [switch]$Alertmanager,
    [switch]$All,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

# svc/<release>-grafana listens on 80; the operator-managed Prometheus and
# Alertmanager services listen on 9090 and 9093.
$targets = @()
if ($All -or (-not $Prometheus -and -not $Alertmanager)) {
    $targets += [pscustomobject]@{ Name = 'Grafana';      Service = "svc/$ReleaseName-grafana";      Local = 3000; Remote = 80 }
}
if ($All -or $Prometheus) {
    $targets += [pscustomobject]@{ Name = 'Prometheus';   Service = "svc/$ReleaseName-prometheus";   Local = 9090; Remote = 9090 }
}
if ($All -or $Alertmanager) {
    $targets += [pscustomobject]@{ Name = 'Alertmanager'; Service = "svc/$ReleaseName-alertmanager"; Local = 9093; Remote = 9093 }
}

$procs = @()

try {
    foreach ($t in $targets) {
        kubectl get $t.Service -n $Namespace *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "!! $($t.Service) not found in '$Namespace' - skipping" -ForegroundColor Yellow
            continue
        }

        $p = Start-Process -FilePath 'kubectl' `
            -ArgumentList @('port-forward', $t.Service, "$($t.Local):$($t.Remote)", '-n', $Namespace) `
            -PassThru -WindowStyle Hidden
        $procs += $p

        Write-Host ("{0,-13} http://localhost:{1}" -f $t.Name, $t.Local) -ForegroundColor Green
    }

    if ($procs.Count -eq 0) { throw "Nothing to forward. Is the stack installed?" }

    Start-Sleep -Seconds 2

    if (-not $NoBrowser -and ($targets | Where-Object Name -eq 'Grafana')) {
        Start-Process 'http://localhost:3000'
    }

    Write-Host ""
    Write-Host "Grafana login: username 'admin'. Recover the password with:" -ForegroundColor DarkGray
    Write-Host "  kubectl get secret grafana-admin -n $Namespace -o jsonpath='{.data.admin-password}' | %{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Ctrl+C to stop." -ForegroundColor Yellow

    # Hold the foreground until interrupted; finally{} does the cleanup.
    while ($true) {
        Start-Sleep -Seconds 1
        foreach ($p in $procs) {
            if ($p.HasExited) { throw "A port-forward exited unexpectedly (exit $($p.ExitCode))." }
        }
    }
}
finally {
    foreach ($p in $procs) {
        if ($p -and -not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host ""
    Write-Host "==> Port-forwards closed" -ForegroundColor DarkGray
}
