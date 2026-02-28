# Test-SessionCheck.ps1 — Quick session state check on DKATTAN-PC3
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
    $sessions = query user 2>&1
    Write-Host "=== SESSIONS ==="
    Write-Host $sessions

    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public struct LI5 { public uint s; public uint t; } public class IC5 { [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LI5 p); [DllImport("kernel32.dll")] public static extern uint GetTickCount(); }' -ErrorAction SilentlyContinue
    $li = New-Object LI5; $li.s = 8; [IC5]::GetLastInputInfo([ref]$li) | Out-Null
    $idleSec = [Math]::Round(([IC5]::GetTickCount() - $li.t) / 1000, 0)
    Write-Host "Idle: ${idleSec}s ($([Math]::Round($idleSec/60,1))min)"

    $logonui = Get-Process LogonUI -ErrorAction SilentlyContinue
    Write-Host "LogonUI running: $($logonui -ne $null)"

    $wudfProcs = Get-Process WUDFHost -ErrorAction SilentlyContinue
    foreach ($p in $wudfProcs) {
        $mttModule = $p.Modules | Where-Object { $_.ModuleName -match 'MttVDD' }
        if ($mttModule) {
            Write-Host "VDD loaded: PID=$($p.Id) from $($mttModule.FileName)"
        }
    }
    Write-Host "STATE_CHECK_DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
