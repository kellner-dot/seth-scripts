<#
  Gaming + Media Server Tune-Up v3 for SETHS-PC
  --------------------------------------------
  Right-click -> "Run with PowerShell" (as Administrator).
  Logs everything to your Desktop (tuneup-log.txt).

  v3 changes (from deep research):
    - Power plan: HIGH PERFORMANCE (benchmarks show zero FPS difference
      vs Ultimate in games, with less idle heat; server stays awake via
      the never-sleep block below)
    - SERVER MODE: never sleep/hibernate, disks never spin down, wake timers off
    - Defender EXCLUSIONS for your media folders + Emby (Defender stays ON —
      exclusions just stop it rescanning every movie during library scans)
    - Delivery Optimization P2P uploads OFF (stops background bandwidth use)
    - PCIe power saving OFF (prevents GPU stutter)

  Safe: no personal files, Emby library, or OneDrive touched.
#>

$ErrorActionPreference = "Continue"

# Self-elevate: if not admin, re-launch with admin rights (click Yes on the prompt)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ---- Your media folders (Defender will skip these during scans) ----
$MediaPaths = @(
    "D:\Movies",
    "D:\TV Shows",
    "D:\Studio Ghibli",
    "$env:USERPROFILE\OneDrive\Desktop\Movies",
    "$env:USERPROFILE\OneDrive\Desktop\TV Shows"
)
$EmbyData = "$env:APPDATA\Emby-Server"

$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "tuneup-log.txt"
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $log -Value $line
}
"=== Tune-up v3 started $(Get-Date) ===" | Out-File $log
Log "Running as admin: OK"

# 1. High Performance power plan (same gaming FPS as Ultimate, cooler idle)
Log "Setting power plan..."
try {
    $hp = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    powercfg -setactive $hp
    Log "Power plan: High Performance active."
} catch { Log "Power plan step failed: $_" }

# 2. SERVER MODE: never sleep, never hibernate, disks never spin down
Log "Setting server mode (never sleep)..."
try {
    powercfg -change -standby-timeout-ac 0
    powercfg -change -standby-timeout-dc 0
    powercfg -change -hibernate-timeout-ac 0
    powercfg -change -hibernate-timeout-dc 0
    powercfg -change -disk-timeout-ac 0
    powercfg -change -disk-timeout-dc 0
    powercfg /hibernate off
    Log "Server mode: sleep/hibernate/disk spindown DISABLED."
} catch { Log "Server mode step failed: $_" }

# 3. Wake timers OFF (best effort — moot anyway since sleep is fully disabled)
Log "Disabling wake timers..."
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8fbc bd3b718a-0680-4d97-93d2-b2b83b49b28d7 0 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8fbc bd3b718a-0680-4d97-93d2-b2b83b49b28d7 0 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -eq 0) { Log "Wake timers: OFF." }
    else { Log "Wake timers: not adjustable here — skipped (harmless: sleep is disabled, so nothing can wake it)." }
} catch { Log "Wake timer step failed: $_" }

# 4. PCIe link-state power saving OFF (best effort)
Log "Disabling PCIe power saving..."
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d06d-4de3-bfa5-1e063e8c9c4a 0 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d06d-4de3-bfa5-1e063e8c9c4a 0 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -eq 0) { Log "PCIe power saving: OFF." }
    else { Log "PCIe power saving: setting not present — skipped (High Performance plan already minimizes it)." }
} catch { Log "PCIe step failed: $_" }

# 5. USB selective suspend OFF (external drives / controllers stay responsive)
Log "Disabling USB selective suspend..."
try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
    Log "USB selective suspend: OFF."
} catch { Log "USB suspend step failed: $_" }

# 6. Game Mode ON
Log "Enabling Game Mode..."
try {
    $gb = "HKCU:\Software\Microsoft\GameBar"
    if (-not (Test-Path $gb)) { New-Item $gb -Force | Out-Null }
    Set-ItemProperty $gb -Name "AllowAutoGameMode" -Value 1 -Type DWord
    Set-ItemProperty $gb -Name "AutoGameModeEnabled" -Value 1 -Type DWord
    Log "Game Mode: ON."
} catch { Log "Game Mode step failed: $_" }

