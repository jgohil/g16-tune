# lib/GHelper.ps1 - read, back up, change and restore G-Helper's config.json.
# G-Helper only reads its config at startup, so every apply is: backup -> stop G-Helper -> edit -> start G-Helper.
# G-Helper then applies the current mode itself (fans, limits, boost, GPU clocks) and logs what it did.

$script:GHelperConfig = Join-Path $env:APPDATA 'GHelper\config.json'
$script:GHelperLog    = Join-Path $env:APPDATA 'GHelper\log.txt'

function Get-G16HelperConfig {
    if (-not (Test-Path $script:GHelperConfig)) { throw "G-Helper config not found at $script:GHelperConfig. Install G-Helper first: https://github.com/seerge/g-helper" }
    Get-Content $script:GHelperConfig -Raw | ConvertFrom-Json
}

function Backup-G16HelperConfig {
    $dir = Join-Path $env:LOCALAPPDATA 'G16Tune\backups'; New-Item -ItemType Directory -Force $dir | Out-Null
    $dest = Join-Path $dir ("ghelper-config-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $script:GHelperConfig $dest -Force
    Write-Host "G-Helper config backed up to $dest" -ForegroundColor Green
    return $dest
}

function Stop-G16Helper {
    <# G-Helper runs elevated, so only an elevated shell can stop it. Fail loudly rather than edit the config
       underneath a running G-Helper, which would overwrite the edit on its next save. Remembers the exe path
       (G-Helper is a portable exe) so Restart-G16Helper can start it again without a scheduled task. #>
    if (-not (Test-G16Admin)) { throw 'G-Helper runs elevated, so this needs an admin PowerShell. Start G16Tune.ps1 from an elevated prompt (or let the menu elevate for you).' }
    $exe = (Get-Process GHelper -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    if ($exe) { $script:GHelperExe = $exe }
    Stop-Process -Name GHelper -Force -ErrorAction SilentlyContinue; Start-Sleep 2
    if (Get-Process GHelper -ErrorAction SilentlyContinue) { throw 'G-Helper is still running after Stop-Process; not touching its config.' }
}

function Restart-G16Helper {
    <# Starts G-Helper again, preferably through its own scheduled task (which carries the admin rights it needs). #>
    Stop-G16Helper
    if (Get-ScheduledTask -TaskName 'GHelper' -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName 'GHelper' }
    elseif ($script:GHelperExe -and (Test-Path $script:GHelperExe)) { Start-Process $script:GHelperExe }
    else { Write-Warning 'Could not find GHelper.exe to start it again; start G-Helper yourself.' }
    Start-Sleep 8
    if (Get-Process GHelper -ErrorAction SilentlyContinue) { Write-Host 'G-Helper restarted.' -ForegroundColor Green } else { Write-Warning 'G-Helper did not come back; start it from the Start menu.' }
}

function Show-G16HelperLogTail {
    param([int]$Lines = 25)
    if (Test-Path $script:GHelperLog) { Get-Content $script:GHelperLog -Tail $Lines | Where-Object { $_ -match 'Mode =|Fan|Boost|PowerLimit|CLOCKS|Power Mode' } }
}

function Get-G16Profile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content $Path -Raw | ConvertFrom-Json
}

function Show-G16Profile {
    <# Prints a profile's settings in human terms, with the reason for each. #>
    param([Parameter(Mandatory)][string]$Path)
    $p = Get-G16Profile $Path
    Write-Host "`n$($p.name)" -ForegroundColor Cyan; Write-Host $p.description; Write-Host ''
    foreach ($prop in $p.settings.PSObject.Properties) {
        $why = $p.explain.($prop.Name)
        $val = $prop.Value
        if ($prop.Name -like 'fan_profile_*') { $val = ((ConvertFrom-G16Curve $val) | ForEach-Object { "$($_.Temp)C=$($_.Percent)%" }) -join ' ' }
        Write-Host ("  {0,-22} {1}" -f $prop.Name, $val)
        if ($why) { Write-Host ("  {0,-22} {1}" -f '', $why) -ForegroundColor DarkGray }
    }
    if ($p.notes) { Write-Host ''; $p.notes | ForEach-Object { Write-Host "  * $_" -ForegroundColor Yellow } }
}

function Apply-G16Profile {
    <# Writes a profile's settings into G-Helper's config (after a backup) and restarts G-Helper. #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Force)
    $p = Get-G16Profile $Path
    Show-G16Profile $Path
    if (-not $Force) { $a = Read-Host "`nApply this profile to G-Helper? (y/N)"; if ($a -ne 'y') { Write-Host 'Nothing changed.'; return } }
    $backup = Backup-G16HelperConfig
    $cfg = Get-G16HelperConfig
    foreach ($prop in $p.settings.PSObject.Properties) {
        if ($cfg.PSObject.Properties[$prop.Name]) { $cfg.($prop.Name) = $prop.Value } else { $cfg | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value }
    }
    # G-Helper writes its config on exit, so stop it before editing or the edit gets overwritten.
    Stop-G16Helper
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $script:GHelperConfig -Encoding UTF8
    Restart-G16Helper
    Write-Host "`nG-Helper reported:" ; Show-G16HelperLogTail 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "`nUndo any time with: G16Tune.ps1 -RestoreGHelper `"$backup`"" -ForegroundColor Yellow
}

function Restore-G16HelperConfig {
    param([string]$Backup, [switch]$Force)
    if (-not $Backup) {
        $dir = Join-Path $env:LOCALAPPDATA 'G16Tune\backups'
        $Backup = (Get-ChildItem $dir -Filter 'ghelper-config-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
        if (-not $Backup) { throw 'No backup found.' }
    }
    if (-not (Test-Path $Backup)) { throw "Backup not found: $Backup" }
    if (-not $Force) { $a = Read-Host "Replace G-Helper's config with $Backup and restart it? (y/N)"; if ($a -ne 'y') { Write-Host 'Nothing changed.'; return } }
    Stop-G16Helper
    Copy-Item $Backup $script:GHelperConfig -Force
    Write-Host "Restored G-Helper config from $Backup" -ForegroundColor Green
    Restart-G16Helper
}
