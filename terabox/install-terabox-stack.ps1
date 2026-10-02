#Requires -Version 5.1
<#
.SYNOPSIS
  One-paste installer for the TeraBox cloud stack on SETHS-PC (Windows 11).
  Installs WinFsp + rclone + Alist, links TeraBox, creates the rclone remote,
  mounts TeraBox (T: preferred), and sets up auto-start scheduled tasks.
  Idempotent: safe to re-run; already-done steps are skipped.
.NOTES
  Run in an elevated PowerShell (right-click Terminal -> Run as administrator),
  then paste the one-line launcher. Every step prints PASS / FAIL / SKIP / MANUAL
  in plain language. Passwords and cookies are never printed.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- helpers ----------------
$script:results = @()
function Write-Step {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } 'MANUAL' { 'Magenta' } default { 'Gray' } }
    Write-Host ("[{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("       {0}" -f $Detail) -ForegroundColor Gray }
    $script:results += [pscustomobject]@{ Step = $Name; Result = $Status; Detail = $Detail }
}
function Write-Info([string]$Msg) { Write-Host $Msg -ForegroundColor Cyan }

function Get-LatestAsset {
    param([string]$Repo, [string]$Pattern)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' found in $Repo latest release." }
    return $asset
}

function Download-File {
    param([string]$Url, [string]$OutFile)
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

# ---------------- 0. admin check ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'STOP: This installer needs administrator rights.' -ForegroundColor Red
    Write-Host 'Right-click Terminal and choose "Run as administrator", then paste the command again.' -ForegroundColor Yellow
    exit 1
}
Write-Info 'TeraBox stack installer v1.8 — running as administrator. Starting...'

$AlistDir  = 'C:\alist'
$RcloneDir = 'C:\rclone'
$TempDir   = Join-Path $env:TEMP 'terabox-stack'
New-Item -ItemType Directory -Force -Path $AlistDir, $RcloneDir, $TempDir | Out-Null

# ---------------- 1. WinFsp ----------------
try {
    $winfspInstalled = (Test-Path "${env:ProgramFiles(x86)}\WinFsp") -or
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'WinFsp*' })
    if ($winfspInstalled) {
        Write-Step 'WinFsp' 'SKIP' 'Already installed.'
    } else {
        Write-Info 'Downloading WinFsp (latest)...'
        $asset = Get-LatestAsset 'winfsp/winfsp' 'winfsp-*.msi'
        $msi = Join-Path $TempDir $asset.name
        Download-File $asset.browser_download_url $msi
        Write-Info ("Installing {0} silently..." -f $asset.name)
        $p = Start-Process 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Step 'WinFsp' 'PASS' ("Installed {0}." -f $asset.name) }
        else { Write-Step 'WinFsp' 'FAIL' ("msiexec exit code {0}." -f $p.ExitCode) }
    }
} catch { Write-Step 'WinFsp' 'FAIL' $_.Exception.Message }

# ---------------- 2. rclone ----------------
try {
    $rcloneExe = Join-Path $RcloneDir 'rclone.exe'
    if (Test-Path $rcloneExe) {
        Write-Step 'rclone' 'SKIP' 'Already installed.'
    } else {
        Write-Info 'Downloading rclone (latest)...'
        $asset = Get-LatestAsset 'rclone/rclone' 'rclone-v*-windows-amd64.zip'
        $zip = Join-Path $TempDir $asset.name
        Download-File $asset.browser_download_url $zip
        $unzipDir = Join-Path $TempDir 'rclone-unzip'
        if (Test-Path $unzipDir) { Remove-Item $unzipDir -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unzipDir -Force
        $found = Get-ChildItem -Path $unzipDir -Recurse -Filter 'rclone.exe' | Select-Object -First 1
        if (-not $found) { throw 'rclone.exe not found inside the downloaded zip.' }
        Copy-Item -LiteralPath $found.FullName -Destination $rcloneExe -Force
        Write-Step 'rclone' 'PASS' ("Installed {0}." -f $asset.name)
    }
    # Ensure C:\rclone is on the machine PATH (idempotent)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$RcloneDir*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$RcloneDir", 'Machine')
        $sig = '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
        $t = Add-Type -MemberDefinition $sig -Name Win32Util -Namespace EnvB -PassThru
        $r = [UIntPtr]::Zero
        [void]$t::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$r)
        Write-Step 'rclone PATH' 'PASS' 'C:\rclone added to system PATH.'
    } else {
        Write-Step 'rclone PATH' 'SKIP' 'C:\rclone already on PATH.'
    }
} catch { Write-Step 'rclone' 'FAIL' $_.Exception.Message }

