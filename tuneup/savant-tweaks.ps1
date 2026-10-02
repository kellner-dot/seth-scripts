<#
  Savant Tweaks — native replacements for the last 4 IObit apps
  ----------------------------------------------------------------
  What each app did, and what this does instead:

  1. Advanced SystemCare -> junk cleanup (done earlier) + STARTUP OPTIMIZER (this script):
     audits everything that launches at boot, kills IObit remnants, reports the rest.
     SKIPPED deliberately: registry cleaning (risky, zero benefit), "internet booster" (placebo).
  2. IObit Software Updater -> WEEKLY MAINTENANCE TASK (this script): silent
     `winget upgrade --all` + temp cleanup, logged to Desktop. No more nag popups.
  3. IObit Uninstaller 15 -> nothing to build: Settings > Apps / `winget uninstall`
     covers it; the uninstall-v3 script already swept IObit leftovers.
  4. Smart Game Booster -> GAME-BOOST.ps1 on your Desktop (this script writes it):
     one double-click kills background hogs before gaming. SKIPPED deliberately:
     GPU overclock (risky, was paid DLC anyway), "game defrag" (pointless on SSDs).
     For FPS/temp overlay: press Win+G (Xbox Game Bar, built into Windows).

  Run in normal PowerShell — asks for admin itself.
#>
$ErrorActionPreference = "Continue"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "savant-tweaks-log.txt"
function Log($m) {
    $line = "[$(Get-Date -Format HH:mm:ss)] $m"
    Write-Host $line
    try { Add-Content -Path $log -Value $line } catch {}
}
"=== Savant Tweaks started $(Get-Date) ===" | Out-File $log

# ============ 1. STARTUP AUDIT (replaces ASC's Startup Optimizer) ============
Log "--- Startup audit ---"
$backupReg = Join-Path $Desktop "startup-backup.reg"
try {
    $tmp1 = Join-Path $env:TEMP "run-hklm.reg"; $tmp2 = Join-Path $env:TEMP "run-hkcu.reg"
    reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" $tmp1 /y 2>$null | Out-Null
    reg export "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" $tmp2 /y 2>$null | Out-Null
    $merged = "Windows Registry Editor Version 5.00`r`n`r`n"
    foreach ($t in @($tmp1, $tmp2)) { if (Test-Path $t) { $merged += ((Get-Content $t -Raw) -replace 'Windows Registry Editor Version 5\.00\r?\n', '') } }
    $merged | Out-File $backupReg -Encoding ascii
    Log "Startup registry backed up to Desktop\startup-backup.reg"
} catch { Log "Backup failed: $_" }

$runKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
$disabledCount = 0
foreach ($rk in $runKeys) {
    if (-not (Test-Path $rk)) { continue }
    Get-Item $rk | Select-Object -ExpandProperty Property | ForEach-Object {
        $valName = $_
        $valData = (Get-ItemProperty $rk -Name $valName -ErrorAction SilentlyContinue).$valName
        $isIObit = ($valName -like "*IObit*") -or ("$valData" -like "*IObit*")
        if ($isIObit) {
            try {
                Remove-ItemProperty $rk -Name $valName -ErrorAction Stop
                Log "  DISABLED IObit remnant at boot: $valName"
                $disabledCount++
            } catch { Log "  could not remove ${rk}\${valName}: $_" }
        } else {
            Log "  boot item (leaving alone): $valName = $valData"
        }
    }
}
# Startup folders
$startupDirs = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
)
foreach ($sd in $startupDirs) {
    if (Test-Path $sd) {
        Get-ChildItem $sd -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -like "*IObit*") {
                try { Remove-Item $_.FullName -Force -ErrorAction Stop; Log "  DISABLED IObit startup link: $($_.Name)"; $disabledCount++ }
                catch { Log "  could not remove startup link $($_.Name): $_" }
            } else {
                Log "  startup folder item (leaving alone): $($_.Name)"
            }
        }
    }
}
Log "Startup cleanup: disabled $disabledCount IObit remnant(s). Review the 'leaving alone' items above — disable others in Task Manager > Startup apps if you want."

