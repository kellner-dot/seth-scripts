<#
  Uninstall IObit — removes all IObit apps and their leftovers
  ------------------------------------------------------------
  Right-click -> "Run with PowerShell" (as Administrator).

  Order of operations (deliberate):
    1. Creates a restore point first (safety net).
    2. Removes Advanced SystemCare / Driver Booster / Smart Defrag /
       Malware Fighter (protection tools go LAST so you're never unprotected).
    3. Removes IObit Uninstaller itself last.
    4. Sweeps leftover scheduled tasks, services, folders, registry keys.
    5. Verifies Windows Defender is still active.

  Run replace-iobit.ps1 first so the native tools are already doing the jobs.
#>

$ErrorActionPreference = "Continue"

# Self-elevate: if not admin, re-launch with admin rights (click Yes on the prompt)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "iobit-uninstall-log.txt"
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $log -Value $line
}
"=== IObit uninstall $(Get-Date) ===" | Out-File $log

# 1. Restore point (safety net)
Log "Creating restore point..."
try {
    Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Before IObit removal" -RestorePointType "MODIFY_SETTINGS"
    Log "Restore point created."
} catch { Log "Restore point failed (continuing anyway): $_" }

# 2. Find all installed IObit products (v2: also checks per-user installs + known names)
function Get-IObitProducts {
    $hives = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $knownNames = @("Advanced SystemCare", "Driver Booster", "Smart Defrag", "Smart Game Booster", "Game Booster", "Software Updater", "IObit Uninstaller", "Malware Fighter")
    foreach ($h in $hives) {
        if (Test-Path $h) {
            Get-ChildItem $h -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.GetValue("DisplayName")
                $pub  = $_.GetValue("Publisher")
                $isIObit = ($name -like "*IObit*") -or ($pub -like "*IObit*")
                if ((-not $isIObit) -and $name) {
                    foreach ($kn in $knownNames) { if ($name -like "*$kn*") { $isIObit = $true; break } }
                }
                if ($isIObit -and $name) {
                    [pscustomobject]@{
                        Name = $name
                        QuietUninstall = $_.GetValue("QuietUninstallString")
                        Uninstall = $_.GetValue("UninstallString")
                    }
                }
            }
        }
    }
}

function Invoke-Uninstaller($cmd) {
    if (-not $cmd) { return $null }
    if ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe, $args = $Matches[1], $Matches[2] }
    elseif ($cmd -match '^(\S+)\s*(.*)$') { $exe, $args = $Matches[1], $Matches[2] }
    else { return $null }
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        return $p.ExitCode
    } catch { Log "  uninstaller launch failed: $_"; return $null }
}

$killNames = @("ASC", "ASCTray", "ASCService", "DriverBooster", "SmartDefrag", "IObitUninstaler", "IMF", "IObit")
function Stop-IObitProcesses {
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = $_; $pn = $proc.ProcessName; $hit = ($proc.Path -like "*IObit*")
        foreach ($kn in $killNames) { if ($pn -like "$kn*") { $hit = $true; break } }
        if ($hit) { try { Stop-Process $proc -Force -ErrorAction Stop } catch {} }
    }
}

$products = Get-IObitProducts | Sort-Object Name -Unique
if (-not $products) { Log "No IObit products found in the registry. Checking leftovers only." }

# Uninstall order: protection + uninstaller LAST
$ordered = @($products | Where-Object { $_.Name -notmatch 'Malware Fighter|IObit Uninstaller' }) +
           @($products | Where-Object { $_.Name -match 'Malware Fighter|IObit Uninstaller' })

