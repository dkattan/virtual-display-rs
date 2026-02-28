# Test-DisplayConfigUpdate.ps1 — Test IddCxAdapterDisplayConfigUpdate path activation
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Add monitor and wait for IddCxAdapterDisplayConfigUpdate
Write-Host "`n== STEP 1: ADD MONITOR ==" -ForegroundColor Cyan

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

    # Wait for IddCx callbacks
    Start-Sleep -Seconds 5

    # Read trace log
    if (Test-Path $logPath) {
        Write-Host "`n=== TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "No trace log found"
    }

    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: Start recording and check
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

    Start-Sleep -Seconds 5

    # Read trace log
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "`n=== TRACE LOG ==="
        Get-Content $logPath -Raw
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Step 3: Cleanup
Write-Host "`n== STEP 3: CLEANUP ==" -ForegroundColor Cyan

$step3Script = @'
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
    Write-Host "Cleanup done"
    $writer.Dispose()
    $pipe.Dispose()
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
