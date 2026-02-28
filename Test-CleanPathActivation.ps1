# Test-CleanPathActivation.ps1 — Clean test of SetDisplayConfig path activation for IDD
# Tests: add monitor → SetDisplayConfig(EXTEND) → check if IddCx activates path
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
# STEP 1: Clear trace log and add monitor via pipe (SYSTEM context)
# =============================================================================
Write-Host "`n== STEP 1: CLEAR LOG + ADD MONITOR ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Clear trace log
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    # Add a virtual monitor
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
    Write-Host "Monitor added via pipe"

    Start-Sleep -Seconds 3

    # Check trace log for adapter_commit_modes
    if (Test-Path $logPath) {
        Write-Host "=== TRACE LOG AFTER ADD ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "No trace log yet"
    }
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# =============================================================================
# STEP 2: Call SetDisplayConfig(EXTEND) from user session
# =============================================================================
Write-Host "`n== STEP 2: SetDisplayConfig EXTEND (CurrentUser) ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DisplayConfig {
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(
        uint numPathArrayElements,
        IntPtr pathArray,
        uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        uint flags);

    // Flag constants
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_NO_OPTIMIZATION = 0x00000100;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_FORCE_MODE_ENUMERATION = 0x00001000;
}
"@ -ErrorAction SilentlyContinue

    # Method 1: Simple extend topology
    Write-Host "Calling SetDisplayConfig(SDC_APPLY | SDC_TOPOLOGY_EXTEND)..."
    $result1 = [DisplayConfig]::SetDisplayConfig(
        0,
        [IntPtr]::Zero,
        0,
        [IntPtr]::Zero,
        [DisplayConfig]::SDC_APPLY -bor [DisplayConfig]::SDC_TOPOLOGY_EXTEND
    )
    Write-Host "SetDisplayConfig result: $result1"

    if ($result1 -ne 0) {
        # If extend fails, try with ALLOW_CHANGES
        Write-Host "Retrying with SDC_ALLOW_CHANGES..."
        $result2 = [DisplayConfig]::SetDisplayConfig(
            0,
            [IntPtr]::Zero,
            0,
            [IntPtr]::Zero,
            [DisplayConfig]::SDC_APPLY -bor [DisplayConfig]::SDC_TOPOLOGY_EXTEND -bor [DisplayConfig]::SDC_ALLOW_CHANGES
        )
        Write-Host "SetDisplayConfig result (retry): $result2"
    }

    Start-Sleep -Seconds 3

    # Check screens
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "  Screen: $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Wait for IddCx to process
Write-Host "  Waiting 8s for IddCx to process..." -ForegroundColor Gray
Start-Sleep -Seconds 8

# =============================================================================
# STEP 3: Check trace log for assign_swap_chain
# =============================================================================
Write-Host "`n== STEP 3: CHECK TRACE LOG ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== FULL TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "NO TRACE LOG FOUND"
    }

    # Also check if the swap chain thread is running
    $wudfProcesses = Get-Process -Name WUDFHost -ErrorAction SilentlyContinue
    Write-Host "`nWUDFHost processes: $($wudfProcesses.Count)"
    foreach ($p in $wudfProcesses) {
        Write-Host "  PID=$($p.Id) Threads=$($p.Threads.Count) Memory=$([Math]::Round($p.WorkingSet64/1MB,1))MB"
    }

    Write-Host "STEP3_DONE"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

# =============================================================================
# STEP 4: Cleanup
# =============================================================================
Write-Host "`n== STEP 4: CLEANUP ==" -ForegroundColor Cyan

$step4Script = @'
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
    Write-Host "Monitors removed"
}
'@

$step4Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step4Script))
Write-Host $step4Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
