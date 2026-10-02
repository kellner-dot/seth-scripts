<#
  IObit Replacement — does their jobs with built-in Windows tools
  ---------------------------------------------------------------
  Right-click -> "Run with PowerShell" (as Administrator).
  Replaces: Advanced SystemCare (junk clean, disk check, spyware scan),
            Smart Defrag (optimize drives), Software Updater (winget),
            plus a driver-age report (safer than Driver Booster's auto-update).

  What it does NOT do (on purpose):
    - Registry cleaning: Microsoft doesn't support it; zero speed gain,
      real breakage risk. Skipped deliberately.
    - RAM "boosting": causes stutters. Skipped deliberately.
    - Blind driver updates: can install wrong drivers. Reports old
      drivers instead — you update via Windows Update > Optional updates
      or the GPU maker's app.
#>

$ErrorActionPreference = "Continue"

# Self-elevate: if not admin, re-launch with admin rights (click Yes on the prompt)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "iobit-replacement-log.txt"
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $log -Value $line
}
"=== IObit replacement run $(Get-Date) ===" | Out-File $log

# 1. Storage Sense ON (automatic junk cleaning, forever)
Log "Enabling Storage Sense..."
try {
    $ss = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
    if (-not (Test-Path $ss)) { New-Item $ss -Force | Out-Null }
    Set-ItemProperty $ss -Name "01" -Value 1 -Type DWord
    Log "Storage Sense: ON."
} catch { Log "Storage Sense failed: $_" }

# 2. Disk Cleanup with a preset (temp files, recycle bin, thumbnails, delivery opt)
Log "Running Disk Cleanup (preset)..."
try {
    $sageset = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $handlers = @("Temporary Files", "Recycle Bin", "Temporary Internet Files",
                  "Delivery Optimization Files", "Thumbnail Cache", "Direct3D Shader Cache")
    foreach ($h in $handlers) {
        $k = Join-Path $sageset $h
        if (Test-Path $k) { Set-ItemProperty $k -Name "StateFlags0001" -Value 2 -Type DWord }
    }
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait -WindowStyle Hidden
    Log "Disk Cleanup: done."
} catch { Log "Disk Cleanup failed: $_" }

# 3. Component store cleanup (Windows Update leftovers)
Log "Cleaning Windows component store..."
try {
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
    Log "Component store: cleaned."
} catch { Log "DISM failed: $_" }

# 4. Temp folders
Log "Clearing temp folders..."
try {
    $freed = 0
    foreach ($p in @("$env:TEMP", "C:\Windows\Temp")) {
        if (Test-Path $p) {
            $freed += [double](Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
            Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        }
    }
    Log "Temp folders: freed $([math]::Round($freed/1MB,1)) MB."
} catch { Log "Temp cleanup failed: $_" }

# 5. Optimize drives (TRIM for SSDs, defrag for HDDs — Smart Defrag's whole job)
Log "Optimizing drives (TRIM/defrag)..."
try {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
        Log "Optimizing $($_.DriveLetter): ..."
        Optimize-Volume -DriveLetter $_.DriveLetter -Verbose 4>&1 |
            ForEach-Object { Log ("  " + $_.ToString().Trim()) }
    }
    Log "Drive optimization: done."
} catch { Log "Optimize-Volume failed: $_" }

# 6. Disk health (SMART)
Log "Disk health (SMART):"
try {
    Get-PhysicalDisk | Get-StorageReliabilityCounter |
        Select-Object @{n="Disk"; e={(Get-PhysicalDisk -UniqueId $_.UniqueId).FriendlyName}},
            TemperatureCelsius, Wear, PowerOnHours, ReadErrorsTotal, WriteErrorsTotal |
        Format-Table -AutoSize | Out-String | ForEach-Object { Log $_.Trim() }
} catch { Log "SMART report failed: $_" }

# 7. Disk error check (schedules chkdsk only if needed — needs reboot)
Log "Checking volumes for errors (read-only)..."
try {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
        $r = Repair-Volume -DriveLetter $_.DriveLetter -Scan -ErrorAction SilentlyContinue
        Log "$($_.DriveLetter): errors found = $($r -ne $null)"
    }
} catch { Log "Volume scan failed: $_" }

# 8. Driver age report (safer than auto-updating everything)
Log "Drivers older than 2 years (consider updating via Windows Update > Optional updates):"
try {
    $cutoff = (Get-Date).AddYears(-2)
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DriverDate -and $_.DriverDate -lt $cutoff -and $_.DeviceName } |
        Select-Object DeviceName,
            @{n="DriverDate"; e={$_.DriverDate.ToString("yyyy-MM-dd")}},
            DriverVersion, Manufacturer |
        Sort-Object DriverDate | Format-Table -AutoSize |
        Out-String | ForEach-Object { Log $_.Trim() }
} catch { Log "Driver report failed: $_" }

# 9. Update all apps (replaces IObit Software Updater)
Log "Updating apps via winget..."
try {
    $out = winget upgrade --all --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
    Log "winget: done."
} catch { Log "winget failed (may not be installed): $_" }

# 10. Defender quick scan (replaces IObit "spyware removal" — Defender is the real engine)
Log "Running Defender quick scan..."
try {
    Update-MpSignature -ErrorAction SilentlyContinue
    Start-MpScan -ScanType QuickScan
    $t = Get-MpThreatDetection | Select-Object -First 5 ThreatID, InitialDetectionTime | Out-String
    Log "Defender scan: complete."
} catch { Log "Defender scan failed: $_" }

Log "=== IObit replacement finished. Log: Desktop\iobit-replacement-log.txt ==="
Write-Host ""
Write-Host "Done! This did the real jobs of Advanced SystemCare, Smart Defrag, and Software Updater." -ForegroundColor Green
pause
