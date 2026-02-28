# Test-Recording3.ps1 — Full test: add monitor, wait for swap chain, record, check shm
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Add monitor via separate connection
Write-Host "`n== STEP 1: ADD VIRTUAL MONITOR ==" -ForegroundColor Cyan

$addMonitorScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true

        # Add a 1920x1080 virtual monitor
        $cmd = '{"Notify":[{"id":0,"name":"TestMonitor","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
        $writer.Write($cmd + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        Write-Host "Sent Notify (add monitor id=0, 1920x1080@60)"

        # Give Windows time to set up display pipeline
        Write-Host "Waiting for display pipeline setup..."
        Start-Sleep -Seconds 5

        # Check the displays now
        $displays = Get-CimInstance Win32_VideoController
        foreach ($d in $displays) {
            Write-Host "  Display: $($d.Name) -- $($d.VideoModeDescription) Status=$($d.Status)"
        }

        Write-Host "MONITOR_ADDED"
    }
    catch {
        Write-Host "ERROR: $_"
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        $pipe.Dispose()
    }
}
'@

$addOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($addMonitorScript))
Write-Host $addOutput

if ($addOutput -notmatch 'MONITOR_ADDED') {
    Write-Host "Failed to add monitor" -ForegroundColor Red
    exit 1
}

# Wait for OS to fully initialize the display (swap chain assignment)
Write-Host "  Waiting 10s for swap chain assignment..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Step 2: Start recording via new connection
Write-Host "`n== STEP 2: START RECORDING ==" -ForegroundColor Cyan

$startRecordScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true

        $cmd = '{"StartRecording":{"monitor_ids":[]}}'
        $writer.Write($cmd + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        Write-Host "StartRecording sent (all monitors)"
        Write-Host "START_SENT"
    }
    catch {
        Write-Host "ERROR: $_"
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        $pipe.Dispose()
    }
}
'@

$startOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($startRecordScript))
Write-Host $startOutput

# Wait for frames to be captured
Write-Host "  Waiting 10s for frames..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Step 3: Check shared memory
Write-Host "`n== STEP 3: CHECK SHARED MEMORY ==" -ForegroundColor Cyan

$checkShmScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ShmCheck3 {
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

    $found = $false
    for ($i = 0; $i -lt 4; $i++) {
        $shmName = "Global\VDD_Frame_$i"
        $handle = [ShmCheck3]::OpenFileMappingW([ShmCheck3]::FILE_MAP_READ, $false, $shmName)
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($handle -ne [IntPtr]::Zero) {
            $found = $true
            $view = [ShmCheck3]::MapViewOfFile($handle, [ShmCheck3]::FILE_MAP_READ, 0, 0, [UIntPtr]::new(64))
            if ($view -ne [IntPtr]::Zero) {
                $header = [byte[]]::new(64)
                [System.Runtime.InteropServices.Marshal]::Copy($view, $header, 0, 64)
                $magic = [BitConverter]::ToUInt32($header, 0)
                $version = [BitConverter]::ToUInt32($header, 4)
                $width = [BitConverter]::ToUInt32($header, 8)
                $height = [BitConverter]::ToUInt32($header, 12)
                $stride = [BitConverter]::ToUInt32($header, 16)
                $format = [BitConverter]::ToUInt32($header, 20)
                $frameCount = [BitConverter]::ToUInt32($header, 24)
                $frameSize = [BitConverter]::ToUInt32($header, 28)
                $writeSeq = [BitConverter]::ToUInt64($header, 32)
                $timestamp = [BitConverter]::ToUInt64($header, 40)
                Write-Host "SHM[$i]: magic=0x$($magic.ToString('X8')) ver=$version ${width}x${height} stride=$stride fmt=$format frames=$frameCount size=$frameSize seq=$writeSeq ts=$timestamp"
                [ShmCheck3]::UnmapViewOfFile($view) | Out-Null
            }
            [ShmCheck3]::CloseHandle($handle) | Out-Null
        } else {
            Write-Host "SHM[$i]: not found (err=$err)"
        }
    }

    if (-not $found) {
        Write-Host "NO SHARED MEMORY FOUND"
        Write-Host "Checking WUDFHost for crash indicators..."
        $wudf = Get-Process WUDFHost -ErrorAction SilentlyContinue
        if ($wudf) {
            Write-Host "  WUDFHost still running (PIDs: $($wudf.Id -join ','))"
            foreach ($p in $wudf) {
                $mods = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD' }
                if ($mods) {
                    Write-Host "  PID $($p.Id) has MttVDD loaded, WS=$([Math]::Round($p.WorkingSet64/1MB,1))MB"
                }
            }
        }

        # Check UMDF error events
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-DriverFrameworks-UserMode'
            Level = 1,2,3
            StartTime = (Get-Date).AddMinutes(-5)
        } -MaxEvents 5 -ErrorAction SilentlyContinue
        if ($events) {
            Write-Host "UMDF ERRORS:"
            $events | ForEach-Object { Write-Host "  $($_.TimeCreated): $($_.Message.Substring(0,[Math]::Min(200,$_.Message.Length)))" }
        } else {
            Write-Host "  No UMDF errors"
        }
    }

    Write-Host "CHECK_DONE"
}
'@

$checkOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($checkShmScript))
Write-Host $checkOutput

# Step 4: Cleanup
Write-Host "`n== STEP 4: CLEANUP ==" -ForegroundColor Cyan

$cleanupScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
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
        Write-Host "Cleanup done (StopRecording + RemoveAll)"
    }
    catch { Write-Host "Cleanup error: $_" }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        $pipe.Dispose()
    }
}
'@

$cleanupOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($cleanupScript))
Write-Host $cleanupOutput

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
