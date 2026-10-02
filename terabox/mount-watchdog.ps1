# TeraBox rclone mount watchdog
# Runs every 5 minutes via the "TeraBox Watchdog" scheduled task.
# Ensures T: (rclone mount of tb:/) is always accessible.

$logFile   = "C:\rclone\watchdog.log"
$rcloneExe = "C:\rclone\rclone.exe"
$alistExe  = "C:\alist\alist.exe"
$alistArgs  = @("server","--data","C:\alist\data")
$mountArgs = @("mount","tb:/","T:","--vfs-cache-mode","full","--vfs-cache-max-size","50G","--dir-cache-time","24h","--network-mode")

function Write-Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $msg" -ErrorAction SilentlyContinue
}

# Fast path: T: healthy -> nothing to do, stay quiet
if (Test-Path "T:\") { exit 0 }

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
    exit 1
}

# 4. Verify recovery
Start-Sleep -Seconds 20
if (Test-Path "T:\") {
    Write-Log "Recovery successful - T: is accessible"
    exit 0
} else {
    Write-Log "WARNING: T: still not accessible after restart"
    exit 1
}
