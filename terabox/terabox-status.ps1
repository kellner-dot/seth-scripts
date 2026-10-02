# TeraBox Migration Status - JSON output for dashboard
# Parses rclone log files and returns migration progress as JSON
# Usage: powershell -File terabox-status.ps1

$ErrorActionPreference = "SilentlyContinue"

function Parse-RcloneLog {
    param([string]$LogPath, [string]$Name)
    
    $result = @{
        name = $Name
        logPath = $LogPath
        exists = $false
        running = $false
        bytesTransferred = ""
        bytesTotal = ""
        bytesPercent = 0
        filesTransferred = 0
        filesTotal = 0
        filesPercent = 0
        speed = ""
        eta = ""
        elapsed = ""
        errors = 0
        lastUpdate = ""
        currentFiles = @()
        status = "unknown"
    }
    
    if (-not (Test-Path $LogPath)) {
        $result.status = "no-log"
        return $result
    }
    
    $result.exists = $true
    
    # Get last 60 lines for parsing
    $lines = Get-Content $LogPath -Tail 60
    
    # Find the most recent "Transferred:" blocks
    # Format: Transferred:   \t    8.252 GiB / 16.985 GiB, 49%, 750.701 KiB/s, ETA 3h23m17s
    # Format: Transferred:            0 / 26, 0%
    
    $bytesPattern = 'Transferred:\s+([\d\.]+\s+\w+)\s+/\s+([\d\.]+\s+\w+),\s+(\d+)%,\s+([^\s,]+(?:\s+[^\s,]+)?),\s+ETA\s+([^\s]+)'
    $filesPattern = 'Transferred:\s+(\d+)\s+/\s+(\d+),\s+(\d+)%'
    $elapsedPattern = 'Elapsed time:\s+([^\s]+)'
    $errorsPattern = 'Errors:\s+(\d+)'
    $timestampPattern = '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})'
    
    # Parse from the end (most recent first)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        
        # Timestamp
        if ($result.lastUpdate -eq "" -and $line -match $timestampPattern) {
            $result.lastUpdate = $matches[1]
        }
        
        # Bytes transferred (only take the first/most recent match)
        if ($result.bytesTotal -eq "" -and $line -match $bytesPattern) {
            $result.bytesTransferred = $matches[1]
            $result.bytesTotal = $matches[2]
            $result.bytesPercent = [int]$matches[3]
            $result.speed = $matches[4]
            $result.eta = $matches[5]
        }
        
        # Files transferred (only take the first/most recent match)
        if ($result.filesTotal -eq 0 -and $line -match $filesPattern) {
            # Make sure this isn't the bytes line (bytes line has GiB/MiB)
            if ($line -notmatch 'GiB|MiB|KiB|GB|MB|KB') {
                $result.filesTransferred = [int]$matches[1]
                $result.filesTotal = [int]$matches[2]
                $result.filesPercent = [int]$matches[3]
            }
        }
        
        # Elapsed time
        if ($result.elapsed -eq "" -and $line -match $elapsedPattern) {
            $result.elapsed = $matches[1]
        }
        
        # Errors
        if ($line -match $errorsPattern) {
            $errCount = [int]$matches[1]
            if ($errCount -gt $result.errors) {
                $result.errors = $errCount
            }
        }
        
        # Current transferring files
        if ($line -match '^\s*\*\s+(.+?):(\d+)%\s+/\s+(.+?),\s+(.+?),\s+(\d+s)') {
            $result.currentFiles += @{
                name = $matches[1].Trim()
                percent = [int]$matches[2]
                size = $matches[3]
                speed = $matches[4]
            }
            if ($result.currentFiles.Count -ge 5) { break }
        }
    }
    
    # Check if the scheduled task is running
    try {
        $task = Get-ScheduledTask -TaskName "*TV Shows*" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*TeraBox*" }
        if ($task) {
            $result.running = ($task.State -eq "Running")
            $result.taskName = $task.TaskName
            $result.taskState = $task.State.ToString()
        }
    } catch {}
    
    # Determine status
    if ($result.running) {
        if ($result.speed -match "0\s*B/s|^\s*$") {
            $result.status = "stalled"
        } else {
            $result.status = "running"
        }
    } elseif ($result.filesPercent -eq 100 -or ($result.filesTotal -gt 0 -and $result.filesTransferred -eq $result.filesTotal)) {
        $result.status = "complete"
    } elseif ($result.lastUpdate -ne "") {
        $result.status = "paused"
    } else {
        $result.status = "unknown"
    }
    
    return $result
}

# Check all known migrations
$migrations = @()

# TV Shows
$tvShows = Parse-RcloneLog -LogPath "C:\Users\sethr\rvd\terabox-tvshows.log" -Name "TV Shows"
$tvShows.source = "C:\Users\sethr\OneDrive\Desktop\TV Shows"
$tvShows.destination = "tb:/TV Shows"
$migrations += $tvShows

# Movies (future - check if log exists)
$moviesLog = "C:\Users\sethr\rvd\terabox-movies.log"
if (Test-Path $moviesLog) {
    $movies = Parse-RcloneLog -LogPath $moviesLog -Name "Movies"
    $movies.source = "TBD"
    $movies.destination = "tb:/Movies"
    $migrations += $movies
} else {
    $migrations += @{
        name = "Movies"
        status = "pending"
        bytesTransferred = "0"
        bytesTotal = "~324 GB"
        bytesPercent = 0
        filesTransferred = 0
        filesTotal = 0
        filesPercent = 0
        speed = "-"
        eta = "-"
        elapsed = "-"
        errors = 0
        lastUpdate = ""
        currentFiles = @()
        source = "C: / D: (TBD)"
        destination = "tb:/Movies"
        note = "Queued after TV Shows verifies"
    }
}

# Check TeraBox mount status
$mountOk = Test-Path "T:\"
$mountStatus = @{
    mounted = $mountOk
    drive = "T:"
}

$output = @{
    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    hostname = $env:COMPUTERNAME
    mount = $mountStatus
    migrations = $migrations
}

$output | ConvertTo-Json -Depth 5 -Compress
