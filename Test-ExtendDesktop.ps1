# Test-ExtendDesktop.ps1 — Add virtual monitor, extend desktop to it, then start recording
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Clear trace log, add monitor, try extend desktop
Write-Host "`n== STEP 1: CLEAR LOG, ADD MONITOR, EXTEND DESKTOP ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Clear trace log
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
    Write-Host "Monitor added"
    $writer.Dispose()
    $pipe.Dispose()

    Start-Sleep -Seconds 3

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DC2 {
    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths,
        IntPtr paths, uint numModes, IntPtr modes, uint flags);

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
}
"@ -ErrorAction SilentlyContinue

    $np = [uint32]0; $nm = [uint32]0
    $r = [DC2]::GetDisplayConfigBufferSizes([DC2]::QDC_ALL_PATHS, [ref]$np, [ref]$nm)
    Write-Host "All paths: $np, modes: $nm (res=$r)"

    $np2 = [uint32]0; $nm2 = [uint32]0
    $r2 = [DC2]::GetDisplayConfigBufferSizes([DC2]::QDC_ONLY_ACTIVE_PATHS, [ref]$np2, [ref]$nm2)
    Write-Host "Active paths: $np2, modes: $nm2 (res=$r2)"

    Write-Host "Attempting SetDisplayConfig(EXTEND)..."
    $extendResult = [DC2]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero,
        [DC2]::SDC_TOPOLOGY_EXTEND -bor [DC2]::SDC_APPLY -bor [DC2]::SDC_ALLOW_CHANGES)
    Write-Host "SetDisplayConfig result: $extendResult"

    Start-Sleep -Seconds 5

    $np3 = [uint32]0; $nm3 = [uint32]0
    $r3 = [DC2]::GetDisplayConfigBufferSizes([DC2]::QDC_ONLY_ACTIVE_PATHS, [ref]$np3, [ref]$nm3)
    Write-Host "Active paths after extend: $np3, modes: $nm3 (res=$r3)"

    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Host "  $($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) Status=$($_.Status)"
    }

    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: Start recording
Write-Host "`n== STEP 2: START RECORDING ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true

    $writer.Write('{"StartRecording":{"monitor_ids":[]}}' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Write-Host "StartRecording sent"
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

Write-Host "  Waiting 10s for frames..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Step 3: Check trace log + shared memory
Write-Host "`n== STEP 3: CHECK TRACE LOG + SHM ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "NO TRACE LOG"
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SC4 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr OpenFileMappingW(uint dwDesiredAccess, bool bInheritHandle, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr MapViewOfFile(IntPtr hMap, uint dwDesiredAccess, uint high, uint low, UIntPtr size);
    [DllImport("kernel32.dll")]
    public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
    public const uint FILE_MAP_READ = 0x0004;
}
"@ -ErrorAction SilentlyContinue

    Write-Host "`n=== SHARED MEMORY ==="
    for ($i = 0; $i -lt 4; $i++) {
        $handle = [SC4]::OpenFileMappingW([SC4]::FILE_MAP_READ, $false, "Global\VDD_Frame_$i")
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($handle -ne [IntPtr]::Zero) {
            $view = [SC4]::MapViewOfFile($handle, [SC4]::FILE_MAP_READ, 0, 0, [UIntPtr]::new(64))
            if ($view -ne [IntPtr]::Zero) {
                $header = [byte[]]::new(64)
                [System.Runtime.InteropServices.Marshal]::Copy($view, $header, 0, 64)
                $magic = [BitConverter]::ToUInt32($header, 0)
                $width = [BitConverter]::ToUInt32($header, 8)
                $height = [BitConverter]::ToUInt32($header, 12)
                $writeSeq = [BitConverter]::ToUInt64($header, 32)
                Write-Host "SHM[$i]: magic=0x$($magic.ToString('X8')) ${width}x${height} seq=$writeSeq"
                [SC4]::UnmapViewOfFile($view) | Out-Null
            }
            [SC4]::CloseHandle($handle) | Out-Null
        } else {
            Write-Host "SHM[$i]: not found (err=$err)"
        }
    }

    Write-Host "CHECK_DONE"
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
    $writer.Write('"StopRecording"' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Start-Sleep -Milliseconds 500
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