# ============ 2. WEEKLY MAINTENANCE TASK (replaces Software Updater nagging) ============
Log "--- Weekly maintenance task ---"
$maintDir = "$env:ProgramData\SavantPC"
$maintScript = Join-Path $maintDir "weekly-maintenance.ps1"
try {
    if (-not (Test-Path $maintDir)) { New-Item $maintDir -ItemType Directory -Force | Out-Null }
    @'
$ErrorActionPreference = "Continue"
$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "maintenance-log.txt"
"=== Weekly maintenance $(Get-Date) ===" | Out-File $log
"--- Software updates (winget) ---" | Add-Content $log
try {
    winget upgrade --all --silent --accept-source-agreements --accept-package-agreements 2>&1 | Add-Content $log
} catch { "winget failed: $_" | Add-Content $log }
"--- Temp cleanup ---" | Add-Content $log
foreach ($t in @($env:TEMP, "$env:WINDIR\Temp")) {
    try { Get-ChildItem $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
try { Get-ChildItem "$env:WINDIR\SoftwareDistribution\DeliveryOptimization" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch {}
"--- Done $(Get-Date) ---" | Add-Content $log
'@ | Out-File $maintScript -Encoding utf8
    Log "Maintenance script written to $maintScript"

    $taskName = "SavantPC Weekly Maintenance"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$maintScript`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 12:00PM
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Description "Weekly silent software updates + temp cleanup (replaces IObit Software Updater)" -ErrorAction Stop | Out-Null
    Log "Scheduled task '$taskName' created: Sundays at noon, runs as you, log on Desktop\maintenance-log.txt"
} catch { Log "Maintenance task setup failed: $_" }

# ============ 3. GAME-BOOST.ps1 (replaces Smart Game Booster's one-click boost) ============
Log "--- Game Boost script ---"
$boostPath = Join-Path $Desktop "game-boost.ps1"
@'
# Game Boost — double-click before gaming. Kills background hogs, frees CPU/RAM.
# (Replaces Smart Game Booster's one-click boost. No admin needed.)
$ErrorActionPreference = "SilentlyContinue"
$before = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
$kills = @("chrome", "msedge", "firefox", "opera", "brave", "vivaldi",
           "AdobeARM", "Spotify", "Teams", "Slack", "zoom",
           "Skype", "OneDriveStandaloneUpdater")
$killed = 0
foreach ($p in $kills) {
    $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
    foreach ($pr in $procs) { try { Stop-Process $pr -Force; $killed++ } catch {} }
}
Start-Sleep 2
$after = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
$gm = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\GameBar" -Name AllowAutoGameMode -ErrorAction SilentlyContinue).AllowAutoGameMode
Write-Host ""
Write-Host "Game Boost done: killed $killed background process(es)." -ForegroundColor Green
Write-Host "Free RAM: ${before}MB -> ${after}MB" -ForegroundColor Cyan
Write-Host "Tip: press Win+G in-game for the FPS / temp overlay (Xbox Game Bar)." -ForegroundColor Yellow
Write-Host ""
pause
'@ | Out-File $boostPath -Encoding utf8
Log "game-boost.ps1 written to Desktop — double-click it before gaming."

Log "=== Savant Tweaks finished. Log: Desktop\savant-tweaks-log.txt ==="
Write-Host ""
Write-Host "Done! What you got:" -ForegroundColor Green
Write-Host "  - Startup cleaned of IObit remnants (backup: startup-backup.reg)" -ForegroundColor Green
Write-Host "  - Weekly silent updates scheduled (Sundays, noon)" -ForegroundColor Green
Write-Host "  - game-boost.ps1 on your Desktop for one-click pre-game boost" -ForegroundColor Green
pause
