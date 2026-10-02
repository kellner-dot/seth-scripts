<#
RVG 1.5 upgrade installer - run ON SETHS-PC, in an ELEVATED PowerShell.
(Right-click PowerShell -> "Run as administrator".)

Every step prints [PASS] or [FAIL] in plain English. Safe to re-run:
finished steps are skipped.

What it does:
  - backs up v1.4 to %USERPROFILE%\rvd\backup-v14\ (rollback files)
  - installs the v1.5 agent + viewer to %USERPROFILE%\rvd\rvg15\
  - KEEPS your token (never regenerated, never deleted)
  - re-creates the "RVG agent" logon task pointing at v1.5
  - installs the "RVG update check" DAILY task (checks GitHub releases;
    does nothing until you configure the repo - see docs\BUILD-NOTES.md)
  - re-applies tailscale serve
#>
$ErrorActionPreference = "Stop"
$RvdDir    = Join-Path $env:USERPROFILE "rvd"
$Dest      = Join-Path $RvdDir "rvg15"
$Backup    = Join-Path $RvdDir "backup-v14"
$TokenFile = Join-Path $RvdDir "token.txt"
$Config    = Join-Path $RvdDir "rvg_update_config.json"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Package root: the folder containing agent\, gui\, docs\, install\, updater\.
$PkgRoot = $ScriptDir
if (-not (Test-Path (Join-Path $PkgRoot "agent\rvg_agent.py"))) {
    $PkgRoot = Split-Path -Parent $ScriptDir
}
if (-not (Test-Path (Join-Path $PkgRoot "agent\rvg_agent.py"))) {
    Write-Host "[FAIL] can't find agent\rvg_agent.py under $ScriptDir or $PkgRoot" -ForegroundColor Red
    Write-Host "Re-download the full RVG-1.5-upgrade.zip and extract it whole, then re-run." -ForegroundColor Red
    exit 1
}

function Step($name) { Write-Host "`n== $name ==" -ForegroundColor Cyan }
function Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red }

# --- 1. must be admin -------------------------------------------------
Step "Admin check"
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Pass "running as administrator" }
else { Fail "not administrator - right-click PowerShell -> Run as administrator, then re-run"; exit 1 }

# --- 2. python + tkinter ----------------------------------------------
Step "Python check"
try {
    $py = (Get-Command python.exe -ErrorAction Stop).Source
    $pyw = Join-Path (Split-Path $py) "pythonw.exe"
    if (-not (Test-Path $pyw)) { throw "pythonw.exe not found next to python.exe" }
    python -c "import tkinter" 2>$null
    if ($LASTEXITCODE -eq 0) { Pass "python + tkinter OK ($py)" }
    else { throw "no tkinter" }
} catch {
    Fail "python with tkinter not found - install from python.org (check 'Add to PATH'), then re-run"
    exit 1
}

# --- 3. tailscale ------------------------------------------------------
Step "Tailscale check"
try { tailscale version 2>$null | Out-Null; Pass "tailscale CLI found" }
catch { Fail "tailscale CLI not found - open the Tailscale app and sign in, then re-run"; exit 1 }

# --- 4. stop the live v1.4 agent ---------------------------------------
Step "Stop old agent"
try {
    schtasks /End /TN "RVG agent" 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*rvg_agent.py*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    Pass "old agent stopped (if it was running)"
} catch { Pass "old agent wasn't running" }

# --- 5. back up v1.4 ----------------------------------------------------
Step "Back up v1.4"
try {
    $oldDest = Join-Path $RvdDir "rvg14"
    if ((Test-Path (Join-Path $Backup "rvg_agent.py"))) {
        Pass "backup already exists at $Backup (kept)"
    } elseif (Test-Path $oldDest) {
        New-Item -ItemType Directory $Backup -Force | Out-Null
        Copy-Item (Join-Path $oldDest "*") $Backup -Recurse -Force
        Pass "v1.4 files backed up to $Backup"
    } else {
        New-Item -ItemType Directory $Backup -Force | Out-Null
        Pass "no v1.4 folder found - fresh backup folder created at $Backup"
    }
} catch { Fail "backup failed: $_"; exit 1 }

