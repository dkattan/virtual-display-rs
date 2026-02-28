# Test-Canary.ps1 — Verify our custom driver code is actually loaded
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
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
    $writer.AutoFlush = $true
    $cmd = '{"Notify":[{"id":0,"name":"CanaryTest","enabled":true,"modes":[{"width":1920,"height":1080,"refresh_rates":[60]}]}]}'
    $writer.Write($cmd + $EOF)
    $writer.Flush()
    $pipe.WaitForPipeDrain()
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Monitor added"

    Start-Sleep -Seconds 3

    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        Write-Host "=== TRACE LOG ==="
        Write-Host $content
        if ($content -match 'BUILD-CANARY-20260227A') {
            Write-Host "CANARY FOUND - our code IS loaded"
        } else {
            Write-Host "CANARY NOT FOUND - old/signed driver is still running!"
        }
    } else {
        Write-Host "No trace log at all"
    }

    $wudfProcs = Get-Process WUDFHost -ErrorAction SilentlyContinue
    foreach ($p in $wudfProcs) {
        $mttModule = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD' }
        if ($mttModule) {
            Write-Host "Loaded from: $($mttModule.FileName)"
            $f = Get-Item $mttModule.FileName
            Write-Host "Size: $($f.Length) bytes, Modified: $($f.LastWriteTime)"
            Write-Host "Signed: $((Get-AuthenticodeSignature $mttModule.FileName).Status)"
        }
    }

    # Also check driver store copy
    $dsCopies = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'MttVDD.dll' -ErrorAction SilentlyContinue
    foreach ($ds in $dsCopies) {
        Write-Host "DriverStore copy: $($ds.FullName) ($($ds.Length) bytes)"
    }

    # Cleanup
    $pipe2 = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe2.Connect(5000)
    $w2 = [System.IO.StreamWriter]::new($pipe2, [System.Text.Encoding]::UTF8, 4096, $true)
    $w2.AutoFlush = $true
    $w2.Write('"RemoveAll"' + $EOF)
    $w2.Flush()
    $pipe2.WaitForPipeDrain()
    $w2.Dispose()
    $pipe2.Dispose()
    Write-Host "Cleaned up"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
