#Requires -RunAsAdministrator
<#
.SYNOPSIS  Installs the KaviGuard mailbox poller (unattended kavi-mail commands).
.NOTES     One paste. Run AFTER the main KaviGuard install. You will paste a
           Gmail app password once; it is encrypted on this PC only (DPAPI)
           and never leaves it.
#>
param(
    [string]$PollerUrl = ""
)

$ErrorActionPreference = "Stop"

$InstallDir = "C:\Tools\KaviGuard"
$BoxDir     = Join-Path $InstallDir "mailbox"

if (-not (Test-Path (Join-Path $InstallDir "KaviGuard.ps1"))) {
    Write-Host "KaviGuard.ps1 not found - run the main KaviGuard install paste first, then this one."
    return
}
if (-not $PollerUrl) {
    Write-Host "Missing -PollerUrl. Re-copy the paste from the chat - it includes the download link."
    return
}

New-Item $BoxDir -ItemType Directory -Force | Out-Null
Write-Host "Downloading mailbox poller ..."
Invoke-WebRequest -Uri $PollerUrl -OutFile (Join-Path $BoxDir "KaviGuard-Mailbox.ps1") -UseBasicParsing

Write-Host ""
Write-Host "Make a Gmail app password (one time, about a minute):"
Write-Host "  1. Go to myaccount.google.com -> Security"
Write-Host "  2. Open 2-Step Verification (turn it on if it is off)"
Write-Host "  3. At the bottom open App passwords -> name it KaviGuard -> Create"
Write-Host "  4. Copy the 16-letter code"
Write-Host ""

$email = Read-Host "Your Gmail address [sethryankellner@gmail.com]"
if (-not $email) { $email = "sethryankellner@gmail.com" }
$sec = Read-Host "Paste the 16-letter app password (typing stays hidden)" -AsSecureString
if ($sec.Length -eq 0) { Write-Host "Empty - stopped, nothing saved."; return }

# strip spaces so pasting "xxxx xxxx xxxx xxxx" works too
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) -replace '\s','')
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
$sec = ConvertTo-SecureString $plain -AsPlainText -Force
$plain = $null

ConvertFrom-SecureString $sec | Set-Content (Join-Path $BoxDir "cred.bin") -Encoding ASCII
$sec = $null

$cfg = @{
    email          = $email
    label          = "kavi-mail"
    allowedSenders = @("sethryankellner@gmail.com","sethrkellner@gmail.com","sethrkellner1980@gmail.com","kellnerseth1980@gmail.com")
} | ConvertTo-Json
Set-Content (Join-Path $BoxDir "config.json") $cfg -Encoding ASCII

$tr  = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BoxDir "KaviGuard-Mailbox.ps1") + '"'
$user = "$env:USERDOMAIN\$env:USERNAME"
schtasks /create /tn "KaviGuard-Mailbox" /tr $tr /sc minute /mo 15 /ru $user /it /rl highest /f | Out-Null
schtasks /run /tn "KaviGuard-Mailbox" | Out-Null

Write-Host ""
Write-Host "DONE. The mailbox poller runs every 15 minutes - no AI needed."
Write-Host "Done = a scheduled task named KaviGuard-Mailbox exists, and"
Write-Host "  C:\Tools\KaviGuard\logs\mailbox.log gets new lines."
Write-Host ""
Write-Host "Test it: any Kavi sends an email to $email with subject"
Write-Host "  [kavi-mail] from:kavi4 to:kaviguard re:test"
Write-Host "and body:  COMMAND: VERSION"
Write-Host "The answer comes back as a kavi-mail email within ~15 minutes."
Write-Host ""
Write-Host "# Uninstall the poller (paste if ever needed):"
Write-Host "# schtasks /delete /tn KaviGuard-Mailbox /f"
Write-Host "# Remove-Item 'C:\Tools\KaviGuard\mailbox' -Recurse -Force"
