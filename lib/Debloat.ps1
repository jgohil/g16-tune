# lib/Debloat.ps1 - fewer things running = cooler idle and fewer things that wake up mid-game.
# Everything here is opt-in from a numbered list, logged to an undo file, and reversible with Undo-G16Debloat
# (Store apps come back from the Microsoft Store rather than from the undo log).

$script:UndoFile = Join-Path $env:LOCALAPPDATA 'G16Tune\undo.json'

function Get-G16UndoList {
    # Windows PowerShell 5.1 hands a JSON array back as one Object[] through the pipeline, so enumerate it
    # with foreach instead of wrapping in @(), or the second entry nests the first inside itself.
    $list = @()
    if (Test-Path $script:UndoFile) { foreach ($x in (Get-Content $script:UndoFile -Raw | ConvertFrom-Json)) { $list += $x } }
    return $list    # callers wrap this in @() because PowerShell unrolls 0- and 1-element arrays on return
}

function Save-G16UndoList {
    param($List)
    New-Item -ItemType Directory -Force (Split-Path $script:UndoFile) | Out-Null
    if (@($List).Count -eq 0) { Remove-Item $script:UndoFile -Force -ErrorAction SilentlyContinue; return }
    # -InputObject keeps a single entry as a one-element JSON array instead of a bare object.
    ConvertTo-Json -InputObject @($List) -Depth 5 | Set-Content $script:UndoFile -Encoding UTF8
}

function Add-G16Undo {
    param([string]$Kind, [string]$Target, $Before)
    $list = @(Get-G16UndoList)
    $list += [pscustomobject]@{ When = (Get-Date -Format s); Kind = $Kind; Target = $Target; Before = $Before }
    Save-G16UndoList $list
}

function Select-G16Items {
    <# Numbered multi-select in the console. Returns the chosen items. #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)]$Items, [string]$Hint)
    if (-not $Items -or $Items.Count -eq 0) { Write-Host "$Title - nothing found." -ForegroundColor DarkGray; return @() }
    Write-Host "`n$Title" -ForegroundColor Cyan
    if ($Hint) { Write-Host $Hint -ForegroundColor DarkGray }
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  [{0,2}] {1,-45} {2}" -f ($i + 1), $Items[$i].Name, $Items[$i].Note) }
    $ans = Read-Host 'Numbers to apply (e.g. 1,3,5), "all", or Enter to skip'
    if ($ans -eq '') { return @() }
    if ($ans -eq 'all') { return $Items }
    $idx = $ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
    return @($Items | Select-Object -Index $idx)
}

