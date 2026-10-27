# lib/Asus.Acpi.ps1 - talk to the ASUS ACPI driver the same way G-Helper does.
# Works without admin on the ROG Zephyrus G16 (2024, GU605). Dot-source this file.

if (-not ([System.Management.Automation.PSTypeName]'G16Acpi').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class G16Acpi {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, IntPtr overlapped);
    const uint CTRL = 0x0022240C, DSTS = 0x53545344, DEVS = 0x53564544;
    static byte[] Call(uint method, byte[] args) {
        using (var h = CreateFile(@"\\.\ATKACPI", 0xC0000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero)) {
            if (h.IsInvalid) throw new Exception("Cannot open \\\\.\\ATKACPI (Win32 error " + Marshal.GetLastWin32Error() + "). Is the ASUS System Control Interface driver installed?");
            byte[] inb = new byte[8 + args.Length];
            BitConverter.GetBytes(method).CopyTo(inb, 0);
            BitConverter.GetBytes((uint)args.Length).CopyTo(inb, 4);
            Array.Copy(args, 0, inb, 8, args.Length);
            byte[] outb = new byte[20]; uint ret;
            if (!DeviceIoControl(h, CTRL, inb, (uint)inb.Length, outb, (uint)outb.Length, out ret, IntPtr.Zero))
                throw new Exception("DeviceIoControl failed (Win32 error " + Marshal.GetLastWin32Error() + ")");
            return outb;
        }
    }
    public static uint Get(uint dev) { byte[] a = new byte[8]; BitConverter.GetBytes(dev).CopyTo(a, 0); return BitConverter.ToUInt32(Call(DSTS, a), 0); }
    public static uint Set(uint dev, uint val) { byte[] a = new byte[8]; BitConverter.GetBytes(dev).CopyTo(a, 0); BitConverter.GetBytes(val).CopyTo(a, 4); return BitConverter.ToUInt32(Call(DEVS, a), 0); }
    public static uint SetBytes(uint dev, byte[] data) { byte[] a = new byte[4 + data.Length]; BitConverter.GetBytes(dev).CopyTo(a, 0); data.CopyTo(a, 4); return BitConverter.ToUInt32(Call(DEVS, a), 0); }
}
'@
}

# Device ids (from G-Helper's AsusACPI.cs)
$script:G16Dev = @{
    PerformanceMode = [uint32]0x00120075   # DEVS value: 0 Balanced, 1 Turbo, 2 Silent. DSTS of it is NOT the current mode.
    FanCpu          = [uint32]0x00110013   # DSTS -> 0x10000 + rpm/100
    FanGpu          = [uint32]0x00110014
    FanCurveCpu     = [uint32]0x00110024   # DEVS with 16 bytes: 8 temps then 8 fan percents
    FanCurveGpu     = [uint32]0x00110025
}

$script:G16Overlay = @{
    efficiency  = '961cc777-2547-4f9d-8174-7d86181b8a7a'
    balanced    = '00000000-0000-0000-0000-000000000000'
    performance = 'ded574b5-45a0-4f42-8737-46345c09c238'
}

function Test-G16Acpi {
    <# Returns $true when the ASUS ACPI device answers. #>
    try { [void][G16Acpi]::Get($script:G16Dev.FanCpu); return $true } catch { return $false }
}

function Get-G16FanRpm {
    <# CPU and GPU fan speed in rpm. #>
    [pscustomobject]@{
        Cpu = ([G16Acpi]::Get($script:G16Dev.FanCpu) - 0x10000) * 100
        Gpu = ([G16Acpi]::Get($script:G16Dev.FanGpu) - 0x10000) * 100
    }
}

function Set-G16PerformanceMode {
    <# Switches the firmware performance preset (fans + power limits) like G-Helper's Silent/Balanced/Turbo buttons.
       G-Helper's own custom curves/limits are only re-applied by G-Helper itself (on screen-on, mode click, start). #>
    param([Parameter(Mandatory)][ValidateSet('silent','balanced','turbo')][string]$Mode)
    $policy = @{ balanced = 0; turbo = 1; silent = 2 }[$Mode]
    $r = [G16Acpi]::Set($script:G16Dev.PerformanceMode, [uint32]$policy)
    if ($r -ne 1) { Write-Warning "Firmware returned $r for performance mode $Mode (1 = OK)" }
    return $r
}

function ConvertFrom-G16Curve {
    <# "1E-46-..-64" (16 hex bytes) -> array of @{Temp; Percent} #>
    param([Parameter(Mandatory)][string]$Hex)
    $b = $Hex -split '-' | ForEach-Object { [Convert]::ToInt32($_, 16) }
    if ($b.Count -ne 16) { throw "Fan curve must be 16 bytes, got $($b.Count)" }
    0..7 | ForEach-Object { [pscustomobject]@{ Temp = $b[$_]; Percent = $b[$_ + 8] } }
}

