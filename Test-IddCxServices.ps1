# Test-IddCxServices.ps1 — List all IddCx service entries and try upgrading
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
    $wudfPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services"

    Write-Host "=== All IddCx Service Entries ==="
    Get-ChildItem $wudfPath | Where-Object { $_.PSChildName -match 'IddCx' } | ForEach-Object {
        Write-Host "`n  Service: $($_.PSChildName)"
        $props = Get-ItemProperty $_.PSPath
        Write-Host "    ImagePath: $($props.ImagePath)"
        Write-Host "    WdfMajorVersion: $($props.WdfMajorVersion)"
        Write-Host "    WdfMinorVersion: $($props.WdfMinorVersion)"
    }

    Write-Host "`n=== MttVDD Service Entry ==="
    $mttPath = "$wudfPath\MttVDD"
    $mttProps = Get-ItemProperty $mttPath
    Write-Host "  WdfExtensions: $($mttProps.WdfExtensions -join ', ')"
    Write-Host "  ImagePath: $($mttProps.ImagePath)"
    Write-Host "  WdfMajorVersion: $($mttProps.WdfMajorVersion)"
    Write-Host "  WdfMinorVersion: $($mttProps.WdfMinorVersion)"

    Write-Host "`n=== IddCx DLL version ==="
    $iddcxPath = 'C:\Windows\System32\drivers\UMDF\IddCx.dll'
    if (Test-Path $iddcxPath) {
        $ver = (Get-Item $iddcxPath).VersionInfo
        Write-Host "  FileVersion: $($ver.FileVersion)"
        Write-Host "  ProductVersion: $($ver.ProductVersion)"
    }

    Write-Host "DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
