# Test-DiagnoseIddCx.ps1 — Deep diagnostics of IddCx path activation issue
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# =============================================================================
# Check device status, driver stack, event logs
# =============================================================================
Write-Host "`n== DIAGNOSTICS ==" -ForegroundColor Cyan

$diagScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    # 1. Device info
    Write-Host "=== DEVICE INFO ==="
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "  InstanceId: $($device.InstanceId)"
    Write-Host "  Status: $($device.Status)"
    Write-Host "  Problem: $($device.Problem)"
    Write-Host "  Class: $($device.Class)"
    Write-Host "  FriendlyName: $($device.FriendlyName)"

    # 2. Driver stack (upper/lower filters)
    Write-Host "`n=== DRIVER STACK ==="
    $devRegPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)"
    $upperFilters = (Get-ItemProperty $devRegPath -Name UpperFilters -ErrorAction SilentlyContinue).UpperFilters
    $lowerFilters = (Get-ItemProperty $devRegPath -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    Write-Host "  UpperFilters: $($upperFilters -join ', ')"
    Write-Host "  LowerFilters: $($lowerFilters -join ', ')"

    # Check IndirectKmd
    $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\IndirectKmd"
    if (Test-Path $svcPath) {
        $indKmd = Get-ItemProperty $svcPath
        Write-Host "  IndirectKmd ImagePath: $($indKmd.ImagePath)"
        Write-Host "  IndirectKmd Start: $($indKmd.Start)"
        Write-Host "  IndirectKmd Type: $($indKmd.Type)"
    } else {
        Write-Host "  IndirectKmd service NOT FOUND"
    }

    # 3. UMDF service info
    Write-Host "`n=== UMDF SERVICE ==="
    $wudfPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services'
    $mttPath = "$wudfPath\MttVDD"
    $mttProps = Get-ItemProperty $mttPath
    Write-Host "  WdfExtensions: $($mttProps.WdfExtensions -join ', ')"
    Write-Host "  WdfMajorVersion: $($mttProps.WdfMajorVersion)"
    Write-Host "  WdfMinorVersion: $($mttProps.WdfMinorVersion)"

    # Check the IddCx extension version
    $iddcxExt = $mttProps.WdfExtensions[0]
    $iddcxPath = "$wudfPath\$iddcxExt"
    if (Test-Path $iddcxPath) {
        $iddcxProps = Get-ItemProperty $iddcxPath
        Write-Host "  $iddcxExt ImagePath: $($iddcxProps.ImagePath)"
        Write-Host "  $iddcxExt WdfMajorVersion: $($iddcxProps.WdfMajorVersion)"
        Write-Host "  $iddcxExt WdfMinorVersion: $($iddcxProps.WdfMinorVersion)"
    }

    # IddCx.dll version
    $iddcxDll = "C:\Windows\System32\drivers\UMDF\IddCx.dll"
    if (Test-Path $iddcxDll) {
        $ver = (Get-Item $iddcxDll).VersionInfo
        Write-Host "  IddCx.dll version: $($ver.FileVersion) ($($ver.ProductVersion))"
    }

    # 4. Event log: last 24h events related to UMDF/IddCx/display
    Write-Host "`n=== RECENT EVENTS (last 30min) ==="
    $since = (Get-Date).AddMinutes(-30)

    # System log
    $sysEvents = Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt $since } |
        Where-Object {
            $_.ProviderName -match 'UMDF|WudfRd|IddCx|Wdf|MttVDD|IndirectKmd|Display|Monitor' -or
            $_.Message -match 'MttVDD|UMDF|IddCx|indirect|display driver|WUDF'
        }

    if ($sysEvents) {
        Write-Host "  System log events:"
        foreach ($e in $sysEvents) {
            Write-Host "    [$($e.TimeCreated)] Level=$($e.Level) Provider=$($e.ProviderName) Id=$($e.Id)"
            Write-Host "      $($e.Message.Substring(0, [Math]::Min(200, $e.Message.Length)))"
        }
    } else {
        Write-Host "  No matching System log events"
    }

    # Microsoft-Windows-WUDF log
    try {
        $wudfEvents = Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 50 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $since }
        if ($wudfEvents) {
            Write-Host "`n  WUDF Operational log events:"
            foreach ($e in ($wudfEvents | Select-Object -First 10)) {
                Write-Host "    [$($e.TimeCreated)] Level=$($e.Level) Id=$($e.Id)"
                Write-Host "      $($e.Message.Substring(0, [Math]::Min(200, $e.Message.Length)))"
            }
        } else {
            Write-Host "  No WUDF operational events"
        }
    } catch {
        Write-Host "  WUDF log not available: $_"
    }

    # 5. WUDFHost process details
    Write-Host "`n=== WUDFHOST PROCESSES ==="
    $wudfProcs = Get-Process WUDFHost -ErrorAction SilentlyContinue
    foreach ($p in $wudfProcs) {
        $modules = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD|IddCx|virtual' }
        if ($modules) {
            Write-Host "  PID=$($p.Id) [DRIVER HOST]:"
            foreach ($m in $modules) {
                Write-Host "    Module: $($m.ModuleName) ($($m.FileVersionInfo.FileVersion))"
            }
        }
    }

    # 6. Check IndirectKmd driver status
    Write-Host "`n=== INDIRECTKMD STATUS ==="
    $kmdService = Get-Service IndirectKmd -ErrorAction SilentlyContinue
    if ($kmdService) {
        Write-Host "  Service: $($kmdService.Status)"
    } else {
        Write-Host "  IndirectKmd service not found via Get-Service"
    }

    # Check if IndirectKmd.sys exists
    $kmdSys = "C:\Windows\System32\drivers\IndirectKmd.sys"
    if (Test-Path $kmdSys) {
        $ver = (Get-Item $kmdSys).VersionInfo
        Write-Host "  IndirectKmd.sys: $($ver.FileVersion)"
    } else {
        Write-Host "  IndirectKmd.sys NOT FOUND"
    }

    Write-Host "DIAG_DONE"
}
'@

$diagOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($diagScript))
Write-Host $diagOutput

Write-Host "`n== DIAGNOSTICS COMPLETE ==" -ForegroundColor Green
