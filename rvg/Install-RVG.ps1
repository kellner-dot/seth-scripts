# Install-RVG.ps1 — first-run setup for the RVG GitHub update channel.
# Run ONCE on Seth's PC, as Administrator.
#
# Does three things:
#   1. Prompts for the GitHub fine-grained PAT (SecureString — never echoed,
#      never stored in plaintext) and DPAPI-encrypts it to
#      $env:ProgramData\RVG\github.pat (LocalMachine scope).
#   2. Copies Update-RVG.ps1 to $env:ProgramData\RVG\ for the scheduled task.
#   3. Registers the "RVG update check" scheduled task (every 6 hours).
#
# The PAT needs only read access to the private kellner-dot/rvg repo.
# To rotate: re-run this script with the new PAT.

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$RVGDataDir = Join-Path $env:ProgramData "RVG"
$AgentPath  = Join-Path $env:USERPROFILE "rvd\rvg15\rvg_agent.py"

if (-not (Test-Path $AgentPath)) {
    throw "RVG agent not found at $AgentPath — install the agent first."
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$updaterSrc = Join-Path $here "Update-RVG.ps1"
if (-not (Test-Path $updaterSrc)) {
    throw "Update-RVG.ps1 not found next to this installer."
}

New-Item -ItemType Directory -Force -Path $RVGDataDir | Out-Null
Copy-Item -Path $updaterSrc -Destination (Join-Path $RVGDataDir "Update-RVG.ps1") -Force
Write-Host "Updater installed to $RVGDataDir"

# --- PAT -----------------------------------------------------------------
Write-Host ""
Write-Host "Paste the GitHub fine-grained PAT (read-only, kellner-dot/rvg):"
$sec = Read-Host -AsSecureString -Prompt "PAT"
if ($sec.Length -eq 0) { throw "No PAT entered — aborting." }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes((Join-Path $RVGDataDir "github.pat"), $enc)
    # Scrub the plaintext from memory as soon as possible.
    [Array]::Clear($bytes, 0, $bytes.Length)
    $plain = $null
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
Write-Host "PAT stored (DPAPI-encrypted, LocalMachine scope)."

# --- Scheduled task -------------------------------------------------------
$taskName = "RVG update check"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' +
    '"& ''' + (Join-Path $RVGDataDir "Update-RVG.ps1") + '''; Invoke-RVGUpdate"'
)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -DontStopOnIdleEnd -AllowStartIfOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount

try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled task '$taskName' registered (every 6h, first run in ~5 min)."

Write-Host ""
Write-Host "Done. Test with:  powershell -File `"$RVGDataDir\Update-RVG.ps1`"; Invoke-RVGUpdate"
Write-Host "Expect a no-op at the current version on first run."
