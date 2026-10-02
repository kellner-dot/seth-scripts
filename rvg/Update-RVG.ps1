# RVG self-update module — mirrors KaviGuard's Invoke-KGUpdate pattern.
# Adapted for a PRIVATE repo: raw fetches authenticate with a fine-grained PAT
# kept in DPAPI-encrypted local storage (never in the repo, never in logs).
#
# Poll cadence: run Invoke-RVGUpdate from the "RVG update check" scheduled
# task (see Install-RVG.ps1). Same ~6h cadence KaviGuard uses.
#
# Note: the agent ALSO has a push-based updater (POST /rvd/update) that a Kavi
# can use to ship a version immediately. This poller is the unattended path —
# it picks up whatever version.txt points at, no Kavi involved.

$RVGUpdateBaseUrl = "https://raw.githubusercontent.com/kellner-dot/rvg/main"  # private repo
$RVGInstallDir    = Join-Path $env:USERPROFILE "rvd\rvg15"

function Get-RVGPAT {
    # Returns the GitHub PAT (plaintext) from DPAPI-encrypted storage, or $null.
    # The PAT is written once by Install-RVG.ps1 via Set-RVGPAT.
    $patFile = Join-Path $env:ProgramData "RVG\github.pat"
    if (-not (Test-Path $patFile)) { return $null }
    try {
        $enc = [IO.File]::ReadAllBytes($patFile)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Text.Encoding]::UTF8.GetString($dec)
    } catch { return $null }
}

function Get-RVGInstalledVersion {
    # Parse VERSION = "x.y" from the installed agent file. $null if unreadable.
    $agent = Join-Path $RVGInstallDir "rvg_agent.py"
    if (-not (Test-Path $agent)) { return $null }
    $m = Select-String -Path $agent -Pattern '^VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Invoke-RVGWebRequest {
    param([string]$Uri, [string]$OutFile)
    $pat = Get-RVGPAT
    if (-not $pat) { throw "RVG update: no GitHub PAT stored (run Install-RVG.ps1)" }
    $headers = @{ Authorization = "Bearer $pat" }
    if ($OutFile) {
        Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 120 -OutFile $OutFile -ErrorAction Stop
    } else {
        (Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop).Content
    }
}

function Invoke-RVGUpdate {
    # URL path in repo -> installed destination path on the PC.
    $targets = @(
        @{ Url = "src/rvg_agent.py"; Dest = (Join-Path $RVGInstallDir "rvg_agent.py") },
    )
    try {
        $remote = (Invoke-RVGWebRequest "$RVGUpdateBaseUrl/version.txt").Trim()
        $installed = Get-RVGInstalledVersion
        if (-not $installed) {
            Write-Host "RVG update: installed agent not found at $RVGInstallDir — run Install-RVG.ps1 first"
            return
        }
        if ([version]$remote -le [version]$installed) { return }  # no-op: already current
        Write-Host "RVG update available: $installed -> $remote"

        $staged = @()
        foreach ($t in $targets) {
            $tmpNew = Join-Path $env:TEMP ("rvg_upd_" + [IO.Path]::GetFileName($t.Url))
            Invoke-RVGWebRequest "$RVGUpdateBaseUrl/$($t.Url)" -OutFile $tmpNew
            $want = (Invoke-RVGWebRequest "$RVGUpdateBaseUrl/$($t.Url).sha256").Trim().Split()[0].ToUpper()
            $got = (Get-FileHash -Path $tmpNew -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpper()
            if ($want -ne $got) { throw "update aborted: hash mismatch on $($t.Url)" }
            # Python syntax check before anything is replaced.
            $py = Get-Command pythonw.exe -ErrorAction SilentlyContinue
            if (-not $py) { $py = Get-Command python.exe -ErrorAction SilentlyContinue }
            if ($py) {
                & $py.Source -m py_compile $tmpNew 2>$null
                if ($LASTEXITCODE -ne 0) { throw "update aborted: Python syntax error in $($t.Url)" }
            } else {
                Write-Host "RVG update: no Python found for syntax check — hash verified only"
            }
            $staged += @{ Tmp = $tmpNew; Dest = $t.Dest; Url = $t.Url }
        }

        # Timestamped backup of the running file, then swap.
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        foreach ($s in $staged) {
            if (Test-Path $s.Dest) {
                Copy-Item -Path $s.Dest -Destination ($s.Dest + ".bak-$stamp") -Force
            }
            Move-Item -Path $s.Tmp -Destination $s.Dest -Force -ErrorAction Stop
            Write-Host "RVG updated $($s.Url)"
        }
        Write-Host "RVG updated to $remote — restarting the RVG agent scheduled task to apply"
        schtasks /run /tn "RVG agent" | Out-Null
    } catch { Write-Host "RVG update check failed: $($_.Exception.Message)" }
}
