# Upgrade-IddCxVersion.ps1 — Create IddCx0104 service entry and switch MttVDD to it
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425,
    [string] $TargetVersion = 'IddCx0104'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

$script = @"
Invoke-ImmyCommand -ContextString 'System' {
    `$targetVersion = '$TargetVersion'
    `$wudfPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services'

    # Step 1: Check if target service already exists
    Write-Host "=== Step 1: Check/Create `$targetVersion service ==="
    `$targetPath = "`$wudfPath\`$targetVersion"
    if (Test-Path `$targetPath) {
        Write-Host "  `$targetVersion already exists"
        `$props = Get-ItemProperty `$targetPath
        Write-Host "  ImagePath: `$(`$props.ImagePath)"
    } else {
        Write-Host "  Creating `$targetVersion service entry..."
        # Copy from IddCx0102
        `$sourcePath = "`$wudfPath\IddCx0102"
        `$sourceProps = Get-ItemProperty `$sourcePath

        New-Item -Path `$targetPath -Force | Out-Null
        Set-ItemProperty -Path `$targetPath -Name 'ImagePath' -Value `$sourceProps.ImagePath -Type String
        Set-ItemProperty -Path `$targetPath -Name 'WdfMajorVersion' -Value `$sourceProps.WdfMajorVersion -Type DWord
        Set-ItemProperty -Path `$targetPath -Name 'WdfMinorVersion' -Value `$sourceProps.WdfMinorVersion -Type DWord

        # Create Parameters subkey
        `$paramsPath = "`$targetPath\Parameters"
        New-Item -Path `$paramsPath -Force | Out-Null

        Write-Host "  Created `$targetVersion -> `$(`$sourceProps.ImagePath)"
    }

    # Step 2: Update MttVDD to use the new version
    Write-Host "`n=== Step 2: Update MttVDD WdfExtensions ==="
    `$mttPath = "`$wudfPath\MttVDD"
    `$currentExt = (Get-ItemProperty `$mttPath).WdfExtensions
    Write-Host "  Current WdfExtensions: `$(`$currentExt -join ', ')"

    Set-ItemProperty -Path `$mttPath -Name 'WdfExtensions' -Value @(`$targetVersion) -Type MultiString
    `$newExt = (Get-ItemProperty `$mttPath).WdfExtensions
    Write-Host "  New WdfExtensions: `$(`$newExt -join ', ')"

    # Step 3: Restart the MttVDD device
    Write-Host "`n=== Step 3: Restart MttVDD device ==="
    `$device = Get-PnpDevice | Where-Object { `$_.HardwareID -contains 'Root\MttVDD' }
    if (`$device) {
        Write-Host "  Disabling `$(`$device.InstanceId)..."
        Disable-PnpDevice -InstanceId `$device.InstanceId -Confirm:`$false
        Start-Sleep -Seconds 3

        Write-Host "  Re-enabling..."
        Enable-PnpDevice -InstanceId `$device.InstanceId -Confirm:`$false
        Start-Sleep -Seconds 3

        `$deviceAfter = Get-PnpDevice | Where-Object { `$_.HardwareID -contains 'Root\MttVDD' }
        Write-Host "  Device status: `$(`$deviceAfter.Status)"

        if (`$deviceAfter.Status -ne 'OK') {
            Write-Host "  WARNING: Device not OK, reverting to IddCx0102..."
            Set-ItemProperty -Path `$mttPath -Name 'WdfExtensions' -Value @('IddCx0102') -Type MultiString

            Disable-PnpDevice -InstanceId `$device.InstanceId -Confirm:`$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Enable-PnpDevice -InstanceId `$device.InstanceId -Confirm:`$false
            Start-Sleep -Seconds 2

            `$deviceReverted = Get-PnpDevice | Where-Object { `$_.HardwareID -contains 'Root\MttVDD' }
            Write-Host "  After revert: `$(`$deviceReverted.Status)"
        }
    }

    # Step 4: Verify
    Write-Host "`n=== Verification ==="
    `$finalExt = (Get-ItemProperty `$mttPath).WdfExtensions
    Write-Host "  MttVDD WdfExtensions: `$(`$finalExt -join ', ')"

    `$finalDevice = Get-PnpDevice | Where-Object { `$_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "  Device Status: `$(`$finalDevice.Status)"

    Write-Host "DONE"
}
"@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
