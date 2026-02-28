# Test-WakeAndActivate3.ps1 — Write helper scripts to disk, run via schtasks
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
# STEP 1: Deploy helper script + wake display + add monitor + extend
# =============================================================================
Write-Host "`n== ALL-IN-ONE ==" -ForegroundColor Cyan

$script = @'
Invoke-ImmyCommand -ContextString 'System' {
    # --- Disable monitor sleep ---
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    Write-Host "Monitor timeout disabled"

    # --- Clear trace log ---
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    # --- Write helper script to disk ---
    $helperScript = @"
Add-Type -TypeDefinition '
using System; using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint np, IntPtr p, uint nm, IntPtr m, uint f);
}
'
# Wake display
[W]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr](-1))
[W]::mouse_event(0x0001, 10, 10, 0, [IntPtr]::Zero)
Start-Sleep -Seconds 2
# Extend display
`$r = [W]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x84)
Add-Type -AssemblyName System.Windows.Forms
`$s = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "`$(`$_.DeviceName) `$(`$_.Bounds)" }
[IO.File]::WriteAllText('C:\Windows\Temp\VDD_extend.txt', "result=`$r`nscreens=`$(`$s -join ';')`ntime=$(Get-Date -Format o)")
"@
    Set-Content 'C:\Windows\Temp\VDD_helper.ps1' $helperScript -Encoding UTF8
    Write-Host "Helper script written"

    # --- Add virtual monitor ---
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true
    $cmd = '{"Notify":[{"id":0,"name":"WakeTest3","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
    $writer.Write($cmd + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Monitor added"
    Start-Sleep -Seconds 2

    # --- Run helper in interactive session via schtasks ---
    schtasks /delete /tn "VDD_Helper" /f 2>$null
    $quser = query user 2>&1 | Select-String 'console'
    $userName = ($quser -replace '^\s*>\s*' -replace '\s{2,}', '|' -split '\|')[0].Trim()
    Write-Host "User: $userName"

    schtasks /create /tn "VDD_Helper" /tr "powershell.exe -NoProfile -File C:\Windows\Temp\VDD_helper.ps1" /sc once /st 00:00 /ru $userName /rl HIGHEST /f 2>&1
    schtasks /run /tn "VDD_Helper" 2>&1
    Write-Host "Helper task launched, waiting 15s..."
    Start-Sleep -Seconds 15

    # --- Check results ---
    $extendResult = 'C:\Windows\Temp\VDD_extend.txt'
    if (Test-Path $extendResult) {
        Write-Host "=== EXTEND RESULT ==="
        Get-Content $extendResult -Raw
    } else {
        Write-Host "No extend result (task may have failed)"
        # Check if the task ran
        schtasks /query /tn "VDD_Helper" /v /fo LIST 2>&1 | Select-String "Status|Last Run|Last Result" | ForEach-Object { Write-Host $_ }
    }

    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        Write-Host "=== TRACE LOG ==="
        Write-Host $content

        if ($content -match 'BUILD-CANARY') { Write-Host "CANARY: YES" } else { Write-Host "CANARY: NO" }
        if ($content -match 'active=true') { Write-Host "PATH ACTIVE: YES!" } else { Write-Host "PATH ACTIVE: NO" }
        if ($content -match 'assign_swap_chain') { Write-Host "SWAP CHAIN: YES!" } else { Write-Host "SWAP CHAIN: NO" }
    } else {
        Write-Host "NO TRACE LOG"
    }

    # Check idle time
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public struct LII { public uint s; public uint t; } public class IT2 { [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LII p); [DllImport("kernel32.dll")] public static extern uint GetTickCount(); }' -ErrorAction SilentlyContinue
    $li = New-Object LII; $li.s = 8
    [IT2]::GetLastInputInfo([ref]$li) | Out-Null
    $idle = [Math]::Round(([IT2]::GetTickCount() - $li.t) / 60000, 1)
    Write-Host "Idle after wake attempt: $idle min"

    # --- Cleanup ---
    schtasks /delete /tn "VDD_Helper" /f 2>$null
    Remove-Item 'C:\Windows\Temp\VDD_helper.ps1' -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\VDD_extend.txt' -Force -ErrorAction SilentlyContinue

    # Remove monitor
    $pipe2 = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe2.Connect(5000)
    $w2 = [System.IO.StreamWriter]::new($pipe2, [System.Text.Encoding]::UTF8, 4096, $true)
    $w2.AutoFlush = $true
    $w2.Write('"RemoveAll"' + $EOF)
    $w2.Flush()
    $pipe2.WaitForPipeDrain()
    $w2.Dispose()
    $pipe2.Dispose()

    # Restore monitor timeout
    powercfg /change monitor-timeout-ac 5
    powercfg /change monitor-timeout-dc 3

    Write-Host "ALL_DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
