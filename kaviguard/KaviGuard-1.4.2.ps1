param(
    [switch]$Status,
    [ValidateSet("Quick", "Full")][string]$ScanNow,
    [string]$AddExclusion,
    [string]$RemoveExclusion,
    [switch]$TuneUp,
    [string]$ScanPath
)

# KaviGuard v1 - lightweight malware watcher for Windows.
# Honest design: Windows Defender stays the engine. KaviGuard watches new files,
# checks hashes against MalwareBazaar, monitors persistence points, runs
# scheduled Defender scans, and updates itself. No kernel driver, no AV engine.

# ------------------------------ config ------------------------------
$Version       = "1.4.2"
$InstallDir    = "C:\Tools\KaviGuard"
$QuarantineDir = Join-Path $InstallDir "quarantine"
$LogDir        = Join-Path $InstallDir "logs"

$WatchFolders = @(
    (Join-Path $env:USERPROFILE "Downloads"),
    ([Environment]::GetFolderPath("Desktop")),
    $env:TEMP
)
$ScanExtensions = @(".exe",".msi",".bat",".cmd",".ps1",".vbs",".js",".jse",".scr",".dll",".com",".pif")
$MaxHashMB      = 500   # files bigger than this skip hash/lookup, still get a Defender scan

# Exclusions: folders KaviGuard never touches (no hash, no lookup, no quarantine,
# and the installer adds them as Defender exclusions too).
# These are blind spots by design - keep this list tight, review it occasionally.
$ExcludePaths = @(
    (Join-Path $env:USERPROFILE "rvd"),
    (Join-Path $env:USERPROFILE "rvg13"),
    (Join-Path $env:USERPROFILE "rvg14"),
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "RVG-v1.2-rollback"),
    "C:\Tools\KaviGuard",
    "C:\Users\sethr\kavi-mail",
    "C:\Program Files\Tailscale",
    "C:\Program Files\Mesh Agent"
)
$ExcludeFileNames = @("tailscale.exe", "meshagent.exe")   # exact file names to skip

# Known-good persistence entries: never alert on these (substring match, case-insensitive).
# Tunnels are infrastructure - the watcher protects them, never fights them.
$KnownGoodTasks = @(
    "Tailscale",
    "Mesh Agent",
    "meshagent",
    "KaviGuard",
    "KaviGuard-Mailbox",
    "RVG agent",
    "RVG update check"
)

$UpdateBaseUrl = "https://raw.githubusercontent.com/kellner-dot/kaviguard/main"

$QuickScanTime = "03:00"   # daily Defender QuickScan at/after HH:mm
$FullScanDay   = "Sunday"  # weekly Defender FullScan weekday
$FullScanTime  = "03:00"   # ...at/after HH:mm
# --------------------------------------------------------------------

# trailing backslash on prefixes so C:\Tools\KaviGuard2 can't false-match
$ExcludePaths = @($ExcludePaths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })

