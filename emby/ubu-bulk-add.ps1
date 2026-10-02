# Bulk-add missing FastUbu films to Emby UbuWeb library
# Reads C:\Users\sethr\rvd\ubu-missing.json, creates .strm + .nfo per film
# Tracks progress in C:\Users\sethr\rvd\ubu-bulk-add-progress.txt
# Usage: .\ubu-bulk-add.ps1 -BatchSize 200 -BatchNumber 0  (0-indexed)

param(
    [int]$BatchSize = 200,
    [int]$BatchNumber = 0
)

$ErrorActionPreference = 'Continue'
$base = 'C:\UbuWeb\UbuWeb'
$jsonPath = 'C:\Users\sethr\rvd\ubu-missing.json'
$progressPath = 'C:\Users\sethr\rvd\ubu-bulk-add-progress.txt'
$failPath = 'C:\Users\sethr\rvd\ubu-bulk-add-failed.txt'

function Sanitize-Name($s) {
    if (-not $s) { return 'Unknown' }
    $s = $s -replace '[<>:"/\\|?*#]', ''   # illegal Windows chars + # (problematic)
    $s = $s -replace '"', ''               # quotes
    $s = $s.Trim()
    $s = $s -replace '\s+', ' '
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120).Trim() }
    if (-not $s) { return 'Unknown' }
    return $s
}

function Escape-Xml($s) {
    if (-not $s) { return '' }
    return $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

# Load missing list
$all = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Sort: high confidence first, then medium
$sorted = $all | Sort-Object { if ($_.confidence -eq 'high') { 0 } else { 1 } }, artist, title

# Load completed slugs
$done = @{}
if (Test-Path $progressPath) {
    Get-Content $progressPath | ForEach-Object { $done[$_.Trim()] = $true }
}

# Filter to not-yet-done
$pending = $sorted | Where-Object { -not $done.ContainsKey($_.slug) }

$total = $pending.Count
$start = $BatchNumber * $BatchSize
$batch = $pending | Select-Object -Skip $start -First $BatchSize

Write-Host "BATCH $($BatchNumber): processing $($batch.Count) of $total pending (total list: $($all.Count))"

$added = 0
$failed = 0
$skipped = 0

foreach ($f in $batch) {
    try {
        $artist = Sanitize-Name $f.artist
        $title = $f.title
        if (-not $title) { $title = $f.slug }
        $safeTitle = Sanitize-Name $title
        $year = if ($f.year) { "$($f.year)" } else { '' }

        # Pick stream URL: HLS first, then download
        $url = $f.mainHlsUrl
        if (-not $url) { $url = $f.downloadUrl }
        if (-not $url) {
            Add-Content $failPath "$($f.slug)`tNO_URL" -Encoding UTF8
            $failed++
            continue
        }

        $artistDir = Join-Path $base $artist
        if (-not (Test-Path $artistDir)) {
            New-Item -ItemType Directory -Path $artistDir -Force | Out-Null
        }

        $baseName = "$artist - $safeTitle"
        if ($year) { $baseName += " ($year)" }
        $baseName = Sanitize-Name $baseName

        $strmPath = Join-Path $artistDir "$baseName.strm"
        $nfoPath = Join-Path $artistDir "$baseName.nfo"

        # Skip if files already exist (idempotent)
        if ((Test-Path $strmPath) -and (Test-Path $nfoPath)) {
            Add-Content $progressPath $f.slug -Encoding UTF8
            $skipped++
            continue
        }

        # Write .strm (URL on single line, no BOM issues)
        [System.IO.File]::WriteAllText($strmPath, $url.Trim(), [System.Text.Encoding]::UTF8)

        # Write .nfo (Kodi XML)
        $escTitle = Escape-Xml $title
        $escArtist = Escape-Xml $f.artist
        $escYear = Escape-Xml $year
        $plot = Escape-Xml "An avant-garde work by $($f.artist) ($year), preserved in the UbuWeb archive of experimental film, video, and performance art."
        $nfoContent = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>$escTitle</title>
  <originaltitle>$escTitle</originaltitle>
  <year>$escYear</year>
  <director>$escArtist</director>
  <plot>$plot</plot>
  <studio>UbuWeb</studio>
</movie>
"@
        [System.IO.File]::WriteAllText($nfoPath, $nfoContent, [System.Text.Encoding]::UTF8)

        Add-Content $progressPath $f.slug -Encoding UTF8
        $added++
    }
    catch {
        Add-Content $failPath "$($f.slug)`t$($_.Exception.Message)" -Encoding UTF8
        $failed++
    }
}

Write-Host "RESULT batch=$BatchNumber added=$added skipped=$skipped failed=$failed remaining=$($total - $start - $batch.Count)"
