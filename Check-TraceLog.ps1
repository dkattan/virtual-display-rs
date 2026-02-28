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
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        $content = Get-Content $logPath -Raw
        $size = (Get-Item $logPath).Length
        Write-Host "=== VDD_trace.log ($size bytes) ==="
        Write-Host $content
    } else {
        Write-Host "VDD_trace.log NOT FOUND at $logPath"
        # Check what's in Windows\Temp
        Write-Host "Files in C:\Windows\Temp matching VDD*:"
        Get-ChildItem 'C:\Windows\Temp' -Filter 'VDD*' -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  $($_.Name) ($($_.Length) bytes)"
        }
    }
    Write-Host "TRACE_CHECK_DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
