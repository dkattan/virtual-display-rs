# Test-Recording.ps1 — Test StartRecording/StopRecording via IPC on DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425,
    [int] $RecordSeconds = 10
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# =============================================================================
# STEP 1: Send StartRecording and check state
# =============================================================================
Write-Host "`n== STEP 1: START RECORDING ==" -ForegroundColor Cyan

$startScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    # Connect to the VDD named pipe
    Write-Host "Connecting to \\.\pipe\$pipeName..."
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        Write-Host "Connected"

        $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true

        # Send StartRecording (empty monitor_ids = all monitors)
        $cmd = '{"StartRecording":{"monitor_ids":[]}}'
        Write-Host "Sending: $cmd"
        $writer.Write($cmd + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        Start-Sleep -Milliseconds 500
        Write-Host "StartRecording sent"

        # Query recording state
        $query = '"RecordingState"'
        Write-Host "Sending state query: $query"
        $writer.Write($query + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()

        # Read response
        $response = [System.Text.StringBuilder]::new()
        $buf = [char[]]::new(4096)
        $pipe.ReadTimeout = 5000
        Start-Sleep -Milliseconds 500

        # Read available data
        while ($pipe.CanRead) {
            try {
                $count = $reader.Read($buf, 0, $buf.Length)
                if ($count -eq 0) { break }
                $chunk = [string]::new($buf, 0, $count)
                $null = $response.Append($chunk)
                # Check for EOF marker
                if ($chunk.Contains($EOF)) { break }
            } catch {
                break
            }
        }

        $responseStr = $response.ToString().TrimEnd($EOF)
        Write-Host "Recording state response: $responseStr"

        # Check for shared memory sections
        Start-Sleep -Seconds 2

        # Look for Global\ shared memory objects via kernel object directory
        # The shared memory names are in the response
        Write-Host "RECORDING_STARTED"
    }
    catch {
        Write-Host "ERROR: $_"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $pipe) { $pipe.Dispose() }
    }
}
'@

$startOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($startScript))
Write-Host $startOutput

if ($startOutput -notmatch 'RECORDING_STARTED') {
    Write-Host "WARNING: Recording may not have started properly" -ForegroundColor Yellow
}

# =============================================================================
# STEP 2: Wait and check shared memory
# =============================================================================
Write-Host "`n== STEP 2: WAIT ${RecordSeconds}s AND CHECK ==" -ForegroundColor Cyan
Write-Host "  Waiting $RecordSeconds seconds for frames to be captured..." -ForegroundColor Gray
Start-Sleep -Seconds $RecordSeconds

$checkScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Check for shared memory by looking at the driver's debug log or process handles
    # The shared memory is named Global\VDD_Frame_{monitor_id}

    # Try to open the shared memory to verify it exists
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ShmCheck {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr OpenFileMappingW(uint dwDesiredAccess, bool bInheritHandle, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr MapViewOfFile(IntPtr hMap, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);
    [DllImport("kernel32.dll")]
    public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint FILE_MAP_READ = 0x0004;
}
"@ -ErrorAction SilentlyContinue

    # Try monitor IDs 0-3
    for ($i = 0; $i -lt 4; $i++) {
        $shmName = "Global\VDD_Frame_$i"
        $handle = [ShmCheck]::OpenFileMappingW([ShmCheck]::FILE_MAP_READ, $false, $shmName)
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($handle -ne [IntPtr]::Zero) {
            # Read the header (first 64 bytes)
            $view = [ShmCheck]::MapViewOfFile($handle, [ShmCheck]::FILE_MAP_READ, 0, 0, [UIntPtr]::new(64))
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
                Write-Host "SHM[$i]: magic=0x$($magic.ToString('X8')) ver=$version ${width}x${height} stride=$stride fmt=$format frames=$frameCount frameSize=$frameSize writeSeq=$writeSeq"
                [ShmCheck]::UnmapViewOfFile($view) | Out-Null
            }
            [ShmCheck]::CloseHandle($handle) | Out-Null
        } else {
            if ($err -eq 2) {
                # File not found - expected for non-existent monitors
            } else {
                Write-Host "SHM[$i]: OpenFileMapping failed, err=$err"
            }
        }
    }

    # Also check the pipe is still alive
    $pipe = Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object Name -match 'virtualdisplaydriver'
    if ($pipe) {
        Write-Host "PIPE: still alive"
    } else {
        Write-Host "PIPE: GONE (driver may have crashed)"
    }

    Write-Host "CHECK_COMPLETE"
}
'@

$checkOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($checkScript))
Write-Host $checkOutput

# =============================================================================
# STEP 3: Stop recording
# =============================================================================
Write-Host "`n== STEP 3: STOP RECORDING ==" -ForegroundColor Cyan

$stopScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true

        $cmd = '"StopRecording"'
        Write-Host "Sending: $cmd"
        $writer.Write($cmd + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        Write-Host "StopRecording sent"
        Write-Host "STOP_COMPLETE"
    }
    catch {
        Write-Host "ERROR: $_"
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $pipe) { $pipe.Dispose() }
    }
}
'@

$stopOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($stopScript))
Write-Host $stopOutput

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
