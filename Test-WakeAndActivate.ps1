# Test-WakeAndActivate.ps1 — Wake display, then test VDD path activation
# The display may be sleeping, preventing IddCx from processing topology changes.
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
# STEP 1: Wake the display from CurrentUser session
# =============================================================================
Write-Host "`n== STEP 1: WAKE DISPLAY ==" -ForegroundColor Cyan

$wakeScript = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DisplayWake {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint WM_SYSCOMMAND = 0x0112;
    public const int SC_MONITORPOWER = 0xF170;
    public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

    public const uint MOUSEEVENTF_MOVE = 0x0001;

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
}
"@ -ErrorAction SilentlyContinue

    # Method 1: WM_SYSCOMMAND SC_MONITORPOWER -1 = turn monitor ON
    Write-Host "Sending WM_SYSCOMMAND SC_MONITORPOWER (monitor ON)..."
    [DisplayWake]::SendMessage([DisplayWake]::HWND_BROADCAST, [DisplayWake]::WM_SYSCOMMAND,
        [IntPtr][DisplayWake]::SC_MONITORPOWER, [IntPtr](-1))

    # Method 2: Simulate mouse movement to trigger wake
    Write-Host "Sending mouse_event MOVE..."
    [DisplayWake]::mouse_event([DisplayWake]::MOUSEEVENTF_MOVE, 1, 1, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [DisplayWake]::mouse_event([DisplayWake]::MOUSEEVENTF_MOVE, -1, -1, 0, [IntPtr]::Zero)

    # Method 3: SetThreadExecutionState to keep display awake
    Write-Host "Setting ES_DISPLAY_REQUIRED | ES_CONTINUOUS..."
    $r = [DisplayWake]::SetThreadExecutionState(
        [DisplayWake]::ES_CONTINUOUS -bor [DisplayWake]::ES_DISPLAY_REQUIRED -bor [DisplayWake]::ES_SYSTEM_REQUIRED
    )
    Write-Host "SetThreadExecutionState result: $r"

    Write-Host "WAKE_DONE"
}
'@

$wakeOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($wakeScript))
Write-Host $wakeOutput

Write-Host "  Waiting 5s for display to wake..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# =============================================================================
# STEP 2: Clear trace log + add monitor (System context)
# =============================================================================
Write-Host "`n== STEP 2: ADD MONITOR ==" -ForegroundColor Cyan

$addScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true
    $cmd = '{"Notify":[{"id":0,"name":"WakeTest","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
    $writer.Write($cmd + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Monitor added"
    Start-Sleep -Seconds 3

    if (Test-Path $logPath) {
        Write-Host "=== TRACE AFTER ADD ==="
        Get-Content $logPath -Raw
    }
    Write-Host "ADD_DONE"
}
'@

$addOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($addScript))
Write-Host $addOutput

# =============================================================================
# STEP 3: SetDisplayConfig EXTEND from CurrentUser (display should be awake now)
# =============================================================================
Write-Host "`n== STEP 3: EXTEND DISPLAY ==" -ForegroundColor Cyan

$extendScript = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DisplayConfig2 {
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(
        uint numPathArrayElements, IntPtr pathArray,
        uint numModeInfoArrayElements, IntPtr modeInfoArray,
        uint flags);

    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
}
"@ -ErrorAction SilentlyContinue

    Write-Host "Calling SetDisplayConfig(EXTEND)..."
    $r = [DisplayConfig2]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero,
        [DisplayConfig2]::SDC_APPLY -bor [DisplayConfig2]::SDC_TOPOLOGY_EXTEND)
    Write-Host "SetDisplayConfig result: $r"

    Start-Sleep -Seconds 5

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "Screen: $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }
    Write-Host "EXTEND_DONE"
}
'@

$extendOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($extendScript))
Write-Host $extendOutput

# Wait for IddCx to process
Write-Host "  Waiting 10s for IddCx..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# =============================================================================
# STEP 4: Check trace log for ACTIVE flag and assign_swap_chain
# =============================================================================
Write-Host "`n== STEP 4: CHECK RESULTS ==" -ForegroundColor Cyan

$checkScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        Write-Host "=== FULL TRACE LOG ==="
        Write-Host $content

        if ($content -match 'BUILD-CANARY-20260227A') {
            Write-Host "CANARY: YES (our code)"
        } else {
            Write-Host "CANARY: NO (old driver!)"
        }

        if ($content -match 'active=true') {
            Write-Host "PATH ACTIVE: YES!"
        } else {
            Write-Host "PATH ACTIVE: NO"
        }

        if ($content -match 'assign_swap_chain') {
            Write-Host "SWAP CHAIN ASSIGNED: YES!"
        } else {
            Write-Host "SWAP CHAIN ASSIGNED: NO"
        }
    } else {
        Write-Host "NO TRACE LOG"
    }
    Write-Host "CHECK_DONE"
}
'@

$checkOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($checkScript))
Write-Host $checkOutput

# =============================================================================
# STEP 5: Cleanup
# =============================================================================
Write-Host "`n== STEP 5: CLEANUP ==" -ForegroundColor Cyan

$cleanupScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $w = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $w.AutoFlush = $true
    $w.Write('"RemoveAll"' + $EOF)
    $w.Flush()
    $pipe.WaitForPipeDrain()
    $w.Dispose()
    $pipe.Dispose()
    Write-Host "Monitors removed"
}
'@

$cleanupOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($cleanupScript))
Write-Host $cleanupOutput

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
