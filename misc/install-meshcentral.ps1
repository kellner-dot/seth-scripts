<# ============================================================================
  install-meshcentral.ps1
  One-paste installer: MeshCentral remote administration for SETHS-PC,
  exposed ONLY through private Tailscale Serve HTTPS (no public URL,
  no inbound firewall rule, no port forwarding).

  What it does:
    1. Installs Node.js LTS (if missing)
    2. Installs MeshCentral server into C:\MeshCentral (if missing)
    3. Generates local certificates, then locks config to 127.0.0.1:4430 only
    4. Creates a random-password admin account "muse" (saved to Desktop file)
    5. Installs + starts the MeshCentral Windows service
    6. Creates device group "SETHS-PC" and installs the local MeshAgent
    7. Publishes https://127.0.0.1:4430 via "tailscale serve" (tailnet only)
    8. Prints a plain PASS/FAIL scorecard + the exact private URL

  Idempotent: safe to re-run. Steps already done are skipped.
  Run in an elevated PowerShell: right-click PowerShell -> Run as administrator.
============================================================================ #>

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# --- Self-elevate -------------------------------------------------------------
# Works both when pasted into a console and when run from a .ps1 file.
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  if ($PSCommandPath) {
    Write-Host 'Requesting administrator rights (needed to install services)...' -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
    catch { Write-Host 'FAIL: Administrator rights are required.' -ForegroundColor Red }
  } else {
    Write-Host 'FAIL: This installer must run as administrator.' -ForegroundColor Red
    Write-Host 'Close this window, then right-click PowerShell -> "Run as administrator",' -ForegroundColor Yellow
    Write-Host 'paste the installer again and press Enter.' -ForegroundColor Yellow
  }
  return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallDir   = 'C:\MeshCentral'
$MeshDataDir  = Join-Path $InstallDir 'meshcentral-data'
$MeshJs       = Join-Path $InstallDir 'node_modules\meshcentral\meshcentral.js'
$MeshCtrlJs   = Join-Path $InstallDir 'node_modules\meshcentral\meshctrl.js'
$ConfigPath   = Join-Path $MeshDataDir 'config.json'
$GroupName    = 'SETHS-PC'
$AdminUser    = 'muse'
$Port         = 4430
$Desktop      = [Environment]::GetFolderPath('Desktop')
$CredFile     = Join-Path $Desktop 'meshcentral-credentials.txt'
$Results      = New-Object System.Collections.Generic.List[object]

