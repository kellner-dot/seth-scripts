# TeraBox rclone mount watchdog (v3 - with copy job + Movies migration monitoring)
# Runs every 5 minutes via the "TeraBox Watchdog" scheduled task.
# 1. Ensures T: (rclone mount of tb:/) is always accessible.
# 2. Monitors TeraBox copy jobs (scheduled tasks) for stalls/errors, sends phone push on issues.
# 3. Monitors Movies migration rclone processes (started by "TeraBox Uploaders" daily task)
#    for stalls/errors/idle, sends phone push on issues.

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

# Movies migration log files (friendly name -> log path).
# Written by rclone processes started daily at 6am by the "TeraBox Uploaders" task
# (C:\Users\sethr\rvd\start-uploaders.ps1). Detected via Win32_Process command line
# matching "tb:Movies" (the mount process uses "rclone mount tb:/ T:" and won't match).
$moviesMigrations = @{
    "Movies D-drive"  = "C:\Users\sethr\rvd\migrate.log"
    "Movies OneDrive" = "C:\Users\sethr\rvd\migrate2.log"
}
# Idle threshold: "TeraBox Uploaders" hasn't run in X hours while a migration is
# incomplete and no rclone is copying = alert (the daily 6am copy may be failing).
$uploadersIdleThresholdHours = 24

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

function Get-MoviesRcloneProcesses() {
    # Returns rclone.exe processes whose command line targets tb:Movies.
    # The T: mount process ("rclone mount tb:/ T:") and the TV Shows copy
    # ("rclone copy ... tb:/TV Shows") do NOT match.
    # NOTE: processes started by the "TeraBox Uploaders" scheduled task may run in a
    # different security context, in which case Win32_Process.CommandLine comes back
    # empty and they can't be matched here. Log freshness (below) covers that case.
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction Stop |
            Where-Object { "$($_.CommandLine)" -match '(?i)tb:Movies' })
    } catch {
        Write-Log "Movies monitor: failed to enumerate rclone processes: $($_.Exception.Message)"
        return @()
    }
}

function Test-MigrationComplete([string]$logPath) {
    # Heuristic: the last file-count "Transferred: X / Y," summary line has X == Y.
    # (The byte-count "Transferred: 74.273 GiB / 83.006 GiB," line has decimals and
    # won't match the integer-only pattern, so only the file-count line is seen.)
    try {
        $tail = Get-Content $logPath -Tail 100 -ErrorAction Stop
        $transferLines = @($tail | Where-Object { $_ -match 'Transferred:\s+(\d+)\s*/\s*(\d+),' })
        if ($transferLines.Count -eq 0) { return $false }
        $last = $transferLines[-1]
        if ($last -match 'Transferred:\s+(\d+)\s*/\s*(\d+),') {
            $done = [int]$matches[1]
            $total = [int]$matches[2]
            return ($total -gt 0 -and $done -ge $total)
        }
    } catch {}
    return $false
}

