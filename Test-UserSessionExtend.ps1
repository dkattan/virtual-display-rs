# Test-UserSessionExtend.ps1 — Add monitor then extend from user session, check IddCx path activation
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Clear trace log and add monitor
Write-Host "`n== STEP 1: CLEAR LOG & ADD MONITOR ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

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

    # Wait for initial adapter_commit_modes
    Start-Sleep -Seconds 3

    if (Test-Path $logPath) {
        Write-Host "`n=== TRACE LOG (after add) ==="
        Get-Content $logPath -Raw
    }
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: From USER SESSION, run displayswitch /extend
Write-Host "`n== STEP 2: EXTEND FROM USER SESSION ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Write-Host "Running in user session: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Session ID: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"

    # Method 1: displayswitch.exe /extend
    Write-Host "`nMethod 1: displayswitch.exe /extend"
    $proc = Start-Process -FilePath 'displayswitch.exe' -ArgumentList '/extend' -Wait -PassThru -NoNewWindow
    Write-Host "  displayswitch exit code: $($proc.ExitCode)"

    Start-Sleep -Seconds 5

    # Check screen state
    Add-Type -AssemblyName System.Windows.Forms
    $screens = [System.Windows.Forms.Screen]::AllScreens
    Write-Host "`nScreens after displayswitch:"
    foreach ($s in $screens) {
        Write-Host "  $($s.DeviceName) $($s.Bounds) Primary=$($s.Primary)"
    }

    # Method 2: If only 1 screen, try SetDisplayConfig with SDC_TOPOLOGY_EXTEND
    if ($screens.Count -lt 2) {
        Write-Host "`nOnly $($screens.Count) screen(s), trying SetDisplayConfig..."
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CCD2 {
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths,
        IntPtr paths, uint numModes, IntPtr modes, uint flags);

    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
}
"@ -ErrorAction SilentlyContinue

        $result = [CCD2]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero,
            [CCD2]::SDC_APPLY -bor [CCD2]::SDC_TOPOLOGY_EXTEND -bor [CCD2]::SDC_PATH_PERSIST_IF_REQUIRED -bor [CCD2]::SDC_ALLOW_CHANGES)
        Write-Host "  SetDisplayConfig result: $result"
        Start-Sleep -Seconds 5

        $screens2 = [System.Windows.Forms.Screen]::AllScreens
        Write-Host "Screens after SetDisplayConfig:"
        foreach ($s in $screens2) {
            Write-Host "  $($s.DeviceName) $($s.Bounds) Primary=$($s.Primary)"
        }
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Step 3: Check trace log for second adapter_commit_modes with active=true
Write-Host "`n== STEP 3: CHECK TRACE LOG ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== FULL TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "No trace log found"
    }
    Write-Host "STEP3_DONE"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

# Step 4: Cleanup
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
    Write-Host "Cleanup done"
}
'@

$step4Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step4Script))
Write-Host $step4Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
