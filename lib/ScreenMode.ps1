# lib/ScreenMode.ps1 - Silent when the screen turns off, your own plugged-in mode when it turns on.
# Two scheduled tasks trigger on System log events Kernel-Power 506 (screen off) and 507 (screen on) and run a
# small script that switches the firmware preset and the Windows power mode, and applies G-Helper's fan curve for
# that mode if you have one. The On task reads your plugged-in mode from G-Helper's config at run time, so it
# follows whatever you set there. G-Helper restores that mode itself on screen-on anyway; the On task is a belt
# and braces. Install needs admin because the tasks run elevated.

$script:ScreenModeDir = Join-Path $env:ProgramData 'G16Tune'

$script:ScreenModeScript = @'
# Set-ScreenMode.ps1 - installed by G16 Tune. Triggered by Kernel-Power 506 (screen off) / 507 (screen on).
# -Mode auto means "the plugged-in mode saved in G-Helper's config" (Balanced if there is no config).
param([ValidateSet('silent','balanced','turbo','auto')][string]$Mode = 'auto')
$log = Join-Path $PSScriptRoot 'screenmode-log.txt'
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class G16AcpiTask {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, IntPtr overlapped);
    static byte[] Call(uint method, byte[] args) {
        using (var h = CreateFile(@"\\.\ATKACPI", 0xC0000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero)) {
            if (h.IsInvalid) throw new Exception("Cannot open ATKACPI");
            byte[] inb = new byte[8 + args.Length]; BitConverter.GetBytes(method).CopyTo(inb, 0); BitConverter.GetBytes((uint)args.Length).CopyTo(inb, 4); Array.Copy(args, 0, inb, 8, args.Length);
            byte[] outb = new byte[20]; uint ret; if (!DeviceIoControl(h, 0x0022240C, inb, (uint)inb.Length, outb, 20, out ret, IntPtr.Zero)) throw new Exception("DeviceIoControl failed"); return outb; } }
    public static uint Set(uint dev, uint val) { byte[] a = new byte[8]; BitConverter.GetBytes(dev).CopyTo(a, 0); BitConverter.GetBytes(val).CopyTo(a, 4); return BitConverter.ToUInt32(Call(0x53564544u, a), 0); }
    public static uint SetBytes(uint dev, byte[] d) { byte[] a = new byte[4 + d.Length]; BitConverter.GetBytes(dev).CopyTo(a, 0); d.CopyTo(a, 4); return BitConverter.ToUInt32(Call(0x53564544u, a), 0); }
}
"@
try {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($b -and $b.BatteryStatus -eq 1) { "$(Get-Date -Format s) $Mode skipped (on battery)" | Add-Content $log; exit 0 }
    $cfg = $null; $cfgPath = Join-Path $env:APPDATA 'GHelper\config.json'
    if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json }
    if ($Mode -eq 'auto') {
        $Mode = 'balanced'
        if ($cfg -and $cfg.performance_1 -ne $null) { $Mode = @{ '0' = 'balanced'; '1' = 'turbo'; '2' = 'silent' }["$($cfg.performance_1)"] }
        if (-not $Mode) { $Mode = 'balanced' }
    }
    $policy  = @{ silent = 2; balanced = 0; turbo = 1 }[$Mode]
    $overlay = @{ silent = '961cc777-2547-4f9d-8174-7d86181b8a7a'; balanced = '00000000-0000-0000-0000-000000000000'; turbo = 'ded574b5-45a0-4f42-8737-46345c09c238' }[$Mode]
    $r = [G16AcpiTask]::Set([uint32]0x00120075, [uint32]$policy)
    powercfg /overlaysetactive $overlay | Out-Null
    $note = 'stock fan curve'
    if ($cfg) {
        if ($cfg."auto_apply_$policy" -eq 1) {
            foreach ($pair in @(@{ K = "fan_profile_cpu_$policy"; D = [uint32]0x00110024 }, @{ K = "fan_profile_gpu_$policy"; D = [uint32]0x00110025 })) {
                $hex = $cfg.($pair.K)
                if ($hex -and $hex -match '^([0-9A-Fa-f]{2}-){15}[0-9A-Fa-f]{2}$') { [void][G16AcpiTask]::SetBytes($pair.D, [byte[]]($hex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) })) }
            }
            $note = 'G-Helper custom fan curve'
        }
    }
    "$(Get-Date -Format s) $Mode applied (result $r, $note)" | Add-Content $log
} catch { "$(Get-Date -Format s) $Mode FAILED: $($_.Exception.Message)" | Add-Content $log; exit 1 }
'@

function Install-G16ScreenMode {
    param([ValidateSet('silent','balanced','turbo')][string]$OffMode = 'silent', [ValidateSet('silent','balanced','turbo','auto')][string]$OnMode = 'auto')
    if (-not (Test-G16Admin)) { throw 'Install-G16ScreenMode needs an elevated PowerShell (the tasks run elevated).' }
    New-Item -ItemType Directory -Force $script:ScreenModeDir | Out-Null
    $target = Join-Path $script:ScreenModeDir 'Set-ScreenMode.ps1'
    $script:ScreenModeScript | Set-Content $target -Encoding UTF8
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -Hidden
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
    $cim = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler:MSFT_TaskEventTrigger
    foreach ($t in @(@{ Name = 'G16Tune-ScreenOff'; Id = 506; Mode = $OffMode }, @{ Name = 'G16Tune-ScreenOn'; Id = 507; Mode = $OnMode })) {
        $trig = New-CimInstance -CimClass $cim -ClientOnly
        $trig.Enabled = $true
        $trig.Subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=$($t.Id)]]</Select></Query></QueryList>"
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`" -Mode $($t.Mode)"
        $modeText = if ($t.Mode -eq 'auto') { 'your plugged-in mode from G-Helper' } else { $t.Mode }
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trig -Settings $settings -Principal $principal -Force -Description "G16 Tune: switch to $modeText when the screen turns $(if ($t.Id -eq 506) { 'off' } else { 'on' })." | Out-Null
        Write-Host "Registered $($t.Name) -> $modeText" -ForegroundColor Green
    }
    # self-test: fire both in order, so the machine ends up in the screen-on mode it is in right now anyway
    Remove-Item (Join-Path $script:ScreenModeDir 'screenmode-log.txt') -ErrorAction SilentlyContinue
    foreach ($n in 'G16Tune-ScreenOff','G16Tune-ScreenOn') { Start-ScheduledTask -TaskName $n; Start-Sleep 8; $i = Get-ScheduledTask -TaskName $n | Get-ScheduledTaskInfo; Write-Host ("  {0}: result 0x{1:X}" -f $n, $i.LastTaskResult) }
    Get-Content (Join-Path $script:ScreenModeDir 'screenmode-log.txt') -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "`nDone. Lock the screen or wait for the display timeout, then check $script:ScreenModeDir\screenmode-log.txt." -ForegroundColor Green
}

function Uninstall-G16ScreenMode {
    if (-not (Test-G16Admin)) { throw 'Uninstall-G16ScreenMode needs an elevated PowerShell.' }
    foreach ($n in 'G16Tune-ScreenOff','G16Tune-ScreenOn') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $script:ScreenModeDir 'Set-ScreenMode.ps1') -ErrorAction SilentlyContinue
    Write-Host 'Screen-mode tasks removed.' -ForegroundColor Green
}

function Test-G16Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