# --- 6. install files ----------------------------------------------------
Step "Install files"
try {
    New-Item -ItemType Directory $Dest -Force | Out-Null
    Copy-Item (Join-Path $PkgRoot "agent\rvg_agent.py")    $Dest -Force
    Copy-Item (Join-Path $PkgRoot "gui\rvg_viewer.py")     $Dest -Force
    Copy-Item (Join-Path $PkgRoot "updater\rvg_update_check.ps1") `
        (Join-Path $RvdDir "rvg_update_check.ps1") -Force
    if (-not (Test-Path (Join-Path $Dest "rvg_agent.py"))) { throw "copy failed" }
    Pass "agent + viewer installed to $Dest"
    Pass "update-check script installed to $RvdDir\rvg_update_check.ps1"
} catch { Fail "install failed: $_"; exit 1 }

# --- 6b. neon eye icon: keep a copy inside rvg15 ---------------------------
# The v1.4 shortcut's icon lives at rvd\rvg13\rvg.ico today. Copy the first
# one found into the new install folder so the shortcut never depends on
# the old rvg13 folder surviving.
Step "Icon"
try {
    $iconDest = Join-Path $Dest "rvg.ico"
    if (Test-Path $iconDest) {
        Pass "icon already in $Dest (kept)"
    } else {
        $found = $null
        foreach ($cand in @(
            (Join-Path $PkgRoot "rvg.ico"),
            (Join-Path $RvdDir "rvg14\rvg.ico"),
            (Join-Path $RvdDir "rvg13\rvg.ico"))) {
            if (Test-Path $cand) { $found = $cand; break }
        }
        if ($found) {
            Copy-Item $found $iconDest -Force
            Pass "neon eye icon copied to $iconDest"
        } else {
            Pass "no rvg.ico found anywhere - shortcut will use the default icon"
        }
    }
} catch { Fail "icon copy failed (non-fatal): $_" }

# --- 7. token: NEVER touch it --------------------------------------------
Step "Token"
try {
    if (Test-Path $TokenFile) {
        Pass "token already exists at $TokenFile (kept - never regenerated by install or updates)"
    } else {
        $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
        $b = New-Object byte[] 24; $rng.GetBytes($b)
        $tok = [Convert]::ToBase64String($b)
        [IO.File]::WriteAllText($TokenFile, $tok)
        Pass "new token generated and saved to $TokenFile"
        Write-Host "YOUR TOKEN (shown once - the viewer reads it automatically):" -ForegroundColor Yellow
        Write-Host $tok -ForegroundColor Yellow
    }
} catch { Fail "token failed: $_"; exit 1 }

# --- 8. update config (created once, never overwritten) --------------------
Step "Update config"
try {
    if (Test-Path $Config) {
        Pass "update config already exists (kept your repo setting)"
    } else {
        $json = @'
{
  "repo": "",
  "enabled": false,
  "checkTime": "03:00",
  "token": "",
  "note": "Set repo to 'owner/name' and enabled to true after creating the GitHub repo (see docs/BUILD-NOTES.md). For a PRIVATE repo put a fine-grained PAT (contents: read) in 'token'. Until repo is set, the daily check exits quietly."
}
'@
        $json | Out-File $Config -Encoding ascii -Force
        Pass "update config created at $Config (repo not set yet - check does nothing until you set it)"
    }
} catch { Fail "config failed (non-fatal): $_" }

# --- 9. load-screen image -------------------------------------------------
Step "Load-screen image"
try {
    $jpg = Join-Path $PkgRoot "loadscreen.jpg"
    $png = Join-Path $Dest "loadscreen.png"
    if (Test-Path $jpg) {
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($jpg)
        $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $img.Dispose()
        Pass "loadscreen.jpg converted to PNG (the splash will show it)"
    } else {
        Pass "no loadscreen.jpg found - splash will draw its built-in graphic"
    }
} catch { Fail "image conversion failed (non-fatal): $_" }

# --- 10. auto-start task ----------------------------------------------------
Step "Auto-start"
try {
    schtasks /Delete /TN "RVG agent" /F 2>$null | Out-Null
    $pyw = Join-Path (Split-Path (Get-Command python.exe).Source) "pythonw.exe"
    schtasks /Create /TN "RVG agent" /SC ONLOGON /F `
        /TR "`"$pyw`" `"$Dest\rvg_agent.py`"" 2>$null | Out-Null
    Pass "scheduled task 'RVG agent' starts at every logon"
} catch { Fail "auto-start failed: $_"; exit 1 }

