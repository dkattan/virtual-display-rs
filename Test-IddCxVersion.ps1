# Test-IddCxVersion.ps1 — Check and modify IddCx version in driver store
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

$script = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Find the MttVDD driver INF in driver store
    Write-Host "=== Driver Store INF ==="
    $driverStore = "C:\Windows\System32\DriverStore\FileRepository"
    $vddDirs = Get-ChildItem $driverStore -Directory | Where-Object { $_.Name -match 'mttvdd|virtualdisplay' }
    foreach ($dir in $vddDirs) {
        Write-Host "`nDir: $($dir.FullName)"
        $infs = Get-ChildItem $dir.FullName -Filter "*.inf"
        foreach ($inf in $infs) {
            Write-Host "  INF: $($inf.Name)"
            $content = Get-Content $inf.FullName -Raw
            if ($content -match 'IddCx\d+') {
                Write-Host "  IddCx version: $($Matches[0])"
            }
            if ($content -match 'UmdfExtensions\s*=\s*(.+)') {
                Write-Host "  UmdfExtensions: $($Matches[1])"
            }
        }
    }

    # Check device registry
    Write-Host "`n=== Device Registry ==="
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    if ($device) {
        Write-Host "Device: $($device.InstanceId) Status=$($device.Status)"
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)"
        if (Test-Path $regPath) {
            Get-ItemProperty $regPath | Format-List | Out-String | Write-Host
        }
        # Check WUDF subkey
        $wudfPath = "$regPath\Device Parameters\WUDF"
        if (Test-Path $wudfPath) {
            Write-Host "WUDF settings:"
            Get-ItemProperty $wudfPath | Format-List | Out-String | Write-Host
        }
    }

    # Check if IddCx version is stored in WDF registry
    Write-Host "`n=== WDF/IddCx Registry ==="
    $wdfPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF"
    if (Test-Path $wdfPath) {
        Get-ChildItem $wdfPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_
            if ($key.Name -match 'MttVDD|VirtualDisplay|IddCx') {
                Write-Host "Key: $($key.Name)"
                Get-ItemProperty $key.PSPath | Format-List | Out-String | Write-Host
            }
        }
    }

    # Check the actual INF content
    Write-Host "`n=== INF Content (UmdfExtensions line) ==="
    $infFiles = Get-ChildItem $driverStore -Recurse -Filter "*.inf" | Where-Object {
        (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'MttVDD'
    }
    foreach ($inf in $infFiles) {
        Write-Host "File: $($inf.FullName)"
        $lines = Get-Content $inf.FullName
        $lines | Where-Object { $_ -match 'UmdfExtensions|IddCx|ServiceBinary|MttVDD' } | ForEach-Object {
            Write-Host "  $_"
        }
    }

    # Check device registry for IddCx version
    Write-Host "`n=== pnputil driver info ==="
    $pnpOutput = pnputil /enum-drivers 2>&1 | Out-String
    $lines = $pnpOutput -split "`n"
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match 'MttVDD|mttvdd') {
            $inBlock = $true
        }
        if ($inBlock) {
            Write-Host $line
            if ($line -match '^\s*$' -and $inBlock) {
                $inBlock = $false
            }
        }
    }

    Write-Host "DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
