# Deploy-VDD.ps1 — Deploy updated virtual display driver DLL to DKATTAN-PC3 via ImmyBot.
# Replaces the existing MttVDD.dll in System32\drivers\UMDF with our build.
# Requires: $env:IMMYBOT_SUBDOMAIN, $env:IMMYBOT_CLIENT_ID, $env:IMMYBOT_SECRET, $env:IMMYBOT_AZURE_DOMAIN

param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

# -- Auth --
$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# -- Locate built DLL --
$dllPath = Join-Path $PSScriptRoot 'rust\target\release\virtual_display_driver.dll'
if (-not (Test-Path $dllPath)) { throw "Missing built DLL: $dllPath" }
$dllSize = [Math]::Round((Get-Item $dllPath).Length / 1KB)
Write-Host "Built DLL: $dllPath ($dllSize KB)" -ForegroundColor Gray

# =============================================================================
# PHASE 1: UPLOAD DLL
# =============================================================================
Write-Host "`n== PHASE 1: UPLOAD DLL ==" -ForegroundColor Cyan

$blobName = "VDD_deploy_$(Get-Date -Format 'yyyyMMddHHmmss').dll"

$getSasAction = @"
`$sasUri = New-ImmyUploadSasUri -Permission 'rw' -BlobName '$blobName' -ExpiryTime ([datetime]::UtcNow.AddHours(1))
return `$sasUri
"@

$sasRaw = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId `
    -ScriptBlock ([ScriptBlock]::Create($getSasAction))
$uploadUri = ([regex]::Match([string]$sasRaw, 'https://[^\s"'']+').Value).Trim()
if ([string]::IsNullOrWhiteSpace($uploadUri)) { throw "Failed to get upload SAS URI" }

$dllBytes = [System.IO.File]::ReadAllBytes($dllPath)
Invoke-RestMethod -Method PUT -Uri $uploadUri -Body $dllBytes `
    -ContentType 'application/octet-stream' -Headers @{'x-ms-blob-type' = 'BlockBlob'}
Write-Host "  Uploaded $($dllBytes.Length) bytes to blob storage" -ForegroundColor Green

# =============================================================================
# PHASE 2: REPLACE MttVDD.dll ON TARGET
# =============================================================================
Write-Host "`n== PHASE 2: REPLACE MttVDD.dll ON TARGET ==" -ForegroundColor Cyan

$deployScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $downloadUrl = '__DOWNLOAD_URL__'
    $dest = 'C:\Windows\System32\drivers\UMDF\MttVDD.dll'

    # Verify MttVDD exists
    if (-not (Test-Path $dest)) {
        throw "MttVDD.dll not found at $dest — driver not installed?"
    }
    $oldSize = (Get-Item $dest).Length
    Write-Host "Existing MttVDD.dll: $oldSize bytes"

    # Download the new DLL
    $tempDll = 'C:\Windows\Temp\MttVDD_new.dll'
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempDll -UseBasicParsing
    $newSize = (Get-Item $tempDll).Length
    Write-Host "Downloaded new DLL: $newSize bytes"

    # Disable the device to unload the driver
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    if ($device -and $device.Status -eq 'OK') {
        Write-Host "Disabling MttVDD device ($($device.InstanceId))..."
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
        Start-Sleep -Seconds 3
        Write-Host "Device disabled"
    }

    # Backup and replace
    $bak = "$dest.bak"
    if (Test-Path $bak) { Remove-Item $bak -Force }
    Copy-Item $dest $bak -Force
    Write-Host "Backed up original to $bak"

    try {
        Copy-Item $tempDll $dest -Force -ErrorAction Stop
        Write-Host "Replaced MttVDD.dll"
    } catch {
        # DLL still locked — rename approach
        [System.IO.File]::Move($dest, "$dest.old")
        Copy-Item $tempDll $dest -Force -ErrorAction Stop
        Remove-Item "$dest.old" -Force -ErrorAction SilentlyContinue
        Write-Host "Replaced MttVDD.dll via rename"
    }

    # Re-enable the device
    if ($device) {
        Write-Host "Re-enabling MttVDD device..."
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
        Start-Sleep -Seconds 3
    }

    # Verify
    $f = Get-Item $dest
    Write-Host "Verify: MttVDD.dll = $($f.Length) bytes, modified = $($f.LastWriteTime)"

    # Check device status
    $deviceAfter = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "Device status: $($deviceAfter.Status)"

    # Cleanup
    Remove-Item $tempDll -Force -ErrorAction SilentlyContinue

    Write-Host "DEPLOY_COMPLETE"
}
'@

$deployAction = $deployScript.Replace('__DOWNLOAD_URL__', $uploadUri)

$deployOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
    -ScriptBlock ([ScriptBlock]::Create($deployAction))

Write-Host $deployOutput

if ($deployOutput -notmatch 'DEPLOY_COMPLETE') {
    throw "Deploy did not complete. Output:`n$deployOutput"
}

Write-Host "`n== DEPLOY SUCCESSFUL ==" -ForegroundColor Green
