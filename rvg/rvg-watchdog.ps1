# RVG Watchdog - ensures the RVG agent is alive and responding.
# Runs every 2 minutes via scheduled task "RVG watchdog".
# On failure: kills stale port-holders, restarts the "RVG agent" task.

$ErrorActionPreference = "SilentlyContinue"

$TokenFile = "C:\Users\sethr\rvd\token.txt"
$TaskName = "RVG agent"
$Port = 8899
$LogFile = "C:\Users\sethr\rvd\watchdog.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $LogFile "$ts $msg"
}

function Notify($title, $msg) {
    # Windows toast notification - best effort, never throws
    try {
        $t = $title; $m = $msg
        if (Get-Module -ListAvailable -Name BurntToast) {
            try { New-BurntToastNotification -Text $t, $m -ErrorAction Stop; return } catch {}
        }
        try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
            $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            $tx = $tpl.GetElementsByTagName("text")
            $tx[0].AppendChild($tpl.CreateTextNode($t)) | Out-Null
            $tx[1].AppendChild($tpl.CreateTextNode($m)) | Out-Null
            $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("RVG Watchdog").Show($toast)
            return
        } catch {}
        try { msg * "$t : $m" } catch {}
    } catch {}
}

# Read token
if (-not (Test-Path $TokenFile)) { Log "no token file"; exit 1 }
$token = (Get-Content $TokenFile -Raw).Trim()

# Health check
$healthy = $false
try {
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/rvd/status" `
        -Headers @{"X-RVD-Token" = $token} -TimeoutSec 10 -UseBasicParsing
    if ($resp.StatusCode -eq 200) { $healthy = $true }
} catch {
    $healthy = $false
}

if ($healthy) { exit 0 }

Log "RVG unhealthy, attempting recovery"

$killedAny = $false
# Kill stale processes holding the port
try {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -like "python*") {
            Log "killing stale $($proc.ProcessName) pid $($proc.Id)"
            Stop-Process -Id $proc.Id -Force
            $killedAny = $true
        }
    }
} catch {
    Log "port cleanup: $_"
}

Start-Sleep 2

# Restart the agent task
try {
    Start-ScheduledTask -TaskName $TaskName
    Log "restarted $TaskName"
    $detail = if ($killedAny) { "Killed stale process and restarted RVG agent." } else { "Restarted RVG agent." }
    Notify "RVG Watchdog" "RVG was down. $detail"
} catch {
    Log "restart failed: $_"
    Notify "RVG Watchdog" "RVG is down and automatic restart FAILED. Manual intervention needed."
    exit 1
}

exit 0
