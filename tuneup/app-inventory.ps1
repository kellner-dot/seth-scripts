<#
  App Inventory — scans everything installed on this PC
  -----------------------------------------------------
  Lists classic installed programs + Microsoft Store apps,
  saves to Desktop\app-inventory.txt. Share that file with Muse
  so it can learn what each app does and suggest tweaks.
  No admin needed. Makes no changes — read-only.
#>
$ErrorActionPreference = "Continue"
$Desktop = [Environment]::GetFolderPath("Desktop")
$out = Join-Path $Desktop "app-inventory.txt"

$lines = @()
$lines += "=== App Inventory for $env:COMPUTERNAME — $(Get-Date) ==="
$lines += ""

# Classic installed programs (registry)
$hives = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)
$apps = foreach ($h in $hives) {
    if (Test-Path $h) {
        Get-ChildItem $h -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.GetValue("DisplayName")
            if ($n) {
                [pscustomobject]@{
                    Name = $n
                    Publisher = $_.GetValue("Publisher")
                    Version = $_.GetValue("DisplayVersion")
                }
            }
        }
    }
}
$apps = $apps | Sort-Object Name -Unique
$lines += "--- Installed programs ($($apps.Count)) ---"
foreach ($a in $apps) {
    $pub = if ($a.Publisher) { " [$($a.Publisher)]" } else { "" }
    $ver = if ($a.Version) { " v$($a.Version)" } else { "" }
    $lines += "$($a.Name)$ver$pub"
}

# Microsoft Store apps (user-installed, skip system frameworks)
$lines += ""
$lines += "--- Microsoft Store apps ---"
try {
    $store = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.SignatureKind -ne "System" -and $_.Name -notlike "*Microsoft.Windows*" -and $_.Name -notlike "*Microsoft.VCLibs*" -and $_.Name -notlike "*Microsoft.NET*" } |
        Sort-Object Name -Unique
    foreach ($s in $store) { $lines += "$($s.Name) [$($s.Publisher)]" }
    if (-not $store) { $lines += "(none found)" }
} catch { $lines += "(could not enumerate: $_)" }

$lines | Out-File $out -Encoding utf8
Write-Host ""
Write-Host "Inventory saved: Desktop\app-inventory.txt ($($apps.Count) programs)" -ForegroundColor Green
Write-Host "Send that file to Muse (attach it in chat) and I'll study every app." -ForegroundColor Cyan
Write-Host ""
pause
