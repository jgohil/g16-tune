# G16Tune.ps1 - measure, understand and tune an ASUS ROG Zephyrus G16 (2024, GU605) that runs G-Helper.
#
#   powershell -ExecutionPolicy Bypass -File .\G16Tune.ps1              # menu
#   .\G16Tune.ps1 -Diagnose                                              # what has this laptop been doing?
#   .\G16Tune.ps1 -Log -Seconds 300                                      # log temps/fans/clocks while you game
#   .\G16Tune.ps1 -FanFloorTest                                          # can the fans actually stop?
#   .\G16Tune.ps1 -Stress                                                # 90 s all-core load + cooldown, saved as CSV
#   .\G16Tune.ps1 -Compare a.csv b.csv                                   # before/after table
#   .\G16Tune.ps1 -ShowProfile profiles\g16-2024-quiet-gaming.json       # read a profile with the reasons
#   .\G16Tune.ps1 -ApplyProfile profiles\g16-2024-quiet-gaming.json      # backup G-Helper config, apply, restart (admin)
#   .\G16Tune.ps1 -RestoreLatest | -RestoreGHelper <backup.json>         # put G-Helper back (admin)
#   .\G16Tune.ps1 -InstallScreenMode | -UninstallScreenMode              # Silent on screen-off (admin)
#   .\G16Tune.ps1 -Debloat | -Undo                                       # opt-in cleanup with an undo log
# Steps marked (admin) ask for elevation themselves when started from a normal prompt.
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Diagnose, [switch]$Log, [int]$Seconds = 300, [int]$Interval = 10, [string]$Label,
    [switch]$FanFloorTest, [switch]$Stress,
    [string[]]$Compare, [Parameter(ValueFromRemainingArguments)][string[]]$ComparePaths,
    [string]$ShowProfile, [string]$ApplyProfile, [switch]$Force, [string]$RestoreGHelper, [switch]$RestoreLatest,
    [switch]$InstallScreenMode, [switch]$UninstallScreenMode,
    [switch]$Debloat, [switch]$Undo
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
foreach ($f in 'Asus.Acpi','Diagnose','Measure','GHelper','ScreenMode','Debloat') { . (Join-Path $root "lib\$f.ps1") }

$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'GU605') { Write-Warning "This was built and measured on a GU605 (Zephyrus G16 2024). Your model reads '$model'. The ACPI calls are the same ones G-Helper uses on all ROG laptops, but the fan-floor and thermal findings may not apply." }
if (-not (Test-G16Acpi)) { Write-Warning 'The ASUS ACPI device did not answer. Fan readings and mode switching will not work; the ASUS System Control Interface driver may be missing.' }

function Elevate([string]$argsLine) {
    if (Test-G16Admin) { return $false }
    Write-Host 'This step needs admin; asking for elevation...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" $argsLine"
    return $true
}

