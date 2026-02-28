# Check-DriverEvents.ps1 — Get VDD driver event log entries from DKATTAN-PC3
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl

# First, add monitor + start recording to generate some logs
$setupScript = @'
Invoke-ImmyCommand -ContextString 'System' {
    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true

    # Add monitor
    $writer.Write('{"Notify":[{"id":0,"name":"TestMonitor","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Write-Host "Monitor added"
    Start-Sleep -Seconds 5

    # Start recording
    $writer.Write('{"StartRecording":{"monitor_ids":[]}}' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Write-Host "Recording started"
    Start-Sleep -Seconds 5

    # Stop and cleanup
    $writer.Write('"StopRecording"' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Start-Sleep -Milliseconds 500

    $writer.Write('"RemoveAll"' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    Write-Host "Cleaned up"

    $writer.Dispose()
    $pipe.Dispose()

    # Now get event logs
    Write-Host "`n=== VDD Event Log (System log, last 10 min) ==="
    # The driver registers as "MttVDD" or "VirtualDisplayDriver" in the event log
    $allEvents = Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object {
        $_.TimeCreated -gt (Get-Date).AddMinutes(-10)
    }

    # Filter for our driver events
    $vddEvents = $allEvents | Where-Object {
        $_.ProviderName -match 'MttVDD|VirtualDisplay|UMDF|iddcx' -or
        $_.Message -match 'MttVDD|VirtualDisplay|virtual display|swap chain|recording'
    }

    if ($vddEvents) {
        foreach ($e in $vddEvents) {
            Write-Host "  [$($e.TimeCreated)] Provider=$($e.ProviderName) Level=$($e.Level) ID=$($e.Id)"
            Write-Host "    $($e.Message)"
        }
    } else {
        Write-Host "  No VDD events found in System log"
    }

    # Also check Application log
    Write-Host "`n=== Application Event Log ==="
    $appEvents = Get-WinEvent -LogName Application -MaxEvents 100 -ErrorAction SilentlyContinue | Where-Object {
        $_.TimeCreated -gt (Get-Date).AddMinutes(-10) -and
        ($_.ProviderName -match 'MttVDD|VirtualDisplay' -or $_.Message -match 'MttVDD|VirtualDisplay')
    }

    if ($appEvents) {
        foreach ($e in $appEvents) {
            Write-Host "  [$($e.TimeCreated)] Provider=$($e.ProviderName) Level=$($e.Level)"
            Write-Host "    $($e.Message)"
        }
    } else {
        Write-Host "  No VDD events in Application log"
    }

    # Check DebugView output by looking at the WUDFHost process handles
    Write-Host "`n=== WUDFHost MttVDD Process ==="
    $wudf = Get-Process WUDFHost -ErrorAction SilentlyContinue | Where-Object {
        $_.Modules | Where-Object ModuleName -eq 'mttvdd.dll'
    }
    if ($wudf) {
        Write-Host "  PID=$($wudf.Id) WS=$([Math]::Round($wudf.WorkingSet64/1MB,1))MB Threads=$($wudf.Threads.Count)"
    }

    Write-Host "`nDONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($setupScript))
Write-Host $result