# Extra exclusions added at runtime via -AddExclusion. Kept in a separate file
# so they survive self-updates (which replace this script).
$ExtraExclusionsFile = Join-Path $InstallDir "extra-exclusions.json"
try {
    if (Test-Path $ExtraExclusionsFile) {
        $extra = @(Get-Content $ExtraExclusionsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        foreach ($x in $extra) {
            if ($x) { $ExcludePaths += ($x.TrimEnd('\') + '\') }
        }
    }
} catch { }

function Write-KGLog($Message) {
    try {
        if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }
        $f = Join-Path $LogDir ("kaviguard-{0:yyyy-MM-dd}.log" -f (Get-Date))
        "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message | Out-File $f -Append -Encoding UTF8
    } catch {}
}

function Test-KGExcluded($Path) {
    foreach ($p in $ExcludePaths) {
        if ($Path.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $name = [System.IO.Path]::GetFileName($Path)
    foreach ($n in $ExcludeFileNames) {
        if ($n -and $name -ieq $n) { return $true }
    }
    return $false
}

$script:ToastTriedInstall = $false
function Show-KGToast($Title, $Message) {
    # BurntToast if already installed; otherwise the Application event log.
    # Never modal, never installs anything (an install prompt kills hidden tasks).
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
            return
        }
    } catch {}
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("KaviGuard")) {
            New-EventLog -LogName Application -Source "KaviGuard" -ErrorAction Stop
        }
        Write-EventLog -LogName Application -Source "KaviGuard" -EntryType Warning `
            -EventId 1001 -Message "$Title`n$Message" -ErrorAction Stop
    } catch { Write-KGLog "toast fallback failed: $Title - $Message" }
}

function Get-KGBazaarVerdict($Sha256) {
    # MalwareBazaar only lists malware, so query_status=ok means known-bad.
    try {
        $r = Invoke-RestMethod -Uri "https://mb-api.abuse.ch/api/v1/" -Method Post `
            -Body @{ query = "get_info"; hash = $Sha256 } -TimeoutSec 25 -ErrorAction Stop
        if ($r.query_status -eq "ok" -and $r.data -and $r.data.Count -gt 0) {
            Write-KGLog "MalwareBazaar HIT: $Sha256 ($($r.data[0].signature))"
            return "malicious"
        }
        return "clean"
    } catch {
        Write-KGLog "MalwareBazaar lookup failed: $($_.Exception.Message)"
        return "unknown"   # rate limit / offline - Defender scan below still runs
    }
}

function Invoke-KGDefenderFileScan($Path) {
    try {
        Start-MpScan -ScanPath $Path -ScanType QuickScan -ErrorAction Stop
        Write-KGLog "Defender file scan done: $Path"
    } catch {
        try {
            $mp = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
            & $mp -Scan -ScanType 3 -File $Path | Out-Null
            Write-KGLog "Defender file scan done (MpCmdRun): $Path"
        } catch { Write-KGLog "Defender file scan failed ($Path): $($_.Exception.Message)" }
    }
}

function Invoke-KGFileCheck($Path) {
    try {
        if (Test-KGExcluded $Path) { return }
        if (-not [System.IO.File]::Exists($Path)) { return }
        $ext = [System.IO.Path]::GetExtension($Path).ToLower()
        if ($ScanExtensions -notcontains $ext) { return }
        # serialize lookups so we don't hammer MalwareBazaar during big installs
        $mtx = New-Object System.Threading.Mutex($false, "KaviGuardFileScan")
        if (-not $mtx.WaitOne(120000)) { Write-KGLog "scan mutex timeout: $Path"; return }
        try {
            $deadline = (Get-Date).AddSeconds(30)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                    $fs.Close(); $ready = $true; break
                } catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $ready) { Write-KGLog "skip, still locked: $Path"; return }
            $verdict = "unscanned"
            if (((Get-Item $Path -ErrorAction Stop).Length / 1MB) -le $MaxHashMB) {
                $sha256 = (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash
                $verdict = Get-KGBazaarVerdict -Sha256 $sha256
            } else {
                Write-KGLog "skip hash, too big: $Path"
            }
            if ($verdict -eq "malicious") {
                if (-not (Test-Path $QuarantineDir)) { New-Item $QuarantineDir -ItemType Directory -Force | Out-Null }
                $dest = Join-Path $QuarantineDir ((Get-Date).ToString("yyyyMMdd-HHmmss-") + [System.IO.Path]::GetFileName($Path))
                Move-Item -Path $Path -Destination $dest -Force -ErrorAction Stop
                Write-KGLog "QUARANTINED (MalwareBazaar): $Path -> $dest"
                $gs = Get-KGState
                $gs.threatsQuarantined = [int]$gs.threatsQuarantined + 1
                Save-KGState $gs
                Write-KGStatus
                Show-KGToast "KaviGuard: threat quarantined" "Moved to quarantine: $([System.IO.Path]::GetFileName($Path))"
                return
            }
            Invoke-KGDefenderFileScan -Path $Path
        } finally { $mtx.ReleaseMutex() }
    } catch { Write-KGLog "file check error ($Path): $($_.Exception.Message)" }
}

$script:Watchers = @()
foreach ($folder in $WatchFolders) {
    if (-not (Test-Path $folder)) { Write-KGLog "watch folder missing: $folder"; continue }
    $w = New-Object System.IO.FileSystemWatcher
    $w.Path = $folder
    $w.IncludeSubdirectories = $true
    $w.Filter = "*.*"
    $w.NotifyFilter = [System.IO.NotifyFilters]::FileName
    Register-ObjectEvent -InputObject $w -EventName Created -Action {
        Invoke-KGFileCheck -Path $EventArgs.FullPath
    } | Out-Null
    $w.EnableRaisingEvents = $true
    $script:Watchers += $w
    Write-KGLog "watching: $folder"
}

function Get-KGPersistenceSnapshot {
    $snap = @{}
    foreach ($hive in @("HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion",
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion")) {
        foreach ($k in @("Run","RunOnce")) {
            $p = "$hive\$k"
            try {
                $props = Get-ItemProperty -Path $p -ErrorAction Stop
                foreach ($n in $props.PSObject.Properties.Name) {
                    if ($n -notmatch "^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$") {
                        $snap["reg:$p!$n"] = "$($props.$n)"
                    }
                }
            } catch {}
        }
    }
    $su = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    $sc = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    foreach ($d in @($su, $sc)) {
        if (Test-Path $d) {
            foreach ($f in Get-ChildItem $d -File -ErrorAction SilentlyContinue) {
                $snap["startup:$d\$($f.Name)"] = "file"
            }
        }
    }
    try {
        foreach ($t in Get-ScheduledTask -ErrorAction Stop) {
            $snap["task:$($t.TaskPath)$($t.TaskName)"] = "task"
        }
    } catch { Write-KGLog "task snapshot failed: $($_.Exception.Message)" }
    try {
        foreach ($s in Get-Service -ErrorAction Stop) {
            $snap["service:$($s.Name)"] = "$($s.DisplayName)"
        }
    } catch { Write-KGLog "service snapshot failed: $($_.Exception.Message)" }
    return $snap
}

function Test-KGKnownGood($Key) {
    # Match on the leaf name only (exact, case-insensitive) - never substring,
    # so "TailscaleUpdater-Evil" can't ride the "Tailscale" whitelist entry.
    $leaf = $Key
    $i = $leaf.LastIndexOfAny(@('\', '/', ':', '!'))
    if ($i -ge 0) { $leaf = $leaf.Substring($i + 1) }
    foreach ($k in $KnownGoodTasks) {
        if ($k -and $leaf -ieq $k) { return $true }
    }
    return $false
}

function Invoke-KGPersistenceCheck {
    try {
        $snap = Get-KGPersistenceSnapshot
        $baseFile = Join-Path $InstallDir "persistence-baseline.json"
        if (-not (Test-Path $baseFile)) {
            $snap | ConvertTo-Json | Set-Content $baseFile -Encoding UTF8
            Write-KGLog "persistence baseline created ($($snap.Count) entries)"
            return
        }
        $base = Get-Content $baseFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $baseKeys = @($base.PSObject.Properties.Name)
        $new = @($snap.Keys | Where-Object { ($baseKeys -notcontains $_) -and -not (Test-KGKnownGood $_) })
        if ($new.Count -gt 0) {
            foreach ($n in $new) { Write-KGLog "NEW STARTUP ENTRY: $n = $($snap[$n])" }
            $plural = ""
            if ($new.Count -ne 1) { $plural = "s" }
            Show-KGToast "KaviGuard: new startup entry" ("{0} new startup entry{1} detected - new startup entry, verify it's yours. Details in the KaviGuard log." -f $new.Count, $plural)
        }
        $snap | ConvertTo-Json | Set-Content $baseFile -Encoding UTF8
    } catch { Write-KGLog "persistence check failed: $($_.Exception.Message)" }
}

function Invoke-KGHealthCheck {
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if (-not $st.RealTimeProtectionEnabled) {
            Write-KGLog "ALERT: Defender real-time protection is OFF"
            Show-KGToast "KaviGuard: Defender protection off" "Real-time protection is disabled. Turn it back on in Windows Security - KaviGuard will not change it for you."
        } else {
            Write-KGLog "health ok: Defender real-time protection ON"
        }
        $gs = Get-KGState
        $gs.defenderRealtime = [bool]$st.RealTimeProtectionEnabled
        $gs.defenderRealtimeCheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Save-KGState $gs
    } catch { Write-KGLog "health check failed: $($_.Exception.Message)" }
}

function Invoke-KGUpdate {
    try {
        if ($UpdateBaseUrl -like "*YOURUSER*") { return }  # repo not configured yet
        $gsu = Get-KGState
        $gsu.lastUpdateCheck = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Save-KGState $gsu
        $remote = (Invoke-WebRequest -Uri "$UpdateBaseUrl/version.txt" -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop).Content.Trim()
        if ([version]$remote -le [version]$Version) { return }
        Write-KGLog "update available: $Version -> $remote"
        # Full update: core engine + dashboard design + mailbox poller.
        # Every file is hash-verified and syntax-checked BEFORE anything is replaced.
        $targets = @(
            @{ Url = "KaviGuard.ps1";     Dest = $PSCommandPath },
            @{ Url = "KaviGuard-Gui.ps1";  Dest = (Join-Path $InstallDir "KaviGuard-Gui.ps1") }
        )
        $mbDest = Join-Path $InstallDir "mailbox\KaviGuard-Mailbox.ps1"
        if (Test-Path $mbDest) { $targets += @{ Url = "KaviGuard-Mailbox.ps1"; Dest = $mbDest } }
        $staged = @()
        foreach ($t in $targets) {
            $tmpNew = Join-Path $InstallDir ("upd_" + ([IO.Path]::GetFileNameWithoutExtension($t.Url)) + ".new.ps1")
            Invoke-WebRequest -Uri "$UpdateBaseUrl/$($t.Url)" -UseBasicParsing -TimeoutSec 120 -OutFile $tmpNew -ErrorAction Stop
            $want = (Invoke-WebRequest -Uri "$UpdateBaseUrl/$($t.Url).sha256" -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop).Content.Trim().Split()[0].ToUpper()
            $got = (Get-FileHash -Path $tmpNew -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpper()
            if ($want -ne $got) { throw "update aborted: hash mismatch on $($t.Url)" }
            $errs = $null
            [void][System.Management.Automation.PSParser]::Tokenize((Get-Content $tmpNew -Raw), [ref]$errs)
            if ($errs.Count -gt 0) { throw "update aborted: syntax errors in $($t.Url)" }
            $staged += @{ Tmp = $tmpNew; Dest = $t.Dest; Url = $t.Url }
        }
        foreach ($s in $staged) {
            Move-Item -Path $s.Tmp -Destination $s.Dest -Force -ErrorAction Stop
            Write-KGLog "updated $($s.Url)"
        }
        try {
            Invoke-WebRequest -Uri "$UpdateBaseUrl/version.txt" -UseBasicParsing -TimeoutSec 20 `
                -OutFile (Join-Path $InstallDir "version.txt") -ErrorAction Stop
        } catch {}
        Write-KGLog "updated to $remote, restarting watcher with new code"
        Show-KGToast "KaviGuard updated" "v$remote installed - restarting."
        $helper = "Start-Sleep -Seconds 10; schtasks /end /tn 'KaviGuard' 2>`$null | Out-Null; Start-Sleep -Seconds 3; schtasks /run /tn 'KaviGuard' | Out-Null"
        Start-Process "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-Command",$helper | Out-Null
        exit
    } catch { Write-KGLog "update check failed: $($_.Exception.Message)" }
}

