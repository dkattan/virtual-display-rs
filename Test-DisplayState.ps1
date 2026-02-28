# Test-DisplayState.ps1 — Check display topology and whether the virtual monitor has a desktop
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl

# Step 1: Add monitor and check display state
$script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    # First add a monitor
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true
    $cmd = '{"Notify":[{"id":0,"name":"TestMonitor","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
    $writer.Write($cmd + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Write-Host "Monitor added"
    $writer.Dispose()
    $pipe.Dispose()

    Start-Sleep -Seconds 10

    # Check display configuration
    Write-Host "`n=== Win32_DesktopMonitor ==="
    Get-CimInstance Win32_DesktopMonitor | ForEach-Object {
        Write-Host "  $($_.Name) -- Active=$($_.Availability) ScreenW=$($_.ScreenWidth) ScreenH=$($_.ScreenHeight)"
    }

    Write-Host "`n=== Win32_VideoController ==="
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Host "  $($_.Name) -- $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) Status=$($_.Status)"
    }

    Write-Host "`n=== PnP Monitors ==="
    Get-PnpDevice -Class Monitor -Status OK -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  $($_.FriendlyName) -- $($_.InstanceId)"
    }

    Write-Host "`n=== Display Devices (via displayswitch query) ==="
    # Use CIM to get active display paths
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DisplayConfig {
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    public const uint QDC_ALL_PATHS = 0x00000001;
    public const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
}
"@ -ErrorAction SilentlyContinue

    $numPaths = [uint32]0
    $numModes = [uint32]0
    $res = [DisplayConfig]::GetDisplayConfigBufferSizes([DisplayConfig]::QDC_ONLY_ACTIVE_PATHS, [ref]$numPaths, [ref]$numModes)
    Write-Host "  Active paths: $numPaths, modes: $numModes (result=$res)"

    $res2 = [DisplayConfig]::GetDisplayConfigBufferSizes([DisplayConfig]::QDC_ALL_PATHS, [ref]$numPaths, [ref]$numModes)
    Write-Host "  All paths: $numPaths, modes: $numModes (result=$res2)"

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
    Write-Host "`nMonitors removed"
    Write-Host "DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