if ($Diagnose)            { Invoke-G16Diagnose | Out-Null; return }
if ($Log)                 { Start-G16Log -Seconds $Seconds -Interval $Interval -Label $(if ($Label) { $Label } else { 'log' }) | Out-Null; return }
if ($FanFloorTest)        { Test-G16FanFloor; return }
if ($Stress)              { Invoke-G16Stress -Label $(if ($Label) { $Label } else { 'stress' }) | Out-Null; return }
if ($Compare) {
    # Accept "-Compare a.csv b.csv" and "-Compare a.csv,b.csv" (powershell -File passes the comma form as one string).
    $paths = @(($Compare + $ComparePaths) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($paths.Count -ne 2) { throw '-Compare needs two CSV paths: -Compare before.csv after.csv' }
    Compare-G16Runs -A $paths[0] -B $paths[1]; return
}
if ($ShowProfile)         { Show-G16Profile $ShowProfile; return }
$forceArg = if ($Force) { ' -Force' } else { '' }
if ($ApplyProfile)        { $full = (Resolve-Path $ApplyProfile).Path; if (Elevate "-ApplyProfile `"$full`"$forceArg") { return }; Apply-G16Profile -Path $full -Force:$Force; return }
if ($RestoreGHelper)      { $full = (Resolve-Path $RestoreGHelper).Path; if (Elevate "-RestoreGHelper `"$full`"$forceArg") { return }; Restore-G16HelperConfig -Backup $full -Force:$Force; return }
if ($RestoreLatest)       { if (Elevate "-RestoreLatest$forceArg") { return }; Restore-G16HelperConfig -Force:$Force; return }
if ($InstallScreenMode)   { if (Elevate '-InstallScreenMode') { return }; Install-G16ScreenMode; return }
if ($UninstallScreenMode) { if (Elevate '-UninstallScreenMode') { return }; Uninstall-G16ScreenMode; return }
if ($Debloat)             { Invoke-G16Debloat; return }
if ($Undo)                { Undo-G16Debloat -Force:$Force; return }

# Menu
while ($true) {
    Write-Host ''
    Write-Host 'G16 Tune' -ForegroundColor Cyan
    Write-Host '  1  Diagnose      what has this laptop been doing, and what is G-Helper really set to'
    Write-Host '  2  Log           temps, fans and clocks every 10 s (run this while gaming)'
    Write-Host '  3  Fan floor     can the fans actually stop on this machine?'
    Write-Host '  4  Stress        90 s all-core load, saved for before/after comparison'
    Write-Host '  c  Compare       two saved runs side by side'
    Write-Host '  5  Show profile  read the quiet-gaming profile and why each setting is what it is'
    Write-Host '  6  Apply profile write it into G-Helper (backs up first; admin)'
    Write-Host '  7  Screen mode   install Silent-on-screen-off (admin)'
    Write-Host '  8  Debloat       opt-in cleanup of startup, Store apps, services, Windows settings'
    Write-Host '  9  Undo debloat'
    Write-Host '  0  Restore G-Helper config from the latest backup (admin)'
    Write-Host '  q  Quit'
    $c = Read-Host 'Choose'
    $prof = Join-Path $root 'profiles\g16-2024-quiet-gaming.json'
    try {
        switch ($c) {
            '1' { Invoke-G16Diagnose | Out-Null }
            '2' { $s = Read-Host 'Seconds (default 300)'; if (-not $s) { $s = 300 }; Start-G16Log -Seconds ([int]$s) | Out-Null }
            '3' { Test-G16FanFloor }
            '4' { Invoke-G16Stress | Out-Null }
            'c' {
                $runs = @(Get-ChildItem (Get-G16MeasureDir) -Filter *.csv | Sort-Object LastWriteTime -Descending)
                if ($runs.Count -lt 2) { Write-Host 'Need at least two saved runs (Log or Stress) to compare.'; break }
                for ($i = 0; $i -lt $runs.Count; $i++) { Write-Host ("  [{0,2}] {1}" -f ($i + 1), $runs[$i].Name) }
                $pick = Read-Host 'Two numbers, before and after (e.g. 2,1)'
                $ix = @($pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 })
                if ($ix.Count -ne 2 -or $ix[0] -ge $runs.Count -or $ix[1] -ge $runs.Count) { Write-Host 'Pick exactly two valid numbers.'; break }
                Compare-G16Runs -A $runs[$ix[0]].FullName -B $runs[$ix[1]].FullName
            }
            '5' { Show-G16Profile $prof }
            '6' { if (-not (Elevate "-ApplyProfile `"$prof`"")) { Apply-G16Profile -Path $prof } }
            '7' { if (-not (Elevate '-InstallScreenMode')) { Install-G16ScreenMode } }
            '8' { Invoke-G16Debloat }
            '9' { Undo-G16Debloat }
            '0' { if (-not (Elevate '-RestoreLatest')) { Restore-G16HelperConfig } }
            'q' { return }
        }
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
}
