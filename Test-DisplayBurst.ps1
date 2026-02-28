# Test-DisplayBurst.ps1 — Test CallNtPowerInformation(DisplayBurst=77) from Session 0
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
    # Check idle time first
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public struct LASTINPUTINFO3 { public uint cbSize; public uint dwTime; }
public class IdleCheck {
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO3 p);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
}

public class PowerWake {
    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern uint CallNtPowerInformation(
        int InformationLevel,
        IntPtr InputBuffer,
        uint InputBufferLength,
        IntPtr OutputBuffer,
        uint OutputBufferLength);
}
"@ -ErrorAction SilentlyContinue

    $li = New-Object LASTINPUTINFO3; $li.cbSize = 8
    [IdleCheck]::GetLastInputInfo([ref]$li) | Out-Null
    $idleSec = ([IdleCheck]::GetTickCount() - $li.dwTime) / 1000
    Write-Host "Idle: $([Math]::Round($idleSec, 1)) seconds"

    # Call DisplayBurst (level 77)
    Write-Host "Calling CallNtPowerInformation(DisplayBurst=77)..."
    $result = [PowerWake]::CallNtPowerInformation(77, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0)
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "Result: 0x$($result.ToString('X8')) (Win32Error=$errorCode)"

    if ($result -eq 0) {
        Write-Host "DisplayBurst: SUCCESS (STATUS_SUCCESS)"
    } else {
        Write-Host "DisplayBurst: FAILED (NTSTATUS=0x$($result.ToString('X8')))"
    }

    Start-Sleep -Seconds 2

    # Check idle time again
    [IdleCheck]::GetLastInputInfo([ref]$li) | Out-Null
    $idleSec2 = ([IdleCheck]::GetTickCount() - $li.dwTime) / 1000
    Write-Host "Idle after DisplayBurst: $([Math]::Round($idleSec2, 1)) seconds"

    if ($idleSec2 -lt $idleSec) {
        Write-Host "IDLE TIME RESET - display likely woke!"
    } else {
        Write-Host "Idle time unchanged - DisplayBurst may not have woken the display"
    }

    Write-Host "DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
