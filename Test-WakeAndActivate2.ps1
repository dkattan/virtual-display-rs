# Test-WakeAndActivate2.ps1 — Wake display via System, then test VDD
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
# STEP 1: Wake display via System context (use powercfg + scheduled task)
# =============================================================================
Write-Host "`n== STEP 1: WAKE DISPLAY ==" -ForegroundColor Cyan

$wakeScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Disable monitor timeout
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    Write-Host "Monitor timeout disabled"

    # Find the interactive session ID
    $sessionInfo = query user 2>&1
    Write-Host "Sessions: $sessionInfo"

    # Create a scheduled task to simulate input in the interactive session
    # This will wake the display by sending mouse movement
    $taskScript = @"
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public class WakeHelper {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'
[WakeHelper]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr](-1))
[WakeHelper]::mouse_event(0x0001, 1, 1, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 100
[WakeHelper]::mouse_event(0x0001, -1, -1, 0, [IntPtr]::Zero)
[WakeHelper]::SetThreadExecutionState(0x80000000 -bor 0x00000002 -bor 0x00000001)
"@
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskScript))

    # Remove old task
    schtasks /delete /tn "VDD_WakeDisplay" /f 2>$null

    # Create task running as the interactive user
    $taskAction = "powershell.exe -NoProfile -EncodedCommand $encodedScript"
    schtasks /create /tn "VDD_WakeDisplay" /tr $taskAction /sc once /st 00:00 /ru "INTERACTIVE" /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Schtasks with INTERACTIVE failed, trying with query user session..."
        # Fallback: use the actual username from query user
        $user = (query user 2>&1 | Select-String 'console') -replace '^\s*>\s*' -replace '\s{2,}', '|'
        $parts = $user -split '\|'
        $userName = $parts[0].Trim()
        Write-Host "Detected user: $userName"
        schtasks /create /tn "VDD_WakeDisplay" /tr $taskAction /sc once /st 00:00 /ru $userName /rl HIGHEST /f 2>&1
    }
    schtasks /run /tn "VDD_WakeDisplay" 2>&1
    Write-Host "Wake task launched"
    Start-Sleep -Seconds 3

    # Cleanup task
    schtasks /delete /tn "VDD_WakeDisplay" /f 2>$null

    # Also try waking via powercfg
    powercfg /REQUESTSOVERRIDE PROCESS WUDFHost.exe DISPLAY 2>$null

    Write-Host "WAKE_DONE"
}
'@

$wakeOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($wakeScript))
Write-Host $wakeOutput

Write-Host "  Waiting 5s for display to wake..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# =============================================================================
# STEP 2: Clear trace log + add monitor
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
    $cmd = '{"Notify":[{"id":0,"name":"WakeTest2","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
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
# STEP 3: SetDisplayConfig from scheduled task in interactive session
# =============================================================================
Write-Host "`n== STEP 3: EXTEND VIA SCHEDULED TASK ==" -ForegroundColor Cyan

$extendScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $extendPS = @"
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public class SDC {
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint np, IntPtr p, uint nm, IntPtr m, uint f);
}
'
`$r = [SDC]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x80 -bor 0x04)
[IO.File]::WriteAllText('C:\Windows\Temp\VDD_extend_result.txt', "SetDisplayConfig=$r at $(Get-Date -Format o)")

Add-Type -AssemblyName System.Windows.Forms
`$screens = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "`$(`$_.DeviceName) `$(`$_.Bounds)" }
[IO.File]::AppendAllText('C:\Windows\Temp\VDD_extend_result.txt', "`nScreens: `$(`$screens -join '; ')")
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($extendPS))

    # Get interactive user
    $quser = query user 2>&1 | Select-String 'console'
    $userName = ($quser -replace '^\s*>\s*' -replace '\s{2,}', '|' -split '\|')[0].Trim()
    Write-Host "Interactive user: $userName (will run SetDisplayConfig in their session)"

    schtasks /delete /tn "VDD_Extend" /f 2>$null
    schtasks /create /tn "VDD_Extend" /tr "powershell.exe -NoProfile -EncodedCommand $encoded" /sc once /st 00:00 /ru $userName /rl HIGHEST /f 2>&1
    schtasks /run /tn "VDD_Extend" 2>&1
    Write-Host "Extend task launched"

    Start-Sleep -Seconds 8

    # Read result
    $resultFile = 'C:\Windows\Temp\VDD_extend_result.txt'
    if (Test-Path $resultFile) {
        Write-Host "=== EXTEND RESULT ==="
        Get-Content $resultFile -Raw
    } else {
        Write-Host "No extend result file — task may not have run"
    }

    # Cleanup
    schtasks /delete /tn "VDD_Extend" /f 2>$null

    Write-Host "EXTEND_DONE"
}
'@

$extendOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($extendScript))
Write-Host $extendOutput

# Wait for IddCx
Write-Host "  Waiting 10s for IddCx..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# =============================================================================
# STEP 4: Check trace log
# =============================================================================
Write-Host "`n== STEP 4: CHECK RESULTS ==" -ForegroundColor Cyan

$checkScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        Write-Host "=== FULL TRACE LOG ==="
        Write-Host $content

        if ($content -match 'BUILD-CANARY') { Write-Host "CANARY: YES" }
        if ($content -match 'active=true') { Write-Host "PATH ACTIVE: YES!" }
        else { Write-Host "PATH ACTIVE: NO" }
        if ($content -match 'assign_swap_chain') { Write-Host "SWAP CHAIN: YES!" }
        else { Write-Host "SWAP CHAIN: NO" }
    } else {
        Write-Host "NO TRACE LOG"
    }

    # Check idle time again
    $lii = New-Object LASTINPUTINFO
    $lii.cbSize = 8
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public struct LASTINPUTINFO2 { public uint cbSize; public uint dwTime; } public class IT { [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO2 p); [DllImport("kernel32.dll")] public static extern uint GetTickCount(); }' -ErrorAction SilentlyContinue
    $li = New-Object LASTINPUTINFO2
    $li.cbSize = 8
    [IT]::GetLastInputInfo([ref]$li) | Out-Null
    $idle = [Math]::Round(([IT]::GetTickCount() - $li.dwTime) / 60000, 1)
    Write-Host "Idle: $idle min"

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
    # Restore monitor timeout
    powercfg /change monitor-timeout-ac 5
    powercfg /change monitor-timeout-dc 3

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
    Write-Host "Cleaned up"
}
'@

$cleanupOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($cleanupScript))
Write-Host $cleanupOutput

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