# ---------------- 3. Alist ----------------
$alistExe = Join-Path $AlistDir 'alist.exe'
try {
    if (Test-Path $alistExe) {
        Write-Step 'Alist' 'SKIP' 'Already installed.'
    } else {
        Write-Info 'Downloading Alist (latest)...'
        $asset = Get-LatestAsset 'AlistGo/alist' 'alist-windows-amd64.zip'
        $zip = Join-Path $TempDir $asset.name
        Download-File $asset.browser_download_url $zip
        $unzipDir = Join-Path $TempDir 'alist-unzip'
        if (Test-Path $unzipDir) { Remove-Item $unzipDir -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unzipDir -Force
        $found = Get-ChildItem -Path $unzipDir -Recurse -Filter 'alist.exe' | Select-Object -First 1
        if (-not $found) { throw 'alist.exe not found inside the downloaded zip.' }
        Copy-Item -LiteralPath $found.FullName -Destination $alistExe -Force
        Write-Step 'Alist' 'PASS' ("Installed {0}." -f $asset.name)
    }
} catch { Write-Step 'Alist' 'FAIL' $_.Exception.Message }

# ---------------- 4. Alist admin password ----------------
# NOTE: `alist admin set` dies silently on this Windows box (verified working
# on Linux), so instead we start the server once on a fresh data dir and read
# the initial admin password from its own first-start log line:
#   "Successfully created the admin user and the initial password is: XXXX"
$adminPwFile = Join-Path $AlistDir 'admin-password.txt'
$dataDir = Join-Path $AlistDir 'data'
$adminPw = $null
try {
    $dataExists = Test-Path (Join-Path $dataDir 'data.db')
    if ($dataExists -and (Test-Path $adminPwFile)) {
        $adminPw = (Get-Content -LiteralPath $adminPwFile -Raw).Trim()
        Write-Step 'Alist admin password' 'SKIP' 'Reusing saved password.'
    } else {
        Write-Info 'Starting Alist once to capture the initial admin password...'
        Get-Process -Name 'alist' -ErrorAction SilentlyContinue | Stop-Process -Force
        $waited = 0
        while ((Get-Process -Name 'alist' -ErrorAction SilentlyContinue) -and ($waited -lt 10)) {
            Start-Sleep -Seconds 1; $waited++
        }
        Start-Sleep -Seconds 2  # let file handles release
        if (Test-Path -LiteralPath $dataDir) {
            $bak = "$dataDir.pwreset.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $dataDir -Destination $bak -Force
            Write-Info ("Backed up old data dir to {0}." -f $bak)
        }
        $srvLogOut = Join-Path $env:TEMP 'alist-firststart.out.log'
        $srvLogErr = Join-Path $env:TEMP 'alist-firststart.err.log'
        Remove-Item -LiteralPath $srvLogOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $srvLogErr -Force -ErrorAction SilentlyContinue
        # (PowerShell forbids redirecting stdout and stderr to the SAME file,
        # so use two and search both; logrus writes to stderr by default.)
        Start-Process -FilePath $alistExe -ArgumentList @('--data', $dataDir, 'server') `
            -WorkingDirectory $AlistDir -RedirectStandardOutput $srvLogOut `
            -RedirectStandardError $srvLogErr -WindowStyle Hidden | Out-Null
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and -not $adminPw) {
            Start-Sleep -Seconds 2
            foreach ($log in @($srvLogOut, $srvLogErr)) {
                if (-not $adminPw -and (Test-Path -LiteralPath $log)) {
                    $m = Select-String -Path $log -Pattern 'initial password is:\s*(\S+)' | Select-Object -First 1
                    if ($m) { $adminPw = $m.Matches[0].Groups[1].Value }
                }
            }
        }
        if (-not $adminPw) {
            $tail = ''
            foreach ($log in @($srvLogOut, $srvLogErr)) {
                if (Test-Path -LiteralPath $log) {
                    $tail += ((Get-Content -LiteralPath $log -Raw) -split "`r?`n" |
                        Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' | '
                    $tail += ' || '
                }
            }
            throw ("Initial admin password not found in server logs ({0}, {1}). Tail: {2}" -f $srvLogOut, $srvLogErr, $tail)
        }
        Set-Content -LiteralPath $adminPwFile -Value $adminPw -NoNewline -Force
        # Restrict the file to Administrators + current user
        $acl = Get-Acl -LiteralPath $adminPwFile
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'Administrators', 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $adminPwFile -AclObject $acl
        Write-Step 'Alist admin password' 'PASS' ("Saved to {0} (not shown here)." -f $adminPwFile)
        # Server keeps running; step 5 adopts it.
    }
} catch { Write-Step 'Alist admin password' 'FAIL' $_.Exception.Message }

# ---------------- 5. Alist server: start now + auto-start task ----------------
$alistRunning = $false
try {
    $task = Get-ScheduledTask -TaskName 'Alist Server' -ErrorAction SilentlyContinue
    if (-not $task) {
        $action = New-ScheduledTaskAction -Execute $alistExe -Argument 'server' -WorkingDirectory $AlistDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName 'Alist Server' -Action $action -Trigger $trigger `
            -RunLevel Highest -Description 'Starts the Alist server (TeraBox bridge) at logon.' -Force | Out-Null
        Write-Step 'Alist auto-start task' 'PASS' 'Created "Alist Server" (runs at logon).'
    } else {
        Write-Step 'Alist auto-start task' 'SKIP' 'Task "Alist Server" already exists.'
    }
    if (-not (Get-Process -Name 'alist' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $alistExe -ArgumentList 'server' -WorkingDirectory $AlistDir -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }
    # Wait for the web UI to answer
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try {
            $s = Invoke-RestMethod -Uri 'http://127.0.0.1:5244/api/public/settings' -UseBasicParsing -TimeoutSec 5
            if ($s) { $alistRunning = $true; break }
        } catch { Start-Sleep -Seconds 3 }
    }
    if ($alistRunning) { Write-Step 'Alist server running' 'PASS' 'http://127.0.0.1:5244 is answering.' }
    else { Write-Step 'Alist server running' 'FAIL' 'Alist did not answer within 60s. Check the "Alist Server" task.' }
} catch { Write-Step 'Alist server running' 'FAIL' $_.Exception.Message }

# ---------------- 6. Link TeraBox storage ----------------
$storageLinked = $false
try {
    if (-not $adminPw) { throw 'Skipped: no Alist admin password (step 4 failed).' }
    if (-not $alistRunning) { throw 'Skipped: Alist is not running.' }
    # Is /terabox already linked?
    $token = (Invoke-RestMethod -Uri 'http://127.0.0.1:5244/api/auth/login' -Method Post `
        -Body (@{ username = 'admin'; password = $adminPw } | ConvertTo-Json) `
        -ContentType 'application/json' -UseBasicParsing).data.token
    $storages = Invoke-RestMethod -Uri 'http://127.0.0.1:5244/api/admin/storage/list' `
        -Headers @{ Authorization = $token } -UseBasicParsing
    $existing = $storages.data.content | Where-Object { $_.mount_path -eq '/terabox' }
    if ($existing) {
        $storageLinked = $true
        Write-Step 'TeraBox storage' 'SKIP' '/terabox is already linked in Alist.'
    } else {
        Write-Host ''
        Write-Info 'TeraBox is not linked yet. Two ways to link it:'
        Write-Host '  [Y] Paste your TeraBox cookie here (hidden as you type), and I will link it now.'
        Write-Host '  [N] I will do it myself in the web UI (http://127.0.0.1:5244 -> Manage -> Storages -> Add).'
        $choice = Read-Host 'Link TeraBox now? (Y/N)'
        if ($choice -match '^[Yy]') {
            Write-Host 'In your browser: log in at https://www.terabox.com, press F12, open the Console tab,'
            Write-Host 'type document.cookie, press Enter, and copy the whole line of text.'
            $secCookie = Read-Host 'Paste the cookie text' -AsSecureString
            $cookiePlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secCookie))
            try {
                $addition = @{ cookie = $cookiePlain; download_api = 'official' } | ConvertTo-Json -Compress
                $body = @{
                    mount_path = '/terabox'; order = 0; driver = 'Terabox'
                    cache_expiration = 30; status = 'work'; addition = $addition
                    remark = ''; disabled = $false; enable_sign = $false
                } | ConvertTo-Json -Compress -Depth 5
                $created = Invoke-RestMethod -Uri 'http://127.0.0.1:5244/api/admin/storage/create' `
                    -Method Post -Headers @{ Authorization = $token } -Body $body `
                    -ContentType 'application/json' -UseBasicParsing
                if ($created.code -eq 200) {
                    $storageLinked = $true
                    Write-Step 'TeraBox storage' 'PASS' '/terabox linked via Alist API.'
                } else {
                    throw ("Alist API returned code {0}: {1}" -f $created.code, $created.message)
                }
            } finally {
                $cookiePlain = $null  # never stored, never printed
            }
        } else {
            Write-Step 'TeraBox storage' 'MANUAL' 'Link it in the web UI, then re-run this installer.'
        }
    }
} catch { Write-Step 'TeraBox storage' 'FAIL' $_.Exception.Message }

