# KaviGuard-Mailbox.ps1 - v1.4.0
# Unattended command poller for KaviGuard. Runs with zero AI.
#
# Every 15 minutes it signs in to Gmail over IMAP (app password, DPAPI-encrypted
# on this PC only), looks in the "kavi-mail" label for UNREAD messages with a
# subject like:  [kavi-mail] from:kavi4 to:kaviguard re:scan
# It runs a STRICT whitelist of commands (never executes email content), emails
# the result back to the kavi-mail label, then archives the command message.
#
# Whitelisted commands (email body, plain text):
#   COMMAND: STATUS          - KaviGuard status output
#   COMMAND: VERSION         - version string
#   COMMAND: LOG             - last 25 lines of kaviguard.log
#   COMMAND: SCAN QUICK      - starts a Defender quick scan (detached)
#   COMMAND: SCAN FULL       - starts a Defender full scan (detached)
#   COMMAND: EXCLUDE ADD     - with second line  ARG: C:\path\to\dir
#   COMMAND: EXCLUDE REMOVE  - with second line  ARG: C:\path\to\dir

$ErrorActionPreference = "Continue"

$InstallDir = "C:\Tools\KaviGuard"
$BoxDir     = Join-Path $InstallDir "mailbox"
$LogFile    = Join-Path $InstallDir "logs\mailbox.log"
$LockFile   = Join-Path $BoxDir "mailbox.lock"
$CredFile   = Join-Path $BoxDir "cred.bin"
$CfgFile    = Join-Path $BoxDir "config.json"
$KGScript   = Join-Path $InstallDir "KaviGuard.ps1"
$Ver        = "1.4.0"

function Write-MBLog {
    param([string]$Msg)
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $LogFile -Value "$ts $Msg" -Encoding ASCII -ErrorAction SilentlyContinue
    } catch {}
}

function Show-MBToast {
    param([string]$Title, [string]$Body)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $safe = $Body -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
        $xml = "<toast><visual><binding template='ToastGeneric'><text>$Title</text><text>$safe</text></binding></visual></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("KaviGuard").Show($toast)
    } catch {}
}

function Get-MBConfig {
    $cfg = [pscustomobject]@{
        email          = "sethryankellner@gmail.com"
        label          = "kavi-mail"
        allowedSenders = @("sethryankellner@gmail.com","sethrkellner@gmail.com","sethrkellner1980@gmail.com","kellnerseth1980@gmail.com")
    }
    if (Test-Path $CfgFile) {
        try { $j = Get-Content $CfgFile -Raw | ConvertFrom-Json; if ($j.email) { $cfg.email = [string]$j.email }; if ($j.label) { $cfg.label = [string]$j.label }; if ($j.allowedSenders) { $cfg.allowedSenders = @($j.allowedSenders) } } catch {}
    }
    return $cfg
}

function Get-MBPassword {
    $enc = (Get-Content $CredFile -Raw -ErrorAction Stop).Trim()
    $sec = ConvertTo-SecureString $enc -ErrorAction Stop
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -replace '\s','') }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---------- raw IMAP over TLS ----------
$script:ImapTag = 0
function Send-Imap {
    param($Writer, $Reader, [string]$Command)
    $script:ImapTag++
    $tag = "a{0:d3}" -f $script:ImapTag
    $Writer.WriteLine("$tag $Command")
    $lines = @()
    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { break }
        if ($line -match '\{(\d+)\}$') {
            $n = [int]$Matches[1]
            $buf = New-Object char[] $n
            $got = 0
            while ($got -lt $n) {
                $r = $Reader.Read($buf, $got, $n - $got)
                if ($r -le 0) { break }
                $got += $r
            }
            if ($got -gt 0) { $lines += ((-join $buf[0..($got-1)]) -split "`r?`n") }
            continue
        }
        $lines += $line
        if ($line.StartsWith("$tag ")) { break }
    }
    $last = if ($lines.Count -gt 0) { $lines[-1] } else { "" }
    return @{ Lines = $lines; Ok = ($last -match "^$tag OK") }
}

function Connect-Imap {
    param([string]$Email, [string]$Pass)
    $tcp = New-Object Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect("imap.gmail.com", 993, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(25000)) { throw "IMAP connect timed out" }
    $tcp.EndConnect($iar)
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)
    $ssl.AuthenticateAsClient("imap.gmail.com")
    $enc = [Text.Encoding]::ASCII
    $reader = New-Object IO.StreamReader($ssl, $enc)
    $writer = New-Object IO.StreamWriter($ssl, $enc)
    $writer.AutoFlush = $true
    [void]$reader.ReadLine()  # greeting
    $login = Send-Imap $writer $reader "LOGIN `"$Email`" `"$Pass`""
    if (-not $login.Ok) { throw "IMAP login failed" }
    return @{ Tcp = $tcp; Ssl = $ssl; Reader = $reader; Writer = $writer }
}

function Close-Imap {
    param($Conn)
    try {
        $script:ImapTag++
        $tag = "a{0:d3}" -f $script:ImapTag
        $Conn.Writer.WriteLine("$tag LOGOUT")
    } catch {}
    try { $Conn.Ssl.Close() } catch {}
    try { $Conn.Tcp.Close() } catch {}
}