function Add-Result($Step, $Ok, $Detail) {
  $Results.Add([pscustomobject]@{ Step = $Step; OK = $Ok; Detail = $Detail })
  $color = if ($Ok) { 'Green' } else { 'Red' }
  $word  = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Host "[$word] $Step" -ForegroundColor $color
  if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

function Get-NodeExe {
  $c = Get-Command node -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

# --- Step 1: Node.js LTS ------------------------------------------------------
Write-Host ''
Write-Host 'MeshCentral installer v1.5 — running as administrator. Starting...' -ForegroundColor Cyan
Write-Host 'Step 1/9: Node.js LTS' -ForegroundColor Cyan
try {
  $nodeExe = Get-NodeExe
  if (-not $nodeExe) {
    Write-Host '       Node.js not found. Downloading latest LTS...' -ForegroundColor Gray
    try {
      $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60
      $lts = ($index | Where-Object { $_.lts } | Select-Object -First 1).version
    } catch { $lts = $null }
    if (-not $lts) { $lts = 'v22.20.0' }  # known-good LTS fallback
    $msiUrl = "https://nodejs.org/dist/$lts/node-$lts-x64.msi"
    $msiPath = Join-Path $env:TEMP "node-$lts-x64.msi"
    Write-Host "       Downloading $msiUrl ..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -TimeoutSec 600
    Write-Host '       Installing Node.js (silent, this takes a minute)...' -ForegroundColor Gray
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "msiexec exit code $($p.ExitCode)" }
    Refresh-Path
    $nodeExe = Get-NodeExe
  }
  if (-not $nodeExe) { throw 'node.exe still not found after install' }
  $ver = & $nodeExe --version 2>$null
  Add-Result 'Node.js LTS installed' $true "$ver at $nodeExe"
} catch {
  Add-Result 'Node.js LTS installed' $false $_.Exception.Message
  $nodeExe = $null
}

# --- Step 2: MeshCentral npm install ------------------------------------------
Write-Host ''
Write-Host 'Step 2/9: MeshCentral server files' -ForegroundColor Cyan
try {
  if (-not $nodeExe) { throw 'Skipped: Node.js is not available.' }
  if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory $InstallDir -Force | Out-Null }
  if (Test-Path $MeshJs) {
    Add-Result 'MeshCentral installed (npm)' $true 'Already present, skipped download.'
  } else {
    Write-Host '       Running: npm install meshcentral (takes 1-3 minutes)...' -ForegroundColor Gray
    # Use npm.cmd explicitly: PowerShell resolves bare `npm` to npm.ps1, which the
    # default execution policy blocks. npm.cmd runs outside that policy.
    $npmCmd = Join-Path (Split-Path $nodeExe -Parent) 'npm.cmd'
    if (-not (Test-Path $npmCmd)) { $npmCmd = 'npm.cmd' }
    Push-Location $InstallDir
    try {
      $npmOut = & $npmCmd install meshcentral --no-audit --no-fund 2>&1 | Out-String
      $npmCode = $LASTEXITCODE
    } finally { Pop-Location }
    # npm's output pipe can close before every file is flushed to disk; retry briefly.
    $found = $false
    for ($i = 0; $i -lt 6 -and -not $found; $i++) {
      if (Test-Path $MeshJs) { $found = $true } else { Start-Sleep -Seconds 10 }
    }
    if (-not $found) { throw "npm install finished but meshcentral.js not found (exit $npmCode).`n$npmOut" }
    Add-Result 'MeshCentral installed (npm)' $true "Installed to $InstallDir"
  }
} catch {
  Add-Result 'MeshCentral installed (npm)' $false $_.Exception.Message
}

# --- Step 3: Hardened config (written BEFORE the first server start) --------------
Write-Host ''
Write-Host 'Step 3/9: Loopback-only config' -ForegroundColor Cyan
try {
  if (-not (Test-Path $MeshJs)) { throw 'Skipped: MeshCentral is not installed.' }
  if (-not (Test-Path $MeshDataDir)) { New-Item -ItemType Directory $MeshDataDir -Force | Out-Null }
  # Write the hardened config before MeshCentral ever starts, so the very first
  # start already binds to 127.0.0.1 only (never touches the LAN).
  $hardened = @'
{
  "$schema": "https://raw.githubusercontent.com/Ylianst/MeshCentral/master/meshcentral-config-schema.json",
  "settings": {
    "cert": "127.0.0.1",
    "port": 4430,
    "portbind": "127.0.0.1",
    "redirport": 0,
    "mpsport": 0,
    "exactports": true
  },
  "domains": {
    "": {
      "title": "SETHS-PC Remote Admin",
      "newAccounts": false
    }
  }
}
'@
  if (Test-Path $ConfigPath) { Copy-Item $ConfigPath "$ConfigPath.bak" -Force }
  Set-Content -Path $ConfigPath -Value $hardened -Encoding UTF8
  $cfgText = Get-Content $ConfigPath -Raw
  if ($cfgText -notmatch '"portbind"\s*:\s*"127\.0\.0\.1"') { throw 'Config was written but portbind is not 127.0.0.1.' }
  Add-Result 'Config locked to 127.0.0.1' $true 'portbind=127.0.0.1, redirport=0, mpsport=0, newAccounts=false (backup: config.json.bak)'
} catch {
  Add-Result 'Config locked to 127.0.0.1' $false $_.Exception.Message
}

