# Test-IddCx0104.ps1 — Try IddCx0104 with better error reporting
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
    $wudfPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services'

    # Clear trace log
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    # Create IddCx0104 service with higher WDF version
    $targetPath = "$wudfPath\IddCx0104"
    $sourcePath = "$wudfPath\IddCx0102"
    $sourceProps = Get-ItemProperty $sourcePath

    # Remove and recreate
    if (Test-Path $targetPath) { Remove-Item $targetPath -Recurse -Force }
    New-Item -Path $targetPath -Force | Out-Null
    Set-ItemProperty -Path $targetPath -Name 'ImagePath' -Value $sourceProps.ImagePath -Type String
    Set-ItemProperty -Path $targetPath -Name 'WdfMajorVersion' -Value 2 -Type DWord
    Set-ItemProperty -Path $targetPath -Name 'WdfMinorVersion' -Value 25 -Type DWord  # Higher version

    # Create Parameters and State subkeys (like IddCx0102 has)
    New-Item -Path "$targetPath\Parameters" -Force | Out-Null
    New-Item -Path "$targetPath\State" -Force | Out-Null
    Write-Host "Created IddCx0104 service (WDF 2.25)"

    # Update MttVDD
    $mttPath = "$wudfPath\MttVDD"
    Set-ItemProperty -Path $mttPath -Name 'WdfExtensions' -Value @('IddCx0104') -Type MultiString
    Write-Host "Set MttVDD WdfExtensions to IddCx0104"

    # Get pre-restart event log timestamp
    $timestamp = Get-Date

    # Restart device
    $device = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "Disabling device..."
    Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    Start-Sleep -Seconds 3

    Write-Host "Enabling device..."
    Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    Start-Sleep -Seconds 5

    # Check status
    $deviceAfter = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
    Write-Host "Device status: $($deviceAfter.Status)"
    Write-Host "Device problem code: $($deviceAfter.Problem)"

    if ($deviceAfter.Status -eq 'OK') {
        Write-Host "`nSUCCESS: Device loaded with IddCx0104!"

        # Check trace log
        if (Test-Path $logPath) {
            Write-Host "`n=== TRACE LOG ==="
            Get-Content $logPath -Raw
        }

        # Test adding a monitor
        $pipeName = 'virtualdisplaydriver'
        $EOF = [char]0x04
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $cmd = '{"Notify":[{"id":0,"name":"TestMonitor","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
        $writer.Write($cmd + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        $writer.Dispose()
        $pipe.Dispose()
        Write-Host "Monitor added"

        Start-Sleep -Seconds 8

        if (Test-Path $logPath) {
            Write-Host "`n=== TRACE LOG (after add) ==="
            Get-Content $logPath -Raw
        }

        # Cleanup
        $pipe2 = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe2.Connect(5000)
        $writer2 = [System.IO.StreamWriter]::new($pipe2, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer2.AutoFlush = $true
        $writer2.Write('"RemoveAll"' + $EOF)
        $writer2.Flush()
        $pipe2.WaitForPipeDrain()
        $writer2.Dispose()
        $pipe2.Dispose()
    } else {
        Write-Host "`nDevice failed to start. Checking event log..."

        # Check event log for errors
        $events = Get-WinEvent -LogName System -MaxEvents 50 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $timestamp } |
            Where-Object { $_.ProviderName -match 'UMDF|WudfRd|IddCx|Wdf|MttVDD' -or $_.Message -match 'MttVDD|UMDF|IddCx|driver|WUDF' }

        foreach ($e in $events) {
            Write-Host "  [$($e.TimeCreated)] Level=$($e.Level) Provider=$($e.ProviderName)"
            Write-Host "    $($e.Message)"
        }

        # Also check Application log
        $appEvents = Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $timestamp } |
            Where-Object { $_.ProviderName -match 'UMDF|WudfRd|IddCx|Wdf|MttVDD' }

        foreach ($e in $appEvents) {
            Write-Host "  [APP] [$($e.TimeCreated)] $($e.ProviderName): $($e.Message)"
        }

        # Revert
        Write-Host "`nReverting to IddCx0102..."
        Set-ItemProperty -Path $mttPath -Name 'WdfExtensions' -Value @('IddCx0102') -Type MultiString
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
        Start-Sleep -Seconds 2
        $final = Get-PnpDevice | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
        Write-Host "Reverted, status: $($final.Status)"
    }

    Write-Host "DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