function Get-ImapUids {
    param($Conn, [string]$Label)
    $sel = Send-Imap $Conn.Writer $Conn.Reader "SELECT `"$Label`""
    if (-not $sel.Ok) { throw "SELECT $Label failed" }
    $sr = Send-Imap $Conn.Writer $Conn.Reader "UID SEARCH UNSEEN"
    $uids = @()
    foreach ($l in $sr.Lines) {
        if ($l -match '^\* SEARCH ?(.*)$') {
            $uids += $Matches[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        }
    }
    return $uids
}

function Get-MessageHeader {
    param($Conn, [string]$Uid)
    $r = Send-Imap $Conn.Writer $Conn.Reader "UID FETCH $Uid (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])"
    $from = ""; $subj = ""
    foreach ($l in $r.Lines) {
        if ($l -match '^(?i)From:\s*(.+?)\s*$') { $from = $Matches[1] }
        elseif ($l -match '^(?i)Subject:\s*(.+?)\s*$') { $subj = $Matches[1] }
    }
    return @{ From = $from; Subject = $subj }
}

function Get-MessageBody {
    param($Conn, [string]$Uid)
    $r = Send-Imap $Conn.Writer $Conn.Reader "UID FETCH $Uid (BODY.PEEK[TEXT])"
    $body = ($r.Lines -join "`n")
    $body = $body -replace "=\r?\n", ""   # unfold quoted-printable soft breaks
    return $body
}

function Set-MessageDone {
    param($Conn, [string]$Uid, [string]$Label)
    # NOTE: Archive-ResultMail leaves INBOX selected, and UIDs are per-mailbox,
    # so re-select the command label first or we mark the wrong message (or none).
    $sel = Send-Imap $Conn.Writer $Conn.Reader "SELECT `"$Label`""
    if (-not $sel.Ok) { Write-MBLog "Set-MessageDone: SELECT $Label failed"; return }
    $r1 = Send-Imap $Conn.Writer $Conn.Reader "UID STORE $Uid +FLAGS (\Seen)"
    $r2 = Send-Imap $Conn.Writer $Conn.Reader "UID STORE $Uid -X-GM-LABELS ($Label)"
    if (-not $r1.Ok -or -not $r2.Ok) { Write-MBLog "Set-MessageDone: STORE failed for UID $Uid" }
}

# ---------- command execution (strict whitelist) ----------
function Invoke-KGTool {
    param([string[]]$ToolArgs, [switch]$Detached)
    if ($Detached) {
        $a = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$KGScript) + $ToolArgs
        Start-Process "powershell.exe" -ArgumentList $a | Out-Null
        return "started (detached)"
    }
    $a = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$KGScript) + $ToolArgs
    $out = & powershell.exe $a 2>&1 | Out-String
    if ($out.Length -gt 8000) { $out = $out.Substring(0, 8000) + "`n...[truncated]" }
    return $out
}

function Invoke-MailboxCommand {
    param([string]$Cmd, [string]$Arg)
    switch ($Cmd) {
        "STATUS"        { return Invoke-KGTool @("-Status") }
        "VERSION"       { return "KaviGuard-Mailbox $Ver" }
        "LOG"           {
            $lf = Join-Path $InstallDir "logs\kaviguard.log"
            if (Test-Path $lf) { return (Get-Content $lf -Tail 25 -ErrorAction SilentlyContinue | Out-String) }
            return "no kaviguard.log yet"
        }
        "SCAN QUICK"    { return "quick scan " + (Invoke-KGTool @("-ScanNow","Quick") -Detached) + " - send COMMAND: LOG later to check results" }
        "SCAN FULL"     { return "full scan " + (Invoke-KGTool @("-ScanNow","Full") -Detached) + " - send COMMAND: LOG later to check results" }
        "SCAN PATH"     {
            if ($Arg -match '^[A-Za-z]:\\' -and $Arg -notmatch '\.\.') { return "path scan " + (Invoke-KGTool @("-ScanPath",$Arg) -Detached) + " - send COMMAND: LOG later to check results" }
            return "rejected: bad path [$Arg]"
        }
        "TUNEUP"        { return Invoke-KGTool @("-TuneUp") }
        "EXCLUDE ADD"   {
            if ($Arg -match '^[A-Za-z]:\\' -and $Arg -notmatch '\.\.') { return Invoke-KGTool @("-AddExclusion",$Arg) }
            return "rejected: bad path [$Arg]"
        }
        "EXCLUDE REMOVE" {
            if ($Arg -match '^[A-Za-z]:\\' -and $Arg -notmatch '\.\.') { return Invoke-KGTool @("-RemoveExclusion",$Arg) }
            return "rejected: bad path [$Arg]"
        }
        default         { return "unknown command [$Cmd]. Valid: STATUS, VERSION, LOG, SCAN QUICK, SCAN FULL, SCAN PATH, TUNEUP, EXCLUDE ADD, EXCLUDE REMOVE" }
    }
}