function Get-KGScanState {
    $f = Join-Path $InstallDir "scanstate.json"
    $s = [pscustomobject]@{ lastQuickScan = ""; lastFullScan = "" }
    if (Test-Path $f) {
        try {
            $j = Get-Content $f -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($j.lastQuickScan) { $s.lastQuickScan = [string]$j.lastQuickScan }
            if ($j.lastFullScan)  { $s.lastFullScan  = [string]$j.lastFullScan }
        } catch {}
    }
    return $s
}

function Save-KGScanState($s) {
    $s | ConvertTo-Json | Set-Content (Join-Path $InstallDir "scanstate.json") -Encoding UTF8
}

# Persistent counters / health cache for the agent status file.
$script:GuardStateFile = Join-Path $InstallDir "guardstate.json"
function Get-KGState {
    $s = [pscustomobject]@{
        threatsFound = 0; threatsQuarantined = 0
        lastUpdateCheck = ""; lastError = ""
        defenderRealtime = $null; defenderRealtimeCheckedAt = ""
        startedAt = ""
    }
    try {
        if (Test-Path $script:GuardStateFile) {
            $j = Get-Content $script:GuardStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in @("threatsFound","threatsQuarantined","lastUpdateCheck","lastError",
                             "defenderRealtime","defenderRealtimeCheckedAt","startedAt")) {
                if ($null -ne $j.$p) { $s.$p = $j.$p }
            }
        }
    } catch {}
    return $s
}
function Save-KGState($s) {
    try { $s | ConvertTo-Json | Set-Content $script:GuardStateFile -Encoding UTF8 } catch {}
}