# ---------------- 7. rclone remote "tb" ----------------
$rcloneExe = Join-Path $RcloneDir 'rclone.exe'
try {
    $confDir = Join-Path $env:APPDATA 'rclone'
    $confFile = Join-Path $confDir 'rclone.conf'
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null
    $confText = if (Test-Path $confFile) { Get-Content -LiteralPath $confFile -Raw } else { '' }
    if ($confText -match '(?m)^\[tb\]') {
        Write-Step 'rclone remote "tb"' 'SKIP' 'Remote [tb] already configured.'
    } else {
        if (-not $adminPw) { throw 'Need the Alist admin password to configure the remote.' }
        # rclone obscure needs the password as an argument; it is never printed or logged.
        $obscured = (& $rcloneExe obscure $adminPw 2>$null | Out-String).Trim()
        if (-not $obscured) { throw 'rclone obscure failed to encode the password.' }
        $stanza = "[tb]`r`ntype = webdav`r`nurl = http://127.0.0.1:5244/dav/terabox`r`nvendor = other`r`nuser = admin`r`npass = $obscured`r`n"
        Add-Content -LiteralPath $confFile -Value $stanza -Encoding Ascii
        Write-Step 'rclone remote "tb"' 'PASS' 'WebDAV remote pointing at Alist created.'
    }
} catch { Write-Step 'rclone remote "tb"' 'FAIL' $_.Exception.Message }