function Send-ResultMail {
    param([string]$Email, [string]$Pass, [string]$ToSender, [string]$Topic, [string]$Cmd, [string]$Result, [string]$Token)
    $msg = New-Object Net.Mail.MailMessage
    $msg.From = New-Object Net.Mail.MailAddress($Email)
    $msg.To.Add($Email)
    $subj = "[kavi-mail] from:kaviguard to:$ToSender re:$Topic result #$Token"
    $msg.Subject = $subj
    $msg.Body = "Command: $Cmd`r`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n`r`n$Result"
    $smtp = New-Object Net.Mail.SmtpClient("smtp.gmail.com", 587)
    $smtp.EnableSsl = $true
    $smtp.Credentials = New-Object Net.NetworkCredential($Email, $Pass)
    $smtp.Send($msg)
    $smtp.Dispose()
    return $Token
}

function Archive-ResultMail {
    param($Conn, [string]$Token, [string]$Label)
    $sel = Send-Imap $Conn.Writer $Conn.Reader 'SELECT "INBOX"'
    if (-not $sel.Ok) { return }
    $sr = Send-Imap $Conn.Writer $Conn.Reader "UID SEARCH SUBJECT `"#$Token`""
    foreach ($l in $sr.Lines) {
        if ($l -match '^\* SEARCH ?(.*)$') {
            foreach ($u in $Matches[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
                [void](Send-Imap $Conn.Writer $Conn.Reader "UID STORE $u +X-GM-LABELS ($Label)")
                [void](Send-Imap $Conn.Writer $Conn.Reader "UID STORE $u +FLAGS (\Seen)")
                [void](Send-Imap $Conn.Writer $Conn.Reader "UID STORE $u -X-GM-LABELS (\Inbox)")
            }
        }
    }
}

# ---------- main ----------
try {
    if (-not (Test-Path $CredFile)) { Write-MBLog "no cred.bin - run the mailbox installer once"; exit }
    if (-not (Test-Path $KGScript)) { Write-MBLog "KaviGuard.ps1 missing - run the main installer first"; exit }

    if (Test-Path $LockFile) {
        $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($age.TotalMinutes -lt 30) { exit }
        Write-MBLog "stale lock overridden"
    }
    "pid=$PID $(Get-Date -Format o)" | Set-Content $LockFile -Encoding ASCII -Force

    # watchdog: keep the main watcher task alive
    try {
        $wt = Get-ScheduledTask -TaskName "KaviGuard" -ErrorAction Stop
        if ($wt.State -ne "Running") {
            Start-ScheduledTask -TaskName "KaviGuard" -ErrorAction Stop
            Write-MBLog "watcher task was not running - restarted"
        }
    } catch { Write-MBLog "watcher check: $($_.Exception.Message)" }

    $cfg = Get-MBConfig
    $pass = Get-MBPassword
    $conn = $null
    try {
        $conn = Connect-Imap $cfg.email $pass
        $uids = Get-ImapUids $conn $cfg.label
        foreach ($uid in $uids) {
            $hdr = Get-MessageHeader $conn $uid
            $subj = $hdr.Subject
            if ($subj -notlike "*[kavi-mail]*" -or $subj -notlike "*to:kaviguard*") { continue }
            $okSender = $false
            foreach ($a in $cfg.allowedSenders) { if ($hdr.From -like "*$a*") { $okSender = $true } }
            if (-not $okSender) { Write-MBLog "ignored command from unauthorized sender: $($hdr.From)"; continue }

            $body = Get-MessageBody $conn $uid
            $cmd = ""; $carg = ""
            foreach ($l in ($body -split "`n")) {
                if ($l -match '^\s*COMMAND\s*:\s*(.+?)\s*$') { $cmd = $Matches[1].ToUpper().Trim() }
                elseif ($l -match '^\s*ARG\s*:\s*(.+?)\s*$') { $carg = $Matches[1].Trim() }
            }
            $sender = "kavi"; $topic = "command"
            if ($subj -match 'from:(\S+)') { $sender = $Matches[1] }
            if ($subj -match 're:(.+?)(?:\s+result|\s*$)') { $topic = $Matches[1].Trim() }

            if (-not $cmd) {
                Write-MBLog "no COMMAND in message from $sender - archived"
                Set-MessageDone $conn $uid $cfg.label
                continue
            }

            Write-MBLog "executing [$cmd] from $sender"
            $result = Invoke-MailboxCommand $cmd $carg
            $token = "KG-" + (Get-Date -Format "yyyyMMddHHmmss") + "-" + $uid
            try {
                Send-ResultMail $cfg.email $pass $sender $topic $cmd $result $token | Out-Null
                Archive-ResultMail $conn $token $cfg.label
                Write-MBLog "result mailed for [$cmd] from $sender"
            } catch {
                Write-MBLog "result mail failed: $($_.Exception.Message)"
            }
            Set-MessageDone $conn $uid $cfg.label
            Show-MBToast "KaviGuard" "Ran $cmd (from $sender) - result sent to kavi-mail."
        }
    } finally {
        if ($conn) { Close-Imap $conn }
        $pass = $null
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
} catch {
    Write-MBLog "poller error: $($_.Exception.Message)"
    try { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}
