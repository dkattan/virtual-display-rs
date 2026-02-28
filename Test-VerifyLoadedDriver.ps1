# Test-VerifyLoadedDriver.ps1 — Verify which MttVDD.dll is actually loaded
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
    Write-Host "=== LOADED MODULE PATH ==="
    $wudfProcs = Get-Process WUDFHost -ErrorAction SilentlyContinue
    foreach ($p in $wudfProcs) {
        $mttModule = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD' }
        if ($mttModule) {
            Write-Host "PID=$($p.Id) MttVDD loaded from: $($mttModule.FileName)"
            $loadedFile = Get-Item $mttModule.FileName
            Write-Host "  Size: $($loadedFile.Length) bytes"
            Write-Host "  LastWriteTime: $($loadedFile.LastWriteTime)"
            Write-Host "  Hash: $((Get-FileHash $mttModule.FileName -Algorithm SHA256).Hash)"
            Write-Host "  Version: $($mttModule.FileVersionInfo.FileVersion)"
            Write-Host "  ProductVersion: $($mttModule.FileVersionInfo.ProductVersion)"
            Write-Host "  Signed: $((Get-AuthenticodeSignature $mttModule.FileName).Status)"
        }
    }

    Write-Host "`n=== DEPLOYED COPY (System32\drivers\UMDF) ==="
    $umdfPath = 'C:\Windows\System32\drivers\UMDF\MttVDD.dll'
    if (Test-Path $umdfPath) {
        $f = Get-Item $umdfPath
        Write-Host "  Size: $($f.Length) bytes"
        Write-Host "  LastWriteTime: $($f.LastWriteTime)"
        Write-Host "  Hash: $((Get-FileHash $umdfPath -Algorithm SHA256).Hash)"
        Write-Host "  Signed: $((Get-AuthenticodeSignature $umdfPath).Status)"
    }

    Write-Host "`n=== BACKUP COPY ==="
    $bakPath = 'C:\Windows\System32\drivers\UMDF\MttVDD.dll.bak'
    if (Test-Path $bakPath) {
        $f = Get-Item $bakPath
        Write-Host "  Size: $($f.Length) bytes"
        Write-Host "  LastWriteTime: $($f.LastWriteTime)"
        Write-Host "  Hash: $((Get-FileHash $bakPath -Algorithm SHA256).Hash)"
        Write-Host "  Signed: $((Get-AuthenticodeSignature $bakPath).Status)"
    }

    Write-Host "`n=== DRIVER STORE COPIES ==="
    $driverStoreCopies = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'MttVDD.dll' -ErrorAction SilentlyContinue
    foreach ($ds in $driverStoreCopies) {
        Write-Host "  Path: $($ds.FullName)"
        Write-Host "  Size: $($ds.Length) bytes"
        Write-Host "  LastWriteTime: $($ds.LastWriteTime)"
        Write-Host "  Hash: $((Get-FileHash $ds.FullName -Algorithm SHA256).Hash)"
        Write-Host "  Signed: $((Get-AuthenticodeSignature $ds.FullName).Status)"
    }

    Write-Host "`n=== INF SERVICE CONFIG ==="
    # Check where UMDF expects to load from
    $svcPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\MttVDD'
    if (Test-Path $svcPath) {
        $svc = Get-ItemProperty $svcPath
        Write-Host "  ServiceBinary: $($svc.ServiceBinary)"
        Write-Host "  ImagePath: $($svc.ImagePath)"
    }

    # Check device service binary in enum
    $devPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY\0000'
    if (Test-Path $devPath) {
        $devProps = Get-ItemProperty $devPath -ErrorAction SilentlyContinue
        Write-Host "  Device Service: $($devProps.Service)"
        Write-Host "  Device Driver: $($devProps.Driver)"
    }

    Write-Host "DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
