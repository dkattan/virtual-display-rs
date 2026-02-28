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
    # Check IddCx version on the system
    Write-Host "=== IddCx System Files ==="
    $iddcxFiles = @(
        "C:\Windows\System32\IddCx.dll",
        "C:\Windows\System32\drivers\IddCx.sys",
        "C:\Windows\System32\DriverStore\FileRepository\iddcx.inf*\IddCx.dll"
    )
    foreach ($pattern in $iddcxFiles) {
        Get-Item $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $ver = $_.VersionInfo
            Write-Host "  $($_.FullName): $($ver.FileVersion) ($($ver.ProductVersion))"
        }
    }

    # Check our driver DLL version
    Write-Host "`n=== MttVDD DLL ==="
    $dll = Get-Item "C:\Windows\System32\drivers\UMDF\MttVDD.dll" -ErrorAction SilentlyContinue
    if ($dll) {
        Write-Host "  Size: $($dll.Length) bytes"
        Write-Host "  Modified: $($dll.LastWriteTime)"
        $ver = $dll.VersionInfo
        Write-Host "  FileVersion: $($ver.FileVersion)"
        Write-Host "  ProductVersion: $($ver.ProductVersion)"
    }

    # Check INF for IddCx minimum version
    Write-Host "`n=== MttVDD INF ==="
    $infFiles = Get-ChildItem "C:\Windows\INF" -Filter "oem*.inf" -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content $_.FullName -Raw) -match "MttVDD"
    }
    foreach ($inf in $infFiles) {
        Write-Host "  INF: $($inf.Name)"
        $content = Get-Content $inf.FullName -Raw
        # Look for IddCx version info
        if ($content -match 'IddCxMinimumVersionRequired\s*=\s*(\S+)') {
            Write-Host "  IddCxMinimumVersionRequired: $($Matches[1])"
        }
        # Show relevant sections
        $lines = Get-Content $inf.FullName
        $relevant = $lines | Where-Object { $_ -match 'IddCx|Version|Class|MinimumVersion|DriverVer' }
        foreach ($l in $relevant) {
            Write-Host "  $l"
        }
    }

    # Check driver store
    Write-Host "`n=== Driver Store ==="
    $driverStore = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Filter "*mttvdd*" -Directory -ErrorAction SilentlyContinue
    foreach ($d in $driverStore) {
        Write-Host "  $($d.Name)"
        Get-ChildItem $d.FullName | ForEach-Object {
            Write-Host "    $($_.Name) ($($_.Length) bytes)"
        }
    }

    # Check WUDFHost modules for IddCx version
    Write-Host "`n=== WUDFHost IddCx Module ==="
    Get-Process WUDFHost -ErrorAction SilentlyContinue | ForEach-Object {
        $iddcxMod = $_.Modules | Where-Object { $_.ModuleName -match 'IddCx' }
        if ($iddcxMod) {
            foreach ($m in $iddcxMod) {
                Write-Host "  PID $($_.Id): $($m.ModuleName) v$($m.FileVersionInfo.FileVersion) at $($m.FileName)"
            }
        }
    }

    Write-Host "`nCHECK_DONE"
}
'@

$result = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $result
