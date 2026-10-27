# lib/Measure.ps1 - measure before you believe. Logger, fan-floor test, stress run, and A/B compare.
# All output goes to $env:LOCALAPPDATA\G16Tune\measure as CSV so two runs can be compared.

function Get-G16MeasureDir { $d = Join-Path $env:LOCALAPPDATA 'G16Tune\measure'; New-Item -ItemType Directory -Force $d | Out-Null; $d }

function Start-G16Log {
    <# Samples temps, fans, clocks every $Interval seconds for $Seconds. Run it while gaming.
       The CPU temperature stops updating while the display is off - only trust it with the screen on. #>
    param([int]$Seconds = 300, [int]$Interval = 10, [string]$Label = 'log')
    $file = Join-Path (Get-G16MeasureDir) ("{0}-{1}.csv" -f $Label, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    'Time,CpuC,CpuFan,CpuClk,CpuMHz,GpuC,GpuFan,GpuW,GpuMHz,Overlay' | Set-Content $file
    Write-Host 'Note: the Windows CPU temperature stops updating while the display is off. Only trust cpuC with the screen on.' -ForegroundColor Yellow
    Write-Host ("{0,-8} {1,5} {2,7} {3,7} {4,6} {5,5} {6,7} {7,5} {8,7}  {9}" -f 'time','cpuC','cpuFan','cpuClk%','cpuMHz','gpuC','gpuFan','gpuW','gpuMHz','overlay')
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $s = Get-G16Snapshot
        Write-Host ("{0,-8} {1,5} {2,7} {3,7} {4,6} {5,5} {6,7} {7,5} {8,7}  {9}" -f $s.Time,$s.CpuC,$s.CpuFan,$s.CpuClk,$s.CpuMHz,$s.GpuC,$s.GpuFan,$s.GpuW,$s.GpuMHz,$s.Overlay)
        "$($s.Time),$($s.CpuC),$($s.CpuFan),$($s.CpuClk),$($s.CpuMHz),$($s.GpuC),$($s.GpuFan),$($s.GpuW),$($s.GpuMHz),$($s.Overlay)" | Add-Content $file
        Start-Sleep -Seconds $Interval
    }
    Write-Host "Saved: $file" -ForegroundColor Green
    return $file
}

function Test-G16FanFloor {
    <# Answers "can the fans actually stop?" by writing a curve of 0% up to 98C for 60 seconds.
       On the G16 2024 the GPU fan stops; the CPU fan keeps a ~2000 rpm floor while the CPU is warm.
       Afterwards the firmware preset is reloaded and G-Helper's own curve is re-applied if it has one. #>
    param([int]$Seconds = 60)
    $zero = '1E-28-32-3C-46-50-5A-62-00-00-00-00-00-00-00-64'
    Write-Host "Writing a 0%-until-98C curve to both fans for $Seconds s..." -ForegroundColor Yellow
    [void](Set-G16FanCurve -Fan cpu -Hex $zero); [void](Set-G16FanCurve -Fan gpu -Hex $zero)
    $min = @{ Cpu = 99999; Gpu = 99999 }
    try {
        for ($i = 0; $i -lt $Seconds; $i += 10) {
            Start-Sleep 10; $f = Get-G16FanRpm; $t = Get-G16CpuTemp; $g = Get-G16GpuInfo
            Write-Host ("  +{0,2}s  cpu {1,3}C / {2,5} rpm   gpu {3,3}C / {4,5} rpm" -f ($i+10), $t, $f.Cpu, $(if ($g) { $g.Temp } else { '?' }), $f.Gpu)
            if ($f.Cpu -lt $min.Cpu) { $min.Cpu = $f.Cpu }; if ($f.Gpu -lt $min.Gpu) { $min.Gpu = $f.Gpu }
        }
    } finally { Restore-G16FanCurves }   # also runs on Ctrl-C, so the zero curve never outlives the test
    Write-Host ''
    Write-Host ("CPU fan lowest: {0} rpm -> {1}" -f $min.Cpu, $(if ($min.Cpu -eq 0) { 'it CAN stop' } else { 'firmware keeps a floor; 0% in a curve will not silence it at this temperature' }))
    Write-Host ("GPU fan lowest: {0} rpm -> {1}" -f $min.Gpu, $(if ($min.Gpu -eq 0) { 'it CAN stop' } else { 'did not stop in this window' }))
}

function Restore-G16FanCurves {
    <# Reload the firmware preset for the current G-Helper mode, then re-apply G-Helper's custom curve if enabled. #>
    $cfgPath = Join-Path $env:APPDATA 'GHelper\config.json'
    $mode = 0   # Balanced when there is no G-Helper config to tell us otherwise
    if (Test-Path $cfgPath) { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json; if ($c.performance_mode -ne $null) { $mode = [int]$c.performance_mode } }
    $name = @{ 0 = 'balanced'; 1 = 'turbo'; 2 = 'silent' }[$mode]
    [void](Set-G16PerformanceMode $name)
    if ($c -and $c."auto_apply_$mode" -eq 1) {
        if ($c."fan_profile_cpu_$mode") { [void](Set-G16FanCurve -Fan cpu -Hex $c."fan_profile_cpu_$mode") }
        if ($c."fan_profile_gpu_$mode") { [void](Set-G16FanCurve -Fan gpu -Hex $c."fan_profile_gpu_$mode") }
    }
    Write-Host "Fan curves restored for $name." -ForegroundColor Green
}