# --- Step 4: First start -> certificates -----------------------------------------
Write-Host ''
Write-Host 'Step 4/9: Local certificates' -ForegroundColor Cyan
try {
  if (-not (Test-Path $MeshJs)) { throw 'Skipped: MeshCentral is not installed.' }
  $webCert = Join-Path $MeshDataDir 'webserver-cert-public.crt'
  if (Test-Path $webCert) {
    Add-Result 'Certificates generated' $true 'Already present, skipped.'
  } else {
    Write-Host '       First start: generating certificates (takes 1-3 minutes)...' -ForegroundColor Gray
    # Kill any leftover manual server from a previous run so the port is free.
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'meshcentral' } |
      ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 3
    $log = Join-Path $env:TEMP 'meshcentral-first-run.log'
    $logErr = Join-Path $env:TEMP 'meshcentral-first-run.err.log'
    # Plain start (no --cert flag): with our config present, MeshCentral generates
    # the self-signed cert for 127.0.0.1 on first start, bound to loopback only.
    $proc = Start-Process -FilePath $nodeExe `
      -ArgumentList 'node_modules\meshcentral' `
      -WorkingDirectory $InstallDir `
      -RedirectStandardOutput $log -RedirectStandardError $logErr -PassThru
    $deadline = (Get-Date).AddMinutes(6)
    while (-not (Test-Path $webCert) -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
      Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds 5
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-Path $webCert)) {
      $tail = ''
      if (Test-Path $log) { $tail = ((Get-Content $log -Tail 15) -join "`n") }
      if (Test-Path $logErr) { $tail += ("`n[stderr]`n" + ((Get-Content $logErr -Tail 15) -join "`n")) }
      throw "Certificate was not generated in time. Server log tail:`n$tail"
    }
    Add-Result 'Certificates generated' $true 'Self-signed cert for 127.0.0.1 created.'
  }
} catch {
  Add-Result 'Certificates generated' $false $_.Exception.Message
}

# --- Step 5: Admin account ------------------------------------------------------
Write-Host ''
Write-Host 'Step 5/9: Admin account + credentials file' -ForegroundColor Cyan
$AdminPass = $null
try {
  if (-not (Test-Path $MeshJs)) { throw 'Skipped: MeshCentral is not installed.' }

  # Reuse password from credentials file when re-running
  if (Test-Path $CredFile) {
    $m = Select-String -Path $CredFile -Pattern '^Password:\s*(\S+)' | Select-Object -First 1
    if ($m) { $AdminPass = $m.Matches[0].Groups[1].Value }
  }

  Push-Location $InstallDir
  try {
    $usersJson = & $nodeExe $MeshJs --showusers 2>$null | Out-String
  } finally { Pop-Location }
  $userExists = $usersJson -match '"_id"\s*:\s*"user//muse"'

  if ($userExists -and $AdminPass) {
    Add-Result 'Admin account "muse"' $true 'Already exists; reusing saved password.'
  } elseif ($userExists -and -not $AdminPass) {
    Add-Result 'Admin account "muse"' $false 'Account exists but the password file is gone. To re-run fully: delete the "muse" account in the web UI, or restore Desktop\meshcentral-credentials.txt.'
  } else {
    # Generate a 24-char alphanumeric password (avoids all shell-quoting issues)
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $chars = for ($i = 0; $i -lt 24; $i++) {
      $b = New-Object byte[] 1; $rng.GetBytes($b); $alphabet[$b[0] % $alphabet.Length]
    }
    $AdminPass = -join $chars
    Push-Location $InstallDir
    try {
      & $nodeExe $MeshJs --createaccount $AdminUser --pass $AdminPass --name 'Muse' | Out-Null
      & $nodeExe $MeshJs --adminaccount $AdminUser | Out-Null
    } finally { Pop-Location }
    Add-Result 'Admin account "muse"' $true 'Created and promoted to site administrator.'
  }

  if ($AdminPass -and -not (Test-Path $CredFile)) {
    $credText = @"
MeshCentral admin login (SETHS-PC, private via Tailscale only)
==============================================================
Username: muse
Password: $AdminPass

ACTION NEEDED:
- Keep this file on your PC. The password never leaves this machine.
- Do NOT paste the password in chat. If Muse needs to check the login page,
  the private Tailscale address below is enough (no password required).

This login only works through the private Tailscale address Muse will use.
Nothing here is reachable from the public internet.
"@
    Set-Content -Path $CredFile -Value $credText -Encoding UTF8
    Add-Result 'Credentials file on Desktop' $true 'Saved. Share once in chat, then delete the file.'
  } elseif ($AdminPass) {
    Add-Result 'Credentials file on Desktop' $true 'Already present.'
  } else {
    Add-Result 'Credentials file on Desktop' $false 'No password available (see admin account step).'
  }
} catch {
  Add-Result 'Admin account "muse"' $false $_.Exception.Message
}

