<#
.SYNOPSIS
  Aligns the AI Runway gateway routing name of every ModelDeployment in a namespace
  with the model name the running server actually serves.

.DESCRIPTION
  For each ModelDeployment the script:
    1. waits for its model pod to be Ready,
    2. port-forwards to the model service and reads the served name from GET /v1/models
       (for the aikit Llama image this is e.g. "llama-3.2-1b-instruct"),
    3. compares it with the model name the HTTPRoute matches on (X-Gateway-Model-Name),
    4. if they differ, sets spec.gateway.modelName on the ModelDeployment so that the
       AI Runway controller updates the HTTPRoute,
    5. waits until the HTTPRoute shows the new name.

  It is idempotent: ModelDeployments that already match are left alone.
  kubectl port-forward does not go through the pod network, so it is not affected by the
  Project's network policies.

.PARAMETER Namespace
  Namespace (Project) that contains the ModelDeployments. Default: llm-demo

.PARAMETER LocalPort
  Local port used for the temporary port-forward. Default: 18080

.PARAMETER PodReadyTimeoutSeconds
  How long to wait for each model pod to become Ready. Default: 180

.PARAMETER DryRun
  Only report what would be changed.

.EXAMPLE
  .\fix-gateway-model-names.ps1
  .\fix-gateway-model-names.ps1 -Namespace llm-demo -DryRun
#>
[CmdletBinding()]
param(
    [string]$Namespace = "llm-demo",
    [int]$LocalPort = 18080,
    [int]$PodReadyTimeoutSeconds = 180,
    [switch]$DryRun
)

# Native commands write to stderr on normal failures; handle exit codes manually.
$ErrorActionPreference = "Continue"

function Get-RoutedName([string]$Name) {
    # The HTTPRoute created by AI Runway has the same name as the ModelDeployment.
    $v = kubectl get httproute $Name -n $Namespace -o "jsonpath={.spec.rules[0].matches[0].headers[0].value}" 2>$null
    return $v
}

$names = (kubectl get modeldeployment -n $Namespace -o "jsonpath={.items[*].metadata.name}") -split "\s+" |
    Where-Object { $_ }

if (-not $names) {
    Write-Host "No ModelDeployments found in namespace '$Namespace'."
    return
}

foreach ($md in $names) {
    Write-Host ""
    Write-Host "== $md ==" -ForegroundColor Cyan

    # 1. Wait for the model pod (label comes from the KAITO StatefulSet pod template)
    kubectl wait --for=condition=Ready pod -l "airunway.ai/model-deployment=$md" -n $Namespace --timeout="${PodReadyTimeoutSeconds}s" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Pod for '$md' is not Ready after ${PodReadyTimeoutSeconds}s - skipping. Check: kubectl get events -n $Namespace --sort-by=.lastTimestamp"
        continue
    }

    # 2. Discover the served model name
    $svc  = kubectl get modeldeployment $md -n $Namespace -o "jsonpath={.status.endpoint.service}" 2>$null
    $port = kubectl get modeldeployment $md -n $Namespace -o "jsonpath={.status.endpoint.port}" 2>$null
    if (-not $svc)  { $svc  = $md }
    if (-not $port) { $port = 80 }

    $served = $null
    $pf = Start-Process -FilePath "kubectl" `
        -ArgumentList @("port-forward", "svc/$svc", "${LocalPort}:${port}", "-n", $Namespace) `
        -PassThru -WindowStyle Hidden
    try {
        for ($i = 0; $i -lt 20 -and -not $served; $i++) {
            Start-Sleep -Seconds 1
            try {
                $r = Invoke-RestMethod -Uri "http://localhost:$LocalPort/v1/models" -TimeoutSec 3
                if ($r.data.Count -gt 1) {
                    Write-Warning "Server reports $($r.data.Count) models; using the first one."
                }
                $served = $r.data[0].id
            } catch { }
        }
    }
    finally {
        if ($pf -and -not $pf.HasExited) { Stop-Process -Id $pf.Id -Force }
    }

    if (-not $served) {
        Write-Warning "Could not read /v1/models from svc/$svc - skipping."
        continue
    }

    # 3. Compare with what the gateway routes on
    $routed  = Get-RoutedName $md
    $current = kubectl get modeldeployment $md -n $Namespace -o "jsonpath={.spec.gateway.modelName}" 2>$null

    Write-Host "  served by model server : $served"
    Write-Host "  matched by HTTPRoute   : $routed"
    Write-Host "  spec.gateway.modelName : $(if ($current) { $current } else { '(not set)' })"

    if ($routed -eq $served) {
        Write-Host "  OK - already aligned." -ForegroundColor Green
        continue
    }

    if ($DryRun) {
        Write-Host "  DRY RUN - would set spec.gateway.modelName = $served" -ForegroundColor Yellow
        continue
    }

    # 4. Patch the ModelDeployment
    $patch = @{ spec = @{ gateway = @{ modelName = $served } } } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $patch -Encoding ascii
        kubectl patch modeldeployment $md -n $Namespace --type merge --patch-file $tmp
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Patch was rejected (field may be immutable). Recreate the ModelDeployment with gateway.modelName set, or try spec.model.servedName."
            continue
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    # 5. Wait for the controller to update the HTTPRoute
    $ok = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-RoutedName $md) -eq $served) { $ok = $true; break }
    }
    if ($ok) {
        Write-Host "  FIXED - HTTPRoute now matches '$served'." -ForegroundColor Green
    } else {
        Write-Warning "HTTPRoute still shows '$(Get-RoutedName $md)'. Check: kubectl get httproute $md -n $Namespace -o yaml"
    }
}