# ---------------- 8. mount (T: preferred) + auto-mount task ----------------
$mountTarget = $null
try {
    if (Get-PSDrive -Name T -ErrorAction SilentlyContinue) {
        $mountTarget = 'C:\Cloud\TeraBox'
        New-Item -ItemType Directory -Force -Path $mountTarget | Out-Null
        Write-Info 'T: is taken, using C:\Cloud\TeraBox instead.'
    } else {
        $mountTarget = 'T:'
    }
    $mountArgs = "mount tb:/ $mountTarget --vfs-cache-mode full --vfs-cache-max-size 50G --dir-cache-time 24h"
    $task = Get-ScheduledTask -TaskName 'TeraBox Mount' -ErrorAction SilentlyContinue
    if ($task) {
        # Recreate fresh: earlier versions wrote a broken Delay value into the
        # task XML, so never trust a pre-existing task definition.
        Unregister-ScheduledTask -TaskName 'TeraBox Mount' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Info 'Removed old "TeraBox Mount" task; recreating with the fixed definition.'
    }
    # Always (re)create with the current fixed definition.
    # NOTE: do not use $trigger.Delay — the scheduler rejects both the
    # TimeSpan and ISO-8601 serializations ("task XML ... incorrectly
    # formatted"). The 30s wait lives inside the action instead.
    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 30; & ''{0}'' {1}"' -f $rcloneExe, $mountArgs
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'TeraBox Mount' -Action $action -Trigger $trigger `
        -RunLevel Highest -Description ("Mounts TeraBox to {0} at logon." -f $mountTarget) -Force | Out-Null
    Write-Step 'Auto-mount task' 'PASS' ("Created `"TeraBox Mount`" -> {0} (30s after logon)." -f $mountTarget)

    if ($storageLinked) {
        $alreadyMounted = if ($mountTarget -eq 'T:') { Get-PSDrive -Name T -ErrorAction SilentlyContinue }
                          else { Test-Path (Join-Path $mountTarget '.') }
        if (-not $alreadyMounted) {
            Start-Process -FilePath $rcloneExe -ArgumentList $mountArgs -WindowStyle Hidden
        }
        $deadline = (Get-Date).AddSeconds(90)
        $mounted = $false
        while ((Get-Date) -lt $deadline) {
            if ($mountTarget -eq 'T:') { $mounted = [bool](Get-PSDrive -Name T -ErrorAction SilentlyContinue) }
            else { $mounted = Test-Path $mountTarget }
            if ($mounted) { break }
            Start-Sleep -Seconds 3
        }
        if ($mounted) { Write-Step 'Mount live' 'PASS' ("{0} is mounted." -f $mountTarget) }
        else { Write-Step 'Mount live' 'FAIL' 'Mount did not appear within 90s. A reboot often fixes WinFsp mounts.' }
    } else {
        Write-Step 'Mount live' 'MANUAL' 'Waiting on the TeraBox storage link (step 6), then re-run.'
    }
} catch { Write-Step 'Mount' 'FAIL' $_.Exception.Message }