# status.json - the integration surface every Kavi agent reads.
function Write-KGStatus {
    try {
        $st = Get-KGState
        $sc = Get-KGScanState
        [pscustomobject]@{
            agent                   = "KaviGuard"
            version                 = $Version
            running                 = $true
            startedAt               = $st.startedAt
            lastQuickScan           = $sc.lastQuickScan
            lastFullScan            = $sc.lastFullScan
            threatsFound            = [int]$st.threatsFound
            threatsQuarantined      = [int]$st.threatsQuarantined
            defenderRealtime        = $st.defenderRealtime
            defenderRealtimeCheckedAt = $st.defenderRealtimeCheckedAt
            exclusionCount          = $ExcludePaths.Count
            lastUpdateCheck         = $st.lastUpdateCheck
            lastError               = $st.lastError
        } | ConvertTo-Json | Set-Content (Join-Path $InstallDir "status.json") -Encoding UTF8
    } catch {}
}

function Invoke-KGScan($ScanType) {
    # lock file so scans never stack; stale if the owner PID is gone or the lock is ancient (>6h)
    $lock = Join-Path $InstallDir "scan.lock"
    if (Test-Path $lock) {
        $live = $false
        try {
            $owner = [int]((Get-Content $lock -Raw -ErrorAction Stop).Trim())
            if ($owner -gt 0) { $null = Get-Process -Id $owner -ErrorAction Stop; $live = $true }
        } catch {}
        $age = (Get-Date) - (Get-Item $lock).LastWriteTime
        if ($live -and $age.TotalHours -lt 6) { Write-KGLog "scan skipped ($ScanType): already running"; return }
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
        Write-KGLog "cleared stale scan lock"
    }
    "$PID" | Set-Content $lock -Force
    try {
        Write-KGLog "scan start: $ScanType"
        $start = Get-Date
        $ok = $false
        try { Start-MpScan -ScanType $ScanType -ErrorAction Stop; $ok = $true }
        catch {
            try {
                $mp = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
                if ($ScanType -eq "FullScan") { & $mp -Scan -ScanType 2 | Out-Null } else { & $mp -Scan -ScanType 1 | Out-Null }
                $ok = $true
            } catch { Write-KGLog "scan failed ($ScanType): $($_.Exception.Message)" }
        }
        if ($ok) {
            $n = 0
            try { $n = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $start }).Count } catch {}
            if ($n -gt 0) {
                Write-KGLog "scan finish: $ScanType - $n threat(s) found"
                $gsn = Get-KGState
                $gsn.threatsFound = [int]$gsn.threatsFound + $n
                Save-KGState $gsn
                Show-KGToast "KaviGuard: threats found" "Defender found $n threat(s) in the $ScanType. Open Windows Security to review."
            } else {
                Write-KGLog "scan finish: $ScanType - clean"
            }
        }
        $st = Get-KGScanState
        $today = (Get-Date).ToString("yyyy-MM-dd")
        if ($ScanType -eq "FullScan") { $st.lastFullScan = $today } else { $st.lastQuickScan = $today }
        Save-KGScanState $st
        Write-KGStatus
    } finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}

