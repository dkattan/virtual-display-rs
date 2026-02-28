# Check-VDDLogs.ps1 — Check VDD driver logs and state on DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl

$script = @'
Invoke-ImmyCommand -ContextString 'System' {
    # Check UMDF host event logs for our driver
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-DriverFrameworks-UserMode'
        StartTime = (Get-Date).AddHours(-1)
    } -MaxEvents 20 -ErrorAction SilentlyContinue
    if ($events) {
        Write-Host "=== UMDF Events (last 1hr) ==="
        $events | ForEach-Object {
            Write-Host "  [$($_.TimeCreated)] Level=$($_.Level) ID=$($_.Id): $($_.Message.Substring(0, [Math]::Min(200, $_.Message.Length)))"
        }
    } else {
        Write-Host "=== No UMDF events in last 1hr ==="
    }

    # Check Application event log for driver crashes
    $appEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        Level = 1,2  # Critical, Error
        StartTime = (Get-Date).AddHours(-1)
    } -MaxEvents 10 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'MttVDD|WUDFHost|VirtualDisplay|IddCx' }
    if ($appEvents) {
        Write-Host "=== App Error Events ==="
        $appEvents | ForEach-Object {
            Write-Host "  [$($_.TimeCreated)] $($_.Message.Substring(0, [Math]::Min(300, $_.Message.Length)))"
        }
    }

    # Check WUDFHost process and its loaded modules
    Write-Host "`n=== WUDFHost Processes ==="
    $wudfProcs = Get-Process WUDFHost -ErrorAction SilentlyContinue
    foreach ($p in $wudfProcs) {
        $mods = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD|IddCx|Virtual' }
        if ($mods) {
            Write-Host "  PID $($p.Id): WS=$([Math]::Round($p.WorkingSet64/1MB,1))MB"
            foreach ($m in $mods) {
                Write-Host "    $($m.ModuleName) ($($m.FileVersionInfo.FileVersion))"
            }
        }
    }

    # Check if any virtual monitors are active (display outputs)
    Write-Host "`n=== Active Displays ==="
    $displays = Get-CimInstance Win32_VideoController
    foreach ($d in $displays) {
        Write-Host "  $($d.Name): $($d.VideoModeDescription) Status=$($d.Status)"
    }

    # Check the recording state by connecting to pipe
    Write-Host "`n=== IPC State Check ==="
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(3000)

        # Send State request to see what monitors the driver knows about
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.Write('"State"' + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()

        # Read response with a manual timeout
        Start-Sleep -Milliseconds 1000
        $buf = [byte[]]::new(8192)
        $total = 0
        while ($pipe.IsConnected) {
            if (-not $pipe.CanRead) { break }
            # Use async read with timeout
            $readTask = $pipe.ReadAsync($buf, $total, $buf.Length - $total)
            if ($readTask.Wait(2000)) {
                $n = $readTask.Result
                if ($n -eq 0) { break }
                $total += $n
                $str = [System.Text.Encoding]::UTF8.GetString($buf, 0, $total)
                if ($str.Contains($EOF)) { break }
            } else {
                Write-Host "  Read timed out after 2s (got $total bytes so far)"
                break
            }
        }

        if ($total -gt 0) {
            $response = [System.Text.Encoding]::UTF8.GetString($buf, 0, $total).TrimEnd($EOF)
            Write-Host "  State response: $response"
        } else {
            Write-Host "  No response received"
        }

        $pipe.Dispose()
    } catch {
        Write-Host "  Pipe error: $_"
    }

    Write-Host "`nCHECK_DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