function Invoke-G16Debloat {
    $isAdmin = Test-G16Admin
    Write-Host "`nG16 Tune debloat. Nothing happens without your pick. Undo later with -Undo." -ForegroundColor Cyan
    if (-not $isAdmin) { Write-Host 'Not elevated: your own startup entries and Store apps work; all-user startup entries, services, indexing and Delivery Optimization need an admin PowerShell.' -ForegroundColor Yellow }

    # 1. Startup entries (same toggle as Task Manager > Startup: a StartupApproved value starting with 03 = disabled)
    $items = @()
    $sources = @(@{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Note = '' })
    if ($isAdmin) {
        $sources += @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Note = '(all users)' }
        $sources += @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Note = '(all users)' }
    }
    foreach ($src in $sources) {
        $p = Get-ItemProperty $src.Run -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($e in ($p.PSObject.Properties | Where-Object Name -notmatch '^PS')) {
            $st = (Get-ItemProperty $src.Approved -ErrorAction SilentlyContinue).($e.Name)
            if ($st -and ($st[0] -band 1)) { continue }
            $exe = try { ($e.Value -replace '^"?([^"]+?)"?( .*)?$','$1') | Split-Path -Leaf } catch { '' }
            $items += [pscustomobject]@{ Name = $e.Name; Note = "$exe $($src.Note)".Trim(); Key = $src.Approved }
        }
    }
    $sf = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue
    foreach ($f in $sf) { $st = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' -ErrorAction SilentlyContinue).($f.Name); if ($st -and ($st[0] -band 1)) { continue }; $items += [pscustomobject]@{ Name = $f.Name; Note = 'Startup folder'; Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' } }
    foreach ($it in (Select-G16Items -Title 'Startup programs (enabled)' -Items $items -Hint 'Keep your game launchers, G-Helper and peripheral software. Disable the rest; this is the Task Manager > Startup toggle.')) {
        try {
            $before = (Get-ItemProperty $it.Key -ErrorAction SilentlyContinue).($it.Name)
            if (-not (Test-Path $it.Key)) { New-Item $it.Key -Force | Out-Null }
            Set-ItemProperty -Path $it.Key -Name $it.Name -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
            Add-G16Undo -Kind 'startup' -Target "$($it.Key)|$($it.Name)" -Before $(if ($before) { [Convert]::ToBase64String($before) } else { $null })
            Write-Host "  disabled $($it.Name)" -ForegroundColor Green
        } catch { Write-Host "  $($it.Name): $($_.Exception.Message)" -ForegroundColor Red }
    }

    # 2. Store apps commonly worth removing
    $bloat = 'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch','Microsoft.MicrosoftSolitaireCollection','Clipchamp.Clipchamp','MSTeams','Microsoft.OutlookForWindows','MicrosoftCorporationII.MicrosoftFamily','Microsoft.Windows.DevHome','Microsoft.PowerAutomateDesktop','Microsoft.Todos','Microsoft.People','Microsoft.WindowsMaps','Microsoft.WindowsFeedbackHub','Microsoft.GetHelp','Microsoft.YourPhone','MicrosoftWindows.CrossDevice','MicrosoftWindows.Client.WebExperience','Microsoft.WidgetsPlatformRuntime','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.Edge.GameAssist','Microsoft.StartExperiencesApp','AppUp.IntelGraphicsExperience','AppUp.IntelArcSoftware','AppUp.IntelOptaneMemoryandStorageManagement','Microsoft.Copilot','Microsoft.MicrosoftOfficeHub','Microsoft.ZuneMusic','Microsoft.ZuneVideo','FACEBOOK.317180B0BB486','SpotifyAB.SpotifyMusic','Disney.37853E9C2A6F5','TikTok.TikTok','BytedancePte.Ltd.TikTok'
    $notes = @{ 'Microsoft.YourPhone' = 'Phone Link'; 'MicrosoftWindows.CrossDevice' = 'Phone Link background service'; 'MicrosoftWindows.Client.WebExperience' = 'Widgets'; 'Microsoft.WidgetsPlatformRuntime' = 'Widgets runtime'; 'Microsoft.XboxGamingOverlay' = 'Xbox Game Bar overlay (Gaming Services stays)'; 'Microsoft.XboxGameOverlay' = 'Game Bar component'; 'Microsoft.Edge.GameAssist' = 'Edge in-game browser overlay'; 'Microsoft.StartExperiencesApp' = 'Start menu feed'; 'AppUp.IntelGraphicsExperience' = 'Intel iGPU control (useless in Ultimate GPU mode)'; 'AppUp.IntelArcSoftware' = 'Intel Arc Control (useless in Ultimate GPU mode)'; 'AppUp.IntelOptaneMemoryandStorageManagement' = 'no Optane in this laptop' }
    $items = @(); foreach ($n in $bloat) { $pk = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue; if ($pk) { $items += [pscustomobject]@{ Name = $n; Note = $(if ($notes[$n]) { $notes[$n] } else { '' }) } } }
    foreach ($it in (Select-G16Items -Title 'Store apps' -Items $items -Hint 'Removed for this user only; reinstall from the Microsoft Store if you miss one.')) {
        try { Get-AppxPackage -Name $it.Name | Remove-AppxPackage -ErrorAction Stop; Add-G16Undo -Kind 'appx' -Target $it.Name -Before 'reinstall from Store'; Write-Host "  removed $($it.Name)" -ForegroundColor Green } catch { Write-Host "  $($it.Name): $($_.Exception.Message)" -ForegroundColor Red }
    }
    $dvr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    if ((Get-ItemProperty $dvr -ErrorAction SilentlyContinue).AppCaptureEnabled -ne 0) {
        $a = Read-Host "`nTurn off Game Bar background recording (Settings > Gaming > Captures)? (y/N)"
        if ($a -eq 'y') { $before = (Get-ItemProperty $dvr -ErrorAction SilentlyContinue).AppCaptureEnabled; if (-not (Test-Path $dvr)) { New-Item $dvr -Force | Out-Null }; Set-ItemProperty $dvr -Name AppCaptureEnabled -Value 0 -Type DWord; Add-G16Undo -Kind 'reg' -Target "$dvr|AppCaptureEnabled" -Before $before; Write-Host '  done' -ForegroundColor Green }
    }

    # 3. Windows suggestions / content delivery (user-level)
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $a = Read-Host "`nTurn off Windows suggested content, tips, silent app installs and Start recommendations? (y/N)"
    if ($a -eq 'y') {
        foreach ($n in 'SilentInstalledAppsEnabled','SoftLandingEnabled','SystemPaneSuggestionsEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SubscribedContent-338393Enabled','SubscribedContent-353698Enabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled','ContentDeliveryAllowed') {
            $before = (Get-ItemProperty $cdm -ErrorAction SilentlyContinue).$n; Set-ItemProperty -Path $cdm -Name $n -Value 0 -Type DWord; Add-G16Undo -Kind 'reg' -Target "$cdm|$n" -Before $before }
        $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; $before = (Get-ItemProperty $adv -ErrorAction SilentlyContinue).Start_IrisRecommendations
        Set-ItemProperty $adv -Name Start_IrisRecommendations -Value 0 -Type DWord; Add-G16Undo -Kind 'reg' -Target "$adv|Start_IrisRecommendations" -Before $before
        Write-Host '  done' -ForegroundColor Green
    }
    $edge = 'HKCU:\Software\Policies\Microsoft\Edge'
    if (Get-Process EdgeGameAssist -ErrorAction SilentlyContinue) { $a = Read-Host 'Edge Game Assist (in-game browser overlay) is running. Disable it? (y/N)'; if ($a -eq 'y') { New-Item $edge -Force | Out-Null; Set-ItemProperty $edge -Name GameAssistEnabled -Value 0 -Type DWord; Add-G16Undo -Kind 'reg' -Target "$edge|GameAssistEnabled" -Before $null; Stop-Process -Name EdgeGameAssist -Force -ErrorAction SilentlyContinue; Write-Host '  done' -ForegroundColor Green } }

    if (-not $isAdmin) { Write-Host "`nRe-run from an admin PowerShell for services, drive indexing and Delivery Optimization." -ForegroundColor Yellow; return }

    # 4. Third-party services (admin)
    # Never offer the things that must stay: G-Helper, the NVIDIA driver services, the ASUS touchpad driver, anti-cheat services
    # (disabling those breaks the games they protect), and Xbox/GameInput which some games need.
    $keep = '^(GHelper|Nv|NVDisplay|AsusPTP|Xbl|Xbox|GameInput|EasyAntiCheat|BEService|vgc|vgk|FACEIT|PnkBstr)'
    $svc = Get-CimInstance Win32_Service | Where-Object { ($_.State -eq 'Running' -or $_.StartMode -eq 'Auto') -and $_.PathName -notmatch 'Windows\\|System32|Microsoft' -and $_.Name -notmatch $keep }
    $items = @($svc | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Note = "$($_.DisplayName) ($($_.State), $($_.StartMode))" } })
    foreach ($it in (Select-G16Items -Title 'Third-party services to disable' -Items $items -Hint 'Armoury Crate, GlideX, monitoring tools and updaters are the usual suspects. Leave anything you recognise and use (Steam, Epic, mouse/keyboard software, VPNs).')) {
        $before = (Get-Service $it.Name).StartType
        Stop-Service $it.Name -Force -ErrorAction SilentlyContinue; Set-Service $it.Name -StartupType Disabled
        Add-G16Undo -Kind 'service' -Target $it.Name -Before "$before"; Write-Host "  disabled $($it.Name)" -ForegroundColor Green
    }

    # 5. Indexing on game drives
    $vols = Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -and $_.IndexingEnabled -and $_.DriveLetter -ne 'C:' }
    $items = @($vols | ForEach-Object { [pscustomobject]@{ Name = $_.DriveLetter; Note = "$($_.Label) $([math]::Round($_.Capacity/1GB)) GB, indexed" } })
    foreach ($it in (Select-G16Items -Title 'Stop Windows Search indexing these drives' -Items $items -Hint 'Game libraries do not need indexing; it only burns CPU and disk after every update.')) {
        $v = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($it.Name)'"; $v.IndexingEnabled = $false; Set-CimInstance -InputObject $v
        Add-G16Undo -Kind 'indexing' -Target $it.Name -Before $true; Write-Host "  indexing off for $($it.Name)" -ForegroundColor Green
    }

    # 6. Delivery Optimization
    $doKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    if ((Get-ItemProperty $doKey -ErrorAction SilentlyContinue).DODownloadMode -ne 0) {
        $a = Read-Host "`nForce Delivery Optimization (Windows Update peer-to-peer sharing) off by policy? Skip if you already turned it off in Settings. (y/N)"
        if ($a -eq 'y') { $before = (Get-ItemProperty $doKey -ErrorAction SilentlyContinue).DODownloadMode; New-Item $doKey -Force | Out-Null; Set-ItemProperty $doKey -Name DODownloadMode -Value 0 -Type DWord; Add-G16Undo -Kind 'reg' -Target "$doKey|DODownloadMode" -Before $before; Write-Host '  done' -ForegroundColor Green }
    }
    Write-Host "`nUndo log: $script:UndoFile" -ForegroundColor DarkGray
}

