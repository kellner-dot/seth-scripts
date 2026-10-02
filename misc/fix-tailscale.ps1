<#
  Fix Tailscale — gets SETHS-PC back on the tailnet
  ------------------------------------------------
  1. Makes sure the Tailscale service is set to Automatic and running
  2. Reconnects it and enables UNATTENDED mode (so it survives reboots/logouts)
  3. Reinstalls Tailscale silently if the install is broken/missing
  Run in normal PowerShell — it will ask for admin itself.
#>
$ErrorActionPreference = "Continue"

# Self-elevate
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights - click Yes on the popup..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Desktop = [Environment]::GetFolderPath("Desktop")
$log = Join-Path $Desktop "tailscale-fix-log.txt"
function Log($m) {
    $line = "[$(Get-Date -Format HH:mm:ss)] $m"
    Write-Host $line
    try { Add-Content -Path $log -Value $line } catch {}
}
"=== Tailscale fix started $(Get-Date) ===" | Out-File $log

$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
$ipnExe = "C:\Program Files\Tailscale\tailscale-ipn.exe"

# --- 1. Service ---
Log "Checking Tailscale service..."
$svc = Get-Service Tailscale -ErrorAction SilentlyContinue
if ($svc) {
    Log "Service found: Status=$($svc.Status), StartType=$($svc.StartType)"
    try {
        if ($svc.StartType -ne 'Automatic') {
            Set-Service Tailscale -StartupType Automatic -ErrorAction Stop
            Log "Start type set to Automatic."
        }
        if ($svc.Status -ne 'Running') {
            Log "Starting service..."
            Start-Service Tailscale -ErrorAction Stop
        } else {
            Log "Restarting service (clears wedged state)..."
            Restart-Service Tailscale -Force -ErrorAction Stop
        }
        Start-Sleep 8
        $svc2 = Get-Service Tailscale
        Log "Service now: $($svc2.Status)"
    } catch {
        Log "Service start/restart FAILED: $_"
    }
} else {
    Log "Tailscale service NOT FOUND."
}

# --- 2. Binaries present? Reinstall if missing ---
if (-not (Test-Path $tsExe)) {
    Log "tailscale.exe MISSING — reinstalling silently..."
    try {
        $page = Invoke-WebRequest "https://pkgs.tailscale.com/stable/" -UseBasicParsing -ErrorAction Stop
        $best = $page.Links | Where-Object { $_.href -match 'tailscale-setup-(\d+\.\d+\.\d+)-amd64\.msi$' } |
            ForEach-Object { [pscustomobject]@{ Href = $_.href; Ver = [version]$Matches[1] } } |
            Sort-Object Ver -Descending | Select-Object -First 1
        if (-not $best) { throw "Could not find MSI link on pkgs.tailscale.com/stable/" }
        $msiUrl = "https://pkgs.tailscale.com/stable/$($best.Href)"
        $msiPath = Join-Path $env:TEMP "tailscale-setup.msi"
        Log "Downloading Tailscale $($best.Ver) ..."
        Invoke-WebRequest $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        Log "Installing silently..."
        Start-Process msiexec -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
        Start-Sleep 10
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        if (Test-Path $tsExe) { Log "Reinstall OK." } else { Log "Reinstall FAILED — tailscale.exe still missing." }
    } catch {
        Log "Reinstall FAILED: $_"
        Log "Manual fallback: download https://tailscale.com/download/windows and run the installer."
    }
} else {
    try { Log "Installed version: $((& $tsExe version) -join ' ')" } catch {}
}

# --- 3. Reconnect + unattended mode (the server fix) ---
if (Test-Path $tsExe) {
    Log "Checking connection state..."
    $statusOut = (& $tsExe status 2>&1 | Out-String)
    if ($statusOut -match 'Logged out') {
        Log "Tailscale is LOGGED OUT."
        Log ">>> Open the Tailscale app and click Log in, then re-run this script. <<<"
    } else {
        Log "Reconnecting in unattended mode (survives reboot/logout)..."
        $upOut = (& $tsExe up --unattended 2>&1 | Out-String)
        if ($upOut.Trim()) { Log "tailscale up: $($upOut.Trim())" }
        Start-Sleep 5
        Log "--- tailscale status ---"
        & $tsExe status 2>&1 | ForEach-Object { Log "$_" }
        Log "--- tailscale ip ---"
        $ip = (& $tsExe ip -4 2>&1 | Out-String).Trim()
        Log "Tailscale IPv4: $ip"
        if ($ip -match '^100\.') {
            Log "SUCCESS: this PC is on the tailnet at $ip"
        } else {
            Log "WARNING: no tailnet IP yet — it may still be connecting; wait 1 min and re-run."
        }
    }
    # Relaunch tray UI so the icon works
    if (Test-Path $ipnExe) {
        try { Start-Process $ipnExe -ErrorAction Stop; Log "Tray app relaunched." } catch {}
    }
} else {
    Log "Cannot continue: tailscale.exe not present."
}

Log "Done. Log saved to Desktop\tailscale-fix-log.txt"
pause
