# health-check.ps1 - Kavi-independent system health check for Seth's PC.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File health-check.ps1
# Output: GREEN / RED per system, summary at the end. Exit 0 = all green, 1 = any red.
# See CONTINUITY.md for what to do about any RED.

$ErrorActionPreference = "SilentlyContinue"
$results = @()

function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $status = if ($ok) { "GREEN" } else { "RED" }
    $script:results += [pscustomobject]@{ System = $name; Status = $status; Detail = $detail }
}

# --- 1. RVG agent (port 8899) ---
$rvgOk = $false; $rvgDetail = ""
$tokenFile = "C:\Users\sethr\rvd\token.txt"
try {
    $portOpen = Get-NetTCPConnection -LocalPort 8899 -State Listen -ErrorAction Stop
    if ($portOpen) {
        if (Test-Path $tokenFile) {
            $token = (Get-Content $tokenFile -Raw).Trim()
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:8899/rvd/status" `
                -Headers @{"X-RVD-Token" = $token} -TimeoutSec 10 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                $rvgOk = $true
                $ver = ""
                try { $ver = ($resp.Content | ConvertFrom-Json).version } catch {}
                $rvgDetail = "responding" + $(if ($ver) { " (v$ver)" })
            } else { $rvgDetail = "port open but status=$($resp.StatusCode)" }
        } else { $rvgDetail = "port open but no token file" }
    } else { $rvgDetail = "port 8899 not listening" }
} catch { $rvgDetail = "port 8899 not listening ($($_.Exception.Message))" }
Add-Result "RVG agent :8899" $rvgOk $rvgDetail

# --- 2. T: drive (TeraBox mount) ---
$tOk = Test-Path "T:\"
$tDetail = if ($tOk) {
    try { $n = (Get-ChildItem "T:\" -ErrorAction Stop | Measure-Object).Count; "$n top-level entries visible" }
    catch { "accessible" }
} else { "not accessible - check Alist + rclone (see CONTINUITY.md)" }
Add-Result "TeraBox mount (T:)" $tOk $tDetail

# --- 3. Alist (TeraBox dependency, :5244) ---
$alist = Get-Process alist -ErrorAction SilentlyContinue
Add-Result "Alist :5244" ($null -ne $alist) $(if ($alist) { "running (PID $($alist.Id))" } else { "NOT running - T: will fail" })

# --- 4. TeraBox Watchdog scheduled task ---
$tbTask = Get-ScheduledTask -TaskName "TeraBox Watchdog" -ErrorAction SilentlyContinue
$tbOk = ($null -ne $tbTask) -and ($tbTask.State -ne "Disabled")
$tbDetail = if ($null -eq $tbTask) { "task not found" } else { "State=$($tbTask.State)" }
Add-Result "TeraBox Watchdog task" $tbOk $tbDetail

# --- 5. RVG Watchdog process (2-min loop) ---
$wdRunning = $false
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
    foreach ($p in $procs) {
        if ($p.CommandLine -like "*watchdog*") { $wdRunning = $true; break }
    }
} catch {}
# Fallback: recent log activity counts as alive
if (-not $wdRunning -and (Test-Path "C:\Users\sethr\rvd\watchdog.log")) {
    $last = (Get-Item "C:\Users\sethr\rvd\watchdog.log").LastWriteTime
    if (((Get-Date) - $last).TotalMinutes -lt 10) { $wdRunning = $true }
}
Add-Result "RVG Watchdog (2-min)" $wdRunning $(if ($wdRunning) { "active" } else { "not detected - see CONTINUITY.md to start" })

# --- 6. Emby Server (:8096) ---
$embyOk = $false; $embyDetail = ""
try {
    $e = Invoke-WebRequest -Uri "http://localhost:8096/emby/System/Info/Public" -TimeoutSec 10 -UseBasicParsing
    if ($e.StatusCode -eq 200) {
        $embyOk = $true
        try { $embyDetail = ($e.Content | ConvertFrom-Json).ServerName } catch { $embyDetail = "responding" }
    } else { $embyDetail = "HTTP $($e.StatusCode)" }
} catch { $embyDetail = "not responding" }
Add-Result "Emby Server :8096" $embyOk $embyDetail

# --- 7. Disk space ---
$cDrive = Get-PSDrive C -ErrorAction SilentlyContinue
$cFreeGB = if ($cDrive) { [math]::Round($cDrive.Free / 1GB, 1) } else { -1 }
$cOk = $cFreeGB -gt 10
Add-Result "Disk C: free" $cOk $(if ($cFreeGB -ge 0) { "$cFreeGB GB free" + $(if (-not $cOk) { " (LOW!)" }) } else { "unknown" })

# T: free space is rclone's placeholder (~1PB); report real usage via rclone about if available
$tFreeNote = "rclone reports placeholder quota - check TeraBox app for real usage"
Add-Result "Disk T: free" $tOk $tFreeNote

# --- Report ---
$width = 28
foreach ($r in $results) {
    $color = if ($r.Status -eq "GREEN") { "Green" } else { "Red" }
    Write-Host ("{0,-$width} " -f $r.System) -NoNewline
    Write-Host $r.Status -ForegroundColor $color -NoNewline
    Write-Host ("  " + $r.Detail)
}
$red = ($results | Where-Object { $_.Status -eq "RED" }).Count
Write-Host ""
if ($red -eq 0) {
    Write-Host "ALL SYSTEMS GREEN" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$red system(s) RED - see CONTINUITY.md section 2 for recovery steps." -ForegroundColor Red
    exit 1
}
