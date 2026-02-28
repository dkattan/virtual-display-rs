# Test-ExplicitPathActivation.ps1 — Explicit CCD path activation with SDC_FORCE_MODE_ENUMERATION
# Uses QueryDisplayConfig(QDC_ALL_PATHS) to find the VDD, activates it, and applies.
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# =============================================================================
# STEP 1: Clear trace log and add monitor
# =============================================================================
Write-Host "`n== STEP 1: CLEAR LOG + ADD MONITOR ==" -ForegroundColor Cyan

$step1Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) { Remove-Item $logPath -Force }

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
    $writer.Dispose()
    $pipe.Dispose()
    Write-Host "Monitor added"
    Start-Sleep -Seconds 3

    if (Test-Path $logPath) {
        Get-Content $logPath -Raw
    }
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# =============================================================================
# STEP 2: Explicit path activation with full CCD API (CurrentUser)
# =============================================================================
Write-Host "`n== STEP 2: EXPLICIT PATH ACTIVATION ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class CCD2 {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 72)]
    public struct DISPLAYCONFIG_MODE_INFO {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public LUID adapterId;
    }

    // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
        public uint type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPaths,
        [In, Out] DISPLAYCONFIG_PATH_INFO[] paths, ref uint numModes,
        [In, Out] DISPLAYCONFIG_MODE_INFO[] modes, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths,
        [In] DISPLAYCONFIG_PATH_INFO[] paths, uint numModes,
        [In] DISPLAYCONFIG_MODE_INFO[] modes, uint flags);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME info);

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_NO_OPTIMIZATION = 0x00000100;
    public const uint SDC_FORCE_MODE_ENUMERATION = 0x00001000;
    public const uint SDC_SAVE_TO_DATABASE = 0x00000200;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;
    public const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    public const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
}
"@ -ErrorAction SilentlyContinue

    # Query ALL paths
    $npa = [uint32]0; $nma = [uint32]0
    $r = [CCD2]::GetDisplayConfigBufferSizes([CCD2]::QDC_ALL_PATHS, [ref]$npa, [ref]$nma)
    Write-Host "All paths: $npa paths, $nma modes (result=$r)"

    $allPaths = [CCD2+DISPLAYCONFIG_PATH_INFO[]]::new($npa)
    $allModes = [CCD2+DISPLAYCONFIG_MODE_INFO[]]::new($nma)
    $r = [CCD2]::QueryDisplayConfig([CCD2]::QDC_ALL_PATHS, [ref]$npa, $allPaths, [ref]$nma, $allModes, [IntPtr]::Zero)
    Write-Host "QueryDisplayConfig (all): result=$r, got $npa paths"

    # Also query active paths to know what's currently active
    $nActive = [uint32]0; $nmActive = [uint32]0
    [CCD2]::GetDisplayConfigBufferSizes([CCD2]::QDC_ONLY_ACTIVE_PATHS, [ref]$nActive, [ref]$nmActive) | Out-Null
    $activePaths = [CCD2+DISPLAYCONFIG_PATH_INFO[]]::new($nActive)
    $activeModes = [CCD2+DISPLAYCONFIG_MODE_INFO[]]::new($nmActive)
    [CCD2]::QueryDisplayConfig([CCD2]::QDC_ONLY_ACTIVE_PATHS, [ref]$nActive, $activePaths, [ref]$nmActive, $activeModes, [IntPtr]::Zero) | Out-Null
    Write-Host "Active paths: $nActive"

    # Dump all paths and identify VDD
    $vddIndex = -1
    for ($i = 0; $i -lt $npa; $i++) {
        $p = $allPaths[$i]
        $isActive = ($p.flags -band [CCD2]::DISPLAYCONFIG_PATH_ACTIVE) -ne 0
        # Try to get target name
        $targetName = ""
        try {
            $devInfo = New-Object CCD2+DISPLAYCONFIG_TARGET_DEVICE_NAME
            $devInfo.header.type = [CCD2]::DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            $devInfo.header.size = [System.Runtime.InteropServices.Marshal]::SizeOf($devInfo)
            $devInfo.header.adapterId = $p.targetInfo.adapterId
            $devInfo.header.id = $p.targetInfo.id
            $infoResult = [CCD2]::DisplayConfigGetDeviceInfo([ref]$devInfo)
            if ($infoResult -eq 0) {
                $targetName = $devInfo.monitorFriendlyDeviceName
            }
        } catch { }

        $tech = switch ($p.targetInfo.outputTechnology) {
            5 { "HDMI" }
            10 { "DP" }
            0x80000000 { "Internal" }
            default { "tech=$($p.targetInfo.outputTechnology)" }
        }

        if ($p.targetInfo.targetAvailable -and -not $isActive -and $p.targetInfo.outputTechnology -eq 5) {
            $vddIndex = $i
            Write-Host "  [$i] $tech active=$isActive available=$($p.targetInfo.targetAvailable) name='$targetName' src.adapter=$($p.sourceInfo.adapterId.LowPart):$($p.sourceInfo.adapterId.HighPart) tgt.id=$($p.targetInfo.id) <-- VDD CANDIDATE"
        } elseif ($isActive -or $p.targetInfo.targetAvailable) {
            Write-Host "  [$i] $tech active=$isActive available=$($p.targetInfo.targetAvailable) name='$targetName' src.adapter=$($p.sourceInfo.adapterId.LowPart):$($p.sourceInfo.adapterId.HighPart) tgt.id=$($p.targetInfo.id)"
        }
    }

    if ($vddIndex -lt 0) {
        # Maybe VDD is already active, check active paths for HDMI
        Write-Host "No inactive HDMI path found — VDD might already be active"
        for ($i = 0; $i -lt $nActive; $i++) {
            $p = $activePaths[$i]
            $tech = switch ($p.targetInfo.outputTechnology) {
                5 { "HDMI" }
                10 { "DP" }
                0x80000000 { "Internal" }
                default { "tech=$($p.targetInfo.outputTechnology)" }
            }
            Write-Host "  Active[$i]: $tech tgt.id=$($p.targetInfo.id)"
        }
        Write-Host "STEP2_ALREADY_ACTIVE"
        return
    }

    # Build new path array: all current active paths + VDD path activated
    $newPathCount = $nActive + 1
    $newPaths = [CCD2+DISPLAYCONFIG_PATH_INFO[]]::new($newPathCount)
    for ($i = 0; $i -lt $nActive; $i++) { $newPaths[$i] = $activePaths[$i] }
    $vddPath = $allPaths[$vddIndex]
    $vddPath.flags = $vddPath.flags -bor [CCD2]::DISPLAYCONFIG_PATH_ACTIVE
    $newPaths[$nActive] = $vddPath

    Write-Host "`nApplying $newPathCount paths with SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_NO_OPTIMIZATION..."

    # Try with SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_NO_OPTIMIZATION
    $flags = [CCD2]::SDC_APPLY -bor [CCD2]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [CCD2]::SDC_ALLOW_CHANGES -bor [CCD2]::SDC_NO_OPTIMIZATION
    $setResult = [CCD2]::SetDisplayConfig(
        [uint32]$newPathCount,
        $newPaths,
        0,
        $null,
        $flags
    )
    Write-Host "SetDisplayConfig result: $setResult"

    if ($setResult -ne 0) {
        # Try with FORCE_MODE_ENUMERATION
        Write-Host "Retrying with SDC_FORCE_MODE_ENUMERATION..."
        $flags2 = [CCD2]::SDC_APPLY -bor [CCD2]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [CCD2]::SDC_ALLOW_CHANGES -bor [CCD2]::SDC_FORCE_MODE_ENUMERATION
        $setResult2 = [CCD2]::SetDisplayConfig(
            [uint32]$newPathCount,
            $newPaths,
            0,
            $null,
            $flags2
        )
        Write-Host "SetDisplayConfig result (force enum): $setResult2"

        if ($setResult2 -ne 0) {
            # Try topology extend as fallback
            Write-Host "Trying SDC_TOPOLOGY_EXTEND..."
            $setResult3 = [CCD2]::SetDisplayConfig(
                0,
                $null,
                0,
                $null,
                [CCD2]::SDC_APPLY -bor [CCD2]::SDC_TOPOLOGY_EXTEND
            )
            Write-Host "SetDisplayConfig result (extend): $setResult3"
        }
    }

    Start-Sleep -Seconds 5

    # Re-check active paths
    $np2 = [uint32]0; $nm2 = [uint32]0
    [CCD2]::GetDisplayConfigBufferSizes([CCD2]::QDC_ONLY_ACTIVE_PATHS, [ref]$np2, [ref]$nm2) | Out-Null
    Write-Host "`nAfter apply: $np2 active paths"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "  Screen: $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }
    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 90 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Wait for IddCx
Write-Host "  Waiting 10s for IddCx..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# =============================================================================
# STEP 3: Check trace log
# =============================================================================
Write-Host "`n== STEP 3: CHECK TRACE LOG ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== FULL TRACE LOG ==="
        Get-Content $logPath -Raw
    } else {
        Write-Host "NO TRACE LOG"
    }
    Write-Host "STEP3_DONE"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

# =============================================================================
# STEP 4: Cleanup
# =============================================================================
Write-Host "`n== STEP 4: CLEANUP ==" -ForegroundColor Cyan

$step4Script = @'
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
    Write-Host "Cleaned up"
}
'@

$step4Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step4Script))
Write-Host $step4Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
