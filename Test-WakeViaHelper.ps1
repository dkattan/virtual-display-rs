# Test-WakeViaHelper.ps1 — Wake display via multiple approaches from Session 0
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
    # Check idle
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public struct LI4 { public uint s; public uint t; } public class IC4 { [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LI4 p); [DllImport("kernel32.dll")] public static extern uint GetTickCount(); }' -ErrorAction SilentlyContinue
    $li = New-Object LI4; $li.s = 8; [IC4]::GetLastInputInfo([ref]$li) | Out-Null
    $idleSec = [Math]::Round(([IC4]::GetTickCount() - $li.t) / 1000, 0)
    Write-Host "Pre-wake idle: ${idleSec}s ($([Math]::Round($idleSec/60,1))min)"

    # Disable monitor timeout to prevent re-sleep
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0

    # Write wake helper script to a file
    # Use base64-encoded script content to avoid quoting issues
    $wakeScriptContent = @'
try {
    $log = "START $(Get-Date -Format o)`n"
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Wake2 {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int cbSize);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint f);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}
"@
    $log += "Types loaded`n"

    # SC_MONITORPOWER -1 = ON
    $r1 = [Wake2]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr](-1))
    $log += "SendMessage SC_MONITORPOWER: $r1`n"

    # SendInput mouse move
    $inputs = [Wake2+INPUT[]]::new(1)
    $inputs[0] = New-Object Wake2+INPUT
    $inputs[0].type = 0  # INPUT_MOUSE
    $inputs[0].mi = New-Object Wake2+MOUSEINPUT
    $inputs[0].mi.dx = 1
    $inputs[0].mi.dy = 1
    $inputs[0].mi.dwFlags = 0x0001  # MOUSEEVENTF_MOVE
    $r2 = [Wake2]::SendInput(1, $inputs, [Runtime.InteropServices.Marshal]::SizeOf([Wake2+INPUT]))
    $err2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $log += "SendInput: sent=$r2 err=$err2`n"

    # Prevent re-sleep
    $r3 = [Wake2]::SetThreadExecutionState(0x80000003)
    $log += "SetThreadExecutionState: $r3`n"

    $log += "DONE $(Get-Date -Format o)"
    [IO.File]::WriteAllText('C:\Windows\Temp\VDD_wake_result.txt', $log)
} catch {
    [IO.File]::WriteAllText('C:\Windows\Temp\VDD_wake_result.txt', "ERROR: $_")
}
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wakeScriptContent))
    # Write a launcher that decodes and runs the script
    Set-Content 'C:\Windows\Temp\VDD_wake.ps1' "powershell.exe -NoProfile -EncodedCommand $encoded" -Encoding ASCII
    # Actually, just write the script directly since we're in System context where here-strings work fine
    Set-Content 'C:\Windows\Temp\VDD_wake.ps1' $wakeScriptContent -Encoding UTF8
    Write-Host "Wake script written ($($wakeScriptContent.Length) chars)"

    # Get interactive session
    $sessionId = (query user 2>&1 | Select-String 'console' | ForEach-Object { ($_ -replace '\s{2,}', '|' -split '\|')[2].Trim() }) | Select-Object -First 1
    Write-Host "Console session: $sessionId"

    # Remove old result
    Remove-Item 'C:\Windows\Temp\VDD_wake_result.txt' -Force -ErrorAction SilentlyContinue

    # --- Approach A: CreateProcessAsUser via WTSQueryUserToken ---
    Write-Host "Trying CreateProcessAsUser..."
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SessionHelper {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSQueryUserToken(uint SessionId, out IntPtr Token);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess,
        IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName,
        string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("userenv.dll", SetLastError = true)]
    public static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

    [DllImport("userenv.dll")]
    public static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }
}
"@ -ErrorAction SilentlyContinue

    $consoleSessionId = [SessionHelper]::WTSGetActiveConsoleSessionId()
    Write-Host "Active console session: $consoleSessionId"

    $userToken = [IntPtr]::Zero
    $ok = [SessionHelper]::WTSQueryUserToken($consoleSessionId, [ref]$userToken)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "WTSQueryUserToken: ok=$ok err=$err token=$userToken"

    if ($ok -and $userToken -ne [IntPtr]::Zero) {
        $dupToken = [IntPtr]::Zero
        $ok2 = [SessionHelper]::DuplicateTokenEx($userToken, 0x02000000, [IntPtr]::Zero, 2, 1, [ref]$dupToken)
        Write-Host "DuplicateTokenEx: ok=$ok2 dupToken=$dupToken"

        $envBlock = [IntPtr]::Zero
        [SessionHelper]::CreateEnvironmentBlock([ref]$envBlock, $dupToken, $false) | Out-Null

        $si = New-Object SessionHelper+STARTUPINFO
        $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
        $si.lpDesktop = "winsta0\default"

        $pi = New-Object SessionHelper+PROCESS_INFORMATION

        $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $cmdLine = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\VDD_wake.ps1"
        Write-Host "Launching: $cmdLine"
        $ok3 = [SessionHelper]::CreateProcessAsUser(
            $dupToken,
            $psExe,
            $cmdLine,
            [IntPtr]::Zero, [IntPtr]::Zero, $false,
            0x00000400 -bor 0x00000010,  # CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW
            $envBlock,
            "C:\Windows\Temp",
            [ref]$si, [ref]$pi
        )
        $err3 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host "CreateProcessAsUser: ok=$ok3 err=$err3 pid=$($pi.dwProcessId)"

        if ($ok3) {
            # Wait for helper to finish (max 15s)
            [SessionHelper]::WaitForSingleObject($pi.hProcess, 15000) | Out-Null
            [SessionHelper]::CloseHandle($pi.hProcess) | Out-Null
            [SessionHelper]::CloseHandle($pi.hThread) | Out-Null
        }

        if ($envBlock -ne [IntPtr]::Zero) { [SessionHelper]::DestroyEnvironmentBlock($envBlock) | Out-Null }
        [SessionHelper]::CloseHandle($dupToken) | Out-Null
        [SessionHelper]::CloseHandle($userToken) | Out-Null
    } else {
        Write-Host "WTSQueryUserToken failed, falling back to schtasks /IT"
        schtasks /delete /tn "VDD_Wake" /f 2>$null
        schtasks /create /tn "VDD_Wake" /tr "powershell.exe -NoProfile -File C:\Windows\Temp\VDD_wake.ps1" /sc once /st 00:00 /ru administrator /it /f 2>&1
        schtasks /run /tn "VDD_Wake" 2>&1
        Start-Sleep -Seconds 10
        schtasks /delete /tn "VDD_Wake" /f 2>$null
    }

    Start-Sleep -Seconds 3

    # Check result
    if (Test-Path 'C:\Windows\Temp\VDD_wake_result.txt') {
        $result = Get-Content 'C:\Windows\Temp\VDD_wake_result.txt' -Raw
        Write-Host "Wake result: $result"
    } else {
        Write-Host "No wake result file"
    }

    # Check idle time after wake
    [IC4]::GetLastInputInfo([ref]$li) | Out-Null
    $idleSec2 = [Math]::Round(([IC4]::GetTickCount() - $li.t) / 1000, 0)
    Write-Host "Post-wake idle: ${idleSec2}s ($([Math]::Round($idleSec2/60,1))min)"

    if ($idleSec2 -lt $idleSec) {
        Write-Host "IDLE RESET - display wake WORKED!"
    } else {
        Write-Host "Idle unchanged - wake may not have worked"
    }

    # Cleanup
    Remove-Item 'C:\Windows\Temp\VDD_wake.ps1' -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\VDD_wake_result.txt' -Force -ErrorAction SilentlyContinue
    powercfg /change monitor-timeout-ac 5
    powercfg /change monitor-timeout-dc 3

    Write-Host "WAKE_TEST_DONE"
}
'@

$output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($script))
Write-Host $output