function Check-MoviesMigration($state) {
    # Detection model (robust against unreadable process command lines):
    #   logFresh   = log written within the stall threshold  -> rclone is actively copying
    #   procVisible = rclone process with matching CL found   -> rclone is alive
    #   active     = logFresh OR procVisible
    #   complete   = log NOT fresh AND last file-count summary shows X/X
    # A visible-but-stale process = genuine stall. An idle-but-incomplete
    # migration is normal between the daily 6am runs; only alert if the
    # Uploaders task itself hasn't run in >24h.
    $rcloneProcs = Get-MoviesRcloneProcesses
    Write-Log "Movies monitor: found $($rcloneProcs.Count) rclone process(es) with tb:Movies command line"

    $anyActive = $false
    $allComplete = $true

    foreach ($jobName in $moviesMigrations.Keys) {
        $logPath = $moviesMigrations[$jobName]
        $notifyKeyStall = "movies-$jobName-stall"
        $notifyKeyError = "movies-$jobName-error"

        # Identify the process writing to this job's log (log filename in its command line).
        # "migrate.log" is NOT a substring of "migrate2.log", so the two jobs stay distinct.
        $logFileName = [System.IO.Path]::GetFileName($logPath)
        $jobProcs = @($rcloneProcs | Where-Object { "$($_.CommandLine)" -match [regex]::Escape($logFileName) })
        $procVisible = $jobProcs.Count -gt 0

        $logExists = Test-Path $logPath
        $logFresh = $false
        if ($logExists) {
            $logAge = (Get-Date) - (Get-Item $logPath).LastWriteTime
            $logFresh = $logAge.TotalMinutes -le $stallThresholdMinutes
        }
        # Only trust the completion heuristic once the log has gone quiet;
        # a fresh log means a run is still in flight (or just ended).
        $complete = (-not $logFresh) -and $logExists -and (Test-MigrationComplete $logPath)

        if ($complete) {
            Write-Log "Movies monitor: '$jobName' appears complete - no alert"
            Clear-Notify $notifyKeyStall $state
            Clear-Notify $notifyKeyError $state
            continue
        }

        $allComplete = $false
        $active = $logFresh -or $procVisible

        if ($active) {
            $anyActive = $true
            if ($procVisible) {
                Write-Log "Movies monitor: '$jobName' rclone process visible (PID $($jobProcs[0].ProcessId)), logFresh=$logFresh"
            } else {
                Write-Log "Movies monitor: '$jobName' active via fresh log (process command line not readable)"
            }

            # --- STALL DETECTION: process alive but no log progress ---
            if ($procVisible -and -not $logFresh) {
                $msg = "Movies migration '$jobName' appears stalled - rclone is running but no log activity for over $stallThresholdMinutes min."
                Write-Log "Movies monitor STALL: $msg"
                if (Should-Notify $notifyKeyStall $state) {
                    Send-Toast "TeraBox Movies Stalled" $msg
                    Send-PhonePush "TeraBox Movies Stalled" "$msg Check the PC."
                    Record-Notify $notifyKeyStall $state
                }
            } else {
                Clear-Notify $notifyKeyStall $state
            }

            # --- ERROR DETECTION ---
            if ($logExists) {
                try {
                    $tail = Get-Content $logPath -Tail 50 -ErrorAction Stop
                    $errorLines = $tail | Where-Object { $_ -match 'Errors:\s+(\d+)' }
                    if ($errorLines) {
                        $lastErrorLine = $errorLines | Select-Object -Last 1
                        if ($lastErrorLine -match 'Errors:\s+(\d+)') {
                            $errorCount = [int]$matches[1]
                            if ($errorCount -gt 0) {
                                $msg = "Movies migration '$jobName' reports $errorCount error(s). Check the log for details."
                                Write-Log "Movies monitor ERRORS: $msg"
                                if (Should-Notify $notifyKeyError $state) {
                                    Send-Toast "TeraBox Movies Errors" $msg
                                    Send-PhonePush "TeraBox Movies Errors" "$msg Log: $logPath"
                                    Record-Notify $notifyKeyError $state
                                }
                            } else {
                                Clear-Notify $notifyKeyError $state
                            }
                        }
                    }
                } catch {
                    Write-Log "Movies monitor: failed to parse log tail: $($_.Exception.Message)"
                }
            }
        } else {
            # Idle: nothing copying and migration incomplete.
            # Normal between the daily 6am runs - handled by the idle check below.
            Clear-Notify $notifyKeyStall $state
            Write-Log "Movies monitor: '$jobName' idle (incomplete, nothing copying)"
        }
    }

    # --- IDLE DETECTION ---
    # Nothing copying and at least one migration incomplete: only alert if the
    # daily Uploaders task itself hasn't run in over 24h (between-run idle is normal).
    $idleKey = "movies-uploaders-idle"
    if (-not $anyActive -and -not $allComplete) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName "TeraBox Uploaders" -ErrorAction Stop
            $lastRun = $info.LastRunTime
            if ($lastRun -and $lastRun -ne [DateTime]::MinValue) {
                $idleHours = ((Get-Date) - $lastRun).TotalHours
                Write-Log "Movies monitor: idle, Uploaders last ran $([int]$idleHours)h ago"
                if ($idleHours -gt $uploadersIdleThresholdHours) {
                    $msg = "Movies migration is idle and the 'TeraBox Uploaders' task hasn't run in $([int]$idleHours) hours. The daily 6am copy may be failing."
                    Write-Log "Movies monitor IDLE: $msg"
                    if (Should-Notify $idleKey $state) {
                        Send-Toast "TeraBox Movies Idle" $msg
                        Send-PhonePush "TeraBox Movies Idle" $msg
                        Record-Notify $idleKey $state
                    }
                } else {
                    Clear-Notify $idleKey $state
                }
            } else {
                Write-Log "Movies monitor: Uploaders task has never run"
            }
        } catch {
            Write-Log "Movies monitor: could not read Uploaders task info: $($_.Exception.Message)"
        }
    } else {
        Clear-Notify $idleKey $state
    }
}

# ============================================================================
# MAIN
# ============================================================================

$state = Get-State

# --- PART 1a: TV Shows copy job monitoring (runs every check) ---
Check-CopyJobs $state

# --- PART 1b: Movies migration rclone process monitoring (runs every check) ---
Check-MoviesMigration $state

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