# ---------------- 9. end-to-end test: write through mount, confirm on TeraBox, read back ----------------
try {
    if ($mountTarget -and $storageLinked) {
        $testName = "mount-test-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date)
        $testPath = Join-Path $mountTarget $testName
        $sentinel = "terabox-mount-test $(Get-Date -Format o)"
        Set-Content -LiteralPath $testPath -Value $sentinel -NoNewline -Force
        # Poll until the file shows up in TeraBox itself (proves the mount is live,
        # not just a local folder). Upload through the VFS cache can take a few seconds.
        $onRemote = $false
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            $remoteList = (& $rcloneExe lsf tb:/ 2>$null | Out-String)
            if ($remoteList -match [regex]::Escape($testName)) { $onRemote = $true; break }
            Start-Sleep -Seconds 3
        }
        $readBack = ''
        if (Test-Path -LiteralPath $testPath) { $readBack = (Get-Content -LiteralPath $testPath -Raw).Trim() }
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        if ($onRemote -and ($readBack -eq $sentinel.Trim())) {
            Write-Step 'End-to-end test' 'PASS' 'Wrote a file through the mount, confirmed it on TeraBox, read it back.'
        } else {
            Write-Step 'End-to-end test' 'FAIL' 'File did not round-trip through the mount to TeraBox. Check the Alist storage status.'
        }
        # Quota peek (best effort)
        try {
            $about = & $rcloneExe about tb: 2>$null | Out-String
            if ($about -match 'Total:\s*(\S+)') { Write-Info ("TeraBox quota says: {0}" -f $Matches[0].Trim()) }
        } catch { }
    } else {
        Write-Step 'End-to-end test' 'SKIP' 'Mount or storage link not available yet.'
    }
} catch { Write-Step 'End-to-end test' 'FAIL' $_.Exception.Message }

# ---------------- summary ----------------
Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
$script:results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($script:results | Where-Object { $_.Result -eq 'FAIL' }).Count
$manual = @($script:results | Where-Object { $_.Result -eq 'MANUAL' }).Count
if ($failed -eq 0 -and $manual -eq 0) {
    Write-Host 'All done. Your TeraBox is mounted and verified.' -ForegroundColor Green
    Write-Host ("Next: run migrate-movies.ps1 to start moving your movies. Your mount path is: {0}" -f $mountTarget)
} elseif ($failed -eq 0) {
    Write-Host 'Almost done: finish the MANUAL step(s) above, then re-run this installer.' -ForegroundColor Magenta
} else {
    Write-Host 'Some steps FAILED. Fix them (or tell me what they said) before migrating movies.' -ForegroundColor Red
}
Write-Host ''
Read-Host 'Press Enter to close'
