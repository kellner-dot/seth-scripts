# TeraBox rclone mount watchdog (v2 - with copy job monitoring)
# Runs every 5 minutes via the "TeraBox Watchdog" scheduled task.
# 1. Ensures T: (rclone mount of tb:/) is always accessible.
# 2. Monitors TeraBox copy jobs for stalls/errors, sends phone push on issues.

$logFile   = "C:\rclone\watchdog.log"
$stateFile = "C:\rclone\watchdog-state.json"
$rcloneExe = "C:\rclone\rclone.exe"
$alistExe  = "C:\alist\alist.exe"
$alistArgs  = @("server","--data","C:\alist\data")
$mountArgs = @("mount","tb:/","T:","--vfs-cache-mode","full","--vfs-cache-max-size","50G","--dir-cache-time","24h","--network-mode")
$tokenFile = "C:\Users\sethr\rvd\token.txt"
$rvgPushUrl = "http://127.0.0.1:8899/rvd/push"

# Copy jobs to monitor: TaskName -> LogFile
$copyJobs = @{
    "TeraBox TV Shows Copy" = "C:\Users\sethr\rvd\terabox-tvshows.log"
}

# Stall threshold: log not updated in X minutes while task is Running = stalled
$stallThresholdMinutes = 15
# Minimum minutes between repeat notifications for the same issue
$notifyCooldownMinutes = 60

function Write-Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $msg" -ErrorAction SilentlyContinue
}

function Send-Toast([string]$title, [string]$msg) {
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            try { New-BurntToastNotification -Text $title, $msg -ErrorAction Stop; return } catch {}
        }
        try {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
            $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            $tx = $tpl.GetElementsByTagName("text")
            $tx[0].AppendChild($tpl.CreateTextNode($title)) | Out-Null
            $tx[1].AppendChild($tpl.CreateTextNode($msg)) | Out-Null
            $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("TeraBox Watchdog").Show($toast)
        } catch {}
    } catch {}
}

function Send-PhonePush([string]$title, [string]$msg) {
    try {
        if (-not (Test-Path $tokenFile)) {
            Write-Log "Push skipped: token file not found"
            return $false
        }
        $token = (Get-Content $tokenFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Log "Push skipped: token empty"
            return $false
        }
        $body = @{ title = $title; message = $msg } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri $rvgPushUrl -Method Post `
            -Headers @{ 'X-RVD-Token' = $token } `
            -Body $body -ContentType 'application/json' -TimeoutSec 15
        Write-Log "Phone push sent: $title"
        return $true
    } catch {
        Write-Log "Phone push FAILED: $($_.Exception.Message)"
        return $false
    }
}

function Get-State() {
    try {
        if (Test-Path $stateFile) {
            return Get-Content $stateFile -Raw | ConvertFrom-Json
        }
    } catch {}
    return [PSCustomObject]@{ notifications = @{} }
}

function Save-State($state) {
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content $stateFile -ErrorAction Stop
    } catch {
        Write-Log "Failed to save state file: $($_.Exception.Message)"
    }
}

function Should-Notify([string]$key, $state) {
    # Returns $true if we haven't notified for this key within the cooldown period
    try {
        $lastNotify = $state.notifications.$key
        if (-not $lastNotify) { return $true }
        $lastTime = [DateTime]::Parse($lastNotify)
        $elapsed = (Get-Date) - $lastTime
        return $elapsed.TotalMinutes -ge $notifyCooldownMinutes
    } catch {
        return $true
    }
}

function Record-Notify([string]$key, $state) {
    if (-not $state.notifications) {
        $state | Add-Member -NotePropertyName 'notifications' -NotePropertyValue @{} -Force
    }
    # PSCustomObject doesn't support direct hashtable assignment; use Add-Member
    $state.notifications | Add-Member -NotePropertyName $key -NotePropertyValue (Get-Date -Format "o") -Force
}

function Clear-Notify([string]$key, $state) {
    try {
        if ($state.notifications.PSObject.Properties[$key]) {
            $state.notifications.PSObject.Properties.Remove($key)
        }
    } catch {}
}

