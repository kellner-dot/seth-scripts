<#
RVG update check - runs DAILY as a scheduled task ("RVG update check").

What it does:
  1. Reads %USERPROFILE%\rvd\rvg_update_config.json (repo + enabled flag).
     If not configured, it exits quietly - nothing happens until YOU set
     up the GitHub repo (one-time steps in docs\BUILD-NOTES.md).
  2. Asks the GitHub API for the latest release of the configured repo.
  3. If the release tag is newer than the installed agent's VERSION:
     downloads the rvg_agent.py release asset (plus rvg_viewer.py if the
     release ships one), verifies both (VERSION matches the tag, compiles
     clean, SHA256 logged), then pushes them through the agent's own
     POST /rvd/update endpoint (token auth - the same token as everything
     else). The agent applies both files, then restarts itself.
  4. Logs everything to %USERPROFILE%\rvd\update-check.log.

Runs WITHOUT admin. Works even if the agent is down (it just logs
"agent not running" and tries again tomorrow).
#>
$ErrorActionPreference = "Stop"
$RvdDir   = Join-Path $env:USERPROFILE "rvd"
$Config   = Join-Path $RvdDir "rvg_update_config.json"
$LogFile  = Join-Path $RvdDir "update-check.log"
$AgentDir = Join-Path $RvdDir "rvg15"

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function VerTuple($v) {
    $v -replace '^v','' -split '\.' | ForEach-Object {
        $n = 0; [int]::TryParse(($_ -replace '\D',''), [ref]$n) | Out-Null; $n
    }
}
function VerNewer($a, $b) {   # true if $a is newer than $b
    $ta, $tb = VerTuple $a, VerTuple $b
    for ($i = 0; $i -lt [Math]::Max($ta.Count, $tb.Count); $i++) {
        $x = if ($i -lt $ta.Count) { $ta[$i] } else { 0 }
        $y = if ($i -lt $tb.Count) { $tb[$i] } else { 0 }
        if ($x -ne $y) { return $x -gt $y }
    }
    return $false
}

