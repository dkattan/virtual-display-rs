# Check-VDD.ps1 — Check VDD state on DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

$checkScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Test signing mode?
    $bcd = bcdedit /enum "{current}" 2>&1 | Out-String
    if ($bcd -match "testsigning\s+Yes") {
        Write-Host "TESTSIGN: ENABLED"
    } else {
        Write-Host "TESTSIGN: DISABLED"
    }

    # MttVDD details
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains "Root\MttVDD" }
    if ($device) {
        Write-Host "MttVDD_STATUS: $($device.Status)"
        Write-Host "MttVDD_CLASS: $($device.Class)"
        Write-Host "MttVDD_FRIENDLY: $($device.FriendlyName)"
        Write-Host "MttVDD_INSTANCE: $($device.InstanceId)"
    }

    # Check for VirtualDisplayDriver device too
    $vddDevice = Get-PnpDevice | Where-Object { $_.HardwareID -contains "Root\VirtualDisplayDriver" }
    if ($vddDevice) {
        Write-Host "VDD_EXISTS: YES status=$($vddDevice.Status)"
    } else {
        Write-Host "VDD_EXISTS: NO"
    }

    # Check UMDF driver directory for relevant files
    $umdfDir = 'C:\Windows\System32\drivers\UMDF'
    Get-ChildItem $umdfDir -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match 'Virtual|Mtt|vdd|IDD' -or $_.Name -match 'Display') {
            Write-Host "UMDF_FILE: $($_.Name) ($($_.Length) bytes)"
        }
    }

    # Check driver store for VDD INFs
    $driverStore = 'C:\Windows\System32\DriverStore\FileRepository'
    Get-ChildItem $driverStore -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'virtual|mtt|vdd|display'
    } | ForEach-Object {
        Write-Host "DRIVERSTORE: $($_.Name)"
        Get-ChildItem $_.FullName | ForEach-Object {
            Write-Host "  $($_.Name) ($($_.Length) bytes)"
        }
    }
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($checkScript))
Write-Host $result
