<#
  SAVANT MODE — autonomous PC watchdog for SETHS-PC
  -------------------------------------------------
  What it does:
  1. CHECKS: power plan, never-sleep, hibernate, Game Mode, GPU scheduling,
     Defender, Tailscale, Emby, disk space, IObit remnants.
  2. HEALS ITSELF: restarts Tailscale if down, re-applies power settings if drifted.
  3. REPORTS: writes Desktop\savant-status.txt — your "am I doing it right" dashboard.
     All green = you're good. Share it with Muse if anything looks wrong.
  Runs automatically at every logon + daily at noon. Run in normal PowerShell —
  asks for admin itself (one-paste below).
#>
$ErrorActionPreference = "Continue"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Desktop = [Environment]::GetFolderPath("Desktop")
$statusFile = Join-Path $Desktop "savant-status.txt"

# Install to a permanent home (the one-paste runs from TEMP, which gets cleaned)
$installDir = "$env:ProgramData\SavantPC"
$installed = Join-Path $installDir "savant-check.ps1"
if ($PSCommandPath -ne $installed) {
    try {
        if (-not (Test-Path $installDir)) { New-Item $installDir -ItemType Directory -Force | Out-Null }
        Copy-Item $PSCommandPath $installed -Force
        Write-Host "Installed to $installed" -ForegroundColor DarkGray
    } catch {}
}
$results = @()
function Check($name, $ok, $detail, $healed = $false) {
    $s = if ($healed) { "FIXED" } elseif ($ok) { "PASS" } else { "FAIL" }
    $script:results += [pscustomobject]@{ Name = $name; Status = $s; Detail = $detail }
    Write-Host "[$s] $name — $detail"
}

# 1. Power plan
$plan = (powercfg /getactivescheme 2>$null | Out-String)
Check "Power plan" ($plan -match "High performance") $plan.Trim()

# 2. Never-sleep (standby timeout AC = 0)
$standbyOk = $false; $standbyDetail = "unknown"
try {
    $q = (powercfg /query SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8fbc 29f6c1db-86c7-4e85-8391-fd4d28f27c3f 2>$null | Out-String)
    if ($q -match "Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)") {
        $standbyOk = ([Convert]::ToInt32($Matches[1], 16) -eq 0)
        $standbyDetail = "standby timeout = $([Convert]::ToInt32($Matches[1],16)) (0 = never)"
    }
} catch { $standbyDetail = $_ }
if (-not $standbyOk) {
    powercfg /change standby-timeout-ac 0 2>$null | Out-Null
    powercfg /change standby-timeout-dc 0 2>$null | Out-Null
    $standbyOk = $true; $standbyDetail += " -> re-applied never-sleep"
    Check "Never-sleep" $true $standbyDetail $true
} else { Check "Never-sleep" $true $standbyDetail }

# 3. Hibernate off
$hib = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
if ($hib -ne 0) { powercfg /hibernate off 2>$null | Out-Null; Check "Hibernate off" $true "was on -> turned off" $true }
else { Check "Hibernate off" $true "disabled" }

# 4. Game Mode
$gm = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\GameBar" -Name AllowAutoGameMode -ErrorAction SilentlyContinue).AllowAutoGameMode
Check "Game Mode" ($gm -eq 1) "AllowAutoGameMode=$gm"

# 5. GPU scheduling (HAGS)
$hags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
Check "GPU scheduling" ($hags -eq 2) "HwSchMode=$hags (2=on)"

# 6. Defender real-time protection
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Check "Defender" ($mp.RealTimeProtectionEnabled -eq $true) "real-time=$($mp.RealTimeProtectionEnabled)"
} catch { Check "Defender" $false "check failed: $_" }

