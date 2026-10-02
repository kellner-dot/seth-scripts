#Requires -Version 5.1
<#
.SYNOPSIS
  Copies movies to TeraBox (via the rclone "tb" remote) WITHOUT deleting anything.
  - Refuses to run on OneDrive online-only placeholder files.
  - Uses rclone copy (never move), with retries and progress.
  - Verifies: rclone check + file-count/total-bytes match + SHA256 manifest CSV.
  - Never deletes originals. Prints the staged deletion command on success.
.PARAMETER SourceDir
  Local movie folder. Default: C:\Users\sethr\OneDrive\Desktop\Movies
.PARAMETER Dest
  rclone destination. Default: tb:/Movies
.PARAMETER Checksum
  Full byte-level verification (rclone check --download). Slow on big libraries,
  but proves every byte. Recommended for the first run if you can leave it overnight.
.PARAMETER DryRun
  Show what would be copied without copying anything.
#>

param(
    [string]$SourceDir = 'C:\Users\sethr\OneDrive\Desktop\Movies',
    [string]$Dest = 'tb:/Movies',
    [switch]$Checksum,
    [switch]$DryRun,
    [int]$MaxFiles = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Gray' } }
    Write-Host ("[{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("       {0}" -f $Detail) -ForegroundColor Gray }
}
function Write-Info([string]$Msg) { Write-Host $Msg -ForegroundColor Cyan }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "movie-migration-$stamp.log"
$manifestPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "movie-migration-manifest-$stamp.csv"
"Migration log started $(Get-Date)" | Set-Content -LiteralPath $logFile

Write-Info 'Movie migration to TeraBox — copy only, nothing gets deleted.'
Write-Info ("Source: {0}" -f $SourceDir)
Write-Info ("Dest:   {0}" -f $Dest)
if ($DryRun) { Write-Info 'DRY RUN: nothing will be uploaded.' }
Write-Host ''

# ---------- find rclone ----------
$rcloneExe = $null
foreach ($cand in @('C:\rclone\rclone.exe', (Get-Command rclone -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source))) {
    if ($cand -and (Test-Path $cand)) { $rcloneExe = $cand; break }
}
if (-not $rcloneExe) {
    Write-Step 'Prerequisites' 'FAIL' 'rclone not found. Run install-terabox-stack.ps1 first.'
    exit 1
}
$remotes = (& $rcloneExe listremotes 2>$null | Out-String)
if ($remotes -notmatch '(?m)^tb:') {
    Write-Step 'Prerequisites' 'FAIL' 'rclone remote "tb:" not configured. Run install-terabox-stack.ps1 first.'
    exit 1
}
if (-not (Test-Path -LiteralPath $SourceDir)) {
    Write-Step 'Prerequisites' 'FAIL' ("Source folder not found: {0}" -f $SourceDir)
    exit 1
}
Write-Step 'Prerequisites' 'PASS' 'rclone + tb: remote + source folder all present.'

# ---------- 1. OneDrive placeholder check ----------
Write-Info 'Checking for OneDrive online-only (placeholder) files...'
$offline = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0 }
if ($offline -and $offline.Count -gt 0) {
    Write-Host ''
    Write-Host 'STOP: Found {0} online-only placeholder files (showing a cloud icon).' -f $offline.Count -ForegroundColor Red
    Write-Host 'This script will NOT download terabytes for you silently.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'To fix:' -ForegroundColor Cyan
    Write-Host '  1. Open File Explorer and go to the Movies folder.'
    Write-Host '  2. Right-click the folder -> "Always keep on this device".'
    Write-Host '  3. Wait until every file shows a green checkmark (fully downloaded).'
    Write-Host '  4. Run this script again.'
    Write-Host ''
    Write-Host 'First few placeholders:' -ForegroundColor Gray
    $offline | Select-Object -First 5 | ForEach-Object { Write-Host ("  {0}" -f $_.FullName) -ForegroundColor Gray }
    exit 1
}
Write-Step 'Placeholder check' 'PASS' 'No online-only files. Everything is really on this PC.'

