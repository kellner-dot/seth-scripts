# KaviGuard status dashboard - double-click friendly.
$ErrorActionPreference = "SilentlyContinue"
$dir = "C:\Tools\KaviGuard"
$f = Join-Path $dir "status.json"
Write-Host ""
Write-Host "  ================= KAVIGUARD =================" -ForegroundColor Cyan
if (Test-Path $f) {
    $s = Get-Content $f -Raw | ConvertFrom-Json
    if ($s.running) { Write-Host "  Status:    YES" -ForegroundColor Green }
    else { Write-Host "  Status:    NO" -ForegroundColor Red }
    Write-Host "  Version:   $($s.version)"
    Write-Host "  Since:     $($s.startedAt)"
    Write-Host "  Last quick scan: $($s.lastQuickScan)"
    Write-Host "  Last full scan:  $($s.lastFullScan)"
    $tc = "Green"
    if (([int]$s.threatsFound) -gt 0 -or (([int]$s.threatsQuarantined) -gt 0)) { $tc = "Red" }
    Write-Host "  Threats found:       $($s.threatsFound)" -ForegroundColor $tc
    Write-Host "  Threats quarantined: $($s.threatsQuarantined)" -ForegroundColor $tc
    if ($s.defenderRealtime -eq $true) { Write-Host "  Defender real-time:  ON" -ForegroundColor Green }
    else { Write-Host "  Defender real-time:  OFF!" -ForegroundColor Red }
    if ($s.lastError) { Write-Host "  Last error: $($s.lastError)" -ForegroundColor Yellow }
} else {
    Write-Host "  Not running yet (no status file)." -ForegroundColor Yellow
}
$q = Join-Path $dir "quarantine"
$n = @(Get-ChildItem $q -File -ErrorAction SilentlyContinue).Count
Write-Host "  Files in quarantine: $n"
Write-Host "  ==============================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "  Press Enter to close" | Out-Null
