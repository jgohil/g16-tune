# lib/Diagnose.ps1 - "what has this laptop been doing?" as a readable report.
# Collects the things that explained a hot, noisy idle on a G16: no real sleep, screen-off sessions that
# never slept, G-Helper's actual state (not what you think you set), startup load, background services,
# and the Windows settings that matter for gaming. Writes markdown to $env:LOCALAPPDATA\G16Tune\reports.

function Invoke-G16Diagnose {
    param([switch]$Quiet)
    $out = New-Object System.Collections.Generic.List[string]
    function Add([string]$s) { $out.Add($s) }
    function H2([string]$s) { Add ''; Add "## $s"; Add '' }
    function Row([string]$k, $v) { Add ("- **{0}:** {1}" -f $k, $v) }

    $dir = Join-Path $env:LOCALAPPDATA 'G16Tune\reports'; New-Item -ItemType Directory -Force $dir | Out-Null
    $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem; $cpu = Get-CimInstance Win32_Processor
    Add "# G16 Tune diagnose - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    H2 'Machine'
    Row 'Model' "$($cs.Manufacturer) $($cs.Model)"
    Row 'CPU' $cpu.Name
    Get-CimInstance Win32_VideoController | ForEach-Object { Row 'GPU' "$($_.Name) (driver $($_.DriverVersion))" }
    $bios = Get-CimInstance Win32_BIOS; Row 'BIOS' "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('yyyy-MM-dd')))"
    Row 'Uptime' ("{0:N1} hours" -f ((Get-Date) - $os.LastBootUpTime).TotalHours)
    Row 'Windows' "$($os.Caption) $($os.Version)"

    H2 'Power and sleep'
    try {
        # powercfg prints "Current AC Power Setting Index: 0x00000000"; the label is English-only, so fall back gracefully.
        $acSleep = (powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC').ToString() -replace '.*: ',''
        $acDisp  = (powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Current AC').ToString() -replace '.*: ',''
        $sleepS = [convert]::ToInt32($acSleep, 16); $dispS = [convert]::ToInt32($acDisp, 16)
        Row 'Sleep after (plugged in)' $(if ($sleepS -eq 0) { 'Never - the machine stays fully on with the screen off' } else { "$($sleepS/60) min" })
        Row 'Screen off after (plugged in)' "$($dispS/60) min"
    } catch { Row 'Sleep / screen-off timers' 'could not parse powercfg output (non-English Windows?) - check Settings > System > Power' }
    Row 'Sleep states' ((powercfg /a | Select-String 'S0 Low Power Idle|Hibernate' | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -notmatch 'disabled when' }) -join '; ')
    $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=507; StartTime=(Get-Date).AddDays(-3)} -ErrorAction SilentlyContinue | Select-Object -First 8
    if ($ev) {
        Add ''; Add 'Recent screen-off sessions (from Kernel-Power 507 exit events):'; Add ''
        Add '| Screen on at | Screen was off for | Actually slept? | Time fully awake |'; Add '|---|---|---|---|'
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
            $off = [math]::Round([double]$d['ScreenOffDurationInUs'] / 3600e6, 1)
            $slept = if ($d['SleepEntered'] -eq 'true') { 'yes' } else { 'no' }
            $act = if ($d['DurationInUs']) { [math]::Round([double]$d['ActiveResidencyInUs'] / [double]$d['DurationInUs'] * 100) } else { '?' }
            Add ("| {0} | {1} h | {2} | {3}% |" -f $e.TimeCreated.ToString('MM-dd HH:mm'), $off, $slept, $act)
        }
        Add ''; Add '"Actually slept: no" with 100% fully awake means the system never entered a low-power state: whatever was running kept running the whole time the screen was off.'
    }

    H2 'G-Helper'
    $gh = Get-Process GHelper -ErrorAction SilentlyContinue
    $cfgPath = Join-Path $env:APPDATA 'GHelper\config.json'
    Row 'Running' $(if ($gh) { "yes (since $($gh.StartTime))" } else { 'NO' })
    if (Test-Path $cfgPath) {
        $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $modeName = @{ 0 = 'Balanced'; 1 = 'Turbo'; 2 = 'Silent' }
        $gpuName  = @{ 0 = 'Eco'; 1 = 'Standard'; 2 = 'Ultimate (MUX: dGPU always on)'; 3 = 'Optimized' }
        Row 'Mode G-Helper last set' $modeName[[int]$c.performance_mode]
        Row 'Mode when plugged in / on battery' "$($modeName[[int]$c.performance_1]) / $($modeName[[int]$c.performance_0])"
        Row 'GPU mode' $gpuName[[int]$c.gpu_mode]
        Row 'Charge limit' "$($c.charge_limit)%"
        foreach ($m in 0,1,2) {
            $fansOn = ($c."auto_apply_$m" -eq 1); $powerOn = ($c."auto_apply_power_$m" -eq 1)
            $line = "$($modeName[$m]): custom fan curve " + $(if ($fansOn) { 'APPLIED' } else { 'saved but NOT applied (stock ASUS curve in use)' })
            $line += '; custom power limits ' + $(if ($powerOn) { "APPLIED (PL1 $($c."limit_slow_$m") W)" } else { 'not applied' })
            if ($c."auto_boost_$m" -ne $null) { $line += "; CPU boost setting $($c."auto_boost_$m")" }
            if ($c."gpu_temp_$m") { $line += "; GPU temp target $($c."gpu_temp_$m")C" }
            if ($c."gpu_core_$m" -or $c."gpu_memory_$m") { $line += "; GPU offsets +$($c."gpu_core_$m")/+$($c."gpu_memory_$m")" }
            Row 'Profile' $line
            if ($fansOn -and $c."fan_profile_cpu_$m") {
                $pts = ConvertFrom-G16Curve $c."fan_profile_cpu_$m"; Add ("  - CPU curve: " + (($pts | ForEach-Object { "$($_.Temp)C=$($_.Percent)%" }) -join ' '))
                $pts = ConvertFrom-G16Curve $c."fan_profile_gpu_$m"; Add ("  - GPU curve: " + (($pts | ForEach-Object { "$($_.Temp)C=$($_.Percent)%" }) -join ' '))
            }
        }
    } else { Row 'Config' 'not found - is G-Helper installed?' }
    $ac = @(Get-Service | Where-Object { $_.Name -match '^(ArmouryCrate|ASUSOptimization|AsusAppService|ASUSSystem|ASUSSwitch|ASUSSoftwareManager|AsusCertService)' })
    $acRunning = @($ac | Where-Object Status -eq 'Running')
    Row 'Armoury Crate services' $(if ($ac.Count -eq 0) { 'none installed' } elseif ($acRunning.Count -eq 0) { "$($ac.Count) present, all stopped/disabled (good with G-Helper)" } else { "$($acRunning.Count) RUNNING - they fight G-Helper; use G-Helper > Extra > Services to stop them" })

    H2 'Right now'
    try {
        $s = Get-G16Snapshot
        Row 'CPU' "$($s.CpuC)C, fan $($s.CpuFan) rpm, average clock $($s.CpuClk)% of base"
        Row 'GPU' "$($s.GpuC)C, fan $($s.GpuFan) rpm, $($s.GpuW) W, $($s.GpuMHz) MHz"
        Row 'Windows power mode' $s.Overlay
        Row 'CPU load' "$($cpu.LoadPercentage)%"
    } catch { Row 'Sensors' "unavailable: $($_.Exception.Message)" }

    H2 'Startup programs'
    $approved = @{}
    foreach ($k in 'Run','Run32','StartupFolder') { $p = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$k" -ErrorAction SilentlyContinue; if ($p) { $p.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { $approved[$_.Name] = $_.Value[0] } } }
    foreach ($k in 'Run','Run32') { $p = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$k" -ErrorAction SilentlyContinue; if ($p) { $p.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { $approved[$_.Name] = $_.Value[0] } } }
    $runKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    foreach ($rk in $runKeys) { $p = Get-ItemProperty $rk -ErrorAction SilentlyContinue; if ($p) { $p.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object {
        $state = if ($approved.ContainsKey($_.Name) -and ($approved[$_.Name] -band 1)) { 'disabled' } else { 'ENABLED' }
        Add ("- {0,-8} {1}" -f $state, $_.Name) } } }
    Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | ForEach-Object {
        $state = if ($approved.ContainsKey($_.Name) -and ($approved[$_.Name] -band 1)) { 'disabled' } else { 'ENABLED' }
        Add ("- {0,-8} {1} (Startup folder)" -f $state, $_.Name) }

    H2 'Third-party services running or set to automatic'
    Get-CimInstance Win32_Service | Where-Object { ($_.State -eq 'Running' -or $_.StartMode -eq 'Auto') -and $_.PathName -notmatch 'Windows\\|System32|Microsoft' } |
        Sort-Object Name | ForEach-Object { Add ("- {0,-8} {1,-5} {2}" -f $_.State, $_.StartMode, $_.DisplayName) }

    H2 'Top CPU consumers since boot'
    Get-Process | Where-Object { $_.CPU -gt 0 } | Sort-Object CPU -Descending | Select-Object -First 12 | ForEach-Object {
        Add ("- {0,-32} {1,8:N0} CPU-seconds" -f $_.Name, $_.CPU) }

    H2 'Gaming-relevant Windows settings'
    $vbs = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue).SecurityServicesRunning
    Row 'Memory Integrity (HVCI)' $(if ($vbs -contains 2) { 'ON - widely reported to cost a few percent in games; it is a security feature, so decide for yourself (Windows Security > Core isolation)' } else { 'off' })
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode
    Row 'Hardware GPU scheduling' $(if ($hags -eq 1) { 'OFF' } else { 'on (default)' })
    Row 'Game Bar capture' $(if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -ErrorAction SilentlyContinue).AppCaptureEnabled -eq 0) { 'off' } else { 'on' })
    Get-CimInstance Win32_Volume | Where-Object DriveLetter | ForEach-Object { Row "Search indexing on $($_.DriveLetter.TrimEnd(':'))" $(if ($_.IndexingEnabled) { 'ON' } else { 'off' }) }
    $do = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue).DODownloadMode
    Row 'Delivery Optimization peering' $(if ($do -eq 0) { 'off (policy)' } else { 'not disabled by policy (default shares Windows updates with other PCs; check Settings > Windows Update > Advanced > Delivery Optimization)' })
    Row 'Edge Game Assist' $(if (Get-Process EdgeGameAssist -ErrorAction SilentlyContinue) { 'running' } else { 'not running' })
    Row 'NVIDIA app overlay' $(if (Get-Process 'NVIDIA Overlay' -ErrorAction SilentlyContinue) { 'running' } else { 'not running' })

    $file = Join-Path $dir ("diagnose-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    $out | Set-Content $file -Encoding UTF8
    if (-not $Quiet) { $out | ForEach-Object { Write-Host $_ } }
    Write-Host "`nSaved: $file" -ForegroundColor Green
    return $file
}