# ---------- 2. pre-scan ----------
Write-Info 'Scanning source files (this can take a few minutes on a big library)...'
$allFiles = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue
$bigFiles = $allFiles | Where-Object { $_.Length -gt 4GB }
$okFiles = $allFiles | Where-Object { $_.Length -le 4GB }
$totalBytes = ($okFiles | Measure-Object -Property Length -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }
$okCount = @($okFiles).Count
$bigCount = @($bigFiles).Count
if ($MaxFiles -gt 0 -and $okCount -gt $MaxFiles) {
    $okFiles = @($okFiles | Select-Object -First $MaxFiles)
    $totalBytes = ($okFiles | Measure-Object -Property Length -Sum).Sum
    $okCount = $MaxFiles
    Write-Step 'Test batch' 'PASS' ("Limited to the first {0} files for a trial run." -f $MaxFiles)
}
if ($okCount -eq 0 -and $bigCount -eq 0) {
    Write-Step 'Pre-scan' 'FAIL' 'No files found in the source folder. Nothing to copy.'
    exit 1
}

Write-Step 'Pre-scan' 'PASS' ("{0} files, {1:N2} GB to copy." -f $okCount, ($totalBytes / 1GB))
if ($bigFiles) {
    Write-Step 'Oversize files' 'WARN' ("{0} file(s) are over TeraBox's 4 GB free limit and will be SKIPPED:" -f $bigCount)
    $bigFiles | ForEach-Object { Write-Host ("  SKIP {0:N2} GB  {1}" -f ($_.Length / 1GB), $_.FullName) -ForegroundColor Yellow }
    Write-Host '  These stay on your local drive. (TeraBox Premium raises the cap — optional.)' -ForegroundColor Gray
}
if ($totalBytes -gt 950GB) {
    Write-Step 'Quota warning' 'WARN' 'Source is over ~950 GB; free TeraBox holds 1 TB total. Copy will stop when full — move in batches.'
}

