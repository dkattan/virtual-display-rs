# Test-Recording2.ps1 — Add monitors + start recording on DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

$script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04

    function Send-VddCommand {
        param(
            [System.IO.Pipes.NamedPipeClientStream] $Pipe,
            [string] $Json,
            [bool] $WaitForReply = $false
        )
        $writer = [System.IO.StreamWriter]::new($Pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.Write($Json + $EOF)
        $writer.Flush()
        $Pipe.WaitForPipeDrain()
        Write-Host "  Sent: $Json"

        if ($WaitForReply) {
            Start-Sleep -Milliseconds 500
            $buf = [byte[]]::new(16384)
            $total = 0
            $readTask = $Pipe.ReadAsync($buf, 0, $buf.Length)
            if ($readTask.Wait(3000)) {
                $total = $readTask.Result
            }
            if ($total -gt 0) {
                $resp = [System.Text.Encoding]::UTF8.GetString($buf, 0, $total).TrimEnd($EOF)
                Write-Host "  Response: $resp"
                return $resp
            } else {
                Write-Host "  No response"
                return $null
            }
        }
        $writer.Dispose()
    }

    # Connect to pipe
    Write-Host "Connecting to \\.\pipe\$pipeName..."
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(5000)
        Write-Host "Connected"

        # Step 1: Add a virtual monitor with 1920x1080
        Write-Host "`n-- Step 1: Add virtual monitor --"
        $notifyCmd = '{"Notify":[{"id":0,"name":"TestMonitor","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
        Send-VddCommand -Pipe $pipe -Json $notifyCmd
        Start-Sleep -Seconds 3

        # Step 2: Start recording
        Write-Host "`n-- Step 2: Start recording --"
        $startCmd = '{"StartRecording":{"monitor_ids":[]}}'
        Send-VddCommand -Pipe $pipe -Json $startCmd
        Start-Sleep -Seconds 3

        # Step 3: Query state
        Write-Host "`n-- Step 3: Query recording state --"
        $stateResp = Send-VddCommand -Pipe $pipe -Json '"RecordingState"' -WaitForReply $true

        # Step 4: Wait and check shared memory
        Write-Host "`n-- Step 4: Check shared memory --"
        Start-Sleep -Seconds 5

        # Check for shared memory
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ShmCheck2 {
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

        for ($i = 0; $i -lt 4; $i++) {
            $shmName = "Global\VDD_Frame_$i"
            $handle = [ShmCheck2]::OpenFileMappingW([ShmCheck2]::FILE_MAP_READ, $false, $shmName)
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($handle -ne [IntPtr]::Zero) {
                $view = [ShmCheck2]::MapViewOfFile($handle, [ShmCheck2]::FILE_MAP_READ, 0, 0, [UIntPtr]::new(64))
                if ($view -ne [IntPtr]::Zero) {
                    $header = [byte[]]::new(64)
                    [System.Runtime.InteropServices.Marshal]::Copy($view, $header, 0, 64)
                    $magic = [BitConverter]::ToUInt32($header, 0)
                    $width = [BitConverter]::ToUInt32($header, 8)
                    $height = [BitConverter]::ToUInt32($header, 12)
                    $stride = [BitConverter]::ToUInt32($header, 16)
                    $writeSeq = [BitConverter]::ToUInt64($header, 32)
                    Write-Host "SHM[$i]: magic=0x$($magic.ToString('X8')) ${width}x${height} stride=$stride writeSeq=$writeSeq"
                    [ShmCheck2]::UnmapViewOfFile($view) | Out-Null
                }
                [ShmCheck2]::CloseHandle($handle) | Out-Null
            } else {
                if ($err -ne 2) {
                    Write-Host "SHM[$i]: err=$err"
                }
            }
        }

        # Step 5: Stop recording
        Write-Host "`n-- Step 5: Stop recording --"
        $stopCmd = '"StopRecording"'
        Send-VddCommand -Pipe $pipe -Json $stopCmd

        # Step 6: Remove monitor
        Write-Host "`n-- Step 6: Remove monitor --"
        $removeCmd = '"RemoveAll"'
        Send-VddCommand -Pipe $pipe -Json $removeCmd

    }
    catch {
        Write-Host "ERROR: $_"
        Write-Host $_.ScriptStackTrace
    }
    finally {
        $pipe.Dispose()
    }

    Write-Host "`nTEST_COMPLETE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