# 7. Game DVR background recording OFF (frees CPU + GPU encoder)
Log "Disabling background game recording..."
try {
    $dvr = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    if (-not (Test-Path $dvr)) { New-Item $dvr -Force | Out-Null }
    Set-ItemProperty $dvr -Name "AppCaptureEnabled" -Value 0 -Type DWord
    $gc = "HKCU:\System\GameConfigStore"
    if (Test-Path $gc) { Set-ItemProperty $gc -Name "GameDVR_Enabled" -Value 0 -Type DWord }
    $pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    if (-not (Test-Path $pol)) { New-Item $pol -Force | Out-Null }
    Set-ItemProperty $pol -Name "AllowGameDVR" -Value 0 -Type DWord
    Log "Background recording: OFF."
} catch { Log "Game DVR step failed: $_" }

# 8. Hardware-accelerated GPU scheduling ON
Log "Enabling hardware GPU scheduling..."
try {
    $gd = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    Set-ItemProperty $gd -Name "HwSchMode" -Value 2 -Type DWord
    Log "GPU scheduling: ON (takes effect after reboot)."
} catch { Log "GPU scheduling step failed: $_" }

# 9. Defender EXCLUSIONS for media + Emby (Defender stays ON and protecting you)
Log "Adding Defender exclusions for media folders and Emby..."
try {
    foreach ($p in $MediaPaths) {
        if (Test-Path $p) { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
    }
    if (Test-Path $EmbyData) { Add-MpPreference -ExclusionPath $EmbyData -ErrorAction SilentlyContinue }
    Add-MpPreference -ExclusionProcess "EmbyServer.exe" -ErrorAction SilentlyContinue
    Log "Defender exclusions added (media folders + Emby). Defender still ON."
} catch { Log "Defender exclusion step failed: $_" }

# 10. Delivery Optimization P2P OFF (Windows stops uploading updates to strangers)
Log "Disabling Delivery Optimization P2P uploads..."
try {
    $do = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $do)) { New-Item $do -Force | Out-Null }
    Set-ItemProperty $do -Name "DODownloadMode" -Value 100 -Type DWord
    Log "Delivery Optimization: P2P off."
} catch { Log "Delivery Optimization step failed: $_" }

# 11. Trim heavy visual effects, keep it looking decent
Log "Tuning visual effects..."
try {
    $vx = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    if (-not (Test-Path $vx)) { New-Item $vx -Force | Out-Null }
    Set-ItemProperty $vx -Name "VisualFXSetting" -Value 3 -Type DWord
    Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "100"
    Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAnimations" -Value 0 -Type DWord
    Log "Visual effects: trimmed."
} catch { Log "Visual effects step failed: $_" }

# 12. Cleanup: temp files, caches, component store
Log "Cleaning temp files and caches..."
try {
    $before = 0
    $paths = @("$env:TEMP", "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download")
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $size = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $before += [double]$size
            Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}
    try { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null } catch {}
    $mb = [math]::Round($before / 1MB, 1)
    Log "Cleanup: freed ~$mb MB of temp/cache files."
} catch { Log "Cleanup step failed: $_" }

# 13. Report: VBS / Memory Integrity (report only — kept ON for security)
try {
    $vbs = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -ErrorAction SilentlyContinue
    Log "Memory Integrity (VBS): $(if ($vbs.Enabled -eq 1) { 'ON (secure; costs a few % FPS — your call)' } else { 'OFF' })"
} catch {}

# 14. Report: startup programs
Log "Startup programs on this PC:"
try {
    Get-CimInstance Win32_StartupCommand |
        Select-Object Name, Command, Location |
        Format-Table -AutoSize | Out-String | ForEach-Object { Log $_.Trim() }
} catch { Log "Startup report failed: $_" }

# 15. Report: disk health
Log "Disk health:"
try {
    Get-PhysicalDisk | Select-Object FriendlyName, MediaType,
        @{n="SizeGB"; e={[math]::Round($_.Size / 1GB, 1)}},
        HealthStatus, OperationalStatus |
        Format-Table -AutoSize | Out-String | ForEach-Object { Log $_.Trim() }
} catch { Log "Disk report failed: $_" }

# 16. Report: memory
try {
    $mem = Get-CimInstance Win32_ComputerSystem
    Log "Installed RAM: $([math]::Round($mem.TotalPhysicalMemory / 1GB, 1)) GB"
} catch {}

Log "=== Tune-up v3 finished. REBOOT to apply everything. Log: Desktop\tuneup-log.txt ==="
Write-Host ""
Write-Host "Done! Reboot your PC to apply everything, then check tuneup-log.txt on your Desktop." -ForegroundColor Green
pause