# --- Step 6: Windows service ----------------------------------------------------
Write-Host ''
Write-Host 'Step 6/9: MeshCentral Windows service' -ForegroundColor Cyan
try {
  if (-not (Test-Path $MeshJs)) { throw 'Skipped: MeshCentral is not installed.' }
  # Make sure no manual server is holding the port before the service starts.
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'meshcentral' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Seconds 3
  Push-Location $InstallDir
  try {
    $svc = Get-Service -Name 'MeshCentral' -ErrorAction SilentlyContinue
    if (-not $svc) {
      Write-Host '       Installing MeshCentral service...' -ForegroundColor Gray
      $installOut = & $nodeExe $MeshJs --install 2>&1 | Out-String
      $deadline = (Get-Date).AddMinutes(3)
      while (-not $svc -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name 'MeshCentral' -ErrorAction SilentlyContinue
      }
      if (-not $svc) { throw "Service 'MeshCentral' not found after --install. Installer output:`n$installOut" }
    }
    # Start (not --restart): --restart stops first, which throws when the service
    # was installed but never started.
    Write-Host '       Starting MeshCentral service...' -ForegroundColor Gray
    $svc = Get-Service -Name 'MeshCentral' -ErrorAction SilentlyContinue
    if ($svc.Status -ne 'Running') {
      $started = $false
      try { Start-Service -Name 'MeshCentral' -ErrorAction Stop; $started = $true }
      catch {
        $startOut = & $nodeExe $MeshJs --start 2>&1 | Out-String
        Start-Sleep -Seconds 10
        $svc = Get-Service -Name 'MeshCentral' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { $started = $true }
        else { throw "Service would not start. Start-Service error: $($_.Exception.Message)`n--start output:`n$startOut" }
      }
    }
    $svc = Get-Service -Name 'MeshCentral' -ErrorAction SilentlyContinue
    $svc.WaitForStatus('Running', (New-TimeSpan -Minutes 2))
    Add-Result 'MeshCentral service running' $true "Service status: $($svc.Status)"
  } finally { Pop-Location }
} catch {
  Add-Result 'MeshCentral service running' $false $_.Exception.Message
}

# --- Step 7: Verify web UI on loopback ------------------------------------------
Write-Host ''
Write-Host 'Step 7/9: Web UI on https://127.0.0.1:4430' -ForegroundColor Cyan
try {
  $deadline = (Get-Date).AddMinutes(3)
  $webOk = $false
  while ((Get-Date) -lt $deadline -and -not $webOk) {
    # curl.exe -k ignores the self-signed cert; works on PS 5.1 and 7
    $code = & curl.exe -sk -o NUL -w '%{http_code}' "https://127.0.0.1:$Port/" 2>$null
    if ($code -eq '200') { $webOk = $true } else { Start-Sleep -Seconds 5 }
  }
  if (-not $webOk) { throw 'Login page did not respond on https://127.0.0.1:4430/ within 3 minutes.' }
  # Confirm nothing listens on non-loopback for our ports
  $badListeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $Port -and $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' }
  if ($badListeners) { throw 'Port 4430 is listening on a non-loopback address!' }
  Add-Result 'Web UI answers on loopback only' $true "Login page OK; port $Port bound to 127.0.0.1 only."
} catch {
  Add-Result 'Web UI answers on loopback only' $false $_.Exception.Message
}

