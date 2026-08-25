<#
.SYNOPSIS
    Creates the monitoring namespace and the Grafana admin Secret.

.DESCRIPTION
    The Helm values reference `admin.existingSecret: grafana-admin` rather than
    setting `adminPassword` inline, because helm/kube-prometheus-stack/values.yaml
    is committed to git. This script generates a random password and puts it in a
    Secret, so the credential exists only in the cluster and in whatever password
    manager you paste it into.

    Safe to re-run: it will NOT silently rotate an existing password unless you
    pass -Force, because rotating it out from under a running Grafana leaves you
    locked out until the pod restarts.

.EXAMPLE
    ./scripts/Bootstrap-Secrets.ps1

.EXAMPLE
    ./scripts/Bootstrap-Secrets.ps1 -Force   # rotate an existing password
#>
[CmdletBinding()]
param(
    [string]$Namespace  = 'monitoring',
    [string]$SecretName = 'grafana-admin',
    [string]$AdminUser  = 'admin',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found on PATH."
    }
}

Assert-Command kubectl

# Fail early with a clear message rather than a wall of kubectl connection errors.
try {
    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    throw "kubectl cannot reach a cluster. Run the get_credentials_command from 'terraform output' first."
}

Write-Host "==> Ensuring namespace '$Namespace' exists" -ForegroundColor Cyan
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Failed to create namespace '$Namespace'." }

# ---------------------------------------------------------------------------
# Refuse to clobber an existing password unless asked. Grafana caches the admin
# credential at boot, so a surprise rotation locks you out until the pod cycles.
# ---------------------------------------------------------------------------
$exists = $false
kubectl get secret $SecretName -n $Namespace *> $null
if ($LASTEXITCODE -eq 0) { $exists = $true }

if ($exists -and -not $Force) {
    Write-Host "Secret '$SecretName' already exists in '$Namespace'. Leaving it alone." -ForegroundColor Yellow
    Write-Host "Retrieve the current password with:" -ForegroundColor Yellow
    Write-Host "  kubectl get secret $SecretName -n $Namespace -o jsonpath='{.data.admin-password}' | " -NoNewline
    Write-Host "%{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }"
    Write-Host "Re-run with -Force to rotate it." -ForegroundColor Yellow
    return
}

# 32 bytes of CSPRNG output, base64'd, with base64 punctuation stripped so the
# value survives shell quoting and URL contexts without escaping.
$rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$password = ([Convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, 28)

Write-Host "==> Applying Secret '$SecretName'" -ForegroundColor Cyan
kubectl create secret generic $SecretName `
    --namespace $Namespace `
    --from-literal=admin-user=$AdminUser `
    --from-literal=admin-password=$password `
    --dry-run=client -o yaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Failed to apply Secret '$SecretName'." }

Write-Host ""
Write-Host "  Grafana admin credentials (shown once - store them now)" -ForegroundColor Green
Write-Host "  ------------------------------------------------------" -ForegroundColor Green
Write-Host "  username: $AdminUser"
Write-Host "  password: $password"
Write-Host ""
Write-Host "  Not written to any file in this repo." -ForegroundColor DarkGray

if ($exists) {
    Write-Host ""
    Write-Host "Password rotated. Restart Grafana to pick it up:" -ForegroundColor Yellow
    Write-Host "  kubectl rollout restart deploy/kube-prometheus-stack-grafana -n $Namespace"
}