# 7. Tailscale (SELF-HEALING)
$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
$tsOk = $false; $tsDetail = ""
try {
    $svc = Get-Service Tailscale -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Start-Service Tailscale -ErrorAction Stop; Start-Sleep 8
        $tsDetail = "service was $($svc.Status) -> restarted; "
    }
    if (Test-Path $tsExe) {
        $ip = ((& $tsExe ip -4 2>$null | Out-String).Trim())
        if ($ip -match "^100\.") { $tsOk = $true; $tsDetail += "IP=$ip" }
        else {
            & $tsExe up --unattended 2>$null | Out-Null; Start-Sleep 5
            $ip2 = ((& $tsExe ip -4 2>$null | Out-String).Trim())
            $tsOk = ($ip2 -match "^100\."); $tsDetail += "reconnected, IP=$ip2"
        }
    } else { $tsDetail = "tailscale.exe missing" }
} catch { $tsDetail = "error: $_" }
Check "Tailscale" $tsOk $tsDetail ($tsDetail -match "restarted|reconnected")

# 8. Emby running
$emby = Get-Process -Name "EmbyServer*" -ErrorAction SilentlyContinue
if ($emby) { Check "Emby" $true "running (PID $($emby[0].Id))" }
else {
    # best-effort auto-start from common locations
    $candidates = @(
        "$env:APPDATA\Emby-Server\system\EmbyServer.exe",
        "$env:ProgramFiles\Emby-Server\system\EmbyServer.exe",
        "${env:ProgramFiles(x86)}\Emby-Server\system\EmbyServer.exe"
    )
    $started = $false
    foreach ($c in $candidates) {
        if (Test-Path $c) { try { Start-Process $c -ErrorAction Stop; $started = $true; break } catch {} }
    }
    if ($started) { Start-Sleep 10; Check "Emby" $true "was down -> started" $true }
    else { Check "Emby" $false "not running and auto-start failed — launch Emby Server from Start menu" }
}

# 9. Disk space
foreach ($d in @("C", "D")) {
    $drv = Get-PSDrive $d -ErrorAction SilentlyContinue
    if ($drv -and $drv.Free -ne $null) {
        $pct = [math]::Round($drv.Free / ($drv.Free + $drv.Used) * 100, 1)
        Check "Disk $d free" ($pct -gt 10) "$pct% free"
    }
}

# 10. IObit remnants
$remnants = @()
$remnants += Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*IObit*" -or $_.Name -like "*ASCService*" } | ForEach-Object { "service: $($_.Name)" }
$remnants += Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*IObit*" -or $_.TaskName -like "*ASC*" } | ForEach-Object { "task: $($_.TaskName)" }
foreach ($f in @("$env:ProgramFiles\IObit", "${env:ProgramFiles(x86)}\IObit", "$env:ProgramData\IObit")) {
    if (Test-Path $f) { $remnants += "folder: $f" }
}
Check "IObit remnants" ($remnants.Count -eq 0) ($(if ($remnants.Count -eq 0) { "none" } else { $remnants -join "; " }))

# ---- Write status file ----
$now = Get-Date
$failCount = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$fixCount = ($results | Where-Object { $_.Status -eq "FIXED" }).Count
$verdict = if ($failCount -eq 0) { "ALL SYSTEMS GO" } else { "$failCount ISSUE(S) NEED ATTENTION" }
$out = @()
$out += "=== SAVANT STATUS — $now ==="
$out += "Verdict: $verdict ($fixCount auto-fixed this run)"
$out += ""
foreach ($r in $results) { $out += "[$($r.Status)] $($r.Name): $($r.Detail)" }
$out += ""
$out += "Share this file with Muse if anything says FAIL."
$out | Out-File $statusFile -Encoding utf8

Write-Host ""
Write-Host $verdict -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host "Status saved: Desktop\savant-status.txt" -ForegroundColor Cyan

# ---- Install scheduled task (logon + daily) ----
try {
    $taskName = "SavantPC Health Check"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installed`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Daily -At 12:00PM)
    )
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Description "Savant Mode: PC health check + self-heal (power, Tailscale, Emby, Defender, disks)" -ErrorAction Stop | Out-Null
    Write-Host "Scheduled: '$taskName' runs at every logon + daily at noon." -ForegroundColor Green
} catch { Write-Host "Task scheduling failed: $_" -ForegroundColor Yellow }

pause