# --- Step 8: Device group + agent -------------------------------------------------
Write-Host ''
Write-Host 'Step 8/9: Device group + MeshAgent' -ForegroundColor Cyan
$groupOk = $false; $agentDlOk = $false; $agentSvcOk = $false; $agentSeen = $false
$groupDetail = ''; $agentDlDetail = ''; $agentSvcDetail = ''; $agentSeenDetail = ''
try {
  if (-not $AdminPass) { throw 'Skipped: admin password unavailable (see step 5).' }
  if (-not (Test-Path $MeshCtrlJs)) { throw 'Skipped: meshctrl.js not found.' }
  $mcArgs = @('--url', "wss://127.0.0.1:$Port", '--loginuser', $AdminUser, '--loginpass', $AdminPass)
  Push-Location $InstallDir
  try {
    $groups = & $nodeExe $MeshCtrlJs ListDeviceGroups @mcArgs 2>&1 | Out-String
    if ($groups -match '"([^"]+)",\s*"SETHS-PC"') {
      $MeshId = $Matches[1]
      $groupOk = $true; $groupDetail = "Already exists (id: $MeshId)."
    } else {
      Write-Host '       Creating device group "SETHS-PC"...' -ForegroundColor Gray
      $addOut = & $nodeExe $MeshCtrlJs AddDeviceGroup @mcArgs --name $GroupName 2>&1 | Out-String
      if ($addOut -match 'ok mesh//(\S+)') {
        $MeshId = $Matches[1]
        $groupOk = $true; $groupDetail = "Created (id: $MeshId)."
      } else { $groupDetail = "AddDeviceGroup failed: $addOut" }
    }

    if ($groupOk) {
      # Download the Windows x64 agent (id 4) provisioned for this group
      $agentExe = Get-ChildItem -Path $InstallDir -Filter 'meshagent64-*.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if (-not $agentExe) {
        Write-Host '       Downloading Windows x64 agent...' -ForegroundColor Gray
        & $nodeExe $MeshCtrlJs AgentDownload @mcArgs --id $MeshId --type 4 2>&1 | Out-Null
        $agentExe = Get-ChildItem -Path $InstallDir -Filter 'meshagent64-*.exe' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
      }
      if ($agentExe -and $agentExe.Length -gt 100000) {
        $agentDlOk = $true
        $agentDlDetail = "$($agentExe.Name) ($([math]::Round($agentExe.Length/1MB,1)) MB)"
      } else { $agentDlDetail = 'Agent exe was not downloaded correctly.' }
    }

    if ($agentDlOk) {
      # Install the agent (the exe self-installs the "Mesh Agent" service when elevated)
      $agentSvc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
      if (-not $agentSvc) {
        Write-Host '       Installing agent (silent)...' -ForegroundColor Gray
        Start-Process -FilePath $agentExe.FullName -Wait
        Start-Sleep -Seconds 10
        $agentSvc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
      }
      if ($agentSvc) {
        if ($agentSvc.Status -ne 'Running') { Start-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue }
        $agentSvcOk = $true; $agentSvcDetail = "Service status: $($agentSvc.Status)"
      } else { $agentSvcDetail = 'Agent ran but the "Mesh Agent" service was not found.' }
    }

    if ($agentSvcOk) {
      # Confirm the device checked in
      $deadline = (Get-Date).AddMinutes(2)
      while ((Get-Date) -lt $deadline -and -not $agentSeen) {
        $devs = & $nodeExe $MeshCtrlJs ListDevices @mcArgs 2>&1 | Out-String
        if ($devs -match '(?i)seths-pc') { $agentSeen = $true } else { Start-Sleep -Seconds 10 }
      }
      $agentSeenDetail = if ($agentSeen) { 'Device is checking in.' } else { 'Agent service exists but the device has not appeared yet. It may take a few minutes; check Devices in the web UI.' }
    }
  } finally { Pop-Location }
} catch {
  if (-not $groupDetail) { $groupDetail = $_.Exception.Message }
}
Add-Result 'Device group "SETHS-PC"' $groupOk $groupDetail
Add-Result 'Agent downloaded (Windows x64)' $agentDlOk $(if ($agentDlDetail) { $agentDlDetail } else { 'Skipped (no device group).' })
Add-Result 'MeshAgent service installed' $agentSvcOk $(if ($agentSvcDetail) { $agentSvcDetail } else { 'Skipped (no agent download).' })
Add-Result 'Agent connected to server' $agentSeen $(if ($agentSeenDetail) { $agentSeenDetail } else { 'Skipped (no agent service).' })