foreach ($app in $ordered) {
    Log "Uninstalling: $($app.Name) ..."
    Stop-IObitProcesses
    $code = Invoke-Uninstaller $app.QuietUninstall
    Log "  quiet uninstall exit code: $code"
    Start-Sleep -Seconds 5
    $stillThere = @(Get-IObitProducts | Where-Object { $_.Name -eq $app.Name }).Count -gt 0
    if ($stillThere -and $app.Uninstall) {
        Log "  still present — retrying with forced silent flags..."
        Stop-IObitProcesses
        $code2 = Invoke-Uninstaller ($app.Uninstall.Trim() + " /VERYSILENT /SUPPRESSMSGBOXES /NORESTART")
        Log "  forced uninstall exit code: $code2"
        Start-Sleep -Seconds 5
        $stillThere = @(Get-IObitProducts | Where-Object { $_.Name -eq $app.Name }).Count -gt 0
    }
    if ($stillThere) { Log "  STILL PRESENT — remove it manually: Settings > Apps > $($app.Name) > Uninstall" }
    else { Log "  removed." }
}

# 3. Sweep leftover scheduled tasks
Log "Removing IObit scheduled tasks..."
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like "*IObit*" -or $_.TaskPath -like "*IObit*" -or $_.TaskName -like "*ASC*" -or $_.TaskName -like "*DriverBooster*" -or $_.TaskName -like "*Driver Booster*" -or $_.TaskName -like "*SmartDefrag*" -or $_.TaskName -like "*IMF*" } |
        ForEach-Object {
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Log "  removed task: $($_.TaskName)"
        }
} catch { Log "Task sweep failed: $_" }

# 4. Sweep leftover services
Log "Removing IObit services..."
try {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*IObit*" -or $_.DisplayName -like "*IObit*" -or $_.Name -like "*ASCService*" -or $_.Name -like "*AdvancedSystemCare*" -or $_.Name -like "*IMFservice*" } |
        ForEach-Object {
            Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
            sc.exe delete $_.Name | Out-Null
            Log "  removed service: $($_.DisplayName)"
        }
} catch { Log "Service sweep failed: $_" }

# 5. Sweep leftover folders
Log "Removing IObit folders..."
$folders = @(
    "$env:ProgramFiles\IObit",
    "${env:ProgramFiles(x86)}\IObit",
    "$env:ProgramData\IObit",
    "$env:APPDATA\IObit",
    "$env:LOCALAPPDATA\IObit"
)
foreach ($f in $folders) {
    if (Test-Path $f) {
        try { Remove-Item $f -Recurse -Force -ErrorAction Stop; Log "  removed: $f" }
        catch { Log "  could not remove $f (may need a reboot): $_" }
    }
}

# 6. Sweep leftover registry keys
Log "Removing IObit registry keys..."
foreach ($k in @("HKCU:\Software\IObit", "HKLM:\SOFTWARE\IObit", "HKLM:\SOFTWARE\WOW6432Node\IObit")) {
    if (Test-Path $k) {
        try { Remove-Item $k -Recurse -Force -ErrorAction Stop; Log "  removed: $k" }
        catch { Log "  could not remove $k : $_" }
    }
}

# 7. Verify Defender is active (never leave without protection)
Log "Verifying Windows Defender..."
try {
    $st = Get-MpComputerStatus
    Log "Defender real-time protection: $($st.RealTimeProtectionEnabled)"
    Log "Defender signatures: $($st.AntivirusSignatureLastUpdated)"
    if (-not $st.RealTimeProtectionEnabled) {
        Log "WARNING: real-time protection is OFF — turn it on in Windows Security."
    }
} catch { Log "Defender check failed: $_" }

# 8. Final check
$remaining = Get-IObitProducts
if ($remaining) {
    Log "Still present (may need manual removal from Settings > Apps):"
    $remaining | ForEach-Object { Log "  - $($_.Name)" }
} else {
    Log "No IObit products remain in the registry."
}

Log "=== IObit uninstall finished. REBOOT now. Log: Desktop\iobit-uninstall-log.txt ==="
Write-Host ""
Write-Host "Done! Reboot your PC. Windows Defender is your protection now — it's already built in." -ForegroundColor Green
pause
