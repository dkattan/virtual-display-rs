# Verify-VDD.ps1 — Verify the deployed VDD on DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl

$verifyScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Check driver DLL
    $dll = Get-Item 'C:\Windows\System32\drivers\UMDF\MttVDD.dll' -ErrorAction SilentlyContinue
    Write-Host "DLL: $($dll.Length) bytes, modified=$($dll.LastWriteTime)"

    # Check device
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "Device: status=$($device.Status)"

    # Check named pipe
    $pipe = Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object Name -match 'virtualdisplaydriver'
    if ($pipe) {
        Write-Host "PIPE: FOUND ($($pipe.Name))"
    } else {
        Write-Host "PIPE: NOT_FOUND"
    }

    # Check WUDFHost process for our driver
    $wudfHost = Get-Process WUDFHost -ErrorAction SilentlyContinue
    if ($wudfHost) {
        Write-Host "WUDFHost PIDs: $($wudfHost.Id -join ', ')"
        foreach ($p in $wudfHost) {
            $modules = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD|VirtualDisplay' }
            if ($modules) {
                Write-Host "  PID $($p.Id) loaded: $($modules.ModuleName -join ', ')"
            }
        }
    }

    # Check driver event log for errors
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-DriverFrameworks-UserMode'
        Level = 1,2,3  # Critical, Error, Warning
        StartTime = (Get-Date).AddMinutes(-5)
    } -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($events) {
        Write-Host "RECENT UMDF ERRORS:"
        $events | ForEach-Object { Write-Host "  [$($_.TimeCreated)] $($_.Message)" }
    } else {
        Write-Host "UMDF_ERRORS: NONE (last 5 min)"
    }

    # Check for shared memory objects (recording test)
    $shm = Get-ChildItem 'C:\Windows\Temp\' -Filter 'VDD_Frame_*' -ErrorAction SilentlyContinue
    if ($shm) {
        Write-Host "SHM_FILES: $($shm.Name -join ', ')"
    } else {
        Write-Host "SHM_FILES: NONE (recording not started)"
    }
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($verifyScript))
Write-Host $result