function Test-PySyntax($code, $label) {   # true if $code compiles
    $tmp = Join-Path $env:TEMP "rvg_verify_$label.py"
    [IO.File]::WriteAllText($tmp, $code)
    $ok = $true
    $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    try {
        if ($py) {
            & $py -m py_compile $tmp 2>$null
            if ($LASTEXITCODE -ne 0) { throw "py_compile failed" }
        } else {
            Log "no python found - skipping local syntax check for $label (agent re-checks before applying)"
        }
    } catch {
        Log "$label failed py_compile - refusing that part"
        $ok = $false
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $ok
}

try {
    if (-not (Test-Path $Config)) { exit 0 }   # installer creates it; be quiet
    $cfg = Get-Content $Config -Raw | ConvertFrom-Json
    if (-not $cfg.enabled -or -not $cfg.repo) { exit 0 }
    $ghHeaders = @{ "User-Agent" = "RVG-update-check" }
    if ($cfg.token) { $ghHeaders["Authorization"] = "Bearer $($cfg.token)" }

    # --- local version ------------------------------------------------
    $agentFile = Join-Path $AgentDir "rvg_agent.py"
    if (-not (Test-Path $agentFile)) {
        Log "agent file missing at $agentFile - skipping check"
        exit 0
    }
    $local = ([regex]::Match(
        (Get-Content $agentFile -Raw), '^VERSION\s*=\s*["'']([^"'']+)["'']',
        'Multiline')).Groups[1].Value
    if (-not $local) { Log "couldn't parse local VERSION - skipping"; exit 0 }

    # --- latest GitHub release ----------------------------------------
    $rel = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$($cfg.repo)/releases/latest" `
        -Headers $ghHeaders -TimeoutSec 30
    $tag = $rel.tag_name
    if (-not $tag) { Log "GitHub returned no tag_name - skipping"; exit 0 }

    if (-not (VerNewer $tag $local)) { exit 0 }   # up to date - stay quiet

    Log "update available: local $local -> GitHub $tag"

    # --- download the rvg_agent.py release asset -----------------------
    $asset = $rel.assets | Where-Object { $_.name -like "rvg_agent*.py" } |
             Select-Object -First 1
    if (-not $asset) {
        Log "release $tag has no rvg_agent*.py asset - skipping"
        exit 0
    }
    $tmp = Join-Path $env:TEMP "rvg_agent_update.py"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp `
        -Headers $ghHeaders -TimeoutSec 120
    $code = Get-Content $tmp -Raw
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    # --- verify ---------------------------------------------------------
    $decl = ([regex]::Match($code, '^VERSION\s*=\s*["'']([^"'']+)["'']',
                             'Multiline')).Groups[1].Value
    if ($decl -ne ($tag -replace '^v','')) {
        Log "asset VERSION ($decl) doesn't match tag ($tag) - refusing"
        exit 0
    }
    $sha = (Get-FileHash -Algorithm SHA256 `
            -InputStream ([IO.MemoryStream]::new(
                [Text.Encoding]::UTF8.GetBytes($code)))).Hash
    Log "downloaded $tag, SHA256=$sha"
    if (-not (Test-PySyntax $code "agent")) { exit 0 }
    if ($code -notmatch "127\.0\.0\.1" -or $code -notmatch "X-RVD-Token") {
        Log "downloaded agent missing loopback/token guard - refusing"
        exit 0
    }

    # --- download the rvg_viewer.py release asset (optional) --------------
    # If the release ships a viewer, push it through the same /rvd/update
    # call - the agent validates and applies both files, then restarts.
    # No viewer asset = agent-only update (viewer stays as-is).
    $viewerCode = ""
    $vasset = $rel.assets | Where-Object { $_.name -like "rvg_viewer*.py" } |
              Select-Object -First 1
    if ($vasset) {
        $tmpv = Join-Path $env:TEMP "rvg_viewer_update.py"
        Invoke-WebRequest -Uri $vasset.browser_download_url -OutFile $tmpv `
            -Headers $ghHeaders -TimeoutSec 120
        $viewerCode = Get-Content $tmpv -Raw
        Remove-Item $tmpv -Force -ErrorAction SilentlyContinue
        $vdecl = ([regex]::Match($viewerCode,
                  '^VERSION\s*=\s*["'']([^"'']+)["'']',
                  'Multiline')).Groups[1].Value
        if ($vdecl -ne ($tag -replace '^v','')) {
            Log "viewer asset VERSION ($vdecl) doesn't match tag ($tag) - skipping viewer part"
            $viewerCode = ""
        } elseif (-not (Test-PySyntax $viewerCode "viewer")) {
            $viewerCode = ""
        } else {
            Log "viewer $tag verified"
        }
    } else {
        Log "release $tag has no rvg_viewer*.py asset - agent-only update"
    }

    # --- push through the agent's own update endpoint -------------------
    $tokenFile = Join-Path $RvdDir "token.txt"
    if (-not (Test-Path $tokenFile)) { Log "token.txt missing - skipping"; exit 0 }
    $tok = [IO.File]::ReadAllText($tokenFile).Trim()
    try {
        $body = @{ version = ($tag -replace '^v',''); code = $code }
        if ($viewerCode) { $body["viewer_code"] = $viewerCode }
        $r = Invoke-RestMethod "http://127.0.0.1:8899/rvd/update" -Method Post `
            -Headers @{ "X-RVD-Token" = $tok } `
            -Body ($body | ConvertTo-Json -Depth 3) `
            -ContentType "application/json" -TimeoutSec 60
        Log "update applied: $($r.updated) (backup: $($r.backup))"
    } catch {
        Log "agent not running or refused update - will retry tomorrow: $($_.Exception.Message)"
    }
} catch {
    Log "update check failed: $($_.Exception.Message)"
    exit 1
}
