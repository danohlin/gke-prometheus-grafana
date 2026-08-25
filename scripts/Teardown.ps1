<#
.SYNOPSIS
    Destroys the demo, in the order that avoids leaving disks billing.

.DESCRIPTION
    Order is the whole point of this script.

    Helm does NOT delete PersistentVolumeClaims created from a StatefulSet
    volumeClaimTemplate - that is deliberate upstream behaviour so an accidental
    uninstall does not destroy data. The Prometheus, Alertmanager, and Grafana
    volumes therefore survive `helm uninstall`.

    If you then delete the cluster, those PVCs are removed without their
    reclaim logic ever running, and the underlying Compute Engine persistent
    disks are ORPHANED: still provisioned, still billing, attached to nothing,
    invisible in the Kubernetes API because the cluster is gone.

    So: uninstall releases, delete PVCs (which deletes the PDs via the
    standard-rwo Delete reclaim policy), and only then destroy the cluster.
    A final `gcloud compute disks list` proves nothing was left behind.

.EXAMPLE
    ./scripts/Teardown.ps1

.EXAMPLE
    ./scripts/Teardown.ps1 -KeepCluster
    Remove the workloads and their disks but leave the cluster running.
#>
[CmdletBinding()]
param(
    [string]$MonitoringNamespace = 'monitoring',
    [string]$DemoNamespace       = 'demo',
    [switch]$KeepCluster,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot     = Split-Path -Parent $PSScriptRoot
$TerraformDir = Join-Path $RepoRoot 'terraform'

if (-not $Force) {
    Write-Host "This destroys the monitoring stack, podinfo, their persistent disks" -ForegroundColor Yellow
    if (-not $KeepCluster) { Write-Host "AND the GKE cluster and its VPC." -ForegroundColor Yellow }
    $answer = Read-Host "Type 'destroy' to continue"
    if ($answer -ne 'destroy') { Write-Host "Aborted."; return }
}

function Invoke-Step {
    param([string]$Message, [scriptblock]$Action)
    Write-Host "==> $Message" -ForegroundColor Cyan
    try { & $Action } catch { Write-Host "    (non-fatal) $_" -ForegroundColor DarkGray }
}

# --- 1. Releases ------------------------------------------------------------
Invoke-Step "Uninstalling podinfo" {
    helm uninstall podinfo --namespace $DemoNamespace --ignore-not-found 2>&1 | Out-Host
}
Invoke-Step "Uninstalling kube-prometheus-stack" {
    helm uninstall kube-prometheus-stack --namespace $MonitoringNamespace --ignore-not-found 2>&1 | Out-Host
}

# --- 2. PVCs, BEFORE the cluster goes away ----------------------------------
foreach ($ns in @($MonitoringNamespace, $DemoNamespace)) {
    Invoke-Step "Deleting PVCs in '$ns' (Helm leaves StatefulSet PVCs behind)" {
        $pvcs = kubectl get pvc -n $ns -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $pvcs) {
            $pvcs | Out-Host
            kubectl delete pvc --all -n $ns --timeout=120s 2>&1 | Out-Host
        } else {
            Write-Host "    none" -ForegroundColor DarkGray
        }
    }
}

Invoke-Step "Waiting for PersistentVolumes to be released" {
    # Give the CSI driver time to actually delete the backing PDs before the
    # control plane disappears underneath it.
    foreach ($i in 1..20) {
        $remaining = (kubectl get pv -o name 2>$null | Measure-Object).Count
        if ($remaining -eq 0) { Write-Host "    all PVs gone" -ForegroundColor DarkGray; break }
        Start-Sleep -Seconds 3
    }
}

foreach ($ns in @($MonitoringNamespace, $DemoNamespace)) {
    Invoke-Step "Deleting namespace '$ns'" {
        kubectl delete namespace $ns --ignore-not-found --timeout=120s 2>&1 | Out-Host
    }
}

if ($KeepCluster) {
    Write-Host ""
    Write-Host "Cluster left running (-KeepCluster). It still costs money." -ForegroundColor Yellow
    return
}

# --- 3. Infrastructure ------------------------------------------------------
Write-Host "==> terraform destroy" -ForegroundColor Cyan
Push-Location $TerraformDir
try {
    terraform destroy -auto-approve
    if ($LASTEXITCODE -ne 0) {
        throw "terraform destroy failed. If it complains about deletion protection, set deletion_protection = false in terraform.tfvars, re-apply, then retry."
    }
}
finally { Pop-Location }

# --- 4. Prove nothing is still billing --------------------------------------
Write-Host ""
Write-Host "==> Checking for orphaned persistent disks" -ForegroundColor Cyan
if (Get-Command gcloud -ErrorAction SilentlyContinue) {
    gcloud compute disks list --filter="-users:*" --format="table(name,sizeGb,zone,status)"
    Write-Host ""
    Write-Host "Any disk listed above is unattached and still billing - delete it with:" -ForegroundColor Yellow
    Write-Host "  gcloud compute disks delete DISK_NAME --zone ZONE"
} else {
    Write-Host "gcloud not on PATH; check unattached disks manually." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Teardown complete." -ForegroundColor Green
