# Test-ExtendThenAdd.ps1 — Set extend topology BEFORE adding monitor
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 0: Cleanup any existing monitors and clear log
Write-Host "`n== STEP 0: CLEANUP ==" -ForegroundColor Cyan

$step0Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.Write('"RemoveAll"' + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        $writer.Dispose()
        $pipe.Dispose()
        Write-Host "Removed all existing monitors"
    } catch {
        Write-Host "No existing monitors to remove: $_"
    }

    Start-Sleep -Seconds 3

    # Clear trace log again (RemoveAll triggers some logging)
    if (Test-Path $logPath) { Remove-Item $logPath -Force }
    Write-Host "STEP0_DONE"
}
'@

$step0Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step0Script))
Write-Host $step0Output

# Step 1: From USER SESSION, set extend topology
Write-Host "`n== STEP 1: SET EXTEND TOPOLOGY ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Write-Host "Setting extend topology from user session..."
    Write-Host "Session: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"

    # Set persist extend topology
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DisplaySwitch {
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths,
        IntPtr paths, uint numModes, IntPtr modes, uint flags);

    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_SAVE_TO_DATABASE = 0x00000200;
}
"@ -ErrorAction SilentlyContinue

    # Apply and save extend topology
    $result = [DisplaySwitch]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero,
        [DisplaySwitch]::SDC_APPLY -bor [DisplaySwitch]::SDC_TOPOLOGY_EXTEND -bor
        [DisplaySwitch]::SDC_PATH_PERSIST_IF_REQUIRED -bor [DisplaySwitch]::SDC_ALLOW_CHANGES -bor
        [DisplaySwitch]::SDC_SAVE_TO_DATABASE)
    Write-Host "  SetDisplayConfig EXTEND result: $result"

    Start-Sleep -Seconds 2

    Add-Type -AssemblyName System.Windows.Forms
    $screens = [System.Windows.Forms.Screen]::AllScreens
    Write-Host "Screens (before adding VDD): $($screens.Count)"
    foreach ($s in $screens) {
        Write-Host "  $($s.DeviceName) $($s.Bounds) Primary=$($s.Primary)"
    }

    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: NOW add the monitor (SYSTEM)
Write-Host "`n== STEP 2: ADD MONITOR ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'System' {
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

    # Wait for IddCx callbacks
    Start-Sleep -Seconds 8

    # Read trace log
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "`n=== TRACE LOG ==="
        Get-Content $logPath -Raw
    }
    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Step 3: Cleanup
Write-Host "`n== STEP 3: CLEANUP ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true
    $writer.Write('"RemoveAll"' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Cleanup done"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