function Invoke-G16Stress {
    <# All-core CPU load for $Seconds with sampling, then a cooldown. Shows how fast fans ramp, where the CPU
       settles, and how quickly it recovers. Run before and after a change and use Compare-G16Runs. #>
    param([int]$Seconds = 90, [int]$Cooldown = 60, [string]$Label = 'stress')
    $file = Join-Path (Get-G16MeasureDir) ("{0}-{1}.csv" -f $Label, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    'Phase,Time,CpuC,CpuFan,CpuClk,CpuMHz,GpuC,GpuFan,GpuW,GpuMHz' | Set-Content $file
    $n = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    Write-Host "Starting $n stress threads for $Seconds s (Ctrl-C aborts and leaves no load behind)..." -ForegroundColor Yellow
    $jobs = 1..$n | ForEach-Object { Start-Job -ScriptBlock { $x = 1.0001; while ($true) { $x = [math]::Sqrt($x * $x + 1.0) } } }
    try {
        foreach ($phase in @(@{ Name = 'load'; Len = $Seconds }, @{ Name = 'cool'; Len = $Cooldown })) {
            if ($phase.Name -eq 'cool') { $jobs | Stop-Job; $jobs | Remove-Job -Force; $jobs = $null }
            for ($i = 10; $i -le $phase.Len; $i += 10) {
                Start-Sleep 10; $s = Get-G16Snapshot
                Write-Host ("{0,-5} +{1,3}s  cpu {2,3}C {3,5}rpm clk {4,4}% ({5,4} MHz)   gpu {6,3}C {7,5}rpm {8,4}W" -f $phase.Name, $i, $s.CpuC, $s.CpuFan, $s.CpuClk, $s.CpuMHz, $s.GpuC, $s.GpuFan, $s.GpuW)
                "$($phase.Name),$($s.Time),$($s.CpuC),$($s.CpuFan),$($s.CpuClk),$($s.CpuMHz),$($s.GpuC),$($s.GpuFan),$($s.GpuW),$($s.GpuMHz)" | Add-Content $file
            }
        }
    } finally { if ($jobs) { $jobs | Stop-Job; $jobs | Remove-Job -Force } }
    Write-Host "Saved: $file" -ForegroundColor Green
    return $file
}

function Compare-G16Runs {
    <# Side-by-side summary of two CSVs from Start-G16Log or Invoke-G16Stress. #>
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    function Summ($path) {
        $rows = Import-Csv $path
        if ($rows[0].PSObject.Properties['Phase']) { $rows = $rows | Where-Object Phase -eq 'load' }
        # A column can be empty (no nvidia-smi, sensor frozen); report '-' instead of crashing on an empty average.
        $num = { param($p) @($rows | Where-Object { $_.$p -match '^\d' } | ForEach-Object { [double]$_.$p }) }
        $avg = { param($p) $v = & $num $p; if ($v.Count) { [math]::Round(($v | Measure-Object -Average).Average) } else { $null } }
        $max = { param($p) $v = & $num $p; if ($v.Count) { ($v | Measure-Object -Maximum).Maximum } else { $null } }
        [pscustomobject]@{
            File = Split-Path $path -Leaf; Samples = $rows.Count
            CpuC_avg = & $avg 'CpuC'; CpuC_max = & $max 'CpuC'; CpuClk_avg = & $avg 'CpuClk'; CpuMHz_avg = & $avg 'CpuMHz'; CpuFan_avg = & $avg 'CpuFan'
            GpuC_avg = & $avg 'GpuC'; GpuW_avg = & $avg 'GpuW'; GpuMHz_avg = & $avg 'GpuMHz'; GpuFan_avg = & $avg 'GpuFan'
        }
    }
    $sa = Summ $A; $sb = Summ $B
    Write-Host ''
    Write-Host ("{0,-12} {1,14} {2,14}  {3}" -f 'metric', 'A', 'B', 'change')
    Write-Host ("{0,-12} {1,14} {2,14}" -f 'samples', $sa.Samples, $sb.Samples)
    foreach ($p in 'CpuC_avg','CpuC_max','CpuClk_avg','CpuMHz_avg','CpuFan_avg','GpuC_avg','GpuW_avg','GpuMHz_avg','GpuFan_avg') {
        $va = $sa.$p; $vb = $sb.$p
        $chg = if ($va -ne $null -and $vb -ne $null) { $d = $vb - $va; "{0}{1}" -f $(if ($d -gt 0) { '+' } else { '' }), $d } else { '-' }
        Write-Host ("{0,-12} {1,14} {2,14}  {3}" -f $p, $(if ($va -ne $null) { $va } else { '-' }), $(if ($vb -ne $null) { $vb } else { '-' }), $chg)
    }
    Write-Host ''; Write-Host 'CpuClk_avg is the average clock across all cores as a percentage of the nominal frequency Windows reports (CpuMHz_avg is the same number in MHz): higher is faster. A CPU pinned at its temperature limit shows a LOW number here even though the temperature looks the same.'
}