function Undo-G16Debloat {
    param([switch]$Force)
    $list = @(Get-G16UndoList)
    if ($list.Count -eq 0) { Write-Host 'Nothing to undo.'; return }
    $needsAdmin = @($list | Where-Object { $_.Kind -in 'service','indexing' -or $_.Target -like 'HKLM:*' })
    if ($needsAdmin.Count -and -not (Test-G16Admin)) { throw "The undo log has $($needsAdmin.Count) machine-level entries (services, indexing, all-user settings). Run -Undo from an admin PowerShell so they can all be reversed." }
    Write-Host "`nUndo log ($($list.Count) entries):" -ForegroundColor Cyan
    $list | ForEach-Object { Write-Host ("  {0}  {1,-9} {2}" -f $_.When, $_.Kind, $_.Target) }
    if (-not $Force) { $a = Read-Host 'Reverse all of these? (y/N)'; if ($a -ne 'y') { Write-Host 'Nothing changed.'; return } }
    $failed = @()
    [array]::Reverse($list)
    foreach ($u in $list) {
        try {
            switch ($u.Kind) {
                'startup'  { $k, $n = $u.Target -split '\|'; if ($u.Before) { Set-ItemProperty -Path $k -Name $n -Value ([Convert]::FromBase64String($u.Before)) -Type Binary } else { Remove-ItemProperty -Path $k -Name $n -ErrorAction SilentlyContinue }; Write-Host "  startup restored: $n" }
                'reg'      { $k, $n = $u.Target -split '\|'; if ($u.Before -ne $null) { Set-ItemProperty -Path $k -Name $n -Value $u.Before } else { Remove-ItemProperty -Path $k -Name $n -ErrorAction SilentlyContinue }; Write-Host "  setting restored: $n" }
                'service'  { Set-Service $u.Target -StartupType $u.Before; Write-Host "  service $($u.Target) -> $($u.Before)" }
                'indexing' { $v = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($u.Target)'"; $v.IndexingEnabled = $true; Set-CimInstance -InputObject $v; Write-Host "  indexing on: $($u.Target)" }
                'appx'     { Write-Host "  $($u.Target): reinstall from the Microsoft Store" -ForegroundColor Yellow }
            }
        } catch { $failed += $u; Write-Host "  $($u.Kind) $($u.Target): $($_.Exception.Message)" -ForegroundColor Red }
    }
    # Keep whatever could not be reversed so a second attempt (for example from an admin shell) can still do it.
    [array]::Reverse($failed); Save-G16UndoList $failed
    if ($failed.Count) { Write-Host "$($failed.Count) entries failed and stay in the undo log." -ForegroundColor Yellow } else { Write-Host 'Undo complete.' -ForegroundColor Green }
}
