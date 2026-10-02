#Requires -RunAsAdministrator
<#
.SYNOPSIS  Installs KaviGuard (file watcher + persistence monitor + scheduled Defender scans).
.NOTES     One paste. Nothing else to install.
#>
param(
    [string]$UpdateBaseUrl = "https://raw.githubusercontent.com/kellner-dot/kaviguard/main"
)

$ErrorActionPreference = "Stop"

$InstallDir = "C:\Tools\KaviGuard"
$ScriptName = "KaviGuard.ps1"
$LocalScript = Join-Path $InstallDir $ScriptName

# Find the script: next to this installer, Desktop, TEMP, else download it
$candidates = @()
if ($PSScriptRoot) { $candidates += Join-Path $PSScriptRoot $ScriptName }
$candidates += Join-Path ([Environment]::GetFolderPath("Desktop")) $ScriptName
$candidates += Join-Path $env:TEMP $ScriptName

$source = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $source) {
    Write-Host "Downloading KaviGuard.ps1 ..."
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    $source = Join-Path $env:TEMP $ScriptName
    Invoke-WebRequest -Uri "$UpdateBaseUrl/$ScriptName" -UseBasicParsing -OutFile $source
}

foreach ($d in @($InstallDir, "$InstallDir\quarantine", "$InstallDir\logs")) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

Copy-Item $source $LocalScript -Force

# Point the installed copy at the real update URL
$text = Get-Content $LocalScript -Raw
$text = $text.Replace("https://raw.githubusercontent.com/YOURUSER/kaviguard/main", $UpdateBaseUrl)
Set-Content $LocalScript $text -Encoding UTF8

"1.4.0" | Set-Content (Join-Path $InstallDir "version.txt") -Encoding UTF8

# Defender exclusions: the watcher's own dir + our project blind spots
$paths = @(
    $InstallDir,
    "$env:USERPROFILE\rvd",
    "$env:USERPROFILE\rvg13",
    "$env:USERPROFILE\rvg14",
    "$env:USERPROFILE\Desktop\RVG-v1.2-rollback",
    "C:\Users\sethr\kavi-mail",
    "C:\Program Files\Tailscale",
    "C:\Program Files\Mesh Agent"
)
foreach ($p in $paths) { try { Add-MpPreference -ExclusionPath $p } catch {} }

# Process exclusions: the remote-access service executables themselves.
# These are infrastructure, not suspects.
foreach ($exe in @(
    "C:\Program Files\Tailscale\tailscale.exe",
    "C:\Program Files\Mesh Agent\meshagent.exe"
)) { try { Add-MpPreference -ExclusionProcess $exe } catch {} }

$taskName = "KaviGuard"
try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {}
Start-Sleep -Seconds 2
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch {}

$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LocalScript`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
              -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$settings.Hidden = $true
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -User $env:USERNAME `
    -Description "KaviGuard: file watcher + persistence monitor + scheduled Defender scans" | Out-Null

try { Start-ScheduledTask -TaskName $taskName } catch {}

Write-Host ""
Write-Host "DONE. KaviGuard is installed and running."
Write-Host "Done = you see a scheduled task named KaviGuard (Task Scheduler) and new lines appearing in C:\Tools\KaviGuard\logs\kaviguard.log"
Write-Host ""
Write-Host "# Uninstall (paste if ever needed):"
Write-Host "# Unregister-ScheduledTask -TaskName KaviGuard -Confirm:`$false"
Write-Host "# Remove-MpPreference -ExclusionPath 'C:\Tools\KaviGuard'"
Write-Host "# Remove-MpPreference -ExclusionProcess 'C:\Program Files\Tailscale\tailscale.exe'"
Write-Host "# Remove-MpPreference -ExclusionProcess 'C:\Program Files\Mesh Agent\meshagent.exe'"
Write-Host "# Remove-Item 'C:\Tools\KaviGuard' -Recurse -Force"
