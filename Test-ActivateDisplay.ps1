# Test-ActivateDisplay.ps1 — Add virtual monitor, activate it in display topology, start recording
param(
    [int] $ComputerId = 20374,
    [int] $TenantId = 425
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ImmyBot-Authentication-Package\scripts\functions\public\ImmyBotHelpers.ps1"

$immyBaseUrl = Get-ImmyBaseUrlFromEnvironment
$bearerToken = Get-ImmyBotAccessTokenFromEnvironment -BaseUrl $immyBaseUrl
Write-Host "Auth OK" -ForegroundColor Green

# Step 1: Clear log, add monitor
Write-Host "`n== STEP 1: CLEAR LOG & ADD MONITOR ==" -ForegroundColor Cyan

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
    Write-Host "Monitor added"
    $writer.Dispose()
    $pipe.Dispose()
    Start-Sleep -Seconds 3
    Write-Host "STEP1_DONE"
}
'@

$step1Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step1Script))
Write-Host $step1Output

# Step 2: Activate the virtual display from user session using CCD API
Write-Host "`n== STEP 2: ACTIVATE VIRTUAL DISPLAY (CurrentUser) ==" -ForegroundColor Cyan

$step2Script = @'
Invoke-ImmyCommand -ContextString 'CurrentUser' {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class CCD {
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

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_SAVE_TO_DATABASE = 0x00000200;
    public const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const uint SDC_TOPOLOGY_CLONE = 0x00000002;
    public const uint SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;

    // Path flags
    public const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
}
"@ -ErrorAction SilentlyContinue

    # First query current active topology
    $np = [uint32]0; $nm = [uint32]0
    $r = [CCD]::GetDisplayConfigBufferSizes([CCD]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm)
    Write-Host "Current active: $np paths, $nm modes"

    if ($np -gt 0) {
        $paths = [CCD+DISPLAYCONFIG_PATH_INFO[]]::new($np)
        $modes = [CCD+DISPLAYCONFIG_MODE_INFO[]]::new($nm)
        $r = [CCD]::QueryDisplayConfig([CCD]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero)
        Write-Host "QueryDisplayConfig (active): result=$r"
        for ($i = 0; $i -lt $np; $i++) {
            Write-Host "  Active[$i]: src(adapter=$($paths[$i].sourceInfo.adapterId.LowPart):$($paths[$i].sourceInfo.adapterId.HighPart) id=$($paths[$i].sourceInfo.id)) -> tgt(adapter=$($paths[$i].targetInfo.adapterId.LowPart):$($paths[$i].targetInfo.adapterId.HighPart) id=$($paths[$i].targetInfo.id) tech=$($paths[$i].targetInfo.outputTechnology)) flags=0x$($paths[$i].flags.ToString('X'))"
        }
    }

    # Query ALL paths to find our virtual display
    $npa = [uint32]0; $nma = [uint32]0
    $r = [CCD]::GetDisplayConfigBufferSizes([CCD]::QDC_ALL_PATHS, [ref]$npa, [ref]$nma)
    Write-Host "`nAll paths: $npa paths, $nma modes"

    $allPaths = [CCD+DISPLAYCONFIG_PATH_INFO[]]::new($npa)
    $allModes = [CCD+DISPLAYCONFIG_MODE_INFO[]]::new($nma)
    $r = [CCD]::QueryDisplayConfig([CCD]::QDC_ALL_PATHS, [ref]$npa, $allPaths, [ref]$nma, $allModes, [IntPtr]::Zero)
    Write-Host "QueryDisplayConfig (all): result=$r"

    # Find inactive paths (potential virtual display paths)
    $vddPaths = @()
    for ($i = 0; $i -lt $npa; $i++) {
        $p = $allPaths[$i]
        $isActive = ($p.flags -band [CCD]::DISPLAYCONFIG_PATH_ACTIVE) -ne 0
        # HDMI output technology = 5
        if ($p.targetInfo.outputTechnology -eq 5 -and -not $isActive -and $p.targetInfo.targetAvailable) {
            $vddPaths += @{ Index = $i; Path = $p }
            Write-Host "  INACTIVE HDMI path[$i]: src.adapter=$($p.sourceInfo.adapterId.LowPart):$($p.sourceInfo.adapterId.HighPart) src.id=$($p.sourceInfo.id) tgt.id=$($p.targetInfo.id) available=$($p.targetInfo.targetAvailable)"
        }
    }
    Write-Host "Found $($vddPaths.Count) inactive HDMI paths (potential VDD)"

    # Build new config: current active paths + first inactive VDD path
    if ($vddPaths.Count -gt 0) {
        # Method: Use SDC_TOPOLOGY_EXTEND which should include all available displays
        # But first let me try the simpler approach: just apply with all paths including the VDD one activated

        # Actually, let's use the simplest approach: enable ONE specific path
        $vddPath = $vddPaths[0].Path
        $vddPath.flags = $vddPath.flags -bor [CCD]::DISPLAYCONFIG_PATH_ACTIVE

        # Combine active paths + our newly activated VDD path
        $newPaths = [CCD+DISPLAYCONFIG_PATH_INFO[]]::new($np + 1)
        for ($i = 0; $i -lt $np; $i++) { $newPaths[$i] = $paths[$i] }
        $newPaths[$np] = $vddPath

        Write-Host "`nApplying config with $($np + 1) paths..."
        $setResult = [CCD]::SetDisplayConfig(
            [uint32]($np + 1),
            $newPaths,
            0,
            $null,
            [CCD]::SDC_APPLY -bor [CCD]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [CCD]::SDC_ALLOW_CHANGES -bor [CCD]::SDC_SAVE_TO_DATABASE
        )
        Write-Host "SetDisplayConfig result: $setResult"

        if ($setResult -ne 0) {
            # Try without SDC_SAVE_TO_DATABASE
            Write-Host "Retrying without SAVE_TO_DATABASE..."
            $setResult2 = [CCD]::SetDisplayConfig(
                [uint32]($np + 1),
                $newPaths,
                0,
                $null,
                [CCD]::SDC_APPLY -bor [CCD]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [CCD]::SDC_ALLOW_CHANGES
            )
            Write-Host "SetDisplayConfig result (retry): $setResult2"

            if ($setResult2 -ne 0) {
                # Try with topology extend and path persist
                Write-Host "Trying SDC_TOPOLOGY_EXTEND | SDC_PATH_PERSIST_IF_REQUIRED..."
                $setResult3 = [CCD]::SetDisplayConfig(
                    0,
                    $null,
                    0,
                    $null,
                    [CCD]::SDC_APPLY -bor [CCD]::SDC_TOPOLOGY_EXTEND -bor [CCD]::SDC_PATH_PERSIST_IF_REQUIRED
                )
                Write-Host "SetDisplayConfig result (extend+persist): $setResult3"
            }
        }

        Start-Sleep -Seconds 5

        # Recheck
        $np2 = [uint32]0; $nm2 = [uint32]0
        [CCD]::GetDisplayConfigBufferSizes([CCD]::QDC_ONLY_ACTIVE_PATHS, [ref]$np2, [ref]$nm2) | Out-Null
        Write-Host "`nAfter apply: $np2 active paths"
    } else {
        Write-Host "No inactive HDMI paths found to activate"
    }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        Write-Host "  Screen: $($_.DeviceName) $($_.Bounds) Primary=$($_.Primary)"
    }

    Write-Host "STEP2_DONE"
}
'@

$step2Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 60 `
    -ScriptBlock ([ScriptBlock]::Create($step2Script))
Write-Host $step2Output

# Wait for swap chain
Write-Host "  Waiting 10s for swap chain..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Step 3: Check trace log for assign_swap_chain
Write-Host "`n== STEP 3: CHECK TRACE LOG ==" -ForegroundColor Cyan

$step3Script = @'
Invoke-ImmyCommand -ContextString 'System' {
    $logPath = 'C:\Windows\Temp\VDD_trace.log'
    if (Test-Path $logPath) {
        Write-Host "=== TRACE LOG ==="
        Get-Content $logPath -Raw
    }
    Write-Host "STEP3_DONE"
}
'@

$step3Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step3Script))
Write-Host $step3Output

# Step 4: Cleanup
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
    Write-Host "Cleanup done"
}
'@

$step4Output = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 30 `
    -ScriptBlock ([ScriptBlock]::Create($step4Script))
Write-Host $step4Output

Write-Host "`n== TEST COMPLETE ==" -ForegroundColor Green