# --- Step 9: Tailscale Serve ------------------------------------------------------
Write-Host ''
Write-Host 'Step 9/9: Tailscale Serve (private HTTPS)' -ForegroundColor Cyan
$ServeUrl = $null
try {
  $ts = Get-Command tailscale -ErrorAction SilentlyContinue
  if (-not $ts) { throw 'tailscale command not found. Install Tailscale and sign in first: https://tailscale.com/download/windows' }

  $tsJson = & tailscale status --json 2>$null | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
  if (-not $tsJson -or -not $tsJson.Self -or -not $tsJson.Self.DNSName) {
    throw 'Tailscale is not logged in. Open the Tailscale app and sign in, then re-run this script.'
  }
  $dnsName = $tsJson.Self.DNSName
  $ServeUrl = "https://$dnsName/"

  # Funnel would make this PUBLIC - make sure it stays off
  & tailscale funnel off 2>&1 | Out-Null

  $serveStatus = & tailscale serve status 2>&1 | Out-String
  if ($serveStatus -match "127\.0\.0\.1:$Port|localhost:$Port") {
    Write-Host '       Tailscale Serve already points at 127.0.0.1:4430.' -ForegroundColor Gray
  } else {
    Write-Host '       Enabling Tailscale Serve (tailnet-only HTTPS)...' -ForegroundColor Gray
    # Self-signed backend cert -> https+insecure; Serve still presents a valid *.ts.net cert
    & tailscale serve --bg "https+insecure://127.0.0.1:$Port" 2>&1 | Out-Null
    $serveStatus = & tailscale serve status 2>&1 | Out-String
  }
  if ($serveStatus -notmatch "127\.0\.0\.1:$Port|localhost:$Port") {
    throw "Serve is not pointing at 127.0.0.1:$Port. Output: $serveStatus"
  }
  Add-Result 'Tailscale Serve (private)' $true "Serving https://127.0.0.1:$Port as $ServeUrl (tailnet only; Funnel off)."
} catch {
  Add-Result 'Tailscale Serve (private)' $false $_.Exception.Message
}

# --- Scorecard --------------------------------------------------------------------
Write-Host ''
Write-Host '============================== RESULT ==============================' -ForegroundColor Cyan
foreach ($r in $Results) {
  $word = if ($r.OK) { 'PASS' } else { 'FAIL' }
  Write-Host ("{0,-6} {1}" -f $word, $r.Step)
}
Write-Host '====================================================================' -ForegroundColor Cyan
Write-Host ''
if ($ServeUrl -and $AdminPass) {
  Write-Host 'MeshCentral is ready at (Tailscale only):' -ForegroundColor Green
  Write-Host "  $ServeUrl" -ForegroundColor White
  Write-Host "  Login with username: muse"
  Write-Host "  Password is in: $CredFile (stays on your PC — never paste it in chat)"
} else {
  Write-Host 'Setup did not fully complete. See the FAIL lines above,' -ForegroundColor Red
  Write-Host 'fix what they describe, then re-run this script (it skips finished steps).' -ForegroundColor Red
}
Write-Host ''
Write-Host 'Security notes:' -ForegroundColor Cyan
Write-Host ' - MeshCentral listens ONLY on 127.0.0.1:4430 (no LAN/Wi-Fi exposure).'
Write-Host ' - The .ts.net address works only for devices on your Tailscale network.'
Write-Host ' - Public account signup is disabled; only the "muse" admin exists.'
Write-Host ' - No Windows Firewall rule was opened.'