function ConvertTo-G16Curve {
    <# Points (array of @{Temp;Percent}) -> "1E-..." hex string that G-Helper stores. #>
    param([Parameter(Mandatory)]$Points)
    if ($Points.Count -ne 8) { throw 'A curve needs exactly 8 points' }
    $t = $Points | ForEach-Object { '{0:X2}' -f [int]$_.Temp }
    $p = $Points | ForEach-Object { '{0:X2}' -f [int]$_.Percent }
    ($t + $p) -join '-'
}

function Set-G16FanCurve {
    <# Writes a fan curve to the EC, exactly as G-Helper does. Any non-zero percent spins the fan at its
       minimum (~2000 rpm on the G16 2024); 0 means off. #>
    param([Parameter(Mandatory)][ValidateSet('cpu','gpu')][string]$Fan, [Parameter(Mandatory)][string]$Hex)
    $bytes = [byte[]]($Hex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $dev = if ($Fan -eq 'cpu') { $script:G16Dev.FanCurveCpu } else { $script:G16Dev.FanCurveGpu }
    [G16Acpi]::SetBytes($dev, $bytes)
}

function Get-G16CpuTemp {
    <# Windows thermal zone, the only CPU temperature readable without admin or a driver.
       Known quirk: it stops updating while the display is off. #>
    try {
        $k = (Get-Counter '\Thermal Zone Information(*)\High Precision Temperature' -ErrorAction Stop).CounterSamples |
             Where-Object { $_.CookedValue -gt 0 } | Sort-Object CookedValue -Descending | Select-Object -First 1
        if ($k) { return [math]::Round($k.CookedValue / 10 - 273.15) }
    } catch {}
    return $null
}

function Get-G16GpuInfo {
    <# Temperature, power and clock from nvidia-smi (ships with the NVIDIA driver). #>
    $smi = 'C:\Windows\System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { return $null }
    try {
        $g = (& $smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu --format=csv,noheader,nounits) -split ','
        [pscustomobject]@{ Temp = [int]$g[0].Trim(); Watts = [math]::Round([double]$g[1].Trim()); MHz = [int]$g[2].Trim(); Util = [int]$g[3].Trim() }
    } catch { $null }
}

function Get-G16CpuClock {
    <# Average clock across all logical processors as a percentage of the nominal frequency Windows reports.
       Multiply by Get-G16BaseMHz for MHz. On the Core Ultra 9 185H Windows reports 2000 MHz nominal, so 137% is ~2.7 GHz. #>
    try { [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue) } catch { $null }
}

function Get-G16BaseMHz {
    <# The nominal frequency the "% Processor Performance" counter is relative to: Windows' own "Processor Frequency"
       counter, falling back to the SMBIOS value, which can differ (2500 vs 2000 on this machine). #>
    if (-not $script:G16BaseMHz) {
        try { $script:G16BaseMHz = [int](Get-Counter '\Processor Information(_Total)\Processor Frequency' -ErrorAction Stop).CounterSamples[0].CookedValue } catch {}
        if (-not $script:G16BaseMHz) { $script:G16BaseMHz = [int](Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed }
    }
    $script:G16BaseMHz
}

function Get-G16PowerOverlay {
    $ov = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
    foreach ($k in $script:G16Overlay.Keys) { if ($script:G16Overlay[$k] -eq "$ov") { return $k } }
    return "$ov"
}

function Set-G16PowerOverlay {
    param([Parameter(Mandatory)][ValidateSet('efficiency','balanced','performance')][string]$Overlay)
    powercfg /overlaysetactive $script:G16Overlay[$Overlay] | Out-Null
}

function Get-G16Snapshot {
    <# One row of everything Measure logs. #>
    $fan = Get-G16FanRpm; $gpu = Get-G16GpuInfo; $clk = Get-G16CpuClock
    [pscustomobject]@{
        Time    = Get-Date -Format 'HH:mm:ss'
        CpuC    = Get-G16CpuTemp
        CpuFan  = $fan.Cpu
        CpuClk  = $clk
        CpuMHz  = if ($clk -ne $null) { [math]::Round($clk * (Get-G16BaseMHz) / 100) } else { $null }
        GpuC    = if ($gpu) { $gpu.Temp } else { $null }
        GpuFan  = $fan.Gpu
        GpuW    = if ($gpu) { $gpu.Watts } else { $null }
        GpuMHz  = if ($gpu) { $gpu.MHz } else { $null }
        Overlay = Get-G16PowerOverlay
    }
}
