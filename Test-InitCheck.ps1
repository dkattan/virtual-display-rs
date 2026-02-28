# Test-InitCheck.ps1 — Deploy fresh, add monitor, wait long, check trace
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Check what state we're in now (trace log from deploy)
Write-Host "`n== STEP 1: CHECK CURRENT TRACE LOG (from deploy init) ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        $size = (Get-Item $logPath).Length
        Write-Host "=== VDD_trace.log ($size bytes) ==="
        Write-Host $content
    } else {
        Write-Host "NO TRACE LOG - will create fresh one now"
        # Write a marker to the log
        [System.IO.File]::WriteAllText($logPath, "=== Test-InitCheck marker ===`n")
    }
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: Add monitor (fresh, after the RemoveAll from previous test)
Write-Host "`n== STEP 2: ADD MONITOR & WAIT ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'System' {
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

    # Wait a long time for swap chain assignment
    Write-Host "Waiting 30 seconds for Windows to assign swap chain..."
    Start-Sleep -Seconds 30

    # Check trace log after the wait
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        Write-Host "=== TRACE LOG AFTER 30s WAIT ==="
        Write-Host $content
    }

    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Host "  $($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) Status=$($_.Status)"
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
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
    $writer.Write('"RemoveAll"' + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Cleanup done"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
