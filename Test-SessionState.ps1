# Check session state on DKATTAN-PC3
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
    Write-Host "=== SESSIONS ==="
    $sessions = query user 2>&1
    Write-Host $sessions

    Write-Host "`n=== DISPLAY POWER STATE ==="
    # Check if display is on/off via power settings
    $monTimeout = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>&1
    Write-Host $monTimeout

    Write-Host "`n=== EXPLORER PROCESS ==="
    $explorer = Get-Process explorer -ErrorAction SilentlyContinue
    if ($explorer) {
        Write-Host "Explorer running: PID=$($explorer.Id) SessionId=$($explorer.SessionId)"
    } else {
        Write-Host "Explorer NOT running"
    }

    Write-Host "`n=== LOGONUI PROCESS ==="
    $logonui = Get-Process LogonUI -ErrorAction SilentlyContinue
    if ($logonui) {
        foreach ($l in $logonui) {
            Write-Host "LogonUI: PID=$($l.Id) SessionId=$($l.SessionId)"
        }
    } else {
        Write-Host "LogonUI NOT running"
    }

    Write-Host "`n=== LAST INPUT TIME ==="
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}

public class IdleTime {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();
}
"@ -ErrorAction SilentlyContinue

    $lii = New-Object LASTINPUTINFO
    $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    [IdleTime]::GetLastInputInfo([ref]$lii) | Out-Null
    $idleMs = [IdleTime]::GetTickCount() - $lii.dwTime
    $idleMin = [Math]::Round($idleMs / 60000, 1)
    Write-Host "Idle time: $idleMin minutes ($idleMs ms)"

    Write-Host "DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