# ---------- 3. rclone copy ----------
Write-Info 'Starting upload. This runs for hours/days on a big library — Ctrl+C stops it,'
Write-Info 'and re-running the same command resumes where it left off.'
$filesFrom = $null
if ($MaxFiles -gt 0) {
    # --files-from restricts the copy (and later the check) to exactly the test-batch files.
    $filesFrom = Join-Path $env:TEMP 'terabox-migrate-files.txt'
    $okFiles | ForEach-Object {
        ($_.FullName.Substring($SourceDir.Length).TrimStart('\','/') -replace '\\','/')
    } | Set-Content -Path $filesFrom -Encoding UTF8
    Write-Info ("Test batch file list written to {0}" -f $filesFrom)
}
$copyArgs = @('copy', $SourceDir, $Dest)
if (-not $filesFrom) { $copyArgs += @('--max-size', '4G') }  # file list is already size-filtered
$copyArgs += @(
    '--retries', '5', '--retries-sleep', '30s',
    '--transfers', '4', '--checkers', '16',
    '--order-by', 'size,asc',
    '--progress', '--stats', '30s',
    '--log-level', 'NOTICE', '--log-file', $logFile)
# Exclude the borderline ~4GB Possessor file: it tripped TeraBox's server-side
# 423 upload-session lock on 2026-09-23. Leave it alone until the lock expires.
$copyArgs += @('--exclude', 'Possessor*')
if ($filesFrom) { $copyArgs += @('--files-from', $filesFrom) }
if ($DryRun) { $copyArgs += '--dry-run' }
& $rcloneExe @copyArgs
if ($LASTEXITCODE -ne 0) {
    Write-Step 'Upload' 'FAIL' ("rclone copy exited with code {0}. See {1}" -f $LASTEXITCODE, $logFile)
    exit 1
}
Write-Step 'Upload' 'PASS' 'rclone copy finished without errors.'
if ($DryRun) { Write-Info 'Dry run complete. Re-run without -DryRun to actually copy.'; exit 0 }

# ---------- 4. verification ----------
Write-Info 'Verifying: every file present with matching size...'
function Invoke-Check {
    param([string[]]$ExtraArgs)
    $args = @('check', $SourceDir, $Dest, '--log-level', 'NOTICE') + $ExtraArgs
    if ($filesFrom) { $args += @('--files-from', $filesFrom) } else { $args += @('--max-size', '4G') }
    $out = (& $rcloneExe @args 2>&1 | Out-String)
    return @{ ExitCode = $LASTEXITCODE; Output = $out }
}

$verified = $false
$verifyNote = ''
if ($Checksum) {
    Write-Info 'Full checksum mode: downloading every file back to verify bytes (slow)...'
    $r = Invoke-Check @('--download')
    if ($r.ExitCode -eq 0 -and $r.Output -match '0 differences found') {
        $verified = $true; $verifyNote = 'Byte-level checksum verification passed.'
    }
} else {
    $r = Invoke-Check @()
    if ($r.ExitCode -eq 0 -and $r.Output -match '0 differences found') {
        $verified = $true; $verifyNote = 'All files present with matching size and timestamp.'
    } else {
        # Fallback: some WebDAV servers don't preserve timestamps; size match is still meaningful.
        $r2 = Invoke-Check @('--size-only')
        if ($r2.ExitCode -eq 0 -and $r2.Output -match '0 differences found') {
            $verified = $true
            $verifyNote = 'Sizes match on all files. (Timestamps differ — Alist WebDAV does not preserve them. Harmless.)'
        }
    }
}
if (-not $verified) {
    Write-Step 'Verification' 'FAIL' ("rclone check found differences. Details in {0}" -f $logFile)
    Write-Host $r.Output -ForegroundColor Gray
    exit 1
}
Write-Step 'Verification' 'PASS' $verifyNote

# ---------- 5. manifest CSV + count/bytes cross-check ----------
Write-Info 'Building manifest (relative path, size, SHA256) — hashing reads every file once...'
$manifestRows = @()
$i = 0
$n = $okCount
foreach ($f in $okFiles) {
    $i++
    if ($i % 25 -eq 0 -or $i -eq $n) {
        Write-Progress -Activity 'Hashing files for manifest' -Status ("{0} of {1}" -f $i, $n) `
            -PercentComplete ([int](($i * 100) / [Math]::Max($n, 1)))
    }
    $rel = $f.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $manifestRows += [pscustomobject]@{ RelativePath = $rel; SizeBytes = $f.Length; SHA256 = $hash }
}
Write-Progress -Activity 'Hashing files for manifest' -Completed
$manifestRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

Write-Info 'Cross-checking count and total bytes against TeraBox...'
$lsjson = (& $rcloneExe lsjson --recursive --max-size 4G $Dest 2>$null | Out-String | ConvertFrom-Json)
$destFiles = @($lsjson | Where-Object { -not $_.IsDir })
$destBytes = ($destFiles | Measure-Object -Property Size -Sum).Sum
$srcBytes = ($manifestRows | Measure-Object -Property SizeBytes -Sum).Sum
if ($destFiles.Count -eq $manifestRows.Count -and $destBytes -eq $srcBytes) {
    Write-Step 'Count/bytes match' 'PASS' ("{0} files, {1:N2} GB on both sides." -f $destFiles.Count, ($destBytes / 1GB))
} else {
    Write-Step 'Count/bytes match' 'FAIL' ("Source: {0} files / {1:N2} GB. TeraBox: {2} files / {3:N2} GB." -f `
        $manifestRows.Count, ($srcBytes / 1GB), $destFiles.Count, ($destBytes / 1GB))
    exit 1
}
Write-Step 'Manifest' 'PASS' ("Wrote {0}" -f $manifestPath)

# ---------- done ----------
Write-Host ''
Write-Host '================ MIGRATION COMPLETE ================' -ForegroundColor Green
Write-Host 'Your movies are on TeraBox and verified. NOTHING was deleted.' -ForegroundColor Green
Write-Host ("Manifest: {0}" -f $manifestPath) -ForegroundColor Gray
Write-Host ("Full log: {0}" -f $logFile) -ForegroundColor Gray
Write-Host ''
Write-Host 'Next: point Emby at the cloud copy (see MIGRATE.md), play a few movies' -ForegroundColor Cyan
Write-Host 'start-to-finish, and only then delete locals — ONE folder at a time, YOUR call:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  # Example — delete a single movie folder when YOU are ready:' -ForegroundColor Yellow
Write-Host ("  Remove-Item -LiteralPath `"{0}\<Folder Name>`" -Recurse -Force" -f $SourceDir) -ForegroundColor Yellow
Write-Host ''
Write-Host 'TeraBox keeps deleted cloud files for 10 days as a safety net.' -ForegroundColor Gray