function Check-CopyJobs($state) {
    foreach ($taskName in $copyJobs.Keys) {
        $logPath = $copyJobs[$taskName]
        $notifyKeyStall = "$taskName-stall"
        $notifyKeyError = "$taskName-error"

        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        } catch {
            Write-Log "Copy monitor: task '$taskName' not found, skipping"
            continue
        }

        $taskState = $task.State.ToString()
        Write-Log "Copy monitor: '$taskName' state=$taskState"

        # Only check for stalls/errors when the task is actively Running
        if ($taskState -ne 'Running') {
            # Task not running - clear any stall notification state (job may have finished)
            Clear-Notify $notifyKeyStall $state
            continue
        }

        # Task is Running - check the log file
        if (-not (Test-Path $logPath)) {
            Write-Log "Copy monitor: log not found at $logPath"
            continue
        }

        $logInfo = Get-Item $logPath
        $logAge = (Get-Date) - $logInfo.LastWriteTime

        # --- STALL DETECTION ---
        if ($logAge.TotalMinutes -gt $stallThresholdMinutes) {
            $msg = "'$taskName' appears stalled - no log activity for $([int]$logAge.TotalMinutes) min."
            Write-Log "Copy monitor STALL: $msg"
            if (Should-Notify $notifyKeyStall $state) {
                Send-Toast "TeraBox Copy Stalled" $msg
                Send-PhonePush "TeraBox Copy Stalled" "$msg Check the PC."
                Record-Notify $notifyKeyStall $state
            }
        } else {
            # Log is fresh - clear stall notification state
            Clear-Notify $notifyKeyStall $state
        }

        # --- ERROR DETECTION ---
        # Parse the last 50 lines for rclone "Errors:" summary
        try {
            $tail = Get-Content $logPath -Tail 50 -ErrorAction Stop
            $errorLines = $tail | Where-Object { $_ -match 'Errors:\s+(\d+)' }
            if ($errorLines) {
                $lastErrorLine = $errorLines | Select-Object -Last 1
                if ($lastErrorLine -match 'Errors:\s+(\d+)') {
                    $errorCount = [int]$matches[1]
                    if ($errorCount -gt 0) {
                        $msg = "'$taskName' reports $errorCount error(s). Check the log for details."
                        Write-Log "Copy monitor ERRORS: $msg"
                        if (Should-Notify $notifyKeyError $state) {
                            Send-Toast "TeraBox Copy Errors" $msg
                            Send-PhonePush "TeraBox Copy Errors" "$msg Log: $logPath"
                            Record-Notify $notifyKeyError $state
                        }
                    } else {
                        Clear-Notify $notifyKeyError $state
                    }
                }
            }
        } catch {
            Write-Log "Copy monitor: failed to parse log tail: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

$state = Get-State

# --- PART 1: Copy job monitoring (runs every check) ---
Check-CopyJobs $state

# --- PART 2: Mount monitoring (existing logic, unchanged) ---

# Fast path: T: healthy -> save state and exit
if (Test-Path "T:\") {
    Save-State $state
    exit 0
}

Write-Log "T: not accessible - attempting recovery"

# 1. Alist (WebDAV bridge on :5244) must be up; the tb: remote depends on it
$alist = Get-Process alist -ErrorAction SilentlyContinue
if (-not $alist) {
    Write-Log "Alist not running - starting it"
    try {
        Start-Process -FilePath $alistExe -ArgumentList $alistArgs -WindowStyle Hidden -WorkingDirectory "C:\alist"
        Start-Sleep -Seconds 5
        Write-Log "Alist start issued"
    } catch {
        Write-Log "FAILED to start Alist: $($_.Exception.Message)"
    }
}

# 2. Kill any stale rclone processes (covers "process alive but T: dead")
Get-Process rclone -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log "Killing stale rclone process (PID $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

# 3. Start a fresh mount in the background, hidden window
try {
    Start-Process -FilePath $rcloneExe -ArgumentList $mountArgs -WindowStyle Hidden
    Write-Log "Started new rclone mount process"
} catch {
    Write-Log "FAILED to start rclone: $($_.Exception.Message)"
    Save-State $state
    exit 1
}

# 4. Verify recovery
Start-Sleep -Seconds 20
if (Test-Path "T:\") {
    Write-Log "Recovery successful - T: is accessible"
    Send-Toast "TeraBox Watchdog" "T: drive was down and has been restored."
    Send-PhonePush "TeraBox Restored" "T: drive was down and has been restored."
} else {
    Write-Log "WARNING: T: still not accessible after restart"
    Send-Toast "TeraBox Watchdog" "T: drive is down and automatic recovery FAILED. Manual intervention needed."
    Send-PhonePush "TeraBox DOWN" "T: drive is down and automatic recovery FAILED. Manual intervention needed."
}

Save-State $state
