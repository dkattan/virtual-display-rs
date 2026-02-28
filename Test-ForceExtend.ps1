# Test-ForceExtend.ps1 — Fresh deploy, add monitor, force extend with displayswitch
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Remove any existing monitors and clear log
Write-Host "`n== STEP 1: CLEANUP & FRESH START ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force; Write-Host "Cleared trace log" }

    $pipeName = 'virtualdisplaydriver'
    $EOF = [char]0x04
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.Write('"RemoveAll"' + $EOF)
        $writer.Flush()
        $pipe.WaitForPipeDrain()
        $writer.Dispose()
        $pipe.Dispose()
        Write-Host "RemoveAll sent"
    } catch {
        Write-Host "No existing monitors to remove: $_"
    }

    Start-Sleep -Seconds 3
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: Add monitor
Write-Host "`n== STEP 2: ADD MONITOR ==" -ForegroundColor Cyan

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
    Write-Host "Monitor added via Notify"
    $writer.Dispose()
    $pipe.Dispose()

    Start-Sleep -Seconds 3

    Get-CimInstance Win32_DesktopMonitor | ForEach-Object {
        Write-Host "  Monitor: $($_.Name) Active=$($_.Availability) Status=$($_.Status)"
    }
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Host "  Video: $($_.Name) $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) Status=$($_.Status)"
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Step 3: Force extend from CurrentUser with displayswitch
Write-Host "`n== STEP 3: FORCE EXTEND FROM USER SESSION ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    # Check current displays from user perspective
    Add-Type -AssemblyName System.Windows.Forms
    Write-Host "Before extend:"
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "  $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }

    # Try displayswitch /extend
    Write-Host "Running displayswitch.exe /extend..."
    $p = Start-Process -FilePath "displayswitch.exe" -ArgumentList "/extend" -Wait -PassThru -NoNewWindow
    Write-Host "  Exit code: $($p.ExitCode)"

    Start-Sleep -Seconds 5

    Write-Host "After extend:"
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "  $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }

    # Also try ChangeDisplaySettingsEx to explicitly activate
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DispSettings {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE dd, uint flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    public const int DISPLAY_DEVICE_ACTIVE = 0x00000001;
    public const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
}
"@ -ErrorAction SilentlyContinue

    # Enumerate all display devices
    Write-Host "`nAll display devices:"
    $devIdx = 0
    while ($true) {
        $dd = New-Object DispSettings+DISPLAY_DEVICE
        $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
        $found = [DispSettings]::EnumDisplayDevices($null, $devIdx, [ref]$dd, 0)
        if (-not $found) { break }
        $active = ($dd.StateFlags -band [DispSettings]::DISPLAY_DEVICE_ACTIVE) -ne 0
        Write-Host "  [$devIdx] $($dd.DeviceName): $($dd.DeviceString) Active=$active Flags=0x$($dd.StateFlags.ToString('X8'))"
        Write-Host "       ID=$($dd.DeviceID)"
        $devIdx++
    }

    Write-Host "STEP3_DONE"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

# Wait for things to settle
Write-Host "  Waiting 10s..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Step 4: Check trace log
Write-Host "`n== STEP 4: CHECK TRACE LOG ==" -ForegroundColor Cyan

$step4Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "NO TRACE LOG"
    }
    Write-Host "CHECK_DONE"
}
'@

$step4Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step4Script))
Write-Host $step4Output

# Step 5: Cleanup
Write-Host "`n== STEP 5: CLEANUP ==" -ForegroundColor Cyan

$step5Script = @'
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

$step5Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step5Script))
Write-Host $step5Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
