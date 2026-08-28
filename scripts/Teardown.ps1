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
    # Defaults to project_id from terraform/terraform.tfvars. Only needed if
    # that file is absent or you are cleaning up a different project.
    [string]$ProjectId,
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

# The project MUST be passed explicitly. Without --project, gcloud falls back to
# the active config, which is very often a different project entirely - and the
# check then reports "clean" no matter what is orphaned here. `terraform output`
# is not usable at this point because the destroy has already cleared it, so the
# project is read from tfvars.
if (-not $ProjectId) {
    $tfvars = Join-Path $TerraformDir 'terraform.tfvars'
    if (Test-Path $tfvars) {
        $m = Select-String -Path $tfvars -Pattern '^\s*project_id\s*=\s*"([^"]+)"'
        if ($m) { $ProjectId = $m.Matches[0].Groups[1].Value }
    }
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "gcloud not on PATH; check for unattached disks manually." -ForegroundColor Yellow
}
elseif (-not $ProjectId) {
    Write-Host "Could not determine the project id, so the orphaned-disk check was SKIPPED." -ForegroundColor Yellow
    Write-Host "Re-run with -ProjectId <id>, or check manually:" -ForegroundColor Yellow
    Write-Host '  gcloud compute disks list --project <id> --filter="-users:*"'
}
else {
    # 2>$null suppresses the "filter keys not present in any resource" warning
    # gcloud emits when the project has no disks at all.
    $orphans = @(gcloud compute disks list --project $ProjectId --filter="-users:*" --format="value(name,sizeGb,zone)" 2>$null |
                 Where-Object { $_ -and $_.Trim() })

    if ($orphans.Count -eq 0) {
        Write-Host "No unattached disks in $ProjectId - nothing left billing." -ForegroundColor Green
    } else {
        Write-Host "$($orphans.Count) unattached disk(s) in ${ProjectId} - THESE ARE STILL BILLING:" -ForegroundColor Red
        $orphans | ForEach-Object { Write-Host "  $_" }
        Write-Host "Delete each with:" -ForegroundColor Yellow
        Write-Host "  gcloud compute disks delete DISK_NAME --project $ProjectId --zone ZONE"
    }
}

Write-Host ""
Write-Host "Teardown complete." -ForegroundColor Green