# --- 11. daily update-check task ---------------------------------------------
Step "Daily update check"
try {
    schtasks /Delete /TN "RVG update check" /F 2>$null | Out-Null
    $ps = (Get-Command powershell.exe).Source
    schtasks /Create /TN "RVG update check" /SC DAILY /ST 03:00 /F `
        /TR "`"$ps`" -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RvdDir\rvg_update_check.ps1`"" `
        2>$null | Out-Null
    Pass "scheduled task 'RVG update check' runs daily at 3:00 AM (quiet until you set the repo)"
} catch { Fail "update-check task failed (non-fatal): $_" }

# --- 12. desktop shortcut for the viewer ----------------------------------
Step "Desktop shortcut"
try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    foreach ($gone in @("RVG 1.4 Viewer.lnk", "RVG 1.4 Viewer.bat",
                        "RVG 1.3 Viewer.lnk", "RVG 1.3 Viewer.bat")) {
        $p = Join-Path $desktop $gone
        if (Test-Path $p) { Remove-Item $p -Force }
    }
    $pyw = Join-Path (Split-Path (Get-Command python.exe).Source) "pythonw.exe"
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $desktop "RVG 1.5 Viewer.lnk"))
    $lnk.TargetPath = $pyw
    $lnk.Arguments = "`"$Dest\rvg_viewer.py`""
    $lnk.WorkingDirectory = $Dest
    $ico = Join-Path $Dest "rvg.ico"
    if (Test-Path $ico) { $lnk.IconLocation = $ico }
    $lnk.Save()
    if (Test-Path (Join-Path $desktop "RVG 1.5 Viewer.lnk")) {
        Pass "desktop shortcut 'RVG 1.5 Viewer' created (pythonw - no console window)"
    } else { throw "lnk file not found after save" }
} catch {
    Fail "shortcut failed (non-fatal): $_"
    try {
        $bat = Join-Path ([Environment]::GetFolderPath("Desktop")) "RVG 1.5 Viewer.bat"
        "@echo off`r`npythonw `"$Dest\rvg_viewer.py`"" | Out-File -FilePath $bat -Encoding ascii -Force
        Pass "fallback launcher 'RVG 1.5 Viewer.bat' placed on desktop"
    } catch { Fail "fallback launcher also failed: $_" }
}

# --- 13. start the agent and verify ----------------------------------------
Step "Start + verify"
try {
    Start-ScheduledTask -TaskName "RVG agent" -ErrorAction SilentlyContinue
    Start-Sleep 4
    $tok = [IO.File]::ReadAllText($TokenFile).Trim()
    $r = Invoke-RestMethod "http://127.0.0.1:8899/rvd/status" `
        -Headers @{ "X-RVD-Token" = $tok } -TimeoutSec 10
    if ($r.ok -and $r.version -eq "1.5") {
        Pass "agent v1.5 answering on 127.0.0.1:8899 (screen $($r.screenW)x$($r.screenH), self-update on)"
    } else { throw "unexpected status reply (version=$($r.version))" }
} catch { Fail "agent didn't answer: $_"; exit 1 }

# --- 14. tailscale serve ----------------------------------------------------
Step "Tailscale serve"
try {
    tailscale serve --bg --set-path=/rvd http://127.0.0.1:8899 2>&1 | Out-Null
    $st = tailscale serve status 2>$null | Out-String
    if ($st -match "/rvd") { Pass "tailnet path /rvd is live" }
    else { Pass "serve command sent (check with: tailscale serve status)" }
} catch { Fail "tailscale serve failed: $_ - the agent still works locally"; }

# --- done -------------------------------------------------------------------
Write-Host "`n================ RVG 1.5 INSTALLED ================" -ForegroundColor Cyan
Write-Host "Agent:   %USERPROFILE%\rvd\rvg15\rvg_agent.py (auto-starts at logon)"
Write-Host "Viewer:  double-click the 'RVG 1.5 Viewer' desktop shortcut"
Write-Host "Token:   %USERPROFILE%\rvd\token.txt (untouched - viewer reads it)"
Write-Host "Backup:  %USERPROFILE%\rvd\backup-v14\ (v1.4 rollback files)"
Write-Host "Updates: 'RVG update check' task runs daily at 3:00 AM;"
Write-Host "         set the repo in %USERPROFILE%\rvd\rvg_update_config.json"
Write-Host "         (one-time GitHub setup: docs\BUILD-NOTES.md)"
Write-Host "To stop the agent:  schtasks /End /TN 'RVG agent'"
Write-Host "Rollback:  see docs\README.md"