function Invoke-KGScheduledScans {
    try {
        $now = Get-Date
        $today = $now.ToString("yyyy-MM-dd")
        $hm = $now.ToString("HH:mm")
        $st = Get-KGScanState
        if ($st.lastQuickScan -ne $today -and $hm -ge $QuickScanTime) {
            Invoke-KGScan -ScanType "QuickScan"
        } elseif ($now.DayOfWeek.ToString() -eq $FullScanDay -and $st.lastFullScan -ne $today -and $hm -ge $FullScanTime) {
            Invoke-KGScan -ScanType "FullScan"
        }
    } catch { Write-KGLog "scheduled scan check failed: $($_.Exception.Message)" }
}

# ------------------------------ tune-up + on-demand scan ------------------------------
function Get-KGFolderSize($Path) {
    $s = [long]0
    try { $s = [long](Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum } catch {}
    return $s
}

function Invoke-KGTuneUp {
    # Conservative cleanup: temp folders (skips in-use files) + Recycle Bin.
    # Reports what was freed; never touches documents, downloads, or libraries.
    $freed = [long]0
    $parts = @()
    foreach ($t in @($env:TEMP, (Join-Path $env:SystemRoot "Temp"))) {
        if (-not (Test-Path $t)) { continue }
        $before = Get-KGFolderSize $t
        Get-ChildItem $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $d = $before - (Get-KGFolderSize $t)
        if ($d -gt 0) { $freed += $d; $parts += "temp $([math]::Round($d/1MB,1)) MB" }
    }
    try {
        $binSize = [long]0
        $shell = New-Object -ComObject Shell.Application
        foreach ($i in $shell.Namespace(0xA).Items()) { $binSize += [long]$i.Size }
        if ($binSize -gt 0) {
            Clear-RecycleBin -Force -ErrorAction Stop
            $freed += $binSize
            $parts += "recycle bin $([math]::Round($binSize/1MB,1)) MB"
        }
    } catch { Write-KGLog "tune-up recycle bin skipped: $($_.Exception.Message)" }
    $msg = if ($parts.Count -gt 0) { "tune-up freed $([math]::Round($freed/1MB,1)) MB (" + ($parts -join ", ") + ")" } else { "tune-up: nothing to clean" }
    Write-KGLog $msg
    Show-KGToast "KaviGuard tune-up" $msg
    return $msg
}

function Invoke-KGPathScan($Path) {
    # On-demand Defender scan of one file or folder (antivirus integration).
    if (-not (Test-Path $Path)) { return "not found: $Path" }
    Write-KGLog "on-demand scan started: $Path"
    try {
        if ((Get-Item $Path -ErrorAction Stop).PSIsContainer) {
            Start-MpScan -ScanPath $Path -ScanType CustomScan -ErrorAction Stop
        } else {
            Invoke-KGDefenderFileScan $Path
        }
        $msg = "scan complete: $Path (details in Windows Security > Protection history)"
    } catch { $msg = "scan failed ($Path): $($_.Exception.Message)" }
    Write-KGLog $msg
    Show-KGToast "KaviGuard scan" $msg
    return $msg
}

# ------------------------------ agent CLI ------------------------------
# One-shot modes so any Kavi agent can check on and drive KaviGuard.
# These never start the watcher; they do their job and exit.
function Invoke-KGAgentCli {
    if ($Status) {
        $f = Join-Path $InstallDir "status.json"
        if (Test-Path $f) { Get-Content $f -Raw }
        else { '{"agent":"KaviGuard","running":false,"lastError":"status.json not found - watcher may never have started"}' }
        return
    }
    if ($AddExclusion) {
        $list = @()
        try { if (Test-Path $ExtraExclusionsFile) { $list = @(Get-Content $ExtraExclusionsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } } catch {}
        if ($list -notcontains $AddExclusion) { $list += $AddExclusion }
        $list | ConvertTo-Json | Set-Content $ExtraExclusionsFile -Encoding UTF8
        try { Add-MpPreference -ExclusionPath $AddExclusion -ErrorAction Stop; "exclusion added: $AddExclusion" }
        catch { "saved (Defender exclusion needs Admin): $AddExclusion" }
        return
    }
    if ($RemoveExclusion) {
        $list = @()
        try { if (Test-Path $ExtraExclusionsFile) { $list = @(Get-Content $ExtraExclusionsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } } catch {}
        $list = @($list | Where-Object { $_ -ne $RemoveExclusion })
        $list | ConvertTo-Json | Set-Content $ExtraExclusionsFile -Encoding UTF8
        try { Remove-MpPreference -ExclusionPath $RemoveExclusion -ErrorAction Stop; "exclusion removed: $RemoveExclusion" }
        catch { "removed from list (Defender change needs Admin): $RemoveExclusion" }
        return
    }
    if ($ScanNow) {
        $t = if ($ScanNow -eq "Full") { "FullScan" } else { "QuickScan" }
        Invoke-KGScan -ScanType $t
        "scan requested: $t (see the KaviGuard log for results)"
        return
    }
    if ($TuneUp) { Invoke-KGTuneUp; return }
    if ($ScanPath) { Invoke-KGPathScan $ScanPath; return }
}

if ($Status -or $ScanNow -or $AddExclusion -or $RemoveExclusion -or $TuneUp -or $ScanPath) {
    if (-not (Test-Path $InstallDir)) { New-Item $InstallDir -ItemType Directory -Force | Out-Null }
    Invoke-KGAgentCli
    exit
}

# ------------------------------ main ------------------------------
$single = New-Object System.Threading.Mutex($false, "KaviGuardSingleton")
if (-not $single.WaitOne(0)) { exit }   # another copy already running

foreach ($d in @($InstallDir, $QuarantineDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

Write-KGLog "KaviGuard v$Version starting (user=$env:USERNAME)"

$gs0 = Get-KGState
$gs0.startedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Save-KGState $gs0

Invoke-KGPersistenceCheck   # first run only writes the baseline, no alerts
Invoke-KGHealthCheck
Write-KGStatus

$script:PTimer = New-Object System.Timers.Timer(300000)    # 5 min: persistence
$script:PTimer.AutoReset = $true
Register-ObjectEvent -InputObject $script:PTimer -EventName Elapsed -Action { Invoke-KGPersistenceCheck } | Out-Null
$script:PTimer.Start()

$script:HTimer = New-Object System.Timers.Timer(900000)     # 15 min: Defender health
$script:HTimer.AutoReset = $true
Register-ObjectEvent -InputObject $script:HTimer -EventName Elapsed -Action { Invoke-KGHealthCheck } | Out-Null
$script:HTimer.Start()

$script:UTimer = New-Object System.Timers.Timer(21600000)   # 6 h: self-update
$script:UTimer.AutoReset = $true
Register-ObjectEvent -InputObject $script:UTimer -EventName Elapsed -Action { Invoke-KGUpdate } | Out-Null
$script:UTimer.Start()

Write-KGLog "active: $($script:Watchers.Count) watchers; scans daily $QuickScanTime / $FullScanDay $FullScanTime"
Show-KGToast "KaviGuard $Version active" "Watching Downloads, Desktop and Temp. Double-click the desktop icon for the full status."
while ($true) { Start-Sleep -Seconds 60; Invoke-KGScheduledScans; Write-KGStatus